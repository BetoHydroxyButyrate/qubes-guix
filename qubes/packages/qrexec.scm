;;; qubes/packages/qrexec.scm — qubes-core-qrexec, guest side.
;;;
;;; Builds libqrexec-utils and agent/ (qrexec-agent, qrexec-client-vm,
;;; qrexec-fork-server). The dom0 daemon, policy tools and python package are
;;; not built. Installed with DESTDIR, so binaries live under $out/usr/bin and
;;; $out/usr/lib/qubes (other packages refer to those paths).

(define-module (qubes packages qrexec)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module ((guix utils) #:select (cc-for-target))
  #:use-module (gnu packages base)            ; coreutils (sleep)
  #:use-module (gnu packages bash)            ; bash-minimal
  #:use-module (gnu packages haskell-xyz)     ; pandoc (qrexec-client-vm.1)
  #:use-module (gnu packages linux)           ; linux-pam
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages virtualization)  ; xen
  #:use-module (qubes packages vchan)
  #:use-module (qubes packages qubesdb))      ; qubesdb-read, for WaitForSession

(define-public qubes-core-qrexec
  (package
    (name "qubes-core-qrexec")
    (version "4.3.15")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/QubesOS/qubes-core-qrexec")
             (commit "205db68abd6d89dff1bc03bce8ce0c88749b7248"))) ; v4.3.15
       (file-name (git-file-name name version))
       (sha256
        (base32 "0y9izzyknkd6jncvgqzpqp2n726v8dsb7prpg3i83mfvscb0kf0f"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f                       ; the test suite targets dom0/python
      #:phases
      #~(let ((agent-flags
               ;; HAVE_PAM_APPL is a `wildcard` probe of
               ;; /usr/include/security/pam_appl.h, which never matches on Guix.
               ;; Without it the agent runs every service as root and falls back
               ;; to /bin/su. `os` only selects the PAM file to install.
               (list (string-append "CC=" #$(cc-for-target))
                     "os=Gentoo" "HAVE_PAM_APPL=1"))
              (lib-flags
               (list (string-append "CC=" #$(cc-for-target))
                     (string-append "LIBDIR=" #$output "/lib")
                     (string-append "INCLUDEDIR=" #$output "/include"))))
          (modify-phases %standard-phases
            (delete 'configure)
            ;; Make vchan.pc (VCHAN_PKG) visible to the Makefiles' pkg-config calls.
            (add-before 'build 'ensure-pkgconfig
              (lambda* (#:key inputs #:allow-other-keys)
                (setenv "PKG_CONFIG_PATH"
                        (string-append
                         (dirname (search-input-file inputs "/lib/pkgconfig/vchan.pc")) ":"
                         (or (getenv "PKG_CONFIG_PATH") "")))))
            ;; Upstream bug: do_exec() formats HOME=/SHELL=/USER=... into a
            ;; 64-byte buffer and exits 125, logging nothing, when one doesn't
            ;; fit. A store-path SHELL (~70 chars) broke every PAM user switch.
            (add-after 'unpack 'enlarge-env-buf
              (lambda _
                (substitute* "agent/qrexec-agent.c"
                  (("char env_buf\\[64\\];") "char env_buf[4096];"))))
            (add-after 'unpack 'add-agent-rpath
              (lambda _
                (substitute* "agent/Makefile"
                  (("LDFLAGS \\+= -pie")
                   (string-append "LDFLAGS += -Wl,-rpath," #$output "/lib\n"
                                  "LDFLAGS += -pie")))))
            (replace 'build
              (lambda _
                (apply invoke "make" "-C" "libqrexec" lib-flags)
                (apply invoke "make" "-C" "agent" agent-flags)))
            ;; `install: all` -- same flags, so nothing is rebuilt differently.
            (replace 'install
              (lambda _
                (apply invoke "make" "-C" "libqrexec" "install" lib-flags)
                (apply invoke "make" "-C" "agent" "install"
                       (string-append "DESTDIR=" #$output) agent-flags)))
            ;; The agent runs qubes.WaitForSession before every
            ;; wait-for-session=1 service. Upstream's version (qubes-rpc-base/)
            ;; needs `systemctl --user`. This one waits, like upstream, for the
            ;; GUI session's fork-server socket, but returns at once on a qube
            ;; without the GUI agent (upstream would wait forever there).
            (add-after 'install 'install-wait-for-session
              (lambda* (#:key inputs #:allow-other-keys)
                (let ((file  (string-append #$output
                                            "/etc/qubes-rpc/qubes.WaitForSession"))
                      (sh    (search-input-file inputs "/bin/sh"))
                      (sleep (search-input-file inputs "/bin/sleep"))
                      (qdb   (search-input-file inputs "/bin/qubesdb-read")))
                  (mkdir-p (dirname file))
                  (call-with-output-file file
                    (lambda (port)
                      (format port "#!~a
# Guix port of qubes.WaitForSession (see qubes/packages/qrexec.scm).
set -eu
if [ -n \"${QREXEC_SERVICE_ARGUMENT-}\" ]; then
    echo 'No argument is allowed' >&2; exit 1
fi
# No gui agent installed: nothing to wait for.
[ -x /run/current-system/profile/bin/qubes-gui ] || exit 0
[ \"$(~a --default=True /qubes-gui-enabled)\" = True ] || exit 0
user=\"$(~a /default-user || echo user)\"
while ! [ -e \"/var/run/qubes/qrexec-server.$user.sock\" ]; do
    ~a 0.1
done
" sh qdb qdb sleep)))
                  (chmod file #o755))))))))
    (native-inputs (list pkg-config pandoc))
    (inputs (list bash-minimal coreutils linux-pam xen
                  qubes-core-vchan-xen qubes-core-qubesdb))
    (home-page "https://github.com/QubesOS/qubes-core-qrexec")
    (synopsis "Qubes OS qrexec guest agent")
    (description
     "The guest side of qrexec, the Qubes OS inter-qube RPC mechanism:
@command{qrexec-agent}, which answers dom0 and runs services (with PAM user
switching), @command{qrexec-client-vm} for calling services in other qubes,
@command{qrexec-fork-server} for running services inside the user's session,
and the @code{libqrexec-utils} library.")
    (license license:gpl2+)))
