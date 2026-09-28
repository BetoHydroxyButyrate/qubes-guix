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
the management plane is open. PAM user switching live. Next: re-verify qvm-copy-to-vm lands in
~dap/QubesIncoming (was /root pre-PAM), then gui-agent (step 5).
The port is winning.