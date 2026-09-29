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
  #:use-module (gnu packages linux)          ; iproute
  #:use-module (gnu packages base)           ; coreutils
  #:use-module (gnu packages bash)           ; bash-minimal
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (qubes packages qrexec)
  #:use-module (qubes packages qubesdb)
  #:use-module (qubes packages core-agent)
  #:use-module (qubes packages gui)
  #:export (qubes-guest-configuration
            qubes-guest-configuration?
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
  (network-interface qubes-guest-network-interface (default "eth0")))

(define %xen-modules
  ;; xen-privcmd is the critical one (libxenctrl's xencall).
  '("xen-privcmd" "xenfs" "xen-evtchn" "xen-gntdev" "xen-gntalloc"))

;; Unprivileged vchan servers (qvm-copy, the GUI agent) need these; the
;; default user is in "qubes" (upstream linux-utils udev-qubes-misc.rules).
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

(define (qubes-packages config)
  (append (list (qubes-guest-qrexec config)
                (qubes-guest-qubesdb config)
                (qubes-guest-core-agent config))
          (if (qubes-guest-gui? config)
              ;; pulseaudio: the agent starts it with the vchan sink; this
              ;; also puts pactl/paplay on PATH for checking audio.
              (list (qubes-guest-gui-agent config) pulseaudio)
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
          (service-extension profile-service-type qubes-packages)
          (service-extension kernel-module-loader-service-type
                             (const %xen-modules))
          (service-extension udev-service-type
                             (const (list %qubes-xen-udev-rule)))
          (service-extension account-service-type
                             (const (list (user-group
                                           (name "qubes")
                                           (system? #t)))))))
   (default-value (qubes-guest-configuration))))
