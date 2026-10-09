# PORT-NOTES.md — Guix System on Qubes OS (guix HVM)

## Project Goal
Port Qubes OS guest agents to Guix System so a standalone HVM becomes a
fully-integrated qube: qrexec (survival + command exec), then
qubes-gui-agent (clipboard, seamless windows).

Target: Qubes R4.3.1 (dom0 side), Guix System with linux-libre 6.17,
Xen 4.21.1 guest libraries (from Guix's `xen` package — modern, contrary
to stale forum claims of 4.10).

## Environment Facts
- VM: `guix`, StandaloneVM, hvm, kernel '', eth0 static 10.137.0.49/8,
  gw 10.138.24.90, DNS 10.139.1.1/.2, NetVM sys-firewall-13_13wtf (VLAN 13).
- Intra-VLAN access requires BOTH: `qvm-firewall <src> add accept ...`
  on the source qube AND an `nft` rule in `custom-forward` chain on the
  VLAN firewall clone (persist via /rw/config/qubes-firewall-user-script).

## Package Status (channel: ~/src/qubes, module (qubes packages *))
Channel layout: <root>/qubes/packages/*.scm — module name MUST mirror
file path. Clone all repos from matching tag (R4.3 branch where it
exists).

1. qubes-core-vchan-xen 4.2.8 (tag) — GREEN.
   Builds against Guix Xen 4.21 libxenvchan. Ships lib/libvchan-xen.so.1,
   include/vchan-xen/libvchan.h, both vchan.pc and vchan-xen.pc.
2. qubes-linux-utils mm_25063069 — GREEN.
   Built qmemman/ + qrexec-lib/ only (skip selinux/udev/dracut/etc).
   Artifacts: bin/meminfo-writer, lib/libqubes-pure.so.0,
   libqubes-rpc-filecopy.so.
3. qubes-core-qrexec mm_fa044832 — GREEN.
   Agent-side only (agent/ + libqrexec/; daemon/ is dom0-side, skipped).
   Layout: lib/libqrexec-utils.so.4 + headers; usr/lib/qubes/qrexec-agent,
   usr/bin/{qrexec-client-vm,qrexec-fork-server}. ldd closure clean.
4. qubes-core-agent-linux — NOT STARTED. Needed for: /etc/qubes-rpc
   service scripts (qubes.WaitForSession etc.), meminfo/meminfo-writer
   service, Python agent, suspend hooks.
5. qubes-gui-agent-linux — NOT STARTED (the payoff).

## Bug Taxonomy (patterns that WILL recur)

### Guix derivation gotchas
- `remove`, `append-map` etc. are SRFI-1: NOT in build-side default modules. Use core Guile ((apply append (map ...))) or add #:modules with (srfi srfi-1).
- Backtick/comma in pasted config → `(unquote ...)` string-append errors.
  grep -n '[`,@]' config.scm to find them.
- `missing field initializers (home-page)` is FATAL for package
  registration, not a warning. Always include home-page.
- License import: use ((guix licenses) #:prefix license:) and reference
  license:gpl2+.
- Module path must mirror file path relative to -L root. If "unknown
  package" but the file parses, check module/path match first, then
  stale bytecode (rm -rf ~/.cache/guile), then channels.scm route.
- First git-fetch: zero placeholder hash → error prints real hash →
  paste into (base32 ...).
- Replaced configure phase + autoreconf: invoke configure via (getenv "CONFIG_SHELL") and setenv CONFIG_SHELL/SHELL to bash — no /bin/sh in sandbox (ENOENT on shebang).
- (invoke "make" ... var) not (apply invoke ... mixed dots) — improper
  list errors. Count parens; replace whole file rather than patching.

### MAKEFILE + GUIX SANDBOX (the big one)
- COMMAND-LINE MAKE VARIABLES OVERRIDE ALL `+=` IN MAKEFILES. Passing
  CFLAGS=/LDFLAGS= wipes upstream's accumulated flags. Symptoms:
  * missing -shared → "no main()" link error (libqrexec case)
  * missing -D_GNU_SOURCE → implicit decl of pipe2/euidaccess
  Never pass CFLAGS/LDFLAGS wholesale. Read the Makefile; if you must
  add flags, substitute* the Makefile itself (append, don't replace).
- make PREDEFINES CC=cc, so `CC ?= gcc` is inert. Guix sandbox has no
  `cc` symlink → pass CC=gcc to every make invocation explicitly.
- Multi-.so flat Makefiles: sibling libs found via -L. at build time
  need -Wl,-rpath,<out>/lib baked in for validate-runpath. Inject via
  substitute* on the LDFLAGS += line (as a prepend), embedding the
  literal store path.
- Hardcoded /usr, /etc, /lib/systemd install paths:
  * if (DESTDIR)$(VAR): pass VAR=<out>
  * if literal /usr/...: pass DESTDIR=<out> (accepts usr/ inside output)
  * if systemd units: substitute out entirely — shepherd owns lifecycle.
- lsb_release -is probes in install targets → fails empty on Guix →
  wrong branch. Override: make ... os=Gentoo (picks an existing PAM file).
- Missing deps that surface as compile errors: icu4c (unicode/uchar.h),
  pandoc (manpages — or scrub the .1.gz target).

### Runtime (kernel / xenstore)
- GUIX: /run and /var/run are DIFFERENT directories (no symlink). Upstream
  uses both spellings interchangeably. Our convention: /var/run/qubes
  (qubesdb, qrexec sockets, fork-server, WaitForSession, xorg conf). Any
  upstream "/run/qubes..." path must be checked (qrexec's /run/qubes-rpc and
  /run/qubes/rpc-config search entries are harmless-missing).
- qubes-gui-runuser "augment_pam_env_with_systemd_env: Failed to initialize
  D-Bus" is a warnx, non-fatal (no systemd user manager on Guix).
- Xen guest modules NOT auto-loaded on this kernel config. REQUIRED:
  xen-privcmd (THE critical one — libxenctrl's xencall needs it, else
  "Could not obtain handle on privileged command interface" and every
  vchan server_init fails), xenfs, xen-evtchn, xen-gntdev, xen-gntalloc.
  Loaded at boot via kernel-module-loader-service-type in config.scm.
- Phase-0 lesson: device nodes existing at time T proves only that
  something loaded them then, NOT that boot loads them.
- /var/run/qubes must exist before agent binds its unix socket
  (ENOSPC→ENOENT bind error = missing parent dir). Created via
  activation-service-type mkdir-p. Also MEMINFO_WRITER_PIDFILE lives
  in /var/run/.
- vchan rendezvous published to xenstore at
  /local/domain/<domid>/data/vchan/<own-domid>/<port>/ with ring-ref +
  event-channel. EMPTY data/vchan with agent running = normal idle IF
  no active session; published keys seen on domid 38 boot
  (ring-ref 2101, event-channel 68 — matching agent's bound port).
- Agent built WITHOUT PAM (HAVE_PAM_APPL probe needs
  /usr/include/security/pam_appl.h). Deferred: qvm-run user sessions
  may need -DHAVE_PAM forced + linux-pam in inputs.
- xc_evtchn_status / privcmd EPERM at agent startup: benign probe
  failures, agent proceeds.

## STATE AT HANDOFF
- qrexec FULLY WORKING: `qvm-run --pass-io guix 'echo hi'` round-trips.
  THE fix: kernel-arguments '("xen_privcmd.unrestricted=1" "quiet").
  Modern kernels restrict privcmd hypercalls for guests by default; all
  the "benign" EPERMs (xc_evtchn_status, privcmd ioctl 0x50:0x5) were
  actually this. Without the arg: qrexec-client.c:408 connection timeout.
- 5 packages green in ~/src/qubes channel:
  1. qubes-core-vchan-xen 4.2.8
  2. qubes-linux-utils mm_25063069
  3. qubes-core-qrexec mm_fa044832 (store: 99w5rw...dnyxi9 parent)
  4. qubes-core-agent — NOT YET PACKAGED, see below
  5. qubes-core-qubesdb 4.3.3 (commit aeb3c8d8486673636964bc3beb4819d981dd3920,
     store drv 0awcfl11hm18ir6hd56dfg8rac1qr9vi)
- Hand-made /etc/qubes-rpc/qubes.VMShell DELETED; /etc/qubes-rpc and
  /etc/qubes now come from the qubes-core-agent package (etc-service).
- 2026-09-27: qubes-core-agent GREEN (package #4). Verified: qvm-run
  --pass-io (VMShell from store), inbound qvm-copy-to-vm guix (setuid
  qfile-unpacker via /run/privileged/bin), outbound qvm-copy from guix
  via profile PATH (rc=0, file in target QubesIncoming/guix/).

## RESOLVED (2026-09-27): `qubesdb-read /name` → guix
Two independent faults, both now fixed:
1. VM daemon FORKED under shepherd. Non-systemd path in db-daemon.c
   (~l.883) forks; parent exits 0 on "ready" → shepherd saw exit →
   respawn → duplicate daemons unlinking each other's sockets and
   sharing one vchan ring. Child also logged to
   /var/log/qubes/qubesdb.dom0.log (not shepherd's log).
   FIX (in package): make SYSTEMD=0, plus substitute* in
   daemon/db-daemon.c:
     "    if (1) {"  → "    if (getenv(\"QUBESDB_FORK\")) {"
     "if (write(ready_pipe[1]" → "if (ready_pipe[1] && write(ready_pipe[1]"
   Shepherd: make-forkexec-constructor (list .../qubesdb-daemon "0"),
   respawn #t. Exactly ONE arg "0" — a 2nd arg (vm name) puts it in
   dom0-mode with domid 0 → vchan NULL, no sync, empty DB, but sockets
   still answer (signature: poll set slot fds[2] == -1).
2. DOM0's qubesdb.guix DB was EMPTY. qubesd populates ONLY at
   qvm-start (create_qdb_entries); a dom0 daemon restarted mid-session
   starts empty and nothing refills it. FIX: qvm-shutdown --wait guix
   && qvm-start guix.

### qubesdb rules learned
- Dom0 daemon EXITS PERMANENTLY if a VM client closes the vchan before
  sending its MULTIREAD (remote_connected==0 → "domain is probably
  dead" break). Log signature: "vchan closed" with no "reconnecting".
  After one completed sync, VM-side restarts are safe ("reconnecting").
- NEVER restart dom0 qubesdb-daemon by hand — restart the VM instead.
- VM can QDB_CMD_RM dom0 entries over vchan (qubesdb-rm / in the VM
  wipes dom0's copy). Don't experiment with rm on real paths.
- "terminating" in dom0 qubesdb.<vm>.log = SIGTERM (qubesd pidfile
  kill at VM start), not a crash.
- Diagnostics: VM `qubesdb-ls /` (empty list = empty DB, not a hang);
  dom0 `qubesdb-multiread -d guix /`; `ps -o lstart= -p <dom0 pid>`
  vs qubesd "Starting Qubes DB" time.
- Startup sync loop spins (handle_vchan_data returns 2, no wait) —
  100% CPU daemon with bound socket = dom0 not answering.

## DECISIONS MADE
- Ship ALL qubes-rpc scripts in one umbrella package regardless of
  whether each works at runtime ("ship-first-verify-later"); failure
  mode is clean per-service 127, working services unaffected.
- qubes-vmexec is a PYTHON setuptools entry point (qubesagent.vmexec),
  NOT C. The whole Python half of core-agent (qubesagent + qubesdb
  imports) is one cohesive future sub-project, now unblocked by pkg #5.
- qubesdb packaged as ONE derivation (C + python ext together) because
  setup.py hardcodes ../include and ../client paths.

## qubes-core-agent-linux RECON (mm_47383334, pinned — commit it)
- qubes-rpc/Makefile: BUILDABLE with existing patterns. Notes:
  * All dirs are ?= vars (BINDIR LIBDIR SYSCONFDIR) — flat prefix works.
  * DEVEL_BUILD=1: NOT USED (corrected). Its $ORIGIN/../../$LIB rpath
    only helps when libs share the prefix; ours live in other store
    items and ld-wrapper already adds their RUNPATH.
  * /dev/tcp/127.0.0.1 symlinks (ConnectTCP, UpdatesProxy) = BASH-ISM,
    intentional, not a bug. qvm-connect-tcp machinery.
  * vm-log links -lqubesdb → NOW AVAILABLE from pkg #5.
  * Build ALL except vm-log possible before #5; now nothing blocks.
  * SUID qfile-unpacker (4755): check whether store retains setuid;
    fallback = setuid-program-service-type in config.scm. TEST LATER.
- Skipped dirs: windows/ selinux/ fuzz/ distro-packaging dirs.
- Known runtime gaps (log them, don't block): ShowInTerminal needs
  xterm+socat (profile); StartApp/VMExec need qubesagent python +
  entry points (setup.py line 12).

## NEW BUILD PATTERNS LEARNED THIS SESSION (Python dialect)
- python not on PATH in gnu-build-system sandbox: resolve via
  (search-input-file inputs "/bin/python3") — NOT /bin/python (no
  bare name in Guix), and assoc-ref gives the PREFIX (dir), which
  exec 127s when invoked directly.
- setup.py: ModuleNotFoundError setuptools → add python-setuptools
  to native-inputs AND manually set GUIX_PYTHONPATH (gnu-build-system
  does NOT do it for you; python-build-system would).
- CRITICAL: LDFLAGS env var passed to setup.py build_ext REPLACES the
  extension's default link flags (distutils does not append!) → lost
  libgcc_s path → RUNPATH validation failure. Fix: patchelf
  --add-rpath (ADD not SET) post-install phase, leaving LDFLAGS alone.
  Store result validated green.
- setup.py install via (invoke python "setup.py" "install" "--prefix" out).

## STEP 4 DONE (2026-09-27): python-qubesagent GREEN
- In core-agent.scm; same source. setup.py CustomInstall removed
  (writes <root>/usr/bin — sandbox-hostile, ignored by wheel builds);
  launchers qubes-vmexec/qubes-firewall written pre-'wrap. Tests:
  qubesagent.test_vmexec only. core-agent rewrites /usr/bin/qubes-vmexec.
- dom0 only routes --no-shell to qubes.VMExec when the qube has feature
  vmexec (qvm_run.py:259); otherwise it silently falls back to VMShell
  + shlex.quote. Set by hand: `qvm-features guix vmexec 1` (upstream
  sets it at boot via qvm-features-request in misc/ — not packaged).
- patch-source-shebangs warnings for network/*.nft (nft) and
  package-managers (python2) are harmless: those files aren't installed.

## RESOLVED 2026-09-28: qrexec user switching via PAM
- VERIFIED: qvm-run -p --no-shell guix id -> uid=1000(dap), groups incl.
  qubes; -u root -> uid=0. (History below.)
- 2026-09-28: PAM agent built; every user switch exited 125 silently.
  CAUSE: do_exec() char env_buf[64]; "SHELL=<store path to bash>" is ~70
  chars -> snprintf overflow -> goto error (no log) after
  pam_open_session succeeded. FIX: substitute env_buf[64] -> [4096]
  (qrexec.scm 'enlarge-env-buf). GUIX-ISM TO WATCH FOR: fixed-size
  buffers sized for FHS paths. Worth an upstream report.
- PAM stack observed working: /etc/pam.d/qrexec (pam_rootok auth,
  pam_unix account/session) + pam_elogind auto-added to session by
  Guix's elogind service (registers a logind session, /run/user/1000).
- qrexec.scm now passes HAVE_PAM_APPL=1 to build AND install, linux-pam
  input (Damon added build side 2026-09-28).
- qrexec-agent.c non-PAM #else (~l.350): services (prog set) →
  exec_qubes_rpc2() with NO user switch (runs as root); raw commands →
  execl("/bin/su") which doesn't exist on Guix. Evidence: plain
  `qvm-run --no-shell guix id` → uid=0. Inbound qvm-copy-to-vm likely
  unpacked into /root/QubesIncoming.
- FIX (qrexec pkg): inputs += linux-pam; pass "HAVE_PAM_APPL=1" to the
  agent make (build AND install). It's a plain = wildcard probe on
  /usr/include/security/pam_appl.h — command-line override is correct
  here (not a += accumulator).
- FIX (config.scm): simple-service 'qrexec-pam pam-root-service-type
  (list (pam-service (name "qrexec")
     (auth (pam_rootok.so sufficient)) (account pam_unix required)
     (session pam_unix required)))). Agent calls pam_start("qrexec"),
  pam_authenticate, pam_setcred, pam_open_session as root.
- Check dom0 `qvm-prefs guix default_user` names a real guix account.
- Test: qvm-run -p --no-shell guix id → uid=1000; -u root → uid=0.
- Later (GUI): consider pam_elogind in session for XDG_RUNTIME_DIR.

## STEP 5 GREEN (2026-09-29 09:37): SEAMLESS WINDOWS WORK
- `qvm-run guix alacritty` from dom0 opens a seamless window. First
  Guix System qube with a native Qubes GUI agent.
- Remaining for step 5: auto-start? #t (+ respawn? #t) once stable;
  clipboard (Ctrl-Shift-C/V) test; qubes-session XDG autostart
  (qubes-session-autostart needs pyxdg + qubesagent.xdg); qubes.StartApp +
  qubes.GetAppmenus (app menu sync, needs pyxdg/gi); window icons
  (icon-sender, python-xcffib); keyboard layout (qubes-keymap.sh);
  audio (pulse/ or pipewire/ module) — all deferred.

## FEATURES + MEMORY (2026-09-29, drafted)
- One-shot 'qubes-features-request (after qrexec-agent, qubesdb): writes
  /features-request/{qubes-agent-version,os,os-distribution=guix,qrexec,
  vmexec,gui,qubes-firewall=0,supported-service.meminfo-writer,
  supported-feature.memory-hotplug} to qubesdb then qrexec-client-vm dom0
  qubes.FeaturesRequest (standalone/template only). Runs every boot.
  Replaces manual `qvm-features guix vmexec 1`.
- VERIFIED: qvm-features shows qrexec, vmexec, gui, os, os-distribution=guix,
  qubes-agent-version, supported-service.meminfo-writer, memory-hotplug.
- 'qubes-meminfo-writer: upstream VM mode = pidfile
  /var/run/meminfo-writer.pid; it daemonizes and WAITS for SIGUSR1 from
  qrexec-agent's first request (wake_meminfo_writer; pidfile path compiled
  into the agent). Without pidfile it forks+exits 0 -> respawn loop.
  Silent exit 1 (syslog "error writing meminfo to xenstore ?") when the
  qube is NOT in memory balancing: dom0 doesn't make memory/meminfo
  writable. So start only if qubesdb /qubes-service/meminfo-writer = 1
  (upstream qsvc gate); else service 'starts' with value #t, no process.
  Enable: Qube settings -> Advanced -> Include in memory balancing.
  VERIFIED after boot: herd start OK, dom0 memory/meminfo updates.
- BOOT RACE: /var/run is ON DISK on Guix (not tmpfs). Stale
  /var/run/meminfo-writer.pid from the last boot -> qrexec-agent's first
  request SIGUSR1s that PID (default action: terminate) = often this
  boot's meminfo-writer parent before it rewrote the pidfile -> "PID file
  did not show up". FIX: delete it in activation and in the start lambda.
  GENERAL: never trust leftover /var/run state across Guix reboots.
- SWAPINFO (the real cause, not a boot race): our linux-utils pin
  includes upstream 4575219 "Report swapinfo" (2026-06-25, after 4.3.19).
  It writes memory/swapinfo after memory/meminfo and exits 1 if that
  fails. R4.3 dom0 doesn't make memory/swapinfo writable, so EVERY run
  writes meminfo once and then dies (which is why manual runs looked like
  they worked). FIX in linux-utils.scm: substitute* so that a swapinfo
  write failure is ignored ("strlen(used->swap)))" ->
  "strlen(used->swap)) && 0)"). The write is still attempted, so it keeps
  working once dom0 supports it. UPSTREAM BUG: new agent + R4.3 dom0 =
  no memory balancing. (Also, prev_used_swap is never updated.)
- The agent's SIGUSR1 comes only once, on the first qrexec request, so a
  plain respawn would wait forever. Hence qubes-meminfo-supervisor (sh loop run through
  make-forkexec-constructor). It starts the writer in pidfile mode, waits
  10s, sends SIGUSR1 itself, polls with kill -0, restarts it 10s after it
  dies, and kills the child on TERM. Log: /var/log/qubes/meminfo-writer.log.
- udev 50-qubes-mem-hotplug.rules (online hot-added memory).
- memory-hotplug advertised only if /proc/config.gz has
  CONFIG_XEN_BALLOON_MEMORY_HOTPLUG=y.

## NETWORK FROM QUBESDB (2026-09-29): WORKING
- qubes-guest-service-type now provides 'networking via one-shot
  'qubes-network (fields network? #t, network-interface "eth0"): port of
  core-agent network/setup-ip non-NM path — /net-config/<MAC>/* with
  /qubes-* fallback, /32 addr, gateway neighbour pinned to fe:ff:ff:ff:ff:ff,
  link route + default onlink, IPv6 if present, resolv.conf from
  /qubes-primary-dns/-secondary-dns; honours qubes-service
  disable-default-route / disable-dns-server (read from qubesdb directly;
  /run/qubes-service isn't populated on Guix). Waits up to 30s for
  /qubes-ip (qubesdb -w); no netvm => exits 0, 'networking still provided.
- config.scm: static-networking-service-type REMOVED (would conflict on
  'networking).

## AUDIO (2026-09-29): WORKING — sox tone via paplay and Firefox/YouTube audio reach dom0
- pulse/module-vchan-sink: compiled -Werror clean outside Guix (PA 16.1,
  matching pulsecore-16.1); needs ltdl.h (libltdl). Links only
  libvchan-xen + libqubesdb; ~85 pa_* symbols resolved from the running
  PA at load -> header set MUST match the running PA (vendored
  pulse/pulsecore-<ver>, 17.0 present for Guix's pulseaudio 17.0).
- Guix: module can't go in PA's store module dir -> $out/lib/pulse-qubes,
  PA started with --dl-search-path=<ours>:<pa modules>, config
  $out/etc/pulse/qubes-default.pa. bin/qubes-start-pulseaudio (from
  qubes-session, background): waits qubesdb /qubes-audio-domain-xid,
  kills any desktop-autospawned PA for the user (one per user), starts ours.
- KEYBOARD fix verified working (arrows OK).

## KEYBOARD (2026-09-29)
- Letters OK, arrows/nav keys dead in seamless windows (fine in dom0 and
  in the local XFCE :0). qubes-gui feeds dom0's RAW keycodes to the qubes
  input driver ('K' via xf86-qubes-socket), which registers its keyboard
  with the server's DEFAULT XKB keymap. Upstream distros default to evdev
  rules; Guix's Xorg apparently doesn't -> nav cluster keycodes (evdev Up=111,
  Left=113...) land on other keys. Upstream also runs qubes-keymap.sh
  (qubesdb /keyboard-layout -> setxkbmap, qubesdb-watch loop) from XDG
  autostart, which we skipped.
- FIX (gui.scm): install lib/qubes/qubes-keymap.sh, store paths for
  qubesdb-read/-watch + setxkbmap, force "-rules evdev -model pc105",
  only display :1; qubes-session starts it in the background.
- Quick manual check: DISPLAY=:1 setxkbmap -rules evdev -model pc105 -layout us

## SHUTDOWN + SetMonitorLayout (2026-09-29)
- qvm-shutdown of the HVM did nothing, no logs: dom0 writes xenstore
  control/shutdown -> kernel Xen driver -> orderly_poweroff() runs usermode
  helper /sbin/poweroff (kernel.poweroff_cmd; reboot hard-wired to
  /sbin/reboot). Guix has no /sbin -> silent failure. FIX (agent service
  activation): /sbin/poweroff -> profile sbin/halt, /sbin/reboot -> reboot.
  VERIFIED: qvm-shutdown works.
- setuid-program-service-type is deprecated in current Guix: use
  privileged-program-service-type + (privileged-program ... (setuid? #t))
  from (gnu system privilege). Same /run/privileged/bin path.
- qubes.SetMonitorLayout exit 127: upstream symlink to
  /usr/bin/qubes-set-monitor-layout (gui-agent pkg) never shipped. FIX:
  gui.scm installs bin/qubes-set-monitor-layout (DISPLAY :0->:1, store
  xrandr/cvt) + etc/qubes-rpc/qubes.SetMonitorLayout; the service links
  gui-agent's etc/qubes-rpc/* into /run/qubes-rpc (searched before
  /etc/qubes-rpc; literal /run on Guix). Pattern for any future non-core
  qrexec services.

## CONFIG REFACTOR (2026-09-29): (qubes services agent)
- All Qubes integration moved into qubes/services/agent.scm:
  qubes-guest-service-type (+ qubes-guest-configuration: qrexec, qubesdb,
  core-agent, gui-agent packages; gui? #t) extending shepherd-root, pam-root,
  etc, setuid-program, activation, profile, kernel-module-loader, udev,
  account (system group "qubes"). %qubes-kernel-arguments exported
  (kernel args can't come from a service).
- config.scm keeps only: (use-modules (qubes services agent)),
  kernel-arguments append, "qubes" in the user's supplementary-groups,
  (service qubes-guest-service-type).
- Also removed the duplicate plain `mkdir-p /var/run/qubes` activation.

## STATUS 2026-09-29 12:21: GUI AGENT IN PRODUCTION
- qubes-gui-agent service now auto-start? #t, respawn? #t; survives
  reboot. Seamless windows, app menu launch (StartApp), GUI backup/restore
  (SelectFile via zenity wrapper) all working.
- Done since: keyboard layout sync (evdev rules), audio (pulse vchan sink),
  qvm-shutdown (/sbin helpers), SetMonitorLayout.
- Still deferred: XDG autostart in qubes-session, window icons
  (icon-sender), audio INPUT (microphone) untested, pipewire variant,
  qvm-features-request (so dom0 learns vmexec/etc. automatically),
  PCI detach test, upstream reports (env_buf[64] in qrexec-agent,
  env_buf[256] in qubes-gui-runuser, wait_for_space no-timeout).

## GUI FOLLOW-UPS (2026-09-29)
- qubes.GetAppmenus WORKS (menu entries appear in dom0).
- App menu entries run qubes.StartApp (python: qubesagent.xdg + pyxdg +
  PyGObject Gio/GLib + qubesdb). FIX: python-qubesagent ships
  bin/qubes-startapp (wrapped: GUIX_PYTHONPATH + GI_TYPELIB_PATH;
  propagates pyxdg, pygobject, qubesdb); core-agent symlinks
  etc/qubes-rpc/qubes.StartApp to it.
- Clipboard from the EMULATED (stubdom) window: guid uses qrexec service
  qubes.ClipboardCopy/Paste ("specific to Windows/non-X11",
  xside.c:736 when domid != target_domid). No Linux agent ships it, and
  dom0 sends "QUBESRPC qubes.ClipboardCopy" with no source-domain field,
  which libqrexec rejects ("No space found after service descriptor").
  EXPECTED/unsupported. Clipboard in SEAMLESS windows goes over the GUI
  protocol instead — test there.

- qubes.SelectFile/SelectDirectory (GUI backup/restore location picker)
  `exec zenity` -> not found. FIX: zenity as core-agent input; store path
  rewritten in scripts (SelectFile/Dir, qvm-open-in-vm, qvm-actions.sh)
  and in gui-fatal.c (qfile-agent/unpacker error dialogs).
  Then: zenity 4 (GTK4) aborted (int3) "Settings schema
  'org.gtk.gtk4.Settings.FileChooser' is not installed" — qrexec session's
  XDG_DATA_DIRS lacks GTK. FIX: core-agent compiles GTK's *.gschema.xml
  into $out/share/qubes/gsettings-schemas (glib:bin native input) and all
  call sites use $out/libexec/qubes-zenity, a wrapper exporting
  GSETTINGS_SCHEMA_DIR. GENERAL LESSON: GUI tools launched via qrexec get
  the minimal session env, not a desktop env — wrap them.
- Backup/Restore: CLI verified end to end (qvm-backup -d guix,
  qvm-backup-restore -d guix --verify-only). Silent restore hang =
  dom0 qfile-dom0-unpacker wait_for_space() (-w 500MB, no timeout,
  unpack.c:77) when dom0 root is nearly full — not a guix bug.
  `tar tv` stops after backup-header: Qubes backups are concatenated tars,
  use `tar tvi`.

## STEP 5 HISTORY (2026-09-28): qubes-gui-agent (qubes/packages/gui.scm)
- Sources: gui-agent-linux v4.3.21 (a7528d157abea4fef71dacf64bb1981e24ef1a1d),
  gui-common v4.3.1 (66b879e36d6cd2a01271fc8d4c2c0f3be85d0029, headers only,
  copy-build-system). Audio (pulse/, pipewire/) deferred.
- Compile-verified outside Guix (Ubuntu, Xorg 21.1.11, -Werror clean):
  qubes-gui, qubes-gui-runuser, libxf86-qubes-common.so, dummyqbs_drv.so
  (links libxengnttab), qubes_drv.so.
- Patches: vmside.c execl /usr/bin/qubes-run-xorg -> $out; runuser
  env_buf[256] -> [4096] (same bug class as qrexec). Drivers: autoreconf +
  configure LDFLAGS=-Wl,-rpath,$out/lib (they link xf86-qubes-common from the
  build tree). Template gets a Files/ModulePath with $out + xorg-server
  modules. Generated xorg conf -> /run/qubes/xorg-qubes.conf.
- Guix glue: bin/qubes-gui-agent-start (= pre.sh + exec qubes-gui, stdin
  </dev/tty7 because runuser derives PAM_TTY/XDG_VTNR from it);
  bin/qubes-session (xsetroot + qrexec-fork-server; no systemd --user, no
  XDG autostart yet). qsvc() = test -e /run/qubes-service/$1.
- Runtime chain: shepherd -> qubes-gui-agent-start (root) -> qubes-gui ->
  (on dom0 screen-size msg) qubes-run-xorg -> qubes-gui-runuser dap (PAM
  service "qubes-gui-agent") -> sh -l -> xinit qubes-session -- Xorg :0 vt07.
- /run/qubes must be 2770 root:qubes (upstream tmpfiles) so the user's
  fork-server can create qrexec-server.$USER.sock.
- 2026-09-28 DECISION: agent X on :1, coexisting with the local XFCE
  desktop (display manager on :0/vt7, emulated VGA). Removing the display
  manager during reconfigure made the qube unreachable (screen gone AND
  qrexec unresponsive) — keep XFCE as the recovery console for now.
  Mechanism: Xorg ":1 -sharevts -novtswitch" (no VT_ACTIVATE/KD_GRAPHICS,
  drivers need no console), start script stdin </dev/null (runuser skips
  PAM_TTY/VT_ACTIVATE when stdin isn't a tty), bochs-drm NOT unbound.
  Upstream model (gui-agent XOR lightdm) remains the eventual target.
- 2026-09-28 LOCKOUT CAUSE (likely): upstream qubes-run-xorg exports
  XDG_SEAT=seat0 before qubes-gui-runuser opens its PAM session ->
  pam_elogind registers a 2nd graphical session on seat0 and activates it
  -> local XFCE session (seat0, vt8) goes inactive, loses DRM/input fds.
  FIX: strip XDG_SEAT (seatless session); xorg template ServerFlags
  AutoAddDevices/AutoAddGPU/AutoBindGPU false (don't grab QEMU input or
  bochs card0). Service now (auto-start? #f) until proven: reconfigure
  installs it, `herd start qubes-gui-agent` tests it.
- Logs from failed generations (/var/log/qubes-gui-agent.log,
  ~/.xsession-errors) persist across rollback — check timestamps/build.
- 2026-09-29 FIRST LIGHT: agent Xorg :1 came fully up (seatless elogind
  session, dummyqbs 3440x1440, qubes input, qubes-gui "Ok, somebody
  connected") then was shut down 20ms later by xinit. CAUSE:
  qrexec-fork-server daemonizes (parent exits 0 after bind); our session
  did `fork-server & wait` -> returned at once -> xinit tore down X. FIX:
  run fork-server in foreground-then-daemon, then `exec sleep infinity`
  (upstream qubes-session ends with `sleep inf`).
- xinit "XFree86_VT property unexpectedly has 0 items" is harmless with
  -sharevts (only WINDOWPATH unset; xinit.c:505 returns and continues).
- Xorg "(EE) systemd-logind: failed to take device /dev/dri/card0" is the
  good outcome: our seatless session can't grab the local desktop's GPU.
- SOLVED "lockout": NOT a VM problem. dom0 shows an HVM's stubdomain
  emulated VGA only until the VM's gui agent connects over vchan, then
  closes that window (seamless mode). The agent then died (fork-server
  bug) -> nothing displayed. Verified during the "lockout": tty0 active =
  tty8, seat0 ActiveSession = c3 (XFCE), state active — XFCE untouched.
  RECOVERY (dom0, no reboot): `qvm-start-daemon --force-stubdomain guix`.
  qrexec keeps working throughout (separate from GUI).
- GOTCHA: substitute* lines include the trailing "\n" — `$` never matches;
  anchor on "\n" instead.

## CORE-AGENT RUNTIME LESSONS (2026-09-27)
- Outbound qrexec from a USER process (qvm-copy → qrexec-client-vm)
  makes the client the vchan SERVER → needs /dev/xen/{evtchn,gntdev,
  gntalloc,privcmd,xenbus,hypercall} 0660 group qubes (upstream
  linux-utils udev-qubes-misc.rules). Symptom without it:
  qrexec-agent-data.c:370 "Data vchan connection failed" (immediate
  libvchan_server_init NULL, not the 120s timeout). Root-run paths
  (qvm-run into guix) work regardless — don't let them mask this.
- file-append refs (etc overlay, setuid) put a package in the store but
  NOT on PATH — must also be in (packages ...).
- Never glob /gnu/store/*/bin/X: multiple builds expand; the 2nd path
  becomes an argument (qvm-copy "copied itself").
- dom0 ask-dialog steals focus between Enter press/release → autorepeat
  newlines into the terminal. `sleep 1; qvm-copy ...` avoids it.
- Killing the VM-side client does NOT withdraw dom0's pending ask
  prompt; answer/cancel it in dom0.

## CONFIG.SCM CURRENT STATE
- use-modules includes (qubes packages qubesdb) (+ qrexec, vchan).
- packages: qubes-core-qubesdb added to system packages list (variable
  direct, no specification->package — not in official channels).
- kernel-arguments: xen_privcmd.unrestricted=1 QUIET.
- kernel-module-loader: xen-privcmd xenfs xen-evtchn xen-gntdev xen-gntalloc.
- activation: mkdir-p /var/run/qubes.
- activation: also mkdir-p /var/log/qubes (vm-log etc. will want it).
- use-modules adds (qubes packages core-agent); packages list includes
  qubes-core-qubesdb AND qubes-core-agent.
- etc-service-type: "qubes-rpc" → $core-agent/etc/qubes-rpc,
  "qubes" → $core-agent/etc/qubes (rpc-config, suspend/post-* dirs).
- setuid-programs: $core-agent/lib/qubes/qfile-unpacker.
- udev-rules-service 'qubes-xen-devices (90-qubes-xen.rules, six xen
  nodes 0660 group qubes) #:groups '("qubes"); user in "qubes"
  supplementary group.
- shepherd: qrexec-agent (user-processes req, respawn, log to
  /var/log/qrexec-agent.log); qubesdb-daemon WORKING: foreground
  (patched), args ("0") only, respawn #t, parallel to qrexec-agent.
  Future core-agent services that read qubesdb must require
  'qubesdb-daemon.

## NEXT SESSION SEQUENCE
1. DONE: qubesdb-read /name works. Confirm it survives a cold
   qvm-shutdown/qvm-start with the shepherd service (single instance:
   pgrep -c qubesdb-daemon == 1).
2. qubes-core-agent package DRAFTED: qubes/packages/core-agent.scm
   (commit 4738333496c6b689207d8274d0f3425e796b6197, qubes-rpc/ only).
   Compile + install verified outside Guix (gcc 13, -Werror clean).
   Fixups: /usr/lib/qubes/qrexec-client-vm→qrexec pkg usr/bin;
   qfile-unpacker→/run/privileged/bin (setuid-programs, store strips
   4755); /usr/lib/qubes/→$out/lib/qubes/; exec /bin/bash→bash input;
   qvm-copy's $scriptdir/qubes/ (relative to PROFILE symlink)→store;
   patch-shebang over etc/qubes-rpc + lib/qubes (stock phase skips
   them). substitute* only on regular non-ELF files (symlinks:
   VMExecGUI, Log, /dev/tcp ConnectTCP/UpdatesProxy).
   -> DONE, GREEN 2026-09-27 (see STATE AT HANDOFF).
3. DONE: etc-service-type overlay of $out/etc/qubes-rpc/* onto /etc.
   Delete hand-made VMShell. Test: qvm-run --pass-io, then plain
   qvm-run. CORRECTION: qubes.WaitForSession DOES exist — in the qrexec
   repo (qubes-rpc-base/, installed only by top-level install-base). The
   agent forks+execs it for wait-for-session=1 services. If missing: logs
   "Service not found", exits 1, and the agent runs the queued requests
   ANYWAY (SIGCHLD handler ignores status) — so absence is only noise.
   Upstream script needs systemctl --user and, with gui enabled, waits
   with no timeout for qrexec-server.$user.sock (= forever without a gui
   agent). Guix version written in qrexec.scm (no-op until
   /run/current-system/profile/bin/qubes-gui exists — placeholder path),
   symlinked into core-agent's etc/qubes-rpc (NOT directory-union: agent
   readlink()s services one level for /dev/tcp detection, exec.c:401).
4. DONE 2026-09-27. python-qubesagent sub-project (setup.py entry points incl.
   qubes-vmexec; needs qubesdb python module → propagated).
5. THEN gui-agent country: qubes-drv Xorg driver, clipboard, the payoff.

## STATUS SENTIMENT
Five repos, five green builds, qrexec + qubesdb live, first native qvm-run in a Guix System
ever. qubesdb syncs from dom0 and file copy works both ways:
the management plane is open. 2026-09-29: seamless GUI live. PAM user switching live. Next: re-verify qvm-copy-to-vm lands in
~dap/QubesIncoming (was /root pre-PAM), then gui-agent (step 5).
The port is winning.
## WINDOW ICONS (2026-09-29): WORKING (icon-sender)
- gui.scm installs window-icon-updater/icon-sender at lib/qubes/icon-sender.
  The python3 shebang and qrexec-client-vm path are patched, and it is
  wrapped with GUIX_PYTHONPATH (python-xcffib + cffi). It doesn't use
  qubesimgconverter; dom0 does the tinting. qubes-session starts it in the
  background (upstream uses XDG autostart). Log: ~/.cache/icon-sender.log.
  qrexec service: qubes.WindowIconUpdater (VM -> dom0).
- qrexec binaries live under $qrexec/usr/bin (the DESTDIR install), so
  search-input-file needs "/usr/bin/qrexec-client-vm", not "/bin/...".

## U2F / FIDO2 PROXY (2026-10-06): WORKING, qubes-ctap (qubes-app-u2f v2.0.7)
- New module qubes/packages/ctap.scm (pyproject). Guest frontend only:
  qctap-proxy <backend> creates a virtual FIDO HID via /dev/uhid and
  forwards requests over qrexec (ctap.GetInfo, ctap.ClientPin,
  u2f.Register, u2f.Authenticate+<hash>) to sys-usb.
- Guix has python-fido2 2.2.1 (upstream CI pins >=1.1). All 65 upstream
  tests pass against 2.2.1; the check phase runs them.
- setup.py CustomInstall (writes <root>/usr/bin) dropped; our own launcher
  bin/qctap-proxy gets wrapped. const.py's QREXEC_CLIENT is patched to
  $qrexec/usr/bin/qrexec-client-vm.
- agent.scm: fields ctap (package) and ctap-backend ("sys-usb"; #f = off).
  Shepherd 'qubes-ctap-proxy is gated on qubesdb
  /qubes-service/qubes-ctap-proxy or qubes-u2f-proxy = 1 (the upstream
  ConditionPathExists pair). Also: uhid module; udev 60-qctap-hidraw.rules
  (hidraw 0660 group qubes, so the browser can open the virtual key);
  features supported-service.qubes-ctap-proxy/qubes-u2f-proxy.
  Logs: /var/log/qubes/qctap (python logging), qctap-proxy.log (stdout).
- dom0: qvm-service guix qubes-ctap-proxy on. sys-usb template needs the
  qubes-ctap package.
- Build fix: 2 test_systemd_notify tests failed with "AF_UNIX path too long"
  (the pytest tmp dir under /tmp/guix-build-...drv-0 is too deep). The check
  phase now passes --basetemp=/tmp/qctap.
- dom0 "Update qubes" on guix: the R4.3 updater runs `/usr/bin/python3
  entrypoint.py` via qubes.VMExec (FileNotFoundError: no /usr/bin/python3),
  and its agent only knows apt/dnf/pacman anyway. Guix updates are
  `guix pull` + reconfigure. FIX (dom0): qvm-features guix skip-update 1.
- Bring-up gotchas: (1) a reconfigure doesn't make the running udev
  reload rules, so the hidraw node stayed root:root until reboot (or
  `udevadm control --reload; udevadm trigger --action=change
  --subsystem-match=hidraw`). Guix's own 60-fido-id.rules also tags it
  uaccess (the ACL "+"). (2) From R4.2, dom0 ships no ctap policy; Qubes
  Global Config -> USB Devices -> U2F Proxy writes it. A denial shows in
  /var/log/qubes/qctap as "qrexec call was denied ... returncode 126", and
  the client sees CTAP INVALID_COMMAND.
- VERIFIED 2026-10-06: webauthn site login with a YubiKey from guix Firefox.
  A direct fido2 Ctap2(dev).get_info() still errors; ignored for now.
- UPSTREAM BUG (hidemu._handle_ctaphid_request, v2.0.7 and master): replies
  to CTAPHID_CBOR requests are framed as CTAPHID_MSG. python-fido2 rejects
  that as INVALID_COMMAND (which explains the get_info() failure, even with
  policy allowed and a FIDO2-capable YubiKey). ctap.scm phase
  'cbor-reply-command answers with CBOR for CBOR requests. Checked with a
  mock: the original replies MSG, the patched one CBOR; 65 tests pass.
  To report upstream. FIDO2 also needs dom0 policy ctap.GetInfo +
  ctap.ClientPin (guix -> sys-usb allow); Global Config gave only u2f.*.
- UPSTREAM BUG #2: makeCredential with rp = {"id": ...} and no "name"
  (CTAP2 makes name optional; Firefox omits it) fails with "Error parsing
  field rp for MakeCredential" (0x6A80), because python-fido2's
  PublicKeyCredentialRpEntity requires name (1.1.3 and 2.2.1 both). sys-usb
  parses the forwarded request with the same code, so fixing only the type
  just moves the failure there. ctap.scm phase 'default-rp-name sets
  name = id when it is missing. The request is re-encoded from the parsed
  object, so sys-usb gets the name too. Verified on both fido2 versions:
  guix parse, forwarded bytes and sys-usb-side parse all OK; 65 tests pass.
- VERIFIED 2026-10-06 (FIDO2): webauthn.io registered a device-bound
  passkey from guix Firefox through sys-usb. The site identified the key as
  YubiKey 5 Series with NFC (AAGUID 2fc0579f-8113-47ea-b116-bb5a8db9202a),
  transport usb. The fixes it needed: CBOR reply framing, rp.name default,
  dom0 policy ctap.GetInfo/ctap.ClientPin.

## MICROPHONE (2026-10-06): WORKING
- module-vchan-sink provides the source vchan_input (plus vchan_output.monitor).
  `qvm-device mic attach guix dom0:mic`, then `parecord -d vchan_input`
  records the dom0 mic; playback is fine. No port changes needed.
- 2026-10-06: qubes-linux-utils is now pinned to v4.3.19 (2c79ddb, the head of
  release4.3). The old main pin was just 4575219 + a merge ahead, with no other
  diff (qrexec-lib identical), so the nonfatal-swapinfo phase is dropped.
  The other repos are still on main/mm_ pins; consider release4.3 for them
  too (check the qrexec/gui/core-agent diffs first).

## SPLIT-GPG2 CLIENT (2026-10-06): packaged, untested
- The gpg qube is gpg-admin (Debian trixie) and had only split-gpg v1
  (qubes.Gpg). Install split-gpg2 in its template; both coexist.
- New qubes/packages/split-gpg.scm: qubes-split-gpg2-client v1.1.14
  (b48de62). Installs libexec/split-gpg2/split-gpg2-client (socat on gpg's
  agent socket -> qrexec-client-vm @default qubes.Gpg2; tool paths patched)
  and the gpg-agent-placeholder (gated via qubesdb, not
  /run/qubes-service). The session hook lib/qubes/session.d/split-gpg2-client
  is gated on qubesdb /qubes-service/split-gpg2-client = 1 and loops the
  forwarder.
- gui.scm qubes-session now runs every executable in
  /run/current-system/profile/lib/qubes/session.d/ in the background (a
  generic hook point instead of XDG autostart).
- agent.scm: field split-gpg2 (package, or #f); in the profile when gui?;
  advertises supported-service.split-gpg2-client.
- dom0: policy `qubes.Gpg2 + guix @default allow target=gpg-admin`;
  `qvm-service guix split-gpg2-client on`. Server exposes subkeys only by
  default, so a signing subkey ([S]) is required.
- 2026-10-07: split-gpg2 WORKING. guix gpg -K shows sec# + 3 ssb from
  gpg-admin (Debian trixie, split-gpg2 1.1.14). Gotchas:
  (1) dom0 policy `qubes.Gpg2 * guix @default allow target=gpg-admin`.
  (2) While the forwarder was being denied, gpg auto-started a LOCAL
      gpg-agent, which took over the socket path (socat kept listening on
      the old, replaced socket file), giving a confusing
      "ERR ... No such file or directory <GPG Agent>". Fix: kill the local
      agent and socat (the hook restarts it). Prevent: `no-autostart` in
      ~/.gnupg/gpg.conf.
  (3) The split-gpg2 server matches Assuan command names case-sensitively:
      gpg-connect-agent 'keyinfo --list' -> "Command filtered", while
      'KEYINFO --list' is OK.
  (4) gpg 2.5.21 (guix) vs agent 2.4.7 (gpg-admin) prints a harmless
      "server is older than us" warning. Don't `gpgconf --kill all`.
  (5) The gnupg package was not in the profile; agent.scm now adds it with
      split-gpg2.
- VERIFIED 2026-10-07: `git commit -S` in guix, signed via split-gpg2 by the
  [S] subkey 1607721B3110F3709497F436B548D5A5665FD366 (primary
  F9BE45DFA380E9C88D474E966767C5ED20D31AEA); `git log --show-signature`
  says Good signature. Guix channel auth is by key fingerprint only;
  author email is irrelevant.

## CHANNEL (2026-10-06/07)
- ~/src/qubes is a git repo with .guix-channel (version 0), pulled via
  ~/.config/guix/channels.scm (url file:///home/dap/src/qubes).
- Workflow: -L ~/src/qubes for iteration (it shadows the pulled channel);
  commit + guix pull + reconfigure without -L to record provenance. Pin the
  guix channel commit if you don't want every pull to update Guix too.
- NEXT: sign it. A keyring branch with the public key,
  .guix-authorizations (F9BE 45DF A380 E9C8 8D47  4E96 6767 C5ED 20D3 1AEA),
  and an introduction commit; check with `guix git authenticate`; add
  `introduction` to channels.scm. Then README/COPYING/cleanup and publish
  (Codeberg/GitLab, push-mirrored from Gitea).
- TODO: the split-gpg2 hook should kill a stray local gpg-agent before
  binding.
- CHANNEL SIGNING GOTCHA: Guix compares the introduction's
  openpgp-fingerprint with the key that actually made the signature, here
  the [S] SUBKEY 1607 721B 3110 F370 9497  F436 B548 D5A5 665F D366, not the
  primary F9BE.... So the introduction uses the subkey fingerprint, and
  .guix-authorizations lists the subkey (plus the primary, harmless). The
  original intro commit 0398b29 was abandoned; a new commit that adds the
  subkey to .guix-authorizations is the introduction.
- 2026-10-07: qrexec.scm cleanup for publishing. Pinned to v4.3.15 (205db68,
  head of release4.3) instead of main (fa04483); agent/ + libqrexec/ differ
  by 7 files / ~20 lines, and both patch anchors still match. Converted to
  the gexp style; CC from cc-for-target; unused imports dropped (gnu
  packages, haskell-apps). NOT build-tested here; the source hash was
  computed locally (same method reproduced the old pin's hash).
- Correction: `no-autostart` in gpg.conf is WRONG for GnuPG 2.5. gpg uses
  keyboxd (the public keyring daemon), and no-autostart stops it from
  starting too: "no keyboxd running in this session", and signing fails.
  Use upstream's approach instead:
  `agent-program /run/current-system/profile/libexec/split-gpg2/gpg-agent-placeholder`
  (it refuses to start a local agent for ~/.gnupg while the
  split-gpg2-client service is on, and otherwise execs the real gpg-agent).

## CORE-AGENT TO R4.3 (2026-10-08): drafted, NOT build-tested
- Pinned qubes-core-agent-linux to v4.3.48 (e1cf558, head of release4.3)
  instead of mm_47383334 (main, 4.4.2). Every other repo already tracks R4.3.
  Hash computed with the NAR method that reproduces the old pin's hash.
- Diff vs main is confined to qubes-rpc/ (setup.py and qubesagent/ are
  identical, so python-qubesagent is unaffected). What changes:
  - qubes.WaitForSession is installed by core-agent on R4.3 (main moved it
    to qrexec). The link-wait-for-session phase now deletes upstream's
    systemctl-based copy before linking ours; without that, symlink fails
    with "File exists".
  - vm-log / qubes.Log (sys-log) and qubes.PostUpdate are R4.4-only: gone.
    qubesdb input has no C user now; kept until a build shows it's unneeded.
  - qvm-open-in-vm requires an explicit vmname again (no @default fallback).
  - qubes.Filecopy bookmark hook renamed qvm_nautilus_bookmark.sh (inert).
  - release4.3 qubes-rpc/Makefile mkdirs $(DESTDIR)/etc/qubes/{suspend-pre,
    suspend-post,post-install}.d but installs into $(QUBESCONFDIR): build died
    "cannot create directory '/etc/qubes'". Phase fix-qubesconfdir backports
    upstream main 8bc5d2d0.
- All substitute* anchors still match. Hand-ported network/setup-ip and the
  features script: no upstream change between the two commits.
- Test: guix build -L . qubes-core-agent python-qubesagent; reconfigure;
  qvm-run --pass-io guix 'ls -l /etc/qubes-rpc/qubes.WaitForSession'
  (-> qrexec store path), qvm-copy both ways, app menu launch, GUI backup.

## TEMPLATES (2026-10-09): written, NOT tested
- Decisions (Damon): create the template directly (qubes-guix-create
  --template), not by converting a StandaloneVM; updates via
  qubes.UpdatesProxy; AppVM installs are throwaway like apt (root resets).
- agent.scm `template?` field (system.scm #:template?). Services: qubes-rwdev
  (port of setup-rwdev.sh + setup-rw.sh: mkfs a virgin xvdb, fsck, seed
  /rw/home from root /home on a scratch mount, always exit 0),
  file-system /rw (shepherd-requirements qubes-rwdev) + /home bind
  (dependencies /rw), qubes-rw-resize, qubes-volatile-swap (sfdisk xvdc:
  1 GiB xvdc1 swap, as upstream's initramfs), qubes-hostname (from
  qubesdb /name), qubes-updates-proxy (inetd 127.0.0.1:8082 ->
  qrexec-client-vm --use-stdin-socket '' qubes.UpdatesProxy, gated on
  qubes-service/updates-proxy-setup, then guix-daemon set-http-proxy).
- GUIX GOTCHA (gnu/services/base.scm): file systems WITH
  shepherd-requirements are left out of the 'file-systems target, which
  user-homes and user-processes wait on. So /home has none; it reaches
  qubes-rwdev only through its dependency on /rw. That's also why the
  /rw/home seeding runs before /rw is mounted (scratch mount point).
- Loop-device tested here: rwdev (virgin -> mkfs + seed, uid kept;
  existing -> fsck only; non-ext4 junk -> refused, exit 0), the swap
  partition table. Guile: wrap-config #:template? cases. NOT built.
- To verify on real Qubes: AppVM root (xvda) writable as a snapshot under
  HVM; dom0 sets updates-proxy-setup for templates by itself; guix pull's
  git (libgit2) honours http(s)_proxy; virt_mode/kernel inheritance for
  AppVMs; DisposableVMs (persistence none) not handled yet.
- Also: qubes-agent-version now advertised as 4.3 (was 4.4).
- 2026-10-09: dom0 typing helpers. xdotool `type --window` sends synthetic
  events whose Shift state the Qubes GUI daemon ignores ($ -> 4, | -> \,
  > -> .). Fix: VT switch synthetic (`key --window W ctrl+alt+F3`; a REAL
  Ctrl+Alt+Fn would switch dom0's own console), then `windowactivate
  --sync W` and plain `xdotool type` (XTEST). Installer: shell VT3
  (ctrl+alt+F3), installer UI back on ctrl+alt+F1. --bootstrap types a
  heredoc into /tmp/qubes-guix-bootstrap.sh (no tabs, no '!', `set +H`),
  shows it, doesn't run it.
- Setup belongs in the TEMPLATE: an AppVM boots the template's root, so
  an AppVM of a not-yet-set-up template is plain Guix (no agent, no net).
- qubes-operating-system: #:passwordless-sudo? (default #t), %qubes
  NOPASSWD appended to the sudoers file (Guix visudo-checks it at build).

## ONE MANUAL STEP: FINISH-INSTALL (2026-10-09): written, NOT tested
Goal: the Guix install is the only interactive part.
- `guest/qubes-guix-finish-install` runs in the installer, as root, at "Installation complete" and before the reboot. It wraps /mnt/etc/config.scm, then runs `guix time-machine -C <qubes channels> -- system init` on /mnt. The installer's guix has no qubes channel, so time-machine builds one. That's slow and needs memory: is the 4000 MiB default enough, with cow-store on /mnt? Unverified.
- The installer may unmount the target once it finishes. gnu/installer/install.scm tears down cow-store and the mounts after the install, I believe. So the script remounts it when it finds a single ext4/btrfs/xfs partition, plus a vfat partition on /boot/efi if that exists. It refuses on anything else: LUKS, or several candidates. It then restarts cow-store on the target.
- dom0 `qubes-guix-create --finish-install [--template] [-b B] [--run] NAME` types into VT3: `guix shell git -- git clone` into /tmp/qubes-guix, then shows (or with --run, runs) the command. It needs the installer's network from --type-network, which is still up at that point.
- System-wide channels: qubes-operating-system puts the qubes channel into `guix-configuration-channels` (#:system-channels?, default #t; #:channel-branch). That becomes /etc/guix/channels.scm, which `guix pull` reads when ~/.config/guix/channels.scm is absent (guix/scripts/pull.scm: channel-list falls back to %system-channels-file). So after finish-install, the first boot needs no per-user channel file. wrap-config.guile passes QUBES_BRANCH through as #:channel-branch when the branch isn't main.
- sudo timeouts: qubes-guix-setup now runs `sudo -v` before `guix pull`, and a background `sudo -n -v` every 60 s until the script exits (trap). A walk-away pull no longer ends in a timed-out password prompt at the cp/reconfigure step. NOPASSWD itself only exists once the qubes config is live: after the first reconfigure, or from the first boot via finish-install.
- 2026-10-10, TESTED on guix-tmpl, and it hung: qubes-updates-proxy required guix-daemon and called its set-http-proxy action from its own start. That action restarts guix-daemon, and a restart first stops the dependents, including qubes-updates-proxy, which was still starting. The result was a deadlock: the service was stuck in "Starting" for good, and `herd stop root` (qvm-shutdown) waited on it forever, after it had already stopped the GUI agent. With no fork server left, qrexec requests ran without DISPLAY. FIX: guix-daemon is no longer a requirement; the start brings it up itself (start-service) and catches errors from the action. Also seen: dom0 does set updates-proxy-setup on templates.
- 2026-10-10, VERIFIED on guix-tmpl with the deadlock fixed: qubes-updates-proxy runs, guix-daemon's environ has http_proxy and https_proxy set to 127.0.0.1:8082, and `guix shell fish` fetched its substitutes with no netvm (`ip -4 a`: lo only). Offline `guix pull` with http_proxy and https_proxy set: works (libgit2 honours them). Not yet tested: AppVMs, and a clean qvm-shutdown with the proxy running.
