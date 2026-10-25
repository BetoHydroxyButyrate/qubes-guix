# Installing from the qubes-guix ISO

[← README](../README.md) · the other ways in: [the stock Guix ISO](install-stock-iso.md), [the full setup](full-setup.md)

The qubes-guix installer ISO has the Qubes agent and the Qubes packages already in it, so dom0 installs a qube from it in one command, with no manual steps. You build it once, on any x86_64 Guix. Without your own substitute server, the rest of an install comes from Guix's substitute servers (bordeaux and ci); with one, see [the full setup](full-setup.md).

In short:

1. Get the dom0 scripts into dom0: `qubes-guix-refresh` ([how](install-stock-iso.md#creating-the-qube-dom0)).
2. Build the ISO. From dom0, with a Guix template you have: `qg-build-iso --template TEMPLATE` ([below](#building-it-from-dom0)). Or on any Guix machine: `qubes-guix/iso/qubes-guix-iso`, which writes `qubes-guix-installer.iso`.
3. In dom0: `qg-create --unattended guix QUBE:/path/to/qubes-guix-installer.iso` (add `--template` for a template).

## Building it from dom0

`qg-build-iso` (`dom0/qubes-guix-build-iso`) builds the ISO in a builder qube, `qg-iso-builder`, which it makes the first time from the Guix template you name (`--template`). The builder is a StandaloneVM, so it keeps its Guix store, and later builds reuse what earlier ones fetched or built (`--appvm` makes an AppVM instead, whose store resets to its template's at every start). It has 4 vCPUs, 6000 MiB, its default netvm, 40 GiB for `/home` and 120 GiB of root for the store. Each run then, in the builder: clones or fetches qubes-guix into `~/qubes-guix` at the branch (`-b`, default `main`) or `--qubes-commit`; copies in your substitute servers (`~/.config/qubes-guix/qubes-guix-substitutes`, as `qg-config` writes it) and authorizes their keys there; and runs `iso/qubes-guix-iso`, with its output in your terminal and in `~/qubes-guix-iso.log` there. `--offline` puts what a default install needs in the ISO; options after `--` go to `qubes-guix-iso` as they are. The ISO stays in the builder (dom0 has little room), and the script ends with the `qg-create` line that installs from it.

## The ISO

`iso/qubes-guix-iso` builds an installer ISO for Qubes (`qubes/installer.scm`). It's the Guix installer plus a headless Qubes agent: QubesDB, the qrexec agent, and the network from QubesDB. Under Qubes, that removes every manual step of the stock ISO:
- **No GRUB edit:** `nomodeset` is on its kernel command line.
- **No network setup:** the address, gateway and DNS come from QubesDB, as in any qube.
- **No typing into the console:** dom0 drives the install with `qvm-run -u root`, and the output shows in the dom0 terminal.
- **Nothing to build for the Qubes agents:** the ISO's `guix` already includes the qubes channel, and its store has the Qubes packages built by that Guix. `qubes-guix-finish-install` uses that Guix directly, instead of `guix time-machine`.

The guest scripts are on the ISO, in `/root/qubes-guix/guest`, and so is git. The installer's console window (tty1) shows a monitor while it works: tmux with `htop` above and the network traffic per remote address below (`qubes-guix-netacct watch`). Ctrl-b d leaves it for a notice, where `monitor` goes back and `install` starts the installer's own dialogs for a manual install. At the end of an unattended install, or when it stops early, the traffic per address is reported in dom0's terminal; with the stock ISO too (it fetches `nftables` first).

The installer boots from the ISO as an emulated CD (QEMU's IDE, in the qube's stub domain), and reads its store through it. Installing from a 3.3 GiB ISO, stretches of that CD came back wrong, whether the ISO was in another qube or in dom0, and the copy to the new system failed or would have been corrupt. So `qubes-guix-create --unattended NAME ISO_VM:ISO_PATH` also attaches the same ISO, read-only, as a Xen PV disk, and the install (`qubes-guix-pv-store`) reads the store from that instead, bound over `/gnu/store` before anything is copied. `--unattended NAME` alone doesn't know where the ISO is, so it keeps the CD.

Build it on an x86_64 Guix, such as a Guix qube or your substitute server:

```
qubes-guix/iso/qubes-guix-iso                     # qubes-guix-installer.iso, at the head of main
qubes-guix/iso/qubes-guix-iso -b template --offline -o /tmp/qgi.iso
```

`--guix-commit` and `--qubes-commit` pin those channels by hand. `--offline` also puts into the ISO everything the default unattended install needs, and the channels' git checkouts, so that install needs no network at all; the ISO grows by a few GiB. Next to the ISO, `FILE.channels` records the channels it was built from. `-L DIR` builds from a checkout with your current Guix, for testing; that ISO's guix lacks the qubes channel, so installs from it fall back to `guix time-machine`.

With your own substitute server, `--server URL` builds the ISO at the commits the server last built, and installs from it then fetch nearly everything from that server: see [the full setup](full-setup.md). If the checkout's `dom0/qubes-guix-substitutes` names no server, the ISO is built at the head of each channel.

The qubes channel comes from its repository, never from a checkout: work you haven't committed and pushed isn't in the ISO, and with `--server` neither is anything newer than the server's last build. To build on a bigger machine (the substitute server) what you're working on elsewhere, push as usual, then run `iso/qubes-guix-iso-remote` in your working checkout. It stops on uncommitted changes in `qubes/`, `guest/` or `iso/` (untracked files too), and checks that the channel's repository has HEAD on its branch (`-b`, default `main`): pushed, nothing is pushed for you. If your remote has it but the repository doesn't yet (a mirror can lag), it waits. Then on the build host (`--host`, default `guix-subs`; `--dir`, default the same path under your home) it checks that commit out in its checkout and runs `iso/qubes-guix-iso -b main --qubes-commit HEAD`, plus whatever follows `--`. qubes is then exactly your HEAD, the other channels are at the server's last build, and installs from the ISO follow `main`:

```
git push && iso/qubes-guix-iso-remote             # on guix-subs, at this HEAD
iso/qubes-guix-iso-remote -- --offline -o qgi-offline.iso
```

Then, in dom0, one command creates the qube and installs it:

```
./qubes-guix-create --unattended guix work:/home/user/qubes-guix-installer.iso     # add --template for a template
```

It first lists what it will do: the qube, its packages, channels, substitute servers and lock, and the vault clients. Nothing changes until you answer `y` (`--yes` skips the question, for scripts). Then it asks for the password, creates the qube, and boots the ISO. dom0 waits for the installer's qrexec agent (the `qrexec` feature is set first). Then it runs `guest/qubes-guix-install` in it, detached, and follows the log; Ctrl+C stops following, not the install. When the install powers the qube off, it starts the qube from its disk, runs the first `qubes-guix-update -r`, and shuts a template down. Without `-b`, the install uses the ISO's own scripts and its channel branch, which is what its prebuilt packages match. `-b BRANCH` clones that branch instead. The packages, channels and substitutes files work as for the stock ISO: see [Extra packages and channels](configuration.md#extra-packages-and-channels) and [Installing with your server](full-setup.md#installing-with-your-server).

Without `--unattended`, it creates the qube, boots the ISO and prints the two ways on: `--unattended NAME`, or the installer's dialogs followed by `--finish-install NAME`. Over qrexec, `--finish-install` runs straight away and then restarts the qube from its disk, because a reboot inside the qube would boot the ISO again. The installer's network step may find no device to configure (connman is gone, since the agent provides `networking`): continue, the network is up.

dom0 recognises the ISO by a file name containing `qubes-guix`, or from `--unattended`. Otherwise pass `--qubes-iso` (or `--stock-iso`). It matters because dom0 waits up to `qrexec_timeout` for the agent of a qube with the `qrexec` feature, then kills it. The stock ISO has no agent.

The installer never sends its features to dom0 (`features-request? #f` in `qubes-guest-configuration`). dom0 keeps the first `qrexec` and `gui` values a qube gives, and the installer's `gui=0` would have stuck to the installed system.
