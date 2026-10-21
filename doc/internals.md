# Internals

[← README](../README.md)

## What's in the channel

```
qubes/packages/vchan.scm        qubes-core-vchan-xen
qubes/packages/linux-utils.scm  qubes-linux-utils (meminfo-writer, qrexec libs) — R4.3 branch
qubes/packages/qrexec.scm       qubes-core-qrexec (agent, qrexec-client-vm, fork server)
qubes/packages/qubesdb.scm      qubes-core-qubesdb
qubes/packages/core-agent.scm   qubes-core-agent (qubes-rpc services, qfile-*), python-qubesagent
qubes/packages/gui.scm          qubes-gui-common, qubes-gui-agent (Xorg drivers, pulse module, session glue)
qubes/packages/ctap.scm         qubes-ctap (U2F/FIDO2 proxy, frontend)
qubes/packages/split-gpg.scm    qubes-split-gpg2-client
qubes/packages/split-ssh.scm    qubes-split-ssh-client
qubes/packages/usb-proxy.scm    qubes-usb-proxy (qubes.USBAttach: USB devices from sys-usb)
qubes/services/agent.scm        qubes-guest-service-type — the integration
qubes/system.scm                qubes-operating-system — adds all of it to any operating-system
qubes/installer.scm             qubes-installation-os — the qubes-guix installer ISO
iso/qubes-guix-iso              build that ISO (on any x86_64 Guix)
iso/qubes-guix-iso-remote       build it on another machine, from this checkout's HEAD
dom0/qubes-guix-create          dom0: create the qube and boot the installer
guest/qubes-guix-install        installer shell: unattended install (disk, config.scm, then finish-install)
guest/qubes-guix-netacct        network traffic per remote address (nftables): start, report, watch
guest/qubes-guix-monitor        stock ISO: an install in tmux, with htop and the traffic per address
guest/qubes-guix-pv-store       installer: read the store from the ISO as a PV disk, not the emulated CD
guest/qubes-guix-finish-install installer, before the first reboot: config.scm + guix system init
guest/qubes-guix-setup          guest: channel, guix pull, config.scm, reconfigure
PORT-NOTES.md                   the porting log: every problem hit and why things are the way they are
```

The service runs everything under Shepherd. That covers QubesDB, the qrexec agent, the GUI agent, networking, feature advertisement, meminfo-writer and the CTAP proxy. It also provides:
- the block-device export: upstream's udev rule and scripts, so the qube's disks, USB drives and loop devices are listed by `qvm-block` in dom0, and `qvm-start --cdrom=QUBE:/path.iso` works with an ISO kept in a Guix qube;
- PAM stacks;
- `/etc/qubes-rpc`;
- the setuid `qfile-unpacker`;
- udev rules and kernel modules;
- the `qubes` group;
- the `/sbin/poweroff` and `/sbin/reboot` links that Xen's shutdown path calls.

## Upstream bugs found (patched here)

Each fix is a build phase in the relevant package, with a comment, and each bug is reported upstream. The phases go once the fixes reach a release this channel builds.

- **qrexec-agent:** `env_buf[64]`. **qubes-gui-runuser:** `env_buf[256]`. Both abort the PAM session when `SHELL` or `PATH` is long; store paths are. ([QubesOS/qubes-issues#11163](https://github.com/QubesOS/qubes-issues/issues/11163))
- **qubes-app-u2f:** replies to CTAPHID_CBOR requests are framed as CTAPHID_MSG, which breaks spec-compliant FIDO2 clients. ([QubesOS/qubes-issues#10981](https://github.com/QubesOS/qubes-issues/issues/10981))
- **qubes-app-u2f:** a makeCredential request without `rp.name` is rejected, although CTAP2 allows that. ([QubesOS/qubes-issues#11162](https://github.com/QubesOS/qubes-issues/issues/11162))

## Gotchas worth knowing

- **Build the Qubes components from the branch matching dom0's release, not `main`.** Upstream supports a newer dom0 with older qubes, not the reverse. For example, qubes-linux-utils from `main` reports swapinfo, which only an R4.4 dom0 accepts, and on R4.3 its meminfo-writer exits after one update ([QubesOS/qubes-issues#11164](https://github.com/QubesOS/qubes-issues/issues/11164), closed as an unsupported combination). This channel builds the R4.3 branches.
- **`/var/run` is not `/run` on Guix, and `/var/run` survives reboots.** Stale pidfiles bite.
- **There is no `/sbin`.** The service creates the two links Xen's shutdown path needs.
- **Services in packages other than core-agent are linked into `/run/qubes-rpc`.** The qrexec agent searches there first.
- **Packages can add their own session start-up hooks.** `qubes-session` runs every executable in `/run/current-system/profile/lib/qubes/session.d/` (the split-gpg2 client uses this). This replaces XDG autostart.

See `PORT-NOTES.md` for the full story.
