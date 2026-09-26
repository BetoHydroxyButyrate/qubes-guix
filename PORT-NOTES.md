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
- Clipboard today: SSH from same-VLAN qubes (banking), xclip-based
  to-guix/from-guix helpers.
- dom0 cannot paste into guest consoles — retyping is the cost of work
  until gui-agent exists.
- Serial/PV console exists at /dev/hvc0 (console/tty visible in xenstore).
- WATCHDOG: qrexec check kills VM after ~60s. `timeout` pref has a HARD
  floor of 60 — 0/-1 error, 3600/1000000 still killed at 60s. There is
  NO escape hatch; the agent must answer.
- domid changes each boot (observed 35 → 38 → 42).

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
- `remove` is SRFI-1: import (srfi srfi-1) or use modify-services/delete.
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

## CURRENT BLOCKER (as of 2026-09-25)
- VM SURVIVES the 60s watchdog across reboots ✓ (agent runs, is
  respawnable via shepherd, /var/run/qubes socket binds).
- BUT dom0→guest connection fails: `qvm-run --pass-io --no-gui guix
  'echo hi'` → dom0 log: "qrexec-client.c:408:main: qrexec connection
  timeout". Plain qvm-run also 125s (blocked until ~login, then
  qrexec timeout).
- Control test: same qvm-run against existing AppVM prints hello —
  dom0 machinery healthy.
- qrexec-daemon@guix.service unit does not exist in dom0; nor for
  working AppVMs (unit naming/layout differs on R4.3 — find via
  ps aux | grep [q]rexec).
- Suspicion list for next session (ranked):
  1. dom0's per-VM qrexec-daemon not spawning/connecting for this VM
     despite qrexec=1 feature — verify process exists, check its args
     and dom0 journal. NOTE: on the last boot, data/vchan appeared
     EMPTY even with agent running — versus domid 38 boot where keys
     were published. Investigate whether publication is conditional
     (e.g., agent publishes only if some precondition at startup,
     or the client is expected to trigger rendezvous).
  2. Direction of connection: doc says "qrexec-client starts a vchan
     server, which qrexec-agent then connects to" for per-connection
     channels — but main channel is agent-as-server (VCHAN_BASE_PORT
     via libvchan_server_init(0, ...)). Determine which side initiates
     in R4.3 and what triggers it.
  3. Xen 4.21 guest libs vs dom0 expectations (protocol or version
     negotiation). If so: build guest against Xen 4.17 libs
     (qubes-arch issue mentions R4.3 built against 4.17: libvchan.so.4.17).
  4. Compare xenstore anatomy of a WORKING VM (dump /local/domain/<its
     domid>/data/vchan + qubes-* keys while a qvm-run session is open
     in it) against our tree at the same moment.

## Decisive diagnostics for next session
- dom0: ps aux | grep [q]rexec; journalctl -f | grep -i qrexec while
  triggering qvm-run.
- guest: sudo tail -f /var/log/qrexec-agent.log during qvm-run — does
  the agent's read(4) ever wake? (Silence = dom0 never reached us.)
- guest xenstore recheck every boot: xenstore-ls -p
  /local/domain/$(xenstore-read domid)/data (full tree, incl. qubes-*).
- strace the agent with poll: sudo guix shell strace -- strace -f -e
  trace=poll,read,write <agent path>.

## Roadmap (post-unblock)
1. Resolve dom0 connection (above).
2. qvm-run --pass-io works → plain qvm-run fails on missing
   qubes.WaitForSession → package qubes-core-agent-linux minimal
   (service scripts into REAL /etc/qubes-rpc via etc-service or
   similar — note our qrexec package put etc/qubes-rpc in the STORE
   output, not the rootfs; the fork-server searches the real path).
3. qubes-rpc policies in dom0 already exist from default install?
   (qvm-rpc list). Then: qvm-copy-to-vm, clipboard RPC groundwork.
4. qubes-gui-agent-linux: qubes-drv Xorg driver + agent shepherd
   service. Black-screen safety: hvc0 console (console=hvc0 kernel
   arg) + xl console guix from dom0 + SSH lifeline.
5. Ultimately: Proton-grade channel hygiene — commit early, commit
   often, git history is the reproducibility proof for the dom0-trusted
   binaries.

### FIXME
the xen_privcmd.unrestricted=1 fix resulting in a successful connection
(move it from "blocker" to "fixed"), and the new next-step —
qubes.VMShell service script into real /etc/qubes-rpc/ (Path A test
script vs. Path B packaging).
