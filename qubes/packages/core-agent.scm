;;; qubes/packages/core-agent.scm — qubes-core-agent-linux, qubes-rpc/ half.
;;;
;;; Scope: C helpers (qfile-*, tar2qfile, vm-log, vm-file-editor, ...),
;;; qvm-* user commands, /etc/qubes-rpc service scripts, /etc/qubes/rpc-config.
;;; Plus python-qubesagent (qubesagent module: qubes-vmexec, qubes-firewall).
;;; Out of scope (later): misc/, network/, systemd/init glue, selinux,
;;; distro packaging.

(define-module (qubes packages core-agent)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system pyproject)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-build)
  ;; Adjust these three to your actual module / variable names if they differ.
  #:use-module (qubes packages linux-utils)   ; qubes-linux-utils
  #:use-module (qubes packages qrexec)        ; qubes-core-qrexec
  #:use-module (qubes packages qubesdb))      ; qubes-core-qubesdb

(define-public qubes-core-agent
  (package
    (name "qubes-core-agent")
    (version "4.4.2")                   ; version file at mm_47383334
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/QubesOS/qubes-core-agent-linux")
             ;; tag mm_47383334
             (commit "4738333496c6b689207d8274d0f3425e796b6197")))
       (file-name (git-file-name name version))
       (sha256
        ;; Precomputed NAR hash of the checkout; if guix disagrees,
        ;; paste the hash it reports.
        (base32 "1gl6kvpywa8g34q781yf0ysd5w7wrib5p5vyqpq6dv7cf3hmc7jd"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          ;; Only qubes-rpc/. The top-level Makefile runs `lsb_release -is`
          ;; and pulls in misc/ (update-desktop-database etc.) — avoid it.
          ;; NO CFLAGS/LDFLAGS: qubes-rpc/Makefile builds them with := and
          ;; a command-line value would replace -Wall -fPIC -pie wholesale.
          ;; No DEVEL_BUILD: its $ORIGIN rpath only helps when the libs share
          ;; our prefix; ld-wrapper already adds RUNPATH for the input libs.
          (replace 'build
            (lambda _
              (invoke "make" "-C" "qubes-rpc" "CC=gcc")))
          ;; All dirs are ?= vars, so a flat prefix works without DESTDIR.
          ;; qfile-unpacker's 4755 is stripped by the store; setuid is
          ;; provided by setuid-programs in config.scm instead.
          (replace 'install
            (lambda _
              (invoke "make" "-C" "qubes-rpc" "install"
                      (string-append "BINDIR=" #$output "/bin")
                      (string-append "LIBDIR=" #$output "/lib")
                      (string-append "SYSCONFDIR=" #$output "/etc"))))
          (add-after 'install 'fix-script-paths
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((qubeslib  (string-append #$output "/lib/qubes/"))
                     (client-vm (search-input-file
                                 inputs "/usr/bin/qrexec-client-vm"))
                     (bash      (search-input-file inputs "/bin/bash"))
                     (vmexec    (search-input-file inputs "/bin/qubes-vmexec"))
                     ;; Regular non-ELF files only: substitute* would turn
                     ;; symlinks into copies (qubes.VMExecGUI, qubes.Log),
                     ;; choke on the dangling /dev/tcp ones, and mangle
                     ;; binaries.
                     (scripts
                      (apply append
                       (map
                        (lambda (dir)
                          (find-files (string-append #$output dir)
                                      (lambda (file stat)
                                        (and (eq? 'regular (stat:type stat))
                                             (not (elf-file? file))))))
                        '("/bin" "/lib/qubes" "/etc/qubes-rpc")))))
                ;; Order matters: specific paths before the generic prefix.
                (substitute* scripts
                  (("/usr/lib/qubes/qrexec-client-vm") client-vm)
                  (("/usr/lib/qubes/qfile-unpacker")
                   "/run/privileged/bin/qfile-unpacker")
                  (("/usr/lib/qubes/") qubeslib)
                  (("exec /bin/bash") (string-append "exec " bash))
                  ;; qubes.VMExec / qubes.VMRootExec
                  (("/usr/bin/qubes-vmexec") vmexec)
                  ;; qvm-copy finds helpers via ${0%/*}/../lib/qubes, i.e.
                  ;; relative to the *profile* symlink, where
                  ;; qrexec-client-vm does not exist.
                  (("\\$scriptdir/qubes/qrexec-client-vm") client-vm)
                  (("\\$scriptdir/qubes/") qubeslib))
                ;; The stock patch-shebangs phase only covers bin/sbin/libexec;
                ;; the service scripts live in etc/qubes-rpc and lib/qubes.
                (for-each patch-shebang scripts)))))))
    (inputs
     (list bash                         ; full bash: VMShell is interactive
           python                       ; shebangs of qrun-in-vm, xdg-icon,
                                        ; qubes-sync-clock, qubes.StartApp
           qubes-linux-utils            ; libqubes-rpc-filecopy, libqubes-pure
           qubes-core-qubesdb           ; libqubesdb (vm-log)
           qubes-core-qrexec            ; qrexec-client-vm path
           python-qubesagent))          ; qubes-vmexec for qubes.VMExec
    (home-page "https://github.com/QubesOS/qubes-core-agent-linux")
    (synopsis "Qubes OS guest agent: qrexec services and file-copy tools")
    (description
     "The qubes-rpc part of the Qubes OS Linux guest agent: the
@file{/etc/qubes-rpc} service scripts, their @file{rpc-config} flags, the
file copy/open helpers (qfile-agent, qfile-unpacker, tar2qfile,
vm-file-editor, vm-log) and the qvm-copy / qvm-open-in-vm / qvm-run-vm
user commands.")
    (license license:gpl2+)))

;;; The python half: qubesagent module (vmexec, firewall, xdg).
;;; setup.py's CustomInstall writes launcher scripts to <root>/usr/bin —
;;; impossible in the sandbox and ignored by wheel builds — so drop it and
;;; write the two launchers ourselves; the 'wrap phase then sets
;;; GUIX_PYTHONPATH so they find qubesagent (and qubesdb for firewall).
(define-public python-qubesagent
  (package
    (name "python-qubesagent")
    (version (package-version qubes-core-agent))
    (source (package-source qubes-core-agent))
    (build-system pyproject-build-system)
    (arguments
     (list
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'drop-custom-install
            (lambda _
              (substitute* "setup.py"
                (("'install': CustomInstall,") ""))))
          ;; Must run before 'wrap so the launchers get wrapped.
          (add-after 'install 'install-launchers
            (lambda _
              (let ((bin (string-append #$output "/bin"))
                    (python (which "python3")))
                (mkdir-p bin)
                (for-each
                 (lambda (entry)
                   (let ((file (string-append bin "/" (car entry))))
                     (call-with-output-file file
                       (lambda (port)
                         (format port "#!~a
from ~a import main
import sys
if __name__ == '__main__':
    sys.exit(main())
" python (cdr entry))))
                     (chmod file #o755)))
                 '(("qubes-vmexec" . "qubesagent.vmexec")
                   ("qubes-firewall" . "qubesagent.firewall"))))))
          ;; Only the vmexec tests: the others need qubesdb running,
          ;; pyxdg, gi or a network VM.
          (replace 'check
            (lambda* (#:key tests? #:allow-other-keys)
              (when tests?
                (invoke "python3" "-m" "unittest" "qubesagent.test_vmexec")))))))
    (native-inputs (list python-setuptools python-wheel))
    ;; firewall.py imports qubesdb; propagate so the wrapper's
    ;; GUIX_PYTHONPATH includes its python module.
    (propagated-inputs (list qubes-core-qubesdb))
    (home-page "https://github.com/QubesOS/qubes-core-agent-linux")
    (synopsis "Qubes OS guest agent python module (qubes-vmexec)")
    (description
     "The @code{qubesagent} python module from the Qubes OS Linux guest
agent, with the @command{qubes-vmexec} launcher used by the
@code{qubes.VMExec} qrexec service, and @command{qubes-firewall}.")
    (license license:gpl2+)))
