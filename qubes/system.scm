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
;;;
;;; Applying it twice changes nothing.

(define-module (qubes system)
  #:use-module (gnu system)
  #:use-module (gnu system accounts)
  #:use-module (gnu services)
  #:use-module (qubes services agent)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:export (qubes-operating-system))

(define %networking-service-names
  ;; service-type-name of the stock services that provision 'networking.
  ;; By name rather than by value, so this module needn't import them all.
  '(network-manager connman dhcp-client dhcpcd wicd))

(define* (qubes-operating-system os
                                 #:key (config (qubes-guest-configuration)))
  "Return OS, with the Qubes guest agents added and CONFIG for them."
  (define (qubes-service? service)
    (eq? (service-kind service) qubes-guest-service-type))

  (define (provides-networking? service)
    (memq (service-type-name (service-kind service))
          %networking-service-names))

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
      (services
       (if (any qubes-service? old-services)
           old-services                 ; already a qube: keep its config
           (cons (service qubes-guest-service-type config)
                 (if (qubes-guest-network? config)
                     (remove provides-networking? old-services)
                     old-services)))))))
