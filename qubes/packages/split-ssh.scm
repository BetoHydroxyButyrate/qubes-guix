;;; qubes/packages/split-ssh.scm — split-ssh client.
;;;
;;; The client side of the usual Qubes "split SSH": a session hook runs socat
;;; on $HOME/.ssh/qubes-agent.sock, forwarding each connection over qrexec
;;; (qubes.SshAgent) to the vault qube dom0's policy picks (@default), where
;;; the service connects it to that qube's ssh-agent. The keys never enter
;;; this qube. qubes-session exports SSH_AUTH_SOCK=$HOME/.ssh/qubes-agent.sock
;;; when this package is installed, so every program of the session uses it.
;;; The vault side is a few lines of shell (see README: Split SSH).

(define-module (qubes packages split-ssh)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix build-system trivial)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages base)          ; coreutils
  #:use-module (gnu packages bash)
  #:use-module (gnu packages networking)    ; socat
  #:use-module (qubes packages qrexec))

(define-public qubes-split-ssh-client
  (package
    (name "qubes-split-ssh-client")
    (version "0.1")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((hooks (string-append #$output "/lib/qubes/session.d"))
                 (hook  (string-append hooks "/split-ssh-client")))
            (mkdir-p hooks)
            (call-with-output-file hook
              (lambda (port)
                (format port "#!~a
# split-ssh client, run by qubes-session for the life of the session:
# $HOME/.ssh/qubes-agent.sock (the session's SSH_AUTH_SOCK) -> qrexec
# qubes.SshAgent -> the vault qube's ssh-agent. @default: dom0's policy
# chooses the vault (and may ask). Restarted if it exits.
sock=\"$HOME/.ssh/qubes-agent.sock\"
~a -p \"$HOME/.ssh\"
~a 700 \"$HOME/.ssh\"
while :; do
    ~a UNIX-LISTEN:\"$sock\",fork,unlink-early,mode=600 \\
        EXEC:\"~a @default qubes.SshAgent\"
    ~a 5
done
"
                        #$(file-append bash-minimal "/bin/sh")
                        #$(file-append coreutils "/bin/mkdir")
                        #$(file-append coreutils "/bin/chmod")
                        #$(file-append socat "/bin/socat")
                        #$(file-append qubes-core-qrexec
                                       "/usr/bin/qrexec-client-vm")
                        #$(file-append coreutils "/bin/sleep"))))
            (chmod hook #o755)))))
    (home-page "https://github.com/BetoHydroxyButyrate/qubes-guix")
    (synopsis "Qubes split-ssh client: use SSH keys held in another qube")
    (description
     "Forwards an SSH agent socket over qrexec (@code{qubes.SshAgent}) to a
vault qube's @command{ssh-agent}, so @command{ssh} and @command{git} here use
keys that never enter this qube.")
    (license license:gpl2+)))
