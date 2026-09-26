(define-module (qubes packages core-agent)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix build-system python)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module ((guix utils) #:select (cc-for-target))
  #:use-module (gnu packages)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-xyz)   ; pyxdg, if needed
  #:use-module (gnu packages virtualization)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages glib)
  #:use-module (qubes packages vchan)
  #:use-module (qubes packages linux-utils))

(define-public qubes-core-agent
  (package
    (name "qubes-core-agent")
    (version "mm_47383334")
    (source (origin ...))                   ; repo root, git-fetch, hash dance
    (build-system python-build-system)
    (arguments
     `(#:tests? #f
       #:phases
       (modify-phases %standard-phases
         (add-after 'unpack 'fix-paths
           (lambda* (#:key outputs inputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out")))
               ;; everything that execs FHS paths gets the store equivalent;
               ;; things that must resolve at RUNTIME get the profile instead
               (substitute* (find-files "qubes-rpc" "^qubes\\.")
                 (("/usr/lib/qubes") (string-append out "/lib/qubes"))
                 (("/usr/bin/qubes-vmexec") (string-append out "/bin/qubes-vmexec"))
                 (("/bin/bash") "/run/current-system/profile/bin/bash"))
               #t)))
         (add-before 'build 'build-c
           (lambda* (#:key outputs inputs #:allow-other-keys)
             (let ((vchan (assoc-ref inputs "qubes-core-vchan-xen"))
                   (utils (assoc-ref inputs "qubes-linux-utils")))
               (setenv "PKG_CONFIG_PATH"
                       (string-append vchan "/lib/pkgconfig:"
                                      (or (getenv "PKG_CONFIG_PATH") "")))
               (invoke "make" "-C" "qubes-rpc" "CC=gcc"
                       (string-append "LDSO_EXTRA=\\\"" ...))))))
         ...)))
    ...))
