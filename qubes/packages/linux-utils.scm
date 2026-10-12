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

;; Pinned to the R4.3 release branch to match the R4.3 dom0. The previous pin
;; (main, mm_25063069) was only 2 commits ahead: upstream 4575219 "Report
;; swapinfo", which needs an R4.4 dom0 (core-admin 0046d33 creates the
;; writable memory/swapinfo key) and killed meminfo-writer on R4.3. Nothing
;; else differs (qrexec-lib identical), so the nonfatal-swapinfo phase is gone.
(define-public qubes-linux-utils
  (package
    (name "qubes-linux-utils")
    (version "4.3.19")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/QubesOS/qubes-linux-utils")
                    (commit "2c79ddbf9d9f9024d1881215d8441b3f0f6058fa"))) ; v4.3.19 = release4.3
              (file-name (git-file-name name version))
              (sha256
               (base32 "1vzssg29wjxpzrkvfppsp021r3ngw76dgryb1in3080k241kyshr"))))
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
