;;; qubes/installer.scm — the qubes-guix installer ISO.
;;;
;;; The stock Guix System installer, plus what makes it a (headless) qube:
;;; QubesDB, the qrexec agent, and the network from QubesDB. So under Qubes:
;;; - no GRUB edit: 'nomodeset' is on the kernel command line (the console on
;;;   VT3 needs it);
;;; - no network setup by hand: the address, gateway and DNS come from QubesDB
;;;   at boot, as in any qube;
;;; - no typing into the console: dom0 drives an install with
;;;   'qvm-run -u root' (qubes-guix-create --unattended), and sees its output;
;;; - this repository's guest/ scripts are in /root/qubes-guix (git, too);
;;; - its 'guix' already includes the qubes channel, and the Qubes packages a
;;;   qube needs are in its store: qubes-guix-finish-install uses that Guix
;;;   directly, with nothing to build for the Qubes agents.
;;; The installer's own dialogs (on tty1) still work, for a manual install,
;;; but only once asked for: tty1 shows a monitor instead (tmux: htop, and
;;; the network traffic per address), then a notice that dom0 drives the
;;; install, so nobody starts the dialogs by accident while an unattended
;;; install runs (installer-gate).
;;;
;;; Build it with iso/qubes-guix-iso (a Guix that includes this channel is
;;; what puts the channel into the ISO's guix), or by hand:
;;;
;;;   guix time-machine -C channels.scm -- system image -t iso9660 \
;;;     -e '((@ (qubes installer) qubes-installation-os))'
;;;
;;; #:offline? #t also puts in the ISO everything the default install
;;; (qubes-guix-install: xterm, user 'user', git) needs, and the git checkouts
;;; of the channels: that install then needs no network at all. It makes the
;;; ISO a few GiB larger.
;;;
;;; The installer never sends its features to dom0 (features-request? #f):
;;; dom0 keeps the first value a qube gives for qrexec and gui, and the
;;; installer's gui=0 would stick to the installed system.

(define-module (qubes installer)
  #:use-module (gnu)
  #:use-module (gnu system install)
  #:use-module ((gnu services base)
                #:select (kmscon-service-type kmscon-configuration))
  #:use-module ((gnu packages version-control) #:select (git))
  #:use-module ((gnu packages) #:select (specification->package))
  #:use-module ((gnu packages bash) #:select (bash-minimal))
  #:use-module ((gnu services desktop) #:select (%desktop-services))
  #:use-module ((gnu packages xorg) #:select (xterm))
  #:use-module (guix channels)
  #:use-module ((guix describe) #:select (current-channels))
  #:autoload   (guix git) (url-cache-directory %repository-cache-directory)
  #:use-module ((guix utils) #:select (cache-directory))
  #:use-module (guix gexp)
  #:use-module (qubes system)
  #:use-module (qubes services agent)
  #:use-module ((qubes packages gui) #:select (qubes-gui-agent))
  #:use-module ((qubes packages ctap) #:select (qubes-ctap))
  #:use-module ((qubes packages split-gpg) #:select (qubes-split-gpg2-client))
  #:use-module ((qubes packages split-ssh) #:select (qubes-split-ssh-client))
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 rdelim)
  #:export (qubes-installation-os
            qubes-reference-os))

;; This repository's guest scripts, copied to /root/qubes-guix/guest at boot
;; (writable, and outside /tmp, which cow-store hides).
(define %guest-scripts
  (local-file "../guest" "qubes-guix-guest" #:recursive? #t))

(define %installer-config
  (qubes-guest-configuration
   (gui? #f)                    ; the console window is the installer's screen
   (ctap-backend #f)
   (split-gpg2 #f)
   (split-ssh #f)
   (usb-proxy #f)
   (features-request? #f)))

(define (qubes-reference-os branch)
  "The system qubes-guix-install writes (xterm, user 'user', git), wrapped as
qubes-guix-finish-install wraps it. Only its packages matter: in the offline
ISO, its closure means an install needs no substitutes. Keep it in step with
the config.scm that guest/qubes-guix-install writes."
  (qubes-operating-system
   (operating-system
     (locale "en_US.utf8")
     (timezone "UTC")
     (keyboard-layout (keyboard-layout "us"))
     (host-name "guix")
     (users (cons* (user-account
                     (name "user")
                     (comment "Qubes user")
                     (group "users")
                     (home-directory "/home/user")
                     (supplementary-groups '("wheel" "netdev" "audio" "video")))
                   %base-user-accounts))
     (packages (cons xterm %base-packages))
     (services %desktop-services)
     (bootloader (bootloader-configuration
                   (bootloader grub-bootloader)
                   (targets (list "/dev/xvda"))
                   (keyboard-layout keyboard-layout)))
     (file-systems (cons* (file-system
                            (mount-point "/")
                            (device (file-system-label "guix-root"))
                            (type "ext4"))
                          %base-file-systems)))
   #:channel-branch branch
   #:extra-packages '("git")))

;; The git checkouts of the channels this Guix was built from, as in
;; ~/.cache/guix/checkouts, and the authentication cache: lowering the
;; system's guix (guix-for-channels) needs them, and would otherwise clone
;; guix.git during the install. Taken from the cache of whoever builds the
;; ISO, which 'guix time-machine' (or pull) has just filled.
(define (channel-checkouts)
  (let ((cache (cache-directory #:ensure? #f)))
    (filter-map
     (lambda (c)
       (let ((dir (url-cache-directory (channel-url c)
                                       (%repository-cache-directory))))
         (and (file-exists? dir)
              (list (string-append "checkouts/" (basename dir))
                    (local-file dir
                                (string-append "checkout-"
                                               (symbol->string (channel-name c)))
                                #:recursive? #t)))))
     (current-channels))))

(define (authentication-cache)
  (let ((dir (string-append (cache-directory #:ensure? #f) "/authentication")))
    (if (file-exists? dir)
        (list (list "authentication"
                    (local-file dir "guix-authentication-cache"
                                #:recursive? #t)))
        '())))

;; /etc/qubes-guix-cache: links finish-install copies into a writable
;; XDG_CACHE_HOME/guix (git writes into its checkouts).
(define (cache-directory-service entries)
  (simple-service 'qubes-guix-cache etc-service-type
                  (list (list "qubes-guix-cache"
                              (file-union "qubes-guix-cache" entries)))))

(define %issue-addition "
This is the qubes-guix installer. Its network, qrexec and QubesDB come up by
themselves under Qubes. To install unattended, run in dom0:

  qubes-guix-create --unattended NAME

or install with the dialogs on tty1 (type 'install' there), then, before
rebooting:

  qubes-guix-create --finish-install --run NAME

The guest scripts are in /root/qubes-guix/guest.

")

(define (substitutes-file-lines file key)
  "The values of FILE's lines that start with KEY (\"url\" or \"key\"), in the
format of dom0/qubes-guix-substitutes."
  (call-with-input-file file
    (lambda (port)
      (let loop ((acc '()))
        (let ((line (read-line port)))
          (if (eof-object? line)
              (reverse acc)
              (let ((line (string-trim-both line)))
                (loop (if (string-prefix? (string-append key " ") line)
                          (cons (string-trim (substring line
                                                        (string-length key)))
                                acc)
                          acc)))))))))

(define %gate-text "
  qubes-guix installer

  Under Qubes, dom0 drives this installer over qrexec: in dom0,

    qubes-guix-create --unattended NAME ISO_VM:ISO_PATH

  installs it, with the progress in dom0's terminal. Nothing to do here.

  monitor  and Enter: back to the monitor (htop, and the network
           traffic per address); Ctrl-b d leaves it again.
  install  and Enter: a manual install with the installer's dialogs
           instead. (Not while an unattended install runs.)

")

;; The monitor: a tmux session, htop above and qubes-guix-netacct's traffic
;; per address below; detaching (C-b d) leaves it running. Its socket under
;; /run: cow-store hides /tmp once an install starts.
(define %monitor-session "qubes-guix")
(define %netacct "/root/qubes-guix/guest/qubes-guix-netacct")

;; tty1's login program: the monitor, then a notice, and the installer's
;; dialogs (PROGRAM) only when asked for. The stock ISO starts them at once,
;; which here would invite a manual install on top of dom0's.
(define (installer-gate program)
  (define tmux (file-append (specification->package "tmux") "/bin/tmux"))
  (define htop (file-append (specification->package "htop") "/bin/htop"))
  (define sh (file-append bash-minimal "/bin/sh"))
  (program-file
   "qubes-installer-gate"
   #~(begin
       (use-modules (ice-9 rdelim))
       (setenv "PATH" "/run/current-system/profile/bin:/run/current-system/profile/sbin")
       (setenv "TMUX_TMPDIR" "/run")
       (define (monitor)
         (if (zero? (system* #$tmux "has-session" "-t" #$%monitor-session))
             (system* #$tmux "attach-session" "-t" #$%monitor-session)
             (system* #$tmux "new-session" "-s" #$%monitor-session #$htop
                      ";" "split-window" "-v" #$sh #$%netacct "watch"
                      ";" "set-option" "status-right" "C-b d: leave the monitor "
                      ";" "set-option" "status-right-length" "40"
                      ";" "select-pane" "-t" "0")))
       (monitor)
       (let loop ()
         (display (string (integer->char 27) #\[ #\H
                          (integer->char 27) #\[ #\2 #\J))
         (display #$%gate-text)
         (display "  > ")
         (force-output)
         (let ((line (read-line)))
           (cond ((eof-object? line) (exit 0))
                 ((string=? (string-trim-both line) "install")
                  (execl #$program #$program))
                 ((string=? (string-trim-both line) "monitor")
                  (monitor)
                  (loop))
                 (else (loop))))))))

;; The installer's dialogs run as kmscon's login program on tty1.
(define (gate-installer services)
  (define vt (@@ (gnu services base) kmscon-configuration-virtual-terminal))
  (define login (@@ (gnu services base) kmscon-configuration-login-program))
  (modify-services services
    (kmscon-service-type
     config => (if (equal? (vt config) "tty1")
                   (kmscon-configuration
                    (inherit config)
                    (login-program (installer-gate (login config))))
                   config))))

(define* (qubes-installation-os #:key
                                (branch "main")
                                (offline? #f)
                                (substitutes-file #f))
  "The Guix installer, as a headless qube (see this module's commentary).
BRANCH is the qubes channel branch recorded in its /etc/guix/channels.scm.
With OFFLINE?, it also holds what a default install needs, and the channel
checkouts. SUBSTITUTES-FILE (dom0/qubes-guix-substitutes' format): the
installer's guix-daemon uses those servers, and the file is kept as
/etc/qubes-guix-substitutes, which qubes-guix-finish-install records in the
installed system (and locks it to the ISO's commits)."
  (let ((base (qubes-operating-system
               (operating-system
                 (inherit installation-os)
                 (label (string-append (operating-system-label installation-os)
                                       " (qubes-guix)"))
                 ;; The emulated VGA: without it, VT3's console stays blank.
                 (kernel-arguments
                  (append (operating-system-user-kernel-arguments
                           installation-os)
                          '("nomodeset")))
                 (issue (string-append (operating-system-issue installation-os)
                                       %issue-addition))
                 ;; tmux, htop, nftables: the monitor on tty1, and the
                 ;; traffic per address an install reports at its end.
                 (packages (append (list git)
                                   (map specification->package
                                        '("tmux" "htop" "nftables"))
                                   (operating-system-packages
                                    installation-os))))
               #:config %installer-config
               #:channel-branch branch
               #:extra-substitute-urls
               (if substitutes-file
                   (substitutes-file-lines substitutes-file "url")
                   '())
               #:extra-authorized-keys
               (if substitutes-file
                   (substitutes-file-lines substitutes-file "key")
                   '()))))
    (operating-system
      (inherit base)
      (services
       (gate-installer
       (append
        (list
         (simple-service
          'qubes-guix-scripts activation-service-type
          #~(begin
              (use-modules (guix build utils))
              (let ((dir "/root/qubes-guix/guest"))
                (unless (file-exists? dir)
                  (mkdir-p "/root/qubes-guix")
                  (copy-recursively #$%guest-scripts dir #:log #f)
                  (for-each (lambda (f) (chmod f #o755))
                            (find-files "/root/qubes-guix"))
                  (for-each (lambda (d) (chmod d #o755))
                            (find-files "/root/qubes-guix"
                                        (lambda (f s)
                                          (eq? 'directory (stat:type s)))
                                        #:directories? #t))))))
         ;; Built here, so not at install: the Qubes packages the installer
         ;; itself doesn't run, and the slowest to build.
         (simple-service 'qubes-packages gc-root-service-type
                         (list qubes-gui-agent qubes-ctap
                               qubes-split-gpg2-client
                               qubes-split-ssh-client)))
        (if substitutes-file
            (list (simple-service
                   'qubes-guix-substitutes etc-service-type
                   (list (list "qubes-guix-substitutes"
                               (local-file substitutes-file
                                           "qubes-guix-substitutes")))))
            '())
        (if offline?
            (list (simple-service 'qubes-reference-system gc-root-service-type
                                  (list (qubes-reference-os branch)))
                  (cache-directory-service
                   (append (channel-checkouts) (authentication-cache))))
            '())
        (operating-system-user-services base)))))))
