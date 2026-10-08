;;; qubes/packages/core-agent.scm — qubes-core-agent-linux, qubes-rpc/ half.
;;;
;;; Scope: C helpers (qfile-*, tar2qfile, vm-file-editor, ...),
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
  #:use-module (gnu packages freedesktop)     ; python-pyxdg
  #:use-module (gnu packages gnome)           ; zenity
  #:use-module (gnu packages gtk)             ; gtk (schemas for zenity)
  #:use-module (gnu packages imagemagick)     ; graphicsmagick
  #:use-module (gnu packages glib)            ; python-pygobject, gobject-introspection
  ;; Adjust these three to your actual module / variable names if they differ.
  #:use-module (qubes packages linux-utils)   ; qubes-linux-utils
  #:use-module (qubes packages qrexec)        ; qubes-core-qrexec
  #:use-module (qubes packages qubesdb))      ; qubes-core-qubesdb

(define-public qubes-core-agent
  (package
    (name "qubes-core-agent")
    (version "4.3.48")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/QubesOS/qubes-core-agent-linux")
             ;; v4.3.48 = head of release4.3, matching the R4.3 dom0
             ;; (main is R4.4: sys-log/vm-log, qubes.PostUpdate).
             (commit "e1cf5585c03149ec9e331983515b0431779f2da0")))
       (file-name (git-file-name name version))
       (sha256
        ;; Precomputed NAR hash of the checkout; if guix disagrees,
        ;; paste the hash it reports.
        (base32 "1fvsgyxxya5nbaxrh3b40bq2v5b6rajsdmi513c047n6zfqa7ic3"))))
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
          ;; gui-fatal.c (error dialogs of qfile-agent/qfile-unpacker)
          ;; execlp()s /usr/bin/zenity.
          (add-before 'build 'patch-zenity
            (lambda* (#:key inputs #:allow-other-keys)
              (substitute* "qubes-rpc/gui-fatal.c"
                (("/usr/bin/zenity")
                 (string-append #$output "/libexec/qubes-zenity")))))
          ;; release4.3 creates suspend-pre.d, suspend-post.d and
          ;; post-install.d as $(DESTDIR)/etc/qubes/... but installs into
          ;; $(QUBESCONFDIR)/... -> "cannot create directory '/etc/qubes'".
          ;; Backport of upstream main 8bc5d2d0.
          (add-before 'build 'fix-qubesconfdir
            (lambda _
              (substitute* "qubes-rpc/Makefile"
                (("\\$\\(DESTDIR\\)/etc/qubes/")
                 "$(DESTDIR)$(QUBESCONFDIR)/"))))
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
          ;; zenity 4 (GTK4) aborts unless GSettings finds GTK's schemas
          ;; (org.gtk.gtk4.Settings.FileChooser); qrexec sessions don't have
          ;; GTK on XDG_DATA_DIRS. Compile GTK's schemas into our own dir and
          ;; call zenity through a wrapper that points GSETTINGS_SCHEMA_DIR
          ;; at it.
          (add-after 'install 'install-zenity-wrapper
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((schemas (string-append #$output "/share/qubes/gsettings-schemas"))
                     (gtk-xml (search-input-file
                               inputs
                               "/share/glib-2.0/schemas/org.gtk.gtk4.Settings.FileChooser.gschema.xml"))
                     (wrapper (string-append #$output "/libexec/qubes-zenity")))
                (mkdir-p schemas)
                (for-each (lambda (f) (install-file f schemas))
                          (find-files (dirname gtk-xml) "\\.gschema\\.xml$"))
                (invoke "glib-compile-schemas" schemas)
                (mkdir-p (dirname wrapper))
                (call-with-output-file wrapper
                  (lambda (port)
                    (format port "#!~a
export GSETTINGS_SCHEMA_DIR=~a
exec ~a \"$@\"
"
                            (search-input-file inputs "/bin/sh")
                            schemas
                            (search-input-file inputs "/bin/zenity"))))
                (chmod wrapper #o755))))
          (add-after 'install-zenity-wrapper 'fix-script-paths
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((qubeslib  (string-append #$output "/lib/qubes/"))
                     (client-vm (search-input-file
                                 inputs "/usr/bin/qrexec-client-vm"))
                     (bash      (search-input-file inputs "/bin/bash"))
                     (vmexec    (search-input-file inputs "/bin/qubes-vmexec"))
                     (zenity    (string-append #$output "/libexec/qubes-zenity"))
                     ;; Regular non-ELF files only: substitute* would turn
                     ;; symlinks into copies (qubes.VMExecGUI),
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
                  ;; qubes.SelectFile/SelectDirectory (exec zenity ...),
                  ;; qvm-open-in-vm (test -f + prompt), qvm-actions.sh.
                  (("/usr/bin/zenity") zenity)
                  (("(^|[[:space:]])zenity --" all pre)
                   (string-append pre zenity " --"))
                  ;; qvm-copy finds helpers via ${0%/*}/../lib/qubes, i.e.
                  ;; relative to the *profile* symlink, where
                  ;; qrexec-client-vm does not exist.
                  (("\\$scriptdir/qubes/qrexec-client-vm") client-vm)
                  (("\\$scriptdir/qubes/") qubeslib))
                ;; The stock patch-shebangs phase only covers bin/sbin/libexec;
                ;; the service scripts live in etc/qubes-rpc and lib/qubes.
                (for-each patch-shebang scripts))))
          ;; qubes.WaitForSession: on R4.3 core-agent installs its own
          ;; (systemctl --user, and with gui it waits with no timeout for
          ;; the qrexec-server socket). Replace it with the Guix version
          ;; from our qrexec package. /etc/qubes-rpc is this package's
          ;; directory, so link it in rather
          ;; than union the two dirs: the agent readlink()s services ONE
          ;; level to spot /dev/tcp targets, so a union (symlink->symlink)
          ;; would break qubes.ConnectTCP and qubes.UpdatesProxy.
          (add-after 'fix-script-paths 'link-wait-for-session
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((svc (string-append #$output
                                        "/etc/qubes-rpc/qubes.WaitForSession")))
                (when (file-exists? svc)
                  (delete-file svc))
                (symlink (search-input-file
                          inputs "/etc/qubes-rpc/qubes.WaitForSession")
                         svc))))
          ;; qubes.StartApp needs qubesagent + pyxdg + PyGObject + qubesdb on
          ;; its path; python-qubesagent ships it as a wrapped program.
          ;; (Symlink to a regular file: fine for the agent's readlink check.)
          (add-after 'link-wait-for-session 'link-startapp
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((svc (string-append #$output "/etc/qubes-rpc/qubes.StartApp")))
                (delete-file svc)
                (symlink (search-input-file inputs "/bin/qubes-startapp")
                         svc))))
          ;; qubes.GetImageRGBA (dom0 fetching app-menu icons) runs gm and
          ;; rsvg-convert from PATH, and lib/qubes/xdg-icon, a python script
          ;; that imports pyxdg and lists /usr/share/icons. qrexec services
          ;; get a minimal environment: no GUIX_PYTHONPATH, no XDG_DATA_DIRS
          ;; with the system profile, and no /usr/share.
          (add-after 'link-startapp 'fix-icon-helpers
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((rgba (string-append #$output
                                         "/etc/qubes-rpc/qubes.GetImageRGBA"))
                    (xdg-icon (string-append #$output "/lib/qubes/xdg-icon"))
                    (gm (search-input-file inputs "/bin/gm"))
                    (rsvg (search-input-file inputs "/bin/rsvg-convert")))
                (substitute* rgba
                  (("(^|[$(]|[[:space:]])gm " all pre)
                   (string-append pre gm " "))
                  (("rsvg-convert ") (string-append rsvg " ")))
                (substitute* xdg-icon
                  (("/usr/share/icons")
                   "/run/current-system/profile/share/icons"))
                (wrap-program xdg-icon
                  `("GUIX_PYTHONPATH" ":" prefix (,(getenv "GUIX_PYTHONPATH")))
                  `("XDG_DATA_DIRS" ":" suffix
                    ("/run/current-system/profile/share")))))))))
    (native-inputs
     (list `(,glib "bin")))             ; glib-compile-schemas
    (inputs
     (list bash                         ; full bash: VMShell is interactive
           python                       ; shebangs of qrun-in-vm, xdg-icon,
                                        ; qubes-sync-clock, qubes.StartApp
           qubes-linux-utils            ; libqubes-rpc-filecopy, libqubes-pure
           qubes-core-qubesdb           ; no C user on R4.3 (vm-log is R4.4);
                                        ; kept until a build proves it unneeded
           qubes-core-qrexec            ; qrexec-client-vm path
           python-qubesagent            ; qubes-vmexec for qubes.VMExec
           zenity                       ; SelectFile/SelectDirectory, dialogs
           gtk                          ; its GSettings schemas (see wrapper)
           python-pyxdg                 ; xdg-icon (qubes.GetImageRGBA)
           graphicsmagick               ; gm in qubes.GetImageRGBA
           librsvg))                    ; rsvg-convert in qubes.GetImageRGBA
    (home-page "https://github.com/QubesOS/qubes-core-agent-linux")
    (synopsis "Qubes OS guest agent: qrexec services and file-copy tools")
    (description
     "The qubes-rpc part of the Qubes OS Linux guest agent: the
@file{/etc/qubes-rpc} service scripts, their @file{rpc-config} flags, the
file copy/open helpers (qfile-agent, qfile-unpacker, tar2qfile,
vm-file-editor) and the qvm-copy / qvm-open-in-vm / qvm-run-vm
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
                   ("qubes-firewall" . "qubesagent.firewall")))
                ;; qubes.StartApp (lives in qubes-rpc/, not the module); its
                ;; "#!/usr/bin/python3 --" is fixed by 'patch-shebangs and it
                ;; gets GUIX_PYTHONPATH from 'wrap like the launchers.
                (copy-file "qubes-rpc/qubes.StartApp"
                           (string-append bin "/qubes-startapp"))
                (chmod (string-append bin "/qubes-startapp") #o755))))
          ;; 'wrap only sets GUIX_PYTHONPATH; qubesagent.xdg also needs the
          ;; Gio/GLib typelibs.
          (add-after 'wrap 'wrap-typelibs
            (lambda _
              (for-each
               (lambda (prog)
                 (wrap-program (string-append #$output "/bin/" prog)
                   `("GI_TYPELIB_PATH" ":" prefix
                     (,(getenv "GI_TYPELIB_PATH")))))
               '("qubes-startapp"))))
          ;; Only the vmexec tests: the others need qubesdb running,
          ;; pyxdg, gi or a network VM.
          (replace 'check
            (lambda* (#:key tests? #:allow-other-keys)
              (when tests?
                (invoke "python3" "-m" "unittest" "qubesagent.test_vmexec")))))))
    (native-inputs (list python-setuptools python-wheel))
    ;; GI_TYPELIB_PATH search path comes from gobject-introspection.
    (inputs (list gobject-introspection glib))
    ;; Propagated so the 'wrap phase's GUIX_PYTHONPATH covers them:
    ;; qubesdb (firewall, StartApp), pyxdg + PyGObject (qubesagent.xdg).
    (propagated-inputs (list qubes-core-qubesdb python-pyxdg python-pygobject))
    (home-page "https://github.com/QubesOS/qubes-core-agent-linux")
    (synopsis "Qubes OS guest agent python module (qubes-vmexec)")
    (description
     "The @code{qubesagent} python module from the Qubes OS Linux guest
agent, with the @command{qubes-vmexec} launcher used by the
@code{qubes.VMExec} qrexec service, and @command{qubes-firewall}.")
    (license license:gpl2+)))
