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
  #:use-module (qubes packages vchan))

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
         (add-after 'unpack 'fix-agent-rpath
           (lambda* (#:key outputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out")))
               (substitute* "agent/Makefile"
                 (("LDFLAGS \\+= -pie")
                  (string-append "LDFLAGS += -Wl,-rpath," out "/lib\n"
                                 "LDFLAGS += -pie"))))))
         (replace 'build
           (lambda* (#:key outputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out")))
               (invoke "make" "-C" "libqrexec" "CC=gcc"
                       (string-append "LIBDIR=" out "/lib")
                       (string-append "INCLUDEDIR=" out "/include"))
               (invoke "make" "-C" "agent" "CC=gcc" "os=Gentoo" "HAVE_PAM_APPL=1"))))
         (replace 'install
           (lambda* (#:key outputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out")))
               (invoke "make" "-C" "libqrexec" "install" "CC=gcc"
                       (string-append "LIBDIR=" out "/lib")
                       (string-append "INCLUDEDIR=" out "/include"))
               (invoke "make" "-C" "agent" "install" "CC=gcc"
                       (string-append "DESTDIR=" out)
                       "os=Gentoo")))))))
    (native-inputs (list pkg-config pandoc))
    (inputs (list xen qubes-core-vchan-xen linux-pam))
    (synopsis "Guest-side qrexec agent for Qubes OS")
    (description "The qrexec guest agent and supporting library, built for
Guix System.")
    (home-page "https://github.com/QubesOS/qubes-core-qrexec")
    (license license:gpl2+)))
