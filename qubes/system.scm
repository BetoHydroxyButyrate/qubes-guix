;;; qubes/system.scm — turn any operating-system into a Qubes qube.
;;;
;;;   (use-modules (gnu) (qubes system))
;;;   (qubes-operating-system
;;;     (operating-system ...))      ; e.g. what the Guix installer wrote
;;;
;;; It adds what a Qubes guest needs and changes nothing else:
;;; - %qubes-kernel-arguments;
;;; - the "qubes" supplementary group for every regular user account;
;;; - qubes-guest-service-type (CONFIG, default (qubes-guest-configuration));
;;; - when the service configures the network (network? #t, the default):
;;;   removes the services that would also provide 'networking (NetworkManager,
;;;   connman, the DHCP clients). Shepherd refuses two providers of one name.
;;;   static-networking is left alone: %base-services uses it for loopback.
;;;   If you configured eth0 with it yourself, remove that by hand.
;;; - unless #:display-manager? is #t: removes the graphical login (GDM,
;;;   which %desktop-services always includes, and the other display
;;;   managers). In a qube the Qubes GUI agent provides the windows, and
;;;   GDM refuses a console login while the agent's session for that user
;;;   is open ("Session Already Running"). The console stays a text login;
;;;   the desktop packages (XFCE etc.) are untouched.
;;; - unless #:passwordless-sudo? is #f: members of "qubes" (every regular
;;;   user) get sudo without a password, as upstream's
;;;   qubes-core-agent-passwordless-root does. A qube is the isolation
;;;   boundary; root inside it guards nothing the user can't already reach.
;;; - unless #:system-channels? is #f: the qubes channel (branch
;;;   #:channel-branch, default "main") added to the channels guix-daemon's
;;;   service installs as /etc/guix/channels.scm. 'guix pull' uses that file
;;;   when a user has no ~/.config/guix/channels.scm, so every user's first
;;;   pull already includes this channel.
;;; - #:guix-commit "C": /etc/guix/channels.scm pins the guix channel at
;;;   commit C, so every 'guix pull' (and qubes-guix-update) stays there:
;;;   the template is "locked". #f (the default) follows the branch head.
;;;   Move it with 'qubes-guix-update --guix-commit C' (or --head).
;;; - unless #:system-guix? is #f (and with system channels): the system's
;;;   own guix is built from the channels of the Guix doing the build, so it
;;;   includes qubes: 'guix describe' shows it from the first boot.
;;; - with #:template? #t: template support (qubes-guest-configuration's
;;;   template? field): /home on the private volume, swap on the volatile
;;;   one, the host name from qubesdb, updates through qubes.UpdatesProxy.
;;;   For a TemplateVM and the AppVMs based on it.
;;;
;;; Applying it twice changes nothing.
;;;
;;; - #:extra-packages '("git" "emacs" ...): added to the system's packages;
;;;   names this Guix doesn't have are skipped with a warning, so the list
;;;   never stops a reconfigure (available-packages, also exported).

(define-module (qubes system)
  #:use-module (gnu system)
  #:use-module (gnu system accounts)
  #:use-module (gnu services)
  #:use-module (gnu services base)          ; guix-service-type
  #:use-module (guix channels)
  #:use-module ((guix describe) #:select (current-channels))
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:use-module ((gnu packages) #:select (find-best-packages-by-name))
  #:use-module ((guix utils) #:select (package-name->name+version))
  #:use-module (qubes services agent)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:export (qubes-operating-system
            available-packages))

(define (available-packages specs)
  "Return the packages named by SPECS (\"git\", \"emacs@29\"), skipping,
with a warning, any that this Guix doesn't have: a list of wanted extras in
config.scm never stops a reconfigure."
  (filter-map
   (lambda (spec)
     (call-with-values (lambda () (package-name->name+version spec))
       (lambda (name version)
         (match (find-best-packages-by-name name version)
           ((package . _) package)
           (()
            (format (current-error-port)
                    "warning: package '~a' not found; skipped~%" spec)
            #f)))))
   specs))

(define %networking-service-names
  ;; service-type-name of the stock services that provision 'networking.
  ;; By name rather than by value, so this module needn't import them all.
  '(network-manager connman dhcp-client dhcpcd wicd))

(define %display-manager-service-names
  '(gdm slim sddm lightdm))

(define (remove-services-named names services)
  "Remove from SERVICES those whose type is named in NAMES, and the services
that extend them: e.g. the installer's (set-xorg-configuration ...) extends
gdm, and Guix refuses an extension whose target is gone."
  (define (named? type) (memq (service-type-name type) names))
  (define (extends-removed? service)
    (any (lambda (extension) (named? (service-extension-target extension)))
         (service-type-extensions (service-kind service))))
  (remove (lambda (service)
            (or (named? (service-kind service)) (extends-removed? service)))
          services))

(define (qubes-sudoers base)
  "BASE, a sudoers file, plus passwordless sudo for the \"qubes\" group.
Guix runs visudo on the result, so a syntax error fails the build."
  (computed-file "sudoers"
                 #~(begin
                     (use-modules (ice-9 textual-ports))
                     (call-with-output-file #$output
                       (lambda (port)
                         (display (call-with-input-file #$base get-string-all)
                                  port)
                         (display "
# Added by (qubes system): passwordless root, as in Qubes' own templates.
%qubes ALL=(ALL) NOPASSWD: ALL
" port))))))

(define (qubes-channel branch)
  (channel
   (name 'qubes)
   (url "https://github.com/BetoHydroxyButyrate/qubes-guix")
   (branch branch)
   (introduction
    (make-channel-introduction
     "ea33fcb13bff41db38017f9ec385565f66f88fae"
     (openpgp-fingerprint                ; the signing subkey
      "1607 721B 3110 F370 9497  F436 B548 D5A5 665F D366")))))

(define (pin-guix chans pin)
  "CHANS with the guix channel at commit PIN (a string), or as they are if
PIN is #f.  (Not named 'commit': inside (channel (inherit ...)) the field
binding would shadow it.)"
  (if pin
      (map (lambda (c)
             (if (eq? (channel-name c) 'guix)
                 (channel (inherit c) (commit pin))
                 c))
           chans)
      chans))

(define* (with-qubes-channel config branch #:optional guix-commit)
  "CONFIG, a guix-configuration, with the qubes channel added to the
system-wide channels (unless it already has one named qubes), and the guix
channel pinned at GUIX-COMMIT if that's a string."
  (let* ((old (or (guix-configuration-channels config) %default-channels))
         (new (pin-guix
               (if (any (lambda (c) (eq? (channel-name c) 'qubes)) old)
                   old
                   (append old (list (qubes-channel branch))))
               guix-commit)))
    (guix-configuration
     (inherit config)
     (channels new))))

;; guix pull warns "channel 'qubes' is not trusted" when it evaluates a
;; channels file listing a channel that isn't among the user's trusted ones:
;; those of ~/.config/guix/trusted-channels.scm, or else those of the Guix
;; doing the pull. On a new system that's the system's Guix, without the
;; qubes channel, so the first pull from /etc/guix/channels.scm warns (for a
;; local file it's only a warning). New home directories get a
;; trusted-channels.scm that trusts what /etc/guix/channels.scm lists.
;; A directory, not a single file: skeletons are copied with
;; copy-recursively, which creates the parents (.config) only for
;; directories. The channels are written out literally (channel->code).
(define (guix-config-skeleton branch)
  (let ((text (string-append
               ";; The channels 'guix pull' trusts. Written by (qubes system) from the
;; system's channels; add others (e.g. nonguix) to trust them too.
"
               (with-output-to-string
                 (lambda ()
                   (pretty-print
                    `(list ,@(map channel->code
                                  (append %default-channels
                                          (list (qubes-channel branch)))))))))))
    (computed-file "guix-config-skeleton"
                   #~(begin
                       (mkdir #$output)
                       (call-with-output-file
                           (string-append #$output "/trusted-channels.scm")
                         (lambda (port) (display #$text port)))))))

(define (with-trusted-channels skeletons branch)
  (if (assoc ".config/guix" skeletons)
      skeletons
      (cons (list ".config/guix" (guix-config-skeleton branch)) skeletons)))

;; The system's own guix (/run/current-system/profile/bin/guix, the one a
;; user has before their first 'guix pull') built from the channels of the
;; Guix doing this build, when those include qubes: so 'guix describe' lists
;; qubes from the first boot, and 'sudo guix system reconfigure' works
;; without a user pull. guix-for-channels needs root's channel checkouts
;; (~root/.cache/guix/checkouts): the install has them (time-machine); a
;; later reconfigure fetches them, through the updates proxy in a template
;; (qubes-guix-update -r passes it to sudo).
;; guix-for-channels lives in (gnu packages package-management), not in
;; (gnu services base); looked up at run time so that a Guix without it
;; just keeps its stock system guix instead of failing to load this module.
(define guix-for-channels*
  (false-if-exception
   (module-ref (resolve-interface '(gnu packages package-management))
               'guix-for-channels)))

(define (with-system-guix config)
  (let ((chans (current-channels)))
    (if (and guix-for-channels*
             (any (lambda (c) (eq? (channel-name c) 'qubes)) chans))
        (guix-configuration
         (inherit config)
         (guix (guix-for-channels* chans)))
        config)))

(define (as-template config)
  ;; Top level: inside qubes-operating-system, the record's field binding
  ;; template? would shadow the keyword argument of the same name.
  (qubes-guest-configuration
   (inherit config)
   (template? #t)))

(define* (qubes-operating-system os
                                 #:key
                                 (config (qubes-guest-configuration))
                                 (display-manager? #f)
                                 (passwordless-sudo? #t)
                                 (system-channels? #t)
                                 (system-guix? #t)
                                 (channel-branch "main")
                                 (guix-commit #f)
                                 (template? #f)
                                 (extra-packages '()))
  "Return OS, with the Qubes guest agents added and CONFIG for them.
Unless DISPLAY-MANAGER? is true, also remove the graphical login.  With
TEMPLATE?, configure it as a Qubes template (and its AppVMs).  EXTRA-PACKAGES
names packages to add (\"git\" \"emacs@29\"); those this Guix lacks are skipped
with a warning."
  (define (qubes-service? service)
    (eq? (service-kind service) qubes-guest-service-type))

  (define (add-qubes-group account)
    (if (or (user-account-system? account)
            (string=? (user-account-name account) "root")
            (member "qubes" (user-account-supplementary-groups account)))
        account
        (user-account
         (inherit account)
         (supplementary-groups
          (append (user-account-supplementary-groups account)
                  '("qubes"))))))

  (let ((old-services (operating-system-user-services os)))
    (operating-system
      (inherit os)
      (kernel-arguments
       (append (remove (cut member <> %qubes-kernel-arguments)
                       (operating-system-user-kernel-arguments os))
               %qubes-kernel-arguments))
      (users (map add-qubes-group (operating-system-users os)))
      (skeletons (if system-channels?
                     (with-trusted-channels (operating-system-skeletons os)
                                            channel-branch)
                     (operating-system-skeletons os)))
      (packages (append (operating-system-packages os)
                        (available-packages extra-packages)))
      (sudoers-file (if passwordless-sudo?
                        (qubes-sudoers (operating-system-sudoers-file os))
                        (operating-system-sudoers-file os)))
      (services
       (let* ((kept0 (if display-manager?
                         old-services
                         (remove-services-named %display-manager-service-names
                                                old-services)))
              (kept (if system-channels?
                        (map (lambda (s)
                               (if (eq? (service-kind s) guix-service-type)
                                   (service guix-service-type
                                            (let ((c (with-qubes-channel
                                                      (service-value s)
                                                      channel-branch
                                                      guix-commit)))
                                              (if system-guix?
                                                  (with-system-guix c)
                                                  c)))
                                   s))
                             kept0)
                        kept0)))
         (if (any qubes-service? kept)
             kept                       ; already a qube: keep its config
             (cons (service qubes-guest-service-type
                            (if template? (as-template config) config))
                   (if (qubes-guest-network? config)
                       (remove-services-named %networking-service-names kept)
                       kept))))))))
