(define-module (qubes packages qubesdb)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages pkg-config)
  #:use-module (qubes packages vchan))

(define-public qubes-core-qubesdb
  (package
    (name "qubes-core-qubesdb")
    (version "4.3.3")
    (source (origin
             (method git-fetch)
             (uri (git-reference
                   (url "https://github.com/QubesOS/qubes-core-qubesdb")
                   (commit "aeb3c8d8486673636964bc3beb4819d981dd3920")))
             (file-name (git-file-name name version))
             (sha256
              (base32 "0p1x87x5i47bqwg5gikfkk9rl4kzpnxjc92h3pvq2bzpwnvq9ar8"))))
    (build-system gnu-build-system)
    (arguments
     `(#:tests? #f
       #:phases
       (modify-phases %standard-phases
         (delete 'configure)
	 (add-after 'unpack 'run-in-foreground
		    (lambda _
		      (substitute* "daemon/db-daemon.c"
				   ;; the non-systemd branch unconditionally forks; make it opt-in
				   (("    if \\(1\\) \\{")
				    "    if (getenv(\"QUBESDB_FORK\")) {")
				   ;; ready_pipe stays {0,0} when not forking; don't write "ready" to fd 0
				   (("if \\(write\\(ready_pipe\\[1\\]")
				    "if (ready_pipe[1] && write(ready_pipe[1]"))))
	 (add-before 'build 'set-pythonpath
		     (lambda* (#:key inputs outputs #:allow-other-keys)
			      (let ((out (assoc-ref outputs "out")))
				;; setuptools' site-packages, whatever the Python version
				;; (3.11 in Guix 1.5.0, 3.12 later).
				(setenv "GUIX_PYTHONPATH"
					(string-append (car (find-files
							     (assoc-ref inputs "python-setuptools")
							     "^site-packages$"
							     #:directories? #t))
						       ":"
						       (or (getenv "GUIX_PYTHONPATH") "")))
				;; Python extension links libqubesdb from ../client (build tree);
				;; give it the store location at runtime.
				(setenv "LDFLAGS"
					(string-append "-Wl,-rpath," out "/lib")))))
         (add-before 'build 'pkg-config-path
           (lambda* (#:key inputs #:allow-other-keys)
             (setenv "PKG_CONFIG_PATH"
                     (string-append (assoc-ref inputs "qubes-core-vchan-xen")
                                    "/lib/pkgconfig:"
                                    (or (getenv "PKG_CONFIG_PATH") "")))))
         (replace 'build
           (lambda* (#:key outputs inputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out"))
		   (python (search-input-file inputs "/bin/python3")))
               (invoke "make" "-C" "client" "CC=gcc"
                       (string-append "APPEND_LDFLAGS=-Wl,-rpath," out "/lib"))
               (invoke "make" "-C" "daemon" "CC=gcc" "SYSTEMD=0")
               (invoke "make" "-C" "include" (string-append "INCLUDEDIR=" out "/include"))
               (with-directory-excursion "python"
                 (invoke python "setup.py" "build_ext")))))
         (replace 'install
           (lambda* (#:key outputs inputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out"))
		   (python (search-input-file inputs "/bin/python3")))
               (invoke "make" "-C" "client" "install"
                       (string-append "LIBDIR=" out "/lib")
                       (string-append "BINDIR=" out "/bin"))
               (invoke "make" "-C" "daemon" "install"
                       (string-append "BINDIR=" out "/bin"))
               (invoke "make" "-C" "include" "install"
                       (string-append "INCLUDEDIR=" out "/include"))
               (with-directory-excursion "python"
                 (invoke python "setup.py" "install"
                         "--prefix" out)))))
	 (add-after 'install 'fix-extension-rpath
		    (lambda* (#:key outputs #:allow-other-keys)
			     (let* ((out (assoc-ref outputs "out"))
				    ;; qubesdb.cpython-3NN-...so, whatever the version.
				    (so (car (find-files out "^qubesdb\\.cpython-.*\\.so$"))))
			       (invoke "patchelf" "--add-rpath"
				       (string-append out "/lib")
				       so))))
         (delete 'sanity-check))))
    (native-inputs (list pkg-config python python-setuptools patchelf))
    (inputs (list qubes-core-vchan-xen))
    (home-page "https://github.com/QubesOS/qubes-core-qubesdb")
    (synopsis "QubesDB client library, tools, daemon, and Python bindings")
    (description "...")
    (license license:gpl2+)))
