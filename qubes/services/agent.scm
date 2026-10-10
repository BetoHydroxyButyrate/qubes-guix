;;; qubes/services/agent.scm — Qubes OS guest integration as one service.
;;;
;;; Usage in config.scm:
;;;   (use-modules (qubes services agent))
;;;   (kernel-arguments (append %qubes-kernel-arguments '("quiet")))
;;;   (services (cons (service qubes-guest-service-type) ...))
;;;   ;; and put your user in the "qubes" supplementary group.
;;;
;;; Everything else — daemons, PAM, udev, /etc/qubes-rpc, setuid, runtime
;;; dirs, kernel modules, packages — is pulled in by the service.

(define-module (qubes services agent)
  #:use-module (gnu services)
  #:use-module (gnu services base)          ; udev-rule, udev-service-type
  #:use-module (gnu services linux)         ; kernel-module-loader-service-type
  #:use-module (gnu services shepherd)
  #:use-module (gnu system pam)
  #:use-module (gnu system privilege)       ; privileged-program
  #:use-module (gnu system shadow)          ; user-group
  #:use-module (gnu packages pulseaudio)     ; pactl/paplay for the vchan sink
  #:use-module (gnu packages linux)          ; iproute, util-linux, e2fsprogs
  #:use-module (gnu system file-systems)     ; /rw and /home (template?)
  #:use-module (gnu packages base)           ; coreutils
  #:use-module (gnu packages bash)           ; bash-minimal
  #:use-module (guix gexp)
  #:use-module (guix packages)              ; qubes-guix-update
  #:use-module (guix build-system trivial)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix records)
  #:use-module (gnu packages compression)    ; gzip (zcat /proc/config.gz)
  #:use-module (gnu packages gnupg)          ; gpg for split-gpg2
  #:use-module (qubes packages linux-utils)  ; meminfo-writer
  #:use-module (qubes packages qrexec)
  #:use-module (qubes packages qubesdb)
  #:use-module (qubes packages core-agent)
  #:use-module (qubes packages gui)
  #:use-module (qubes packages ctap)        ; qctap-proxy (U2F/FIDO2)
  #:use-module (qubes packages split-gpg)   ; split-gpg2 client
  #:export (qubes-guest-configuration
            qubes-guest-configuration?
            qubes-guest-network?
            qubes-guest-template?
            qubes-guest-service-type
            %qubes-kernel-arguments))

;; Modern kernels restrict privcmd hypercalls for guests; without this,
;; every libxenctrl/vchan call fails with EPERM (PORT-NOTES: the qrexec fix).
(define %qubes-kernel-arguments
  '("xen_privcmd.unrestricted=1"))

(define-record-type* <qubes-guest-configuration>
  qubes-guest-configuration make-qubes-guest-configuration
  qubes-guest-configuration?
  (qrexec     qubes-guest-qrexec     (default qubes-core-qrexec))
  (qubesdb    qubes-guest-qubesdb    (default qubes-core-qubesdb))
  (core-agent qubes-guest-core-agent (default qubes-core-agent))
  (gui-agent  qubes-guest-gui-agent  (default qubes-gui-agent))
  ;; #f: no GUI agent (headless qube; qrexec, qubesdb, file copy still work).
  (gui?       qubes-guest-gui?       (default #t))
  ;; #t: configure the uplink from qubesdb and provide 'networking (replaces
  ;; static-networking-service-type — do not use both).
  (network?   qubes-guest-network?   (default #t))
  (network-interface qubes-guest-network-interface (default "eth0"))
  ;; U2F/FIDO2 proxy: the qube holding the real security key, or #f for no
  ;; proxy. Runs only when dom0 enables the qube's qubes-ctap-proxy (or
  ;; legacy qubes-u2f-proxy) service.
  (ctap       qubes-guest-ctap       (default qubes-ctap))
  (ctap-backend qubes-guest-ctap-backend (default "sys-usb"))
  ;; split-gpg2 client (qubes.Gpg2), or #f. Runs in the user's Qubes session
  ;; only when dom0 enables the qube's split-gpg2-client service.
  (split-gpg2 qubes-guest-split-gpg2 (default qubes-split-gpg2-client))
  ;; #t: this system is a Qubes TemplateVM, or an AppVM based on one (they
  ;; share this configuration). Adds what upstream's mount-dirs.sh and
  ;; initramfs do: /home on the private volume (/rw/home), swap on the
  ;; volatile volume, the hostname from qubesdb, and updates through
  ;; qubes.UpdatesProxy. Needs a single-partition root (no separate /home).
  (template? qubes-guest-template? (default #f))
  ;; Desktop files (basenames) dom0 puts in the Qubes menu by default for
  ;; this qube and the AppVMs based on it (feature default-menu-items).
  ;; Only those present in the system profile are requested. Without it,
  ;; dom0 lists every application (e.g. all of Xfce's settings dialogs).
  (default-menu-items qubes-guest-default-menu-items
                      (default '("xfce4-terminal.desktop" "thunar.desktop"
                                 "Thunar.desktop" "Alacritty.desktop"
                                 "firefox.desktop" "icecat.desktop"
                                 "emacs.desktop" "mousepad.desktop"
                                 "org.xfce.mousepad.desktop"))))

(define %xen-modules
  ;; xen-privcmd is the critical one (libxenctrl's xencall).
  '("xen-privcmd" "xenfs" "xen-evtchn" "xen-gntdev" "xen-gntalloc"))

;; Unprivileged vchan servers (qvm-copy, the GUI agent) need these; the
;; default user is in "qubes" (upstream linux-utils udev-qubes-misc.rules).
;; Balloon-added memory arrives offline; online it so dom0's qmemman can
;; grow the qube past its initial RAM (upstream misc/50-qubes-mem-hotplug).
(define %qubes-mem-hotplug-udev-rule
  (udev-rule "50-qubes-mem-hotplug.rules"
             "SUBSYSTEM==\"memory\", ACTION==\"add\", ATTR{state}==\"offline\", ATTR{state}=\"online\"\n"))

;; qctap-proxy's virtual key appears as /dev/hidrawN; the browser (running
;; as the user, who is in "qubes") must open it (upstream
;; 60-qctap-hidraw.rules, minus its blanket rule for raw USB devices).
(define %qubes-ctap-udev-rule
  (udev-rule "60-qctap-hidraw.rules"
             "ACTION!=\"remove\", SUBSYSTEM==\"hidraw\", MODE=\"0660\", GROUP=\"qubes\"\n"))

(define %qubes-xen-udev-rule
  (udev-rule "90-qubes-xen.rules"
             (string-append
              "KERNEL==\"xen/evtchn\", MODE=\"0660\", GROUP=\"qubes\"\n"
              "KERNEL==\"xen/gntdev\", MODE=\"0660\", GROUP=\"qubes\"\n"
              "KERNEL==\"xen/gntalloc\", MODE=\"0660\", GROUP=\"qubes\"\n"
              "KERNEL==\"xen/privcmd\", MODE=\"0660\", GROUP=\"qubes\"\n"
              "KERNEL==\"xen/xenbus\", MODE=\"0660\", GROUP=\"qubes\"\n"
              "KERNEL==\"xen/hypercall\", MODE=\"0660\", GROUP=\"qubes\"\n")))

;; qrexec-agent and qubes-gui-runuser both open PAM sessions as root for the
;; target user; same minimal stack as upstream (rootok + unix).
(define (qubes-pam-service name)
  (pam-service
   (name name)
   (auth    (list (pam-entry (control "sufficient") (module "pam_rootok.so"))))
   (account (list (pam-entry (control "required")   (module "pam_unix.so"))))
   (session (list (pam-entry (control "required")   (module "pam_unix.so"))))))

(define (qubes-pam-services config)
  (cons (qubes-pam-service "qrexec")
        (if (qubes-guest-gui? config)
            (list (qubes-pam-service "qubes-gui-agent"))
            '())))

(define (qubes-network-script config)
  ;; Port of core-agent network/setup-ip (non-NetworkManager path) for a
  ;; client qube: address, gateway pinned to the netvm's fixed MAC, routes,
  ;; resolv.conf — all from qubesdb, so a netvm/IP change in dom0 just works.
  (let ((qdb   (file-append (qubes-guest-qubesdb config) "/bin/qubesdb-read"))
        (ip    (file-append iproute "/sbin/ip"))
        (tmo   (file-append coreutils "/bin/timeout"))
        (sleep (file-append coreutils "/bin/sleep"))
        (cat   (file-append coreutils "/bin/cat"))
        (rm    (file-append coreutils "/bin/rm")))
    (mixed-text-file "qubes-setup-network" "
set -u
IF=" (qubes-guest-network-interface config) "
QDB=" qdb "
IP=" ip "
qsvc() { v=$($QDB /qubes-service/$1 2>/dev/null) && [ \"$v\" = 1 ]; }

# No netvm => no /qubes-ip: leave the uplink down but still provide
# 'networking. -w waits for the key (qubesdb sync from dom0).
if ! " tmo " 30 $QDB -w /qubes-ip >/dev/null 2>&1; then
    echo \"qubes-setup-network: no /qubes-ip in qubesdb; uplink not configured\"
    exit 0
fi
i=0
while [ ! -e /sys/class/net/$IF ] && [ $i -lt 100 ]; do " sleep " 0.1; i=$((i+1)); done
MAC=$(" cat " /sys/class/net/$IF/address)

prefix=/net-config/$MAC/
$QDB \"${prefix}ip\" >/dev/null 2>&1 || prefix=/qubes-
custom=false
$QDB \"/net-config/$MAC/custom\" >/dev/null 2>&1 && custom=true

ip4=$($QDB \"${prefix}ip\")
netmask=$($QDB --default=255.255.255.255 \"${prefix}netmask\")
gateway=$($QDB \"${prefix}gateway\")
ip6=$($QDB \"${prefix}ip6\" 2>/dev/null) || ip6=
netmask6=$($QDB --default=128 \"${prefix}netmask6\")
gateway6=$($QDB --default= \"${prefix}gateway6\")
dns1=$($QDB /qubes-primary-dns 2>/dev/null) || dns1=$gateway
dns2=$($QDB /qubes-secondary-dns 2>/dev/null) || dns2=

$IP address replace \"$ip4/$netmask\" dev $IF
[ \"$custom\" = false ] && $IP neighbour replace to \"$gateway\" dev $IF \\
    lladdr fe:ff:ff:ff:ff:ff nud permanent
if [ -n \"$ip6\" ]; then
    $IP address replace \"$ip6/$netmask6\" dev $IF
    [ -n \"$gateway6\" ] && [ \"$custom\" = false ] && \\
        $IP neighbour replace to \"$gateway6\" dev $IF \\
            lladdr fe:ff:ff:ff:ff:ff nud permanent
fi
$IP link set dev $IF group 1 up
if [ -n \"$gateway\" ]; then
    $IP route replace to unicast \"$gateway\" dev $IF scope link
    if ! qsvc disable-default-route; then
        $IP route replace to unicast default via \"$gateway\" dev $IF onlink
        [ -n \"$gateway6\" ] && \\
            $IP route replace to unicast default via \"$gateway6\" dev $IF onlink
    fi
fi
if ! qsvc disable-dns-server; then
    " rm " -f /etc/resolv.conf
    { echo \"nameserver $dns1\"; [ -n \"$dns2\" ] && echo \"nameserver $dns2\"; } \\
        > /etc/resolv.conf
fi
echo \"qubes-setup-network: $IF $ip4/$netmask via $gateway dns $dns1 $dns2\"
")))

(define (qubes-network-shepherd-service config)
  (shepherd-service
   (documentation "Configure the Qubes uplink from qubesdb (IP, gateway,
DNS).")
   (provision '(networking qubes-network))
   (requirement '(qubesdb-daemon udev))
   (one-shot? #t)
   (start #~(lambda _
              (zero? (system* #$(file-append bash-minimal "/bin/sh")
                              #$(qubes-network-script config)))))))

(define (qubesdb-read-path config)
  (file-append (qubes-guest-qubesdb config) "/bin/qubesdb-read"))

(define (qubes-features-script config)
  ;; Port of core-agent post-install.d/10-qubes-core-agent-features.sh and
  ;; qvm-features-request: write /features-request/* into qubesdb, then ask
  ;; dom0 to apply them (accepted for standalone and template qubes). Run on
  ;; every boot so changes (e.g. gui? toggled) propagate.
  (let ((qwrite (file-append (qubes-guest-qubesdb config) "/bin/qubesdb-write"))
        (client (file-append (qubes-guest-qrexec config)
                             "/usr/bin/qrexec-client-vm"))
        (zcat   (file-append gzip "/bin/zcat"))
        (grep*  (file-append grep "/bin/grep")))
    (mixed-text-file "qubes-features-request" "
set -u
req() { " qwrite " \"/features-request/$1\" \"$2\"; }
req qubes-agent-version 4.3
req os Linux
req os-distribution guix
req qrexec 1
req vmexec 1
req gui " (if (qubes-guest-gui? config) "1" "0") "
req qubes-firewall 0
req supported-service.meminfo-writer 1
" (if (qubes-guest-ctap-backend config)
       "req supported-service.qubes-ctap-proxy 1\nreq supported-service.qubes-u2f-proxy 1\n"
       "") (if (qubes-guest-split-gpg2 config)
       "req supported-service.split-gpg2-client 1\n"
       "") "menu=
for d in " (string-join (qubes-guest-default-menu-items config) " ") "; do
    [ -e /run/current-system/profile/share/applications/$d ] && menu=\"$menu${menu:+ }$d\"
done
[ -n \"$menu\" ] && req default-menu-items \"$menu\"
hp=
if [ -r /proc/config.gz ] && " zcat " /proc/config.gz | " grep* " -q '^CONFIG_XEN_BALLOON_MEMORY_HOTPLUG=y'; then
    hp=1
fi
req supported-feature.memory-hotplug \"$hp\"
exec " client " dom0 qubes.FeaturesRequest </dev/null >/dev/null
")))

(define %meminfo-supervisor
  ;; meminfo-writer (pidfile mode) daemonizes and waits for SIGUSR1, which
  ;; qrexec-agent sends ONCE per boot on its first request; a respawned
  ;; instance would wait for a wake that never comes (see PORT-NOTES:
  ;; swapinfo, which also killed every instance until patched). So: keep
  ;; the pidfile the agent expects, wake it ourselves after a delay, and
  ;; restart it if it dies. Extra SIGUSR1s are harmless (handler stays).
  (mixed-text-file "qubes-meminfo-supervisor" "
set -u
M=" (file-append qubes-linux-utils "/bin/meminfo-writer") "
PIDF=/var/run/meminfo-writer.pid
child=
trap '[ -n \"$child\" ] && kill \"$child\" 2>/dev/null; exit 0' TERM INT
while :; do
    rm -f $PIDF
    if $M 30000 100000 $PIDF && child=$(cat $PIDF 2>/dev/null) && [ -n \"$child\" ]; then
        sleep 10 & wait $!
        kill -USR1 \"$child\" 2>/dev/null
        while kill -0 \"$child\" 2>/dev/null; do sleep 5 & wait $!; done
        echo \"meminfo-writer $child exited; restarting in 10s\"
    fi
    child=
    sleep 10 & wait $!
done
"))

(define (qubes-extra-shepherd-services config)
  (list
   (shepherd-service
    (documentation "Advertise this qube's capabilities to dom0
(qvm-features: qrexec, vmexec, gui, os, memory hotplug...).")
    (provision '(qubes-features-request))
    (requirement '(qrexec-agent qubesdb-daemon))
    (one-shot? #t)
    (start #~(lambda _
               (zero? (system* #$(file-append bash-minimal "/bin/sh")
                               #$(qubes-features-script config))))))
   (shepherd-service
    (documentation "Report memory usage to xenstore for dom0's memory
balancer (qmemman).")
    (provision '(qubes-meminfo-writer))
    (requirement '(qubesdb-daemon))
    ;; Upstream VM mode: with a pidfile it daemonizes, then WAITS for
    ;; SIGUSR1, which qrexec-agent sends on its first request after boot
    ;; (wake_meminfo_writer, qrexec-agent.c; pidfile path is compiled into
    ;; the agent as /var/run/meminfo-writer.pid). Without the pidfile it
    ;; forks after the first report and exits 0 -> shepherd respawn loop.
    ;; Only when dom0 enabled qubes-service meminfo-writer, i.e. the qube is
    ;; included in memory balancing (upstream: qsvc meminfo-writer). Otherwise
    ;; dom0 doesn't make memory/meminfo writable and it dies with exit 1
    ;; ("error writing meminfo to xenstore ?", syslog only).
    (start #~(lambda args
               (false-if-exception (delete-file "/var/run/meminfo-writer.pid"))
               (if (zero? (system* #$(file-append bash-minimal "/bin/sh") "-c"
                                   (string-append
                                    #$(file-append coreutils "/bin/timeout")
                                    " 30 " #$(qubesdb-read-path config)
                                    " -w /name >/dev/null && [ \"$("
                                    #$(qubesdb-read-path config)
                                    " /qubes-service/meminfo-writer 2>/dev/null)\" = 1 ]")))
                   (apply (make-forkexec-constructor
                           (list #$(file-append bash-minimal "/bin/sh")
                                 #$%meminfo-supervisor)
                           #:environment-variables
                           '("PATH=/run/current-system/profile/bin")
                           #:log-file "/var/log/qubes/meminfo-writer.log")
                          args)
                   (begin
                     (format #t "meminfo-writer: memory balancing disabled in dom0~%")
                     #t))))
    ;; Started as plain #t (no process) when balancing is off.
    (stop #~(lambda (running . args)
              (if (eq? running #t)
                  #f
                  (apply (make-kill-destructor) running args))))
    (respawn? #t))))

(define (qubes-ctap-shepherd-service config)
  (let ((qdb     (qubesdb-read-path config))
        (backend (qubes-guest-ctap-backend config)))
    (shepherd-service
     (documentation (string-append "U2F/FIDO2 proxy: virtual security key
(uhid) whose requests go over qrexec to " backend "."))
     (provision '(qubes-ctap-proxy))
     (requirement '(qubesdb-daemon qrexec-agent))
     ;; Upstream unit: ConditionPathExists=|/var/run/qubes-service/
     ;; qubes-ctap-proxy or qubes-u2f-proxy (i.e. qvm-service ... on).
     (start #~(lambda args
                (if (zero? (system* #$(file-append bash-minimal "/bin/sh") "-c"
                                    (string-append
                                     #$(file-append coreutils "/bin/timeout")
                                     " 30 " #$qdb " -w /name >/dev/null && { [ \"$("
                                     #$qdb " /qubes-service/qubes-ctap-proxy 2>/dev/null)\" = 1 ] || [ \"$("
                                     #$qdb " /qubes-service/qubes-u2f-proxy 2>/dev/null)\" = 1 ]; }")))
                    (apply (make-forkexec-constructor
                            (list #$(file-append (qubes-guest-ctap config)
                                                 "/bin/qctap-proxy")
                                  #$backend)
                            #:log-file "/var/log/qubes/qctap-proxy.log")
                           args)
                    (begin
                      (format #t "qctap-proxy: qubes-ctap-proxy service not enabled in dom0~%")
                      #t))))
     ;; Started as plain #t (no process) when disabled in dom0.
     (stop #~(lambda (running . args)
               (if (eq? running #t)
                   #f
                   (apply (make-kill-destructor) running args))))
     (respawn? #t))))


;;;
;;; Template support (template? #t).
;;;

;; Private volume (xvdb). Port of upstream setup-rwdev.sh + setup-rw.sh: a
;; virgin volume (first 10 MiB zero, no signature) gets ext4; then fsck, and
;; /rw/config + /rw/home are created. A new /rw/home is seeded from the
;; root's /home (so the template keeps the home the installer made, and a new
;; AppVM starts from the template's). It runs BEFORE /rw is mounted (on a
;; scratch mount point) because the /home bind mount must stay inside the
;; 'file-systems target that user-homes waits for, and file systems with
;; shepherd-requirements are left out of that target. Always exits 0: a
;; failure here must leave the qube booting with /home on root, not hang it.
(define %qubes-rwdev-script
  (mixed-text-file "qubes-rwdev" "
set -u
PATH=" (file-append util-linux "/bin") ":" (file-append util-linux "/sbin") ":"
  (file-append e2fsprogs "/sbin") ":" (file-append diffutils "/bin") ":"
  (file-append coreutils "/bin") "
DEV=/dev/xvdb
M=/run/qubes-rw-init
if [ ! -b $DEV ]; then
    echo \"qubes-rwdev: no $DEV; /home stays on the root volume\"
    exit 0
fi
size=$(( $(blockdev --getsz $DEV) * 512 ))
[ $size -gt 10485760 ] && size=10485760
blkid -p $DEV >/dev/null 2>&1; sig=$?
if [ $sig -eq 2 ] && cmp -s -n $size $DEV /dev/zero; then
    echo \"qubes-rwdev: virgin private volume, creating ext4 on $DEV\"
    mkfs.ext4 -q -m 0 $DEV || { echo \"qubes-rwdev: mkfs.ext4 failed\"; exit 0; }
fi
fsck.ext4 -p $DEV || echo \"qubes-rwdev: fsck.ext4 -p $DEV returned $?\"
mkdir -p $M
mount -t ext4 $DEV $M || { echo \"qubes-rwdev: cannot mount $DEV\"; exit 0; }
mkdir -p $M/config
if [ ! -d $M/home ]; then
    echo \"qubes-rwdev: populating /rw/home from /home\"
    mkdir $M/home && cp -a /home/. $M/home/
fi
umount $M
exit 0
"))

(define %qubes-rw-file-system
  (file-system
    (device "/dev/xvdb")
    (mount-point "/rw")
    (type "ext4")
    (check? #f)                         ; qubes-rwdev already did
    (create-mount-point? #t)
    (mount-may-fail? #t)
    (shepherd-requirements '(qubes-rwdev))))

(define %qubes-home-file-system
  ;; No shepherd-requirements: it must be part of 'file-systems (above).
  ;; The dependency on /rw orders it after qubes-rwdev all the same.
  (file-system
    (device "/rw/home")
    (mount-point "/home")
    (type "none")
    (flags '(bind-mount))
    (check? #f)
    (mount-may-fail? #t)
    (dependencies (list %qubes-rw-file-system))))

(define (qubes-template-file-systems config)
  (if (qubes-guest-template? config)
      (list %qubes-rw-file-system %qubes-home-file-system)
      '()))

;; Volatile volume (xvdc): blank on every boot. Upstream's initramfs gives it
;; a 1 GiB swap partition (xvdc1); Guix's initramfs doesn't, so do it here.
(define %qubes-swap-script
  (mixed-text-file "qubes-volatile-swap" "
set -u
PATH=" (file-append util-linux "/bin") ":" (file-append util-linux "/sbin") ":"
  (file-append coreutils "/bin") ":" (file-append grep "/bin") "
DEV=/dev/xvdc
[ -b $DEV ] || exit 0
grep -q '^/dev/xvdc1 ' /proc/swaps && exit 0
if [ \"$(blockdev --getsz $DEV)\" -lt $(( (1024 + 2) * 2048 )) ]; then
    echo \"qubes-volatile-swap: $DEV is smaller than 1 GiB; no swap\"
    exit 0
fi
printf 'xvdc1: type=82,start=1MiB,size=1GiB\\nxvdc3: type=83\\n' | sfdisk -q $DEV \\
    || { echo \"qubes-volatile-swap: sfdisk failed\"; exit 0; }
i=0
while [ ! -b /dev/xvdc1 ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
mkswap /dev/xvdc1 >/dev/null && swapon /dev/xvdc1 \\
    && echo \"qubes-volatile-swap: swap on /dev/xvdc1\"
exit 0
"))

(define (qubes-hostname-script config)
  ;; AppVMs share the template's configuration, hence its host-name: take
  ;; the qube's own name from qubesdb instead.
  (mixed-text-file "qubes-hostname" "
n=$(" (file-append coreutils "/bin/timeout") " 30 " (qubesdb-read-path config) " -w /name) || exit 0
[ -n \"$n\" ] && echo \"$n\" > /proc/sys/kernel/hostname
exit 0
"))

(define (qubes-template-shepherd-services config)
  (let ((sh (file-append bash-minimal "/bin/sh"))
        (qdb (qubesdb-read-path config))
        (client (file-append (qubes-guest-qrexec config)
                             "/usr/bin/qrexec-client-vm")))
    (list
     (shepherd-service
      (documentation "Prepare the Qubes private volume for /rw and /home.")
      (provision '(qubes-rwdev))
      (requirement '(root-file-system udev))
      (one-shot? #t)
      (start #~(lambda _
                 (system* #$sh #$%qubes-rwdev-script)
                 #t)))
     (shepherd-service
      (documentation "Grow /rw to the private volume's size (online).")
      (provision '(qubes-rw-resize))
      (requirement '(file-system-/rw))
      (one-shot? #t)
      (start #~(lambda _
                 (when (zero? (system* #$(file-append util-linux "/bin/mountpoint")
                                       "-q" "/rw"))
                   (system* #$(file-append e2fsprogs "/sbin/resize2fs")
                            "/dev/xvdb"))
                 #t)))
     (shepherd-service
      (documentation "Swap on the Qubes volatile volume.")
      (provision '(qubes-volatile-swap))
      (requirement '(udev))
      (one-shot? #t)
      (start #~(lambda _
                 (system* #$sh #$%qubes-swap-script)
                 #t)))
     (shepherd-service
      (documentation "Set the host name to the qube's name.")
      (provision '(qubes-hostname))
      (requirement '(qubesdb-daemon))
      (one-shot? #t)
      (start #~(lambda _
                 (system* #$sh #$(qubes-hostname-script config))
                 #t)))
     ;; Upstream qubes-updates-proxy-forwarder.socket: templates have no
     ;; netvm; each connection to 127.0.0.1:8082 becomes a qubes.UpdatesProxy
     ;; call to the updates VM. Only where dom0 enabled updates-proxy-setup
     ;; (templates); then guix-daemon is pointed at it (its set-http-proxy
     ;; action), so AppVMs keep their direct network.
     (shepherd-service
      (documentation "Forward 127.0.0.1:8082 to the Qubes updates proxy and
point guix-daemon at it.")
      (provision '(qubes-updates-proxy))
      ;; NOT guix-daemon: its set-http-proxy action restarts it, and a
      ;; restart first stops everything that requires it. Required, this
      ;; service would wait for itself (it's still starting): a deadlock
      ;; that left the service 'starting' forever and hung every shutdown.
      (requirement '(qubesdb-daemon qrexec-agent loopback))
      (start #~(lambda args
                 (if (zero? (system* #$sh "-c"
                                     (string-append
                                      #$(file-append coreutils "/bin/timeout")
                                      " 30 " #$qdb " -w /name >/dev/null && [ \"$("
                                      #$qdb " /qubes-service/updates-proxy-setup 2>/dev/null)\" = 1 ]")))
                     (let ((running
                            (apply (make-inetd-constructor
                                    (list #$client "--use-stdin-socket" ""
                                          "qubes.UpdatesProxy")
                                    (list (endpoint
                                           (make-socket-address
                                            AF_INET INADDR_LOOPBACK 8082))))
                                   args)))
                       (catch #t
                         (lambda ()
                           (let ((daemon (lookup-service 'guix-daemon)))
                             (start-service daemon)
                             (perform-service-action daemon 'set-http-proxy
                                                     "http://127.0.0.1:8082")))
                         (lambda (key . rest)
                           (format #t "qubes-updates-proxy: couldn't point guix-daemon at the proxy: ~a ~s~%"
                                   key rest)))
                       running)
                     (begin
                       (format #t "qubes-updates-proxy: updates-proxy-setup not enabled in dom0~%")
                       #t))))
      (stop #~(lambda (running . args)
                (if (eq? running #t)
                    #f
                    (apply (make-inetd-destructor) running args))))))))

(define (qubes-shepherd-services config)
  (let ((qrexec  (qubes-guest-qrexec config))
        (qubesdb (qubes-guest-qubesdb config))
        (gui     (qubes-guest-gui-agent config)))
    (append
     (list
      (shepherd-service
       (documentation "QubesDB guest daemon: receives the VM's configuration
database from dom0 and serves local readers on a unix socket.")
       (provision '(qubesdb-daemon))
       (requirement '(user-processes))
       ;; Foreground build (fork patched out); exactly one argument "0".
       (start #~(make-forkexec-constructor
                 (list #$(file-append qubesdb "/bin/qubesdb-daemon") "0")
                 #:log-file "/var/log/qubes/qubesdb.dom0.log"))
       (stop #~(make-kill-destructor))
       (respawn? #t))
      (shepherd-service
       (documentation "Qubes qrexec guest agent: answers dom0's vchan
handshake; required for VM survival and qvm-run.")
       (provision '(qrexec-agent))
       (requirement '(user-processes))
       (start #~(make-forkexec-constructor
                 (list #$(file-append qrexec "/usr/lib/qubes/qrexec-agent"))
                 #:log-file "/var/log/qrexec-agent.log"))
       (stop #~(make-kill-destructor))
       (respawn? #t)))
     (if (qubes-guest-gui? config)
         (list
          (shepherd-service
           (documentation "Qubes GUI agent: seamless windows via its own
Xorg on :1 (dummyqbs + qubes drivers), relayed to the GUI domain.")
           (provision '(qubes-gui-agent))
           (requirement '(qubesdb-daemon qrexec-agent user-processes elogind))
           (start #~(make-forkexec-constructor
                     (list #$(file-append gui "/bin/qubes-gui-agent-start"))
                     #:environment-variables
                     '("PATH=/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin")
                     #:log-file "/var/log/qubes-gui-agent.log"))
           (stop #~(make-kill-destructor))
           (respawn? #t)))
         '())
     (if (qubes-guest-network? config)
         (list (qubes-network-shepherd-service config))
         '())
     (if (qubes-guest-ctap-backend config)
         (list (qubes-ctap-shepherd-service config))
         '())
     (qubes-extra-shepherd-services config)
     (if (qubes-guest-template? config)
         (qubes-template-shepherd-services config)
         '()))))

(define (qubes-etc-files config)
  (let ((core (qubes-guest-core-agent config)))
    `(("qubes-rpc" ,(file-append core "/etc/qubes-rpc"))
      ("qubes"     ,(file-append core "/etc/qubes")))))

(define (qubes-setuid-programs config)
  ;; qfile-unpacker mounts/chroots into ~/QubesIncoming; the store strips
  ;; 4755, so qubes.Filecopy calls /run/privileged/bin/qfile-unpacker.
  (list (privileged-program
         (program (file-append (qubes-guest-core-agent config)
                               "/lib/qubes/qfile-unpacker"))
         (setuid? #t))))

(define (qubes-activation config)
  #~(begin
      (use-modules (guix build utils))
      (define (force-symlink target link)
        (false-if-exception (delete-file link))
        (symlink target link))

      ;; Upstream tmpfiles: /var/run/qubes 2770 root:qubes, so the user's
      ;; qrexec-fork-server can create qrexec-server.$USER.sock.
      ;; NB: on Guix /run and /var/run are different directories.
      (mkdir-p "/var/run/qubes")
      (mkdir-p "/var/log/qubes")
      ;; /var/run is NOT a tmpfs on Guix: a pidfile from the previous boot
      ;; survives, and qrexec-agent SIGUSR1s whatever PID it names on its
      ;; first request (default action: terminate) — at boot that PID is
      ;; often this boot's meminfo-writer before it wrote its own pidfile.
      (false-if-exception (delete-file "/var/run/meminfo-writer.pid"))
      (chown "/var/run/qubes" 0 (group:gid (getgrnam "qubes")))
      (chmod "/var/run/qubes" #o2770)

      ;; qvm-shutdown / qvm-restart of an HVM: dom0 writes xenstore
      ;; control/shutdown; the kernel's Xen driver then runs the usermode
      ;; helpers /sbin/poweroff (kernel.poweroff_cmd) and /sbin/reboot
      ;; (hard-wired). Guix has no /sbin, so they failed silently.
      (mkdir-p "/sbin")
      (force-symlink "/run/current-system/profile/sbin/halt" "/sbin/poweroff")
      (force-symlink "/run/current-system/profile/sbin/reboot" "/sbin/reboot")

      ;; Extra qrexec services from packages other than core-agent (which
      ;; owns /etc/qubes-rpc). The agent searches /run/qubes-rpc first
      ;; (QREXEC_SERVICE_PATH); plain symlinks keep the one-level readlink
      ;; /dev/tcp detection working.
      (mkdir-p "/run/qubes-rpc")
      (for-each (lambda (dir)
                  (for-each (lambda (f)
                              (force-symlink
                               f (string-append "/run/qubes-rpc/" (basename f))))
                            (find-files dir)))
                '#$(if (qubes-guest-gui? config)
                       (list (file-append (qubes-guest-gui-agent config)
                                          "/etc/qubes-rpc"))
                       '()))))

;; `qubes-guix-update`: guix pull, then optionally reconfigure, through the
;; Qubes updates proxy when dom0 enabled updates-proxy-setup for this qube
;; (templates). guix-daemon is pointed at the proxy by qubes-updates-proxy,
;; but `guix pull` fetches the channels with libgit2 in the caller's own
;; process, which only follows http_proxy/https_proxy.
(define (qubes-guix-update-script config)
  (mixed-text-file "qubes-guix-update" "#!" (file-append bash-minimal "/bin/sh") "
# qubes-guix-update [-r|--reconfigure] [GUIX-PULL-ARGS...]
#   guix pull, through the Qubes updates proxy when this qube has one (a
#   template with updates-proxy-setup); with -r, then also
#   sudo guix system reconfigure ${QUBES_GUIX_CONFIG:-/etc/config.scm}
set -eu
reconfigure=0
case ${1:-} in
    -r|--reconfigure) reconfigure=1; shift;;
    -h|--help) sed -n '2,5p' \"$0\"; exit 0;;
esac
pguix pull \"$@\"
if [ \"$reconfigure\" = 1 ]; then
    guix=$HOME/.config/guix/current/bin/guix
    [ -x \"$guix\" ] || guix=guix
    # Builds and substitutes go through guix-daemon, which has the proxy.
    sudo \"$guix\" system reconfigure \"${QUBES_GUIX_CONFIG:-/etc/config.scm}\"
fi
"))

;; `pguix`: guix, through the Qubes updates proxy when this qube has one.
;; Only the commands that fetch in the caller's own process need it: pull
;; and time-machine (channels, via libgit2), download, refresh. Builds and
;; substitutes go through guix-daemon, which qubes-updates-proxy already
;; points at the proxy. Not set globally: AppVMs share this root but have no
;; proxy (and don't need one).
(define (pguix-script config)
  (mixed-text-file "pguix" "#!" (file-append bash-minimal "/bin/sh") "
# pguix ARGS...: guix ARGS, through the Qubes updates proxy when this qube
# uses one (updates-proxy-setup, i.e. a template); plain guix otherwise.
if [ \"$(" (qubesdb-read-path config) " /qubes-service/updates-proxy-setup 2>/dev/null)\" = 1 ]; then
    http_proxy=http://127.0.0.1:8082
    https_proxy=$http_proxy
    export http_proxy https_proxy
    echo \"pguix: through the Qubes updates proxy ($http_proxy)\" >&2
fi
exec guix \"$@\"
"))

(define (qubes-guix-update config)
  (package
    (name "qubes-guix-update")
    (version "0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:modules '((guix build utils))
           #:builder
           #~(begin
               (use-modules (guix build utils))
               (let ((bin (string-append #$output "/bin")))
                 (mkdir-p bin)
                 (copy-file #$(qubes-guix-update-script config)
                            (string-append bin "/qubes-guix-update"))
                 (copy-file #$(pguix-script config)
                            (string-append bin "/pguix"))
                 (for-each (lambda (f) (chmod (string-append bin "/" f) #o555))
                           '("qubes-guix-update" "pguix"))))))
    (home-page "https://github.com/BetoHydroxyButyrate/qubes-guix")
    (synopsis "guix (pull, reconfigure) through the Qubes updates proxy")
    (description "@command{pguix} runs @command{guix} through the Qubes updates
proxy when the qube uses one; @command{qubes-guix-update} runs @command{pguix
pull}, and optionally @command{guix system reconfigure}.")
    (license license:gpl3+)))

(define (qubes-packages config)
  (append (list (qubes-guest-qrexec config)
                (qubes-guest-qubesdb config)
                (qubes-guest-core-agent config)
                (qubes-guix-update config))
          (if (qubes-guest-gui? config)
              ;; pulseaudio: the agent starts it with the vchan sink; this
              ;; also puts pactl/paplay on PATH for checking audio.
              (list (qubes-guest-gui-agent config) pulseaudio)
              '())
          ;; In the profile so qubes-session finds its session.d hook; gnupg
          ;; because split-gpg2 is used through the ordinary gpg command.
          (if (and (qubes-guest-gui? config) (qubes-guest-split-gpg2 config))
              (list (qubes-guest-split-gpg2 config) gnupg)
              '())))

(define qubes-guest-service-type
  (service-type
   (name 'qubes-guest)
   (description "Integrate Guix System as a Qubes OS qube: qrexec, QubesDB,
qrexec services, file copy, and (optionally) the seamless GUI agent.")
   (extensions
    (list (service-extension shepherd-root-service-type qubes-shepherd-services)
          (service-extension pam-root-service-type qubes-pam-services)
          (service-extension etc-service-type qubes-etc-files)
          (service-extension privileged-program-service-type qubes-setuid-programs)
          (service-extension activation-service-type qubes-activation)
          (service-extension file-system-service-type
                             qubes-template-file-systems)
          (service-extension profile-service-type qubes-packages)
          (service-extension kernel-module-loader-service-type
                             (lambda (config)
                               (if (qubes-guest-ctap-backend config)
                                   (cons "uhid" %xen-modules)
                                   %xen-modules)))
          (service-extension udev-service-type
                             (lambda (config)
                               (append
                                (list %qubes-xen-udev-rule
                                      %qubes-mem-hotplug-udev-rule)
                                (if (qubes-guest-ctap-backend config)
                                    (list %qubes-ctap-udev-rule)
                                    '()))))
          (service-extension account-service-type
                             (const (list (user-group
                                           (name "qubes")
                                           (system? #t)))))))
   (default-value (qubes-guest-configuration))))
