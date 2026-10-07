;;; qubes/packages/split-gpg.scm — split-gpg2 client side (qubes-app-linux-split-gpg2).
;;;
;;; The client forwards gpg's agent socket to the gpg qube over qrexec
;;; (qubes.Gpg2), so plain `gpg` / `git commit -S` here use keys held there.
;;; Only the client half is packaged: the server (python splitgpg2 module)
;;; runs in the gpg qube's template.

(define-module (qubes packages split-gpg)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages base)          ; grep, coreutils
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu packages networking)    ; socat
  #:use-module (qubes packages qrexec)
  #:use-module (qubes packages qubesdb))

(define-public qubes-split-gpg2-client
  (package
    (name "qubes-split-gpg2-client")
    (version "1.1.14")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/QubesOS/qubes-app-linux-split-gpg2")
             (commit "b48de624e01b22a38b25a646e0d31ede51099b00"))) ; v1.1.14
       (file-name (git-file-name name version))
       (sha256
        (base32 "0baax91yhhlzsznjap8yq2lnvbbql15g59b2jh7mb2jvagzl9pga"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (delete 'build)
          (replace 'install
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((libexec (string-append #$output "/libexec/split-gpg2"))
                     (hooks   (string-append #$output "/lib/qubes/session.d"))
                     (bash    (search-input-file inputs "/bin/bash"))
                     (gpgconf (search-input-file inputs "/bin/gpgconf"))
                     (socat   (search-input-file inputs "/bin/socat"))
                     (grep    (search-input-file inputs "/bin/grep"))
                     (cut     (search-input-file inputs "/bin/cut"))
                     (awk     (search-input-file inputs "/bin/awk"))
                     (sleep   (search-input-file inputs "/bin/sleep"))
                     (qdb     (search-input-file inputs "/bin/qubesdb-read"))
                     (qrexec  (search-input-file inputs
                                                 "/usr/bin/qrexec-client-vm")))
                (mkdir-p libexec)
                (mkdir-p hooks)
                ;; The forwarder: socat on gpg's agent socket -> qubes.Gpg2.
                ;; Server qube: $SPLIT_GPG2_SERVER_DOMAIN from
                ;; ~/.config/split-gpg2-rc, else @default (dom0 policy
                ;; target=). /etc/split-gpg2-rc is read too, as upstream.
                (install-file "split-gpg2-client" libexec)
                (substitute* (string-append libexec "/split-gpg2-client")
                  (("^#!/bin/bash --") (string-append "#!" bash " --"))
                  (("\\$\\(gpgconf ") (string-append "$(" gpgconf " "))
                  (("\\| grep ") (string-append "| " grep " "))
                  (("\\| cut ") (string-append "| " cut " "))
                  (("exec socat ") (string-append "exec " socat " "))
                  (("exec:qrexec-client-vm ")
                   (string-append "exec:" qrexec " ")))
                ;; Optional guard against a local gpg-agent grabbing the
                ;; socket first (users opt in with `agent-program` in
                ;; ~/.gnupg/gpg.conf). Upstream tests
                ;; /run/qubes-service/split-gpg2-client; we ask qubesdb.
                (install-file "gpg-agent-placeholder" libexec)
                (substitute* (string-append libexec "/gpg-agent-placeholder")
                  (("^#!/bin/bash") (string-append "#!" bash))
                  (("\\[ -e /run/qubes-service/split-gpg2-client \\]")
                   (string-append "[ \"$(" qdb
                                  " /qubes-service/split-gpg2-client 2>/dev/null)\" = 1 ]"))
                  (("\\$\\(gpgconf ") (string-append "$(" gpgconf " "))
                  (("\\| awk ") (string-append "| " awk " ")))
                ;; Session hook, run by qubes-session (gui.scm) in the
                ;; background. Gate = upstream ConditionPathExists: the qube's
                ;; split-gpg2-client service (qvm-service ... on). Keeps the
                ;; forwarder alive like the systemd user unit would.
                (call-with-output-file (string-append hooks "/split-gpg2-client")
                  (lambda (port)
                    (format port "#!~a
[ \"$(~a /qubes-service/split-gpg2-client 2>/dev/null)\" = 1 ] || exit 0
while :; do
    ~a/split-gpg2-client
    ~a 5
done
" bash qdb libexec sleep)))
                (for-each (lambda (f) (chmod f #o755))
                          (list (string-append libexec "/split-gpg2-client")
                                (string-append libexec "/gpg-agent-placeholder")
                                (string-append hooks "/split-gpg2-client")))
                (install-file "README.md"
                              (string-append #$output "/share/doc/split-gpg2"))
                (install-file "qubes-split-gpg2.conf.example"
                              (string-append #$output "/share/doc/split-gpg2"))))))))
    (inputs
     (list bash-minimal coreutils grep gawk gnupg socat
           qubes-core-qrexec qubes-core-qubesdb))
    (home-page "https://github.com/QubesOS/qubes-app-linux-split-gpg2")
    (synopsis "Qubes split-gpg2 client: use gpg keys held in another qube")
    (description
     "Forwards GnuPG's agent socket over qrexec (@code{qubes.Gpg2}) to the qube
holding the private keys, so ordinary @command{gpg} and @command{git commit -S}
work without the keys ever entering this qube.  Client half of
qubes-app-linux-split-gpg2.")
    (license license:gpl2+)))
