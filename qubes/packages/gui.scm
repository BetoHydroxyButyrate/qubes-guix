;;; qubes/packages/gui.scm — Qubes GUI agent for Guix System.
;;;
;;; qubes-gui-common: protocol headers only.
;;; qubes-gui-agent:  qubes-gui (vchan <-> X11 bridge), qubes-gui-runuser
;;;   (PAM session launcher), the Xorg drivers dummyqbs (shared-memory
;;;   framebuffer over gntalloc) and qubes (input), and the scripts that
;;;   start Xorg, rewritten for Guix. Audio (pulse/, pipewire/) is out of
;;;   scope for now.

(define-module (qubes packages gui)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system copy)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages glib)            ; dbus
  #:use-module (gnu packages gl)              ; mesa (gbm)
  #:use-module (gnu packages libunistring)
  #:use-module (gnu packages linux)           ; linux-pam
  #:use-module (gnu packages pulseaudio)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages virtualization)  ; xen (xengnttab)
  #:use-module (gnu packages xdisorg)         ; libdrm, pixman
  #:use-module (gnu packages xorg)
  #:use-module (qubes packages vchan)
  #:use-module (qubes packages qubesdb)
  #:use-module (qubes packages qrexec))

(define-public qubes-gui-common
  (package
    (name "qubes-gui-common")
    (version "4.3.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/QubesOS/qubes-gui-common")
             (commit "66b879e36d6cd2a01271fc8d4c2c0f3be85d0029"))) ; v4.3.1
       (file-name (git-file-name name version))
       (sha256
        (base32 "1ilr2wximl82y05f9dha69pjwhks2c73cfh08yxpnbdg5yspcc24"))))
    (build-system copy-build-system)
    (arguments (list #:install-plan ''(("include/" "include/"))))
    (home-page "https://github.com/QubesOS/qubes-gui-common")
    (synopsis "Qubes OS GUI protocol headers")
    (description "Headers shared by the Qubes OS GUI daemon and agents.")
    (license license:gpl2+)))

(define-public qubes-gui-agent
  (package
    (name "qubes-gui-agent")
    (version "4.3.21")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/QubesOS/qubes-gui-agent-linux")
             (commit "a7528d157abea4fef71dacf64bb1981e24ef1a1d"))) ; v4.3.21
       (file-name (git-file-name name version))
       (sha256
        (base32 "15y0mi19k3r9mhpk8v50ynvr1r77hb46m9a4fydpsxv8zhvjh1sx"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'patch-sources
            (lambda _
              ;; qubes-gui forks and execs the Xorg launcher by absolute path.
              (substitute* "gui-agent/vmside.c"
                (("\"/usr/bin/qubes-run-xorg\"")
                 (string-append "\"" #$output "/bin/qubes-run-xorg\"")))
              ;; Same bug class as qrexec-agent's env_buf[64]: PATH/SHELL are
              ;; long on Guix; overflow = silent PAM session failure.
              (substitute* "gui-agent/qubes-gui-runuser.c"
                (("char env_buf\\[256\\];") "char env_buf[4096];"))))
          (add-before 'build 'ensure-pkgconfig
            (lambda* (#:key inputs #:allow-other-keys)
              (setenv "PKG_CONFIG_PATH"
                      (string-append
                       (dirname (search-input-file inputs "/lib/pkgconfig/vchan.pc"))
                       ":" (or (getenv "PKG_CONFIG_PATH") "")))))
          ;; NO CFLAGS/LDFLAGS on make command lines (they'd replace the
          ;; Makefiles' += accumulations). Autotools drivers take LDFLAGS at
          ;; configure time, which is the normal, appending mechanism there.
          (replace 'build
            (lambda _
              (invoke "make" "-C" "gui-agent" "CC=gcc")
              (invoke "make" "-C" "xf86-qubes-common" "libxf86-qubes-common.so")
              ;; Both drivers link libxf86-qubes-common from the build tree;
              ;; bake in where it will live after install.
              ;; The sandbox has no /bin/sh: run configure through bash and
              ;; make configure/libtool/make use it (as the stock 'configure
              ;; phase does), or the #!/bin/sh shebang fails with ENOENT.
              (let ((bash (which "bash")))
                (setenv "CONFIG_SHELL" bash)
                (setenv "SHELL" bash))
              (for-each
               (lambda (dir)
                 (with-directory-excursion dir
                   (invoke "autoreconf" "-vfi")
                   (invoke (getenv "CONFIG_SHELL") "./configure"
                           (string-append "--prefix=" #$output)
                           (string-append "LDFLAGS=-Wl,-rpath," #$output "/lib"))
                   (invoke "make")))
               '("xf86-video-dummy" "xf86-input-mfndev"))
              ;; PulseAudio sink over vchan. It includes PA's *internal*
              ;; pulsecore headers, vendored per PA release: pick the set
              ;; matching our pulseaudio exactly (upstream's Makefile does
              ;; the same symlink), and fail loudly if there is none.
              (invoke "sh" "-c"
                      (string-append
                       "v=$(pkg-config --modversion libpulse | cut -d- -f1) && "
                       "test -d pulse/pulsecore-$v && "
                       "ln -sfn pulsecore-$v pulse/pulsecore"))
              (invoke "make" "-C" "pulse" "module-vchan-sink.so")))
          (replace 'install
            (lambda _
              (let ((bin     (string-append #$output "/bin"))
                    (lib     (string-append #$output "/lib"))
                    (drivers (string-append #$output "/lib/xorg/modules/drivers"))
                    (qlib    (string-append #$output "/lib/qubes"))
                    (x11     (string-append #$output "/etc/X11")))
                (for-each mkdir-p (list bin lib drivers qlib x11))
                (install-file "gui-agent/qubes-gui" bin)
                (install-file "gui-agent/qubes-gui-runuser" bin)
                (install-file "xf86-qubes-common/libxf86-qubes-common.so" lib)
                (install-file "xf86-video-dummy/src/.libs/dummyqbs_drv.so" drivers)
                (install-file "xf86-input-mfndev/src/.libs/qubes_drv.so" drivers)
                (install-file "appvm-scripts/usrbin/qubes-run-xorg" bin)
                (install-file "appvm-scripts/usr/lib/qubes/qubes-xorg-wrapper" qlib)
                (install-file "appvm-scripts/etc/X11/xorg-qubes.conf.template" x11)
                (install-file "appvm-scripts/usrbin/qubes-set-monitor-layout" bin)
                (install-file "appvm-scripts/usr/lib/qubes/qubes-keymap.sh" qlib)
                ;; PA can't take modules into its own (store) module dir; we
                ;; start it with --dl-search-path covering this dir too.
                (install-file "pulse/module-vchan-sink.so"
                              (string-append #$output "/lib/pulse-qubes"))
                (install-file "pulse/qubes-default.pa"
                              (string-append #$output "/etc/pulse"))
                ;; qrexec service (upstream: symlink into /etc/qubes-rpc).
                ;; The guest service links this dir into /run/qubes-rpc.
                (mkdir-p (string-append #$output "/etc/qubes-rpc"))
                (symlink (string-append bin "/qubes-set-monitor-layout")
                         (string-append #$output
                                        "/etc/qubes-rpc/qubes.SetMonitorLayout")))))
          (add-after 'install 'adapt-scripts
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((bin      (string-append #$output "/bin"))
                     (qdb      (search-input-file inputs "/bin/qubesdb-read"))
                     (xinit    (search-input-file inputs "/bin/xinit"))
                     (xorg     (search-input-file inputs "/bin/Xorg"))
                     (xorg-mod (string-append (dirname (dirname xorg))
                                              "/lib/xorg/modules"))
                     (template (string-append #$output
                                              "/etc/X11/xorg-qubes.conf.template")))
                ;; Generated config goes to /var/run/qubes (created 2770
                ;; root:qubes at boot), not the read-mostly /etc/X11.
                (substitute* (string-append bin "/qubes-run-xorg")
                  (("^\\. /usr/lib/qubes/init/functions")
                   "qsvc() { [ -e \"/run/qubes-service/$1\" ]; }")
                  ;; output path first, anchored to the line end: the
                  ;; template's store path also contains
                  ;; "/etc/X11/xorg-qubes.conf". substitute* lines keep their
                  ;; "\n", so `$` would never match — match the newline.
                  (("/etc/X11/xorg-qubes\\.conf\n") "/var/run/qubes/xorg-qubes.conf\n")
                  (("/etc/X11/xorg-qubes\\.conf\\.template") template)
                  (("-config xorg-qubes\\.conf")
                   "-config /var/run/qubes/xorg-qubes.conf")
                  (("XSESSION=\"/etc/X11/xinit/xinitrc\"")
                   (string-append "XSESSION=\"" bin "/qubes-session\""))
                  (("/usr/bin/qubes-gui-runuser")
                   (string-append bin "/qubes-gui-runuser"))
                  (("/usr/bin/xinit") xinit)
                  (("/usr/lib/qubes/qubes-xorg-wrapper")
                   (string-append #$output "/lib/qubes/qubes-xorg-wrapper"))
                  (("qubesdb-read ") (string-append qdb " "))
                  ;; Coexist with a local desktop (display manager on :0 /
                  ;; vt7 on the emulated VGA): the agent's Xorg takes :1 and
                  ;; never touches VTs. -sharevts skips VT_ACTIVATE /
                  ;; KD_GRAPHICS / VT process mode entirely; the dummyqbs and
                  ;; qubes drivers need no console. (Upstream instead makes
                  ;; gui-agent and lightdm mutually exclusive.)
                  (("DISPLAY=:0") "DISPLAY=:1")
                  ;; Seatless session: with XDG_SEAT=seat0, pam_elogind
                  ;; registers a second graphical session on seat0 and makes
                  ;; it active, pausing the local desktop's DRM/input access.
                  (("XDG_SEAT=seat0 ") "")
                  ((" :0 -nolisten tcp vt07 ")
                   " :1 -nolisten tcp -sharevts -novtswitch "))
                ;; dom0 sends the monitor layout; apply it to OUR X (:1)
                ;; with store-path xrandr/cvt (the qrexec session PATH may
                ;; not have them).
                (let ((xrandr (search-input-file inputs "/bin/xrandr"))
                      (cvt    (search-input-file inputs "/bin/cvt")))
                  (substitute* (string-append bin "/qubes-set-monitor-layout")
                    (("export DISPLAY=:0") "export DISPLAY=:1")
                    ;; command positions only: not $xrandr_cmd / xrandr_cmd=
                    (("(^|[^_$[:alnum:]])xrandr " all pre)
                     (string-append pre xrandr " "))
                    (("`cvt ") (string-append "`" cvt " "))))
                ;; Keyboard: the qubes input driver registers its keyboard
                ;; with the server's DEFAULT XKB keymap, and dom0 sends raw
                ;; evdev keycodes. Guix's Xorg default isn't evdev, so the
                ;; letters (same codes either way) worked but arrows/nav keys
                ;; didn't. Apply dom0's layout (qubesdb /keyboard-layout) with
                ;; evdev rules forced, on our display only (:1 — not the local
                ;; desktop's :0), and follow changes via qubesdb-watch.
                (let ((setxkbmap (search-input-file inputs "/bin/setxkbmap"))
                      (qwatch (string-append (dirname qdb) "/qubesdb-watch"))
                      (keymap (string-append #$output "/lib/qubes/qubes-keymap.sh")))
                  (substitute* keymap
                    (("/usr/bin/qubesdb-read") qdb)
                    (("qubesdb-watch ") (string-append qwatch " "))
                    (("for x in /tmp/\\.X11-unix/X\\*")
                     "for x in /tmp/.X11-unix/X1")
                    (("setxkbmap -display")
                     (string-append setxkbmap " -rules evdev -model pc105 -display")))
                  (patch-shebang keymap))
                (substitute* (string-append #$output "/lib/qubes/qubes-xorg-wrapper")
                  (("XORG=\"/usr/bin/X\"") (string-append "XORG=\"" xorg "\"")))
                ;; Our drivers live outside xorg-server's module dir; a Files
                ;; section replaces the default ModulePath, so list both.
                (substitute* template
                  (("^Section \"Module\"")
                   (string-append "Section \"Files\"\n        ModulePath \""
                                  #$output "/lib/xorg/modules," xorg-mod
                                  "\"\nEndSection\n\n"
                                  ;; Never probe real hardware: the emulated
                                  ;; VGA and QEMU input belong to the local
                                  ;; desktop on :0; ours are dummyqbs + qubes.
                                  "Section \"ServerFlags\"\n"
                                  "        Option \"AutoAddDevices\" \"false\"\n"
                                  "        Option \"AutoAddGPU\" \"false\"\n"
                                  "        Option \"AutoBindGPU\" \"false\"\n"
                                  "EndSection\n\nSection \"Module\""))))))
          ;; Guix replacements for upstream's systemd-coupled glue.
          (add-after 'adapt-scripts 'install-guix-glue
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((bin   (string-append #$output "/bin"))
                     (sh    (search-input-file inputs "/bin/sh"))
                     (qdb   (search-input-file inputs "/bin/qubesdb-read"))
                     (fork  (search-input-file inputs
                                               "/usr/bin/qrexec-fork-server"))
                     (xsetroot (search-input-file inputs "/bin/xsetroot"))
                     (sleep (search-input-file inputs "/bin/sleep")))
                (define (write-script name body)
                  (let ((file (string-append bin "/" name)))
                    (call-with-output-file file
                      (lambda (port) (format port "#!~a~%~a" sh body)))
                    (chmod file #o755)))
                ;; = upstream qubes-gui-agent-pre.sh + ExecStart, minus the
                ;; /run/qubes-service-environment indirection. Run by shepherd
                ;; as root. Runs the agent's X on :1 without a VT so it can
                ;; coexist with a local desktop on :0 (see adapt-scripts).
                (write-script "qubes-gui-agent-start"
                  (string-append "
set -u
user=\"$(" qdb " /default-user)\" || exit 1
mkdir -p /var/run/console
: > \"/var/run/console/$user\"
gui_xid=\"$(" qdb " -w /qubes-gui-domain-xid)\"
[ -n \"$gui_xid\" ] || gui_xid=0
opts=\"-d $gui_xid\"
debug=\"$(" qdb " /qubes-debug-mode 2>/dev/null || true)\"
if [ -n \"$debug\" ] && [ \"$debug\" -gt 0 ]; then opts=\"$opts -vv\"; fi
echo 1073741824 > /sys/module/xen_gntalloc/parameters/limit || true
# Upstream unbinds bochs-drm (the emulated VGA) here. NOT done: a local
# desktop may be running on it. Likewise stdin is NOT a tty: that makes
# qubes-gui-runuser skip PAM_TTY/XDG_VTNR/VT_ACTIVATE, so the emulated
# console is left alone.
export DISPLAY=:1
exec " #$output "/bin/qubes-gui $opts </dev/null
"))
                ;; = upstream start-pulseaudio-with-vchan. Run from
                ;; qubes-session (background: it waits for the audio domain).
                ;; A local desktop may already have autospawned a PA for this
                ;; user (one per user): replace it with the Qubes-configured
                ;; one; later `pulseaudio --start` calls then find ours.
                (let* ((pa    (search-input-file inputs "/bin/pulseaudio"))
                       (padir (dirname (search-input-file
                                        inputs
                                        "/lib/pulseaudio/modules/module-null-sink.so"))))
                  (write-script "qubes-start-pulseaudio"
                    (string-append "
set -u
[ -e /run/qubes-service/pipewire ] && exit 0
" qdb " -w /qubes-audio-domain-xid >/dev/null || exit 0
" pa " --kill 2>/dev/null || true
sleep 1
exec " pa " --start -n --file=" #$output "/etc/pulse/qubes-default.pa \\
  --exit-idle-time=-1 \\
  --dl-search-path=" #$output "/lib/pulse-qubes:" padir "
")))
                ;; = upstream qubes-session, minus systemd --user and XDG
                ;; autostart (needs pyxdg; later). The fork server creates
                ;; /var/run/qubes/qrexec-server.$USER.sock, which
                ;; qubes.WaitForSession waits for and qrexec-agent uses to run
                ;; services inside this session. It daemonizes itself (parent
                ;; exits 0 after bind), so `wait` returns at once: the script
                ;; must then block forever like upstream's `sleep inf`, or
                ;; xinit sees the client exit and shuts the X server down.
                (write-script "qubes-session"
                  (string-append "
" xsetroot " -solid white || true
" #$output "/lib/qubes/qubes-keymap.sh &
" #$output "/bin/qubes-start-pulseaudio &
" fork "
exec " sleep " infinity
"))))))))
    (native-inputs
     (list autoconf automake libtool pkg-config util-macros))
    (inputs
     (list bash-minimal
           dbus
           libdrm
           libunistring
           libx11
           libxcomposite
           libxcursor
           libxdamage
           libxfixes
           libxt
           linux-pam
           mesa
           pixman
           xen
           xinit
           xorgproto
           xorg-server                  ; also provides cvt
           xrandr
           setxkbmap
           pulseaudio                   ; libpulse.pc + the daemon we start
           libltdl                      ; pulsecore/module.h includes ltdl.h
           xsetroot
           qubes-core-vchan-xen
           qubes-core-qubesdb
           qubes-core-qrexec
           qubes-gui-common))
    (home-page "https://github.com/QubesOS/qubes-gui-agent-linux")
    (synopsis "Qubes OS GUI agent (seamless windows) for Guix System")
    (description
     "The Qubes OS GUI agent: @command{qubes-gui} relays X11 windows to the
GUI domain over vchan; the @code{dummyqbs} and @code{qubes} Xorg drivers
provide a grant-table-shared framebuffer and input. Includes Guix-specific
start-up glue replacing the upstream systemd units.")
    (license license:gpl2+)))
