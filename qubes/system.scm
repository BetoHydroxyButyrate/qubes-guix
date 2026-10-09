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
;;; - with #:template? #t: template support (qubes-guest-configuration's
;;;   template? field): /home on the private volume, swap on the volatile
;;;   one, the host name from qubesdb, updates through qubes.UpdatesProxy.
;;;   For a TemplateVM and the AppVMs based on it.
;;;
;;; Applying it twice changes nothing.

(define-module (qubes system)
  #:use-module (gnu system)
  #:use-module (gnu system accounts)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (qubes services agent)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:export (qubes-operating-system))

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
                                 (template? #f))
  "Return OS, with the Qubes guest agents added and CONFIG for them.
Unless DISPLAY-MANAGER? is true, also remove the graphical login.  With
TEMPLATE?, configure it as a Qubes template (and its AppVMs)."
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
      (sudoers-file (if passwordless-sudo?
                        (qubes-sudoers (operating-system-sudoers-file os))
                        (operating-system-sudoers-file os)))
      (services
       (let ((kept (if display-manager?
                       old-services
                       (remove-services-named %display-manager-service-names
                                              old-services))))
         (if (any qubes-service? kept)
             kept                       ; already a qube: keep its config
             (cons (service qubes-guest-service-type
                            (if template? (as-template config) config))
                   (if (qubes-guest-network? config)
                       (remove-services-named %networking-service-names kept)
                       kept))))))))
