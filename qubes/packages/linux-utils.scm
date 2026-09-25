(define-module (qubes packages linux-utils)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix gexp)
  #:use-module ((guix utils) #:select (cc-for-target))
  #:use-module (gnu packages)
  #:use-module (gnu packages virtualization)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages icu4c)
  #:use-module (qubes packages vchan))

(define-public qubes-linux-utils
  (package
    (name "qubes-linux-utils")
    (version "mm_25063069")                       ;; <- from `git describe --tags`
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/QubesOS/qubes-linux-utils")
                    (commit "25063069abf57d229e01025bb60dbdf3747c60ae")))  ;; <- HEAD of your checkout
              (file-name (git-file-name name version))
              (sha256
               (base32 "0zd8f1g5hmc3xaid33kc98i7imzxsamk7ad2g8ykwcxg5806vppi"))))
    (build-system gnu-build-system)
    (arguments
     `(#:tests? #f
       #:make-flags
       (list (string-append "CC=" ,(cc-for-target))
             "CFLAGS=-O2 -g -Wall -DUSE_XENSTORE_H -fPIC"   ;; pending grep verdict
             (string-append "SBINDIR=" (assoc-ref %outputs "out") "/sbin")
             (string-append "LIBDIR=" (assoc-ref %outputs "out") "/lib")
             (string-append "SCRIPTSDIR=" (assoc-ref %outputs "out") "/lib/qubes")
             (string-append "INCLUDEDIR=" (assoc-ref %outputs "out") "/include")
             (string-append "BINDIR=" (assoc-ref %outputs "out") "/bin")
	     (string-append "LDFLAGS=-Wl,-rpath=" (assoc-ref %outputs "out") "/lib"))
       #:phases
       (modify-phases %standard-phases
         (delete 'configure)
         ;; build/install each component dir separately; the top-level
         ;; `all` drags in selinux/udev we deliberately skip
         (add-after 'unpack 'drop-systemd-units
           (lambda _
             ;; systemd unit install targets absolute /usr paths;
             ;; service lifecycle is handled by shepherd on Guix System
             (substitute* "qmemman/Makefile"
               (("install -d .*/systemd/system/.*") "true")
               (("install -m 0644 .*\\.service.*") "true"))
             #t))
         ;; ... build/install phases unchanged
         (replace 'build
           (lambda* (#:key make-flags #:allow-other-keys)
             (for-each (lambda (d)
                         (apply invoke "make" "-C" d make-flags))
                       '("qmemman" "qrexec-lib"))))
         (replace 'install
           (lambda* (#:key make-flags (outputs %outputs) #:allow-other-keys)
             (for-each (lambda (d)
                         (apply invoke "make" "-C" d "install" make-flags))
                       '("qmemman" "qrexec-lib")))))))
    (native-inputs (list pkg-config))
    (inputs (list xen qubes-core-vchan-xen icu4c))
    (synopsis "Qubes OS common Linux tools for VMs")
    (description "Memory info writer, qrexec support libraries and related
helpers shared by Qubes guest agents.")
    (home-page "https://github.com/QubesOS/qubes-linux-utils")
    (license license:gpl2+)))
