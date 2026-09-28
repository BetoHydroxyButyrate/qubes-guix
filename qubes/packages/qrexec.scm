(define-module (qubes packages qrexec)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix gexp)
  #:use-module ((guix utils) #:select (cc-for-target))
  #:use-module (gnu packages)
  #:use-module (gnu packages haskell-xyz)
  #:use-module (gnu packages virtualization)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages haskell-apps)
  #:use-module (qubes packages vchan)
  #:use-module (qubes packages qubesdb))   ; qubesdb-read for WaitForSession

(define-public qubes-core-qrexec
  (package
    (name "qubes-core-qrexec")
    (version "mm_fa044832")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/QubesOS/qubes-core-qrexec")
                    (commit "fa044832457f3aad8abbbc434df21979db52e23e")))
              (file-name (git-file-name name version))
              (sha256
               (base32 "0mp8qd8wxxdbmnzycdgi6vvx2ba4b29fjh4mjl0bx2pbk85nhb9c"))))
    (build-system gnu-build-system)
    (arguments
     `(#:tests? #f
       #:phases
       (modify-phases %standard-phases
         (delete 'configure)
         (add-before 'build 'ensure-pkgconfig
           (lambda* (#:key inputs #:allow-other-keys)
             (setenv "PKG_CONFIG_PATH"
                     (string-append (assoc-ref inputs "qubes-core-vchan-xen")
                                    "/lib/pkgconfig:"
                                    (or (getenv "PKG_CONFIG_PATH") "")))))
         ;; do_exec() formats HOME=/SHELL=/USER=... into a 64-byte buffer and
         ;; bails out (exit 125, nothing logged) if one doesn't fit. On Guix
         ;; SHELL is a store path (~70 chars with the prefix), so every
         ;; PAM user switch failed right after pam_open_session.
         (add-after 'unpack 'enlarge-env-buf
           (lambda _
             (substitute* "agent/qrexec-agent.c"
               (("char env_buf\\[64\\];") "char env_buf[4096];"))))
         (add-after 'unpack 'fix-agent-rpath
           (lambda* (#:key outputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out")))
               (substitute* "agent/Makefile"
                 (("LDFLAGS \\+= -pie")
                  (string-append "LDFLAGS += -Wl,-rpath," out "/lib\n"
                                 "LDFLAGS += -pie"))))))
         ;; HAVE_PAM_APPL is a plain `=` wildcard probe on
         ;; /usr/include/security/pam_appl.h (never true on Guix), so the
         ;; command-line override is the right tool here. Without it the agent
         ;; runs every service as root and falls back to /bin/su for commands.
         (replace 'build
           (lambda* (#:key outputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out")))
               (invoke "make" "-C" "libqrexec" "CC=gcc"
                       (string-append "LIBDIR=" out "/lib")
                       (string-append "INCLUDEDIR=" out "/include"))
               (invoke "make" "-C" "agent" "CC=gcc" "os=Gentoo"
                       "HAVE_PAM_APPL=1"))))
         ;; `install: all` — pass the same flag so make never sees a different
         ;; CFLAGS/LDLIBS set than the one the objects were built with.
         (replace 'install
           (lambda* (#:key outputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out")))
               (invoke "make" "-C" "libqrexec" "install" "CC=gcc"
                       (string-append "LIBDIR=" out "/lib")
                       (string-append "INCLUDEDIR=" out "/include"))
               (invoke "make" "-C" "agent" "install" "CC=gcc"
                       (string-append "DESTDIR=" out)
                       "os=Gentoo" "HAVE_PAM_APPL=1"))))
         ;; The agent execs qubes.WaitForSession for every wait-for-session=1
         ;; service. Upstream's (qubes-rpc-base/, installed only by the
         ;; top-level Makefile) needs `systemctl --user` and, when the GUI is
         ;; enabled, waits with NO timeout for the gui-agent's per-user qrexec
         ;; socket — i.e. forever on a qube without a gui agent.
         ;; Guix version: no-op until a gui agent is installed, then the
         ;; upstream socket wait. The qubes-gui path is a placeholder until
         ;; qubes-gui-agent is packaged.
         (add-after 'install 'install-wait-for-session
           (lambda* (#:key inputs outputs #:allow-other-keys)
             (let* ((out    (assoc-ref outputs "out"))
                    (file   (string-append out "/etc/qubes-rpc/qubes.WaitForSession"))
                    (sh     (search-input-file inputs "/bin/sh"))
                    (sleep  (search-input-file inputs "/bin/sleep"))
                    (qdb    (search-input-file inputs "/bin/qubesdb-read")))
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
               (chmod file #o755)))))))
    (native-inputs (list pkg-config pandoc))
    (inputs (list xen qubes-core-vchan-xen linux-pam qubes-core-qubesdb))
    (synopsis "Guest-side qrexec agent for Qubes OS")
    (description "The qrexec guest agent and supporting library, built for
Guix System.")
    (home-page "https://github.com/QubesOS/qubes-core-qrexec")
    (license license:gpl2+)))
