# Release notes

## v0.1.0-rc1

The first release candidate of qubes-guix: a Guix channel that makes Guix System a Qubes OS R4.3 qube, with dom0 scripts that create and install one. It's for testing before v0.1.0: please report what breaks.

### What's in it

- **The guest:** the Qubes R4.3 agents (qrexec, QubesDB, the GUI agent, the core agent's services), packaged for Guix and wired into Guix System as one service, `qubes-guest-service-type`. `qubes-operating-system` adds it, and what a qube needs besides, to any `operating-system`. See [Configuring the system](doc/configuration.md).
- **Features:** the seamless GUI, file copy, audio, networking from QubesDB, memory balancing, U2F/FIDO2 through the CTAP proxy, the split-gpg2 and split-ssh clients, USB devices from sys-usb, and block devices for dom0. The README's table says what's been verified.
- **Kinds of qube:** StandaloneVMs, templates, and AppVMs based on them, in PVH (no QEMU, no stub domain; the default for new installs) or HVM.
- **Installing:** `dom0/qubes-guix-create` (`qg-create`) creates the qube and installs it, unattended, in one command. It lists what it will do and asks first (`--yes` for scripts). From the qubes-guix installer ISO, nothing is done by hand; from Guix's own ISO, only a GRUB edit. See the README's [Getting started](README.md#getting-started).
- **The dom0 side:** `qubes-guix-refresh` copies the dom0 scripts from your checkout in a qube (showing its commit and signature first) and links each into `~/bin`, also by a short name: `qg-create`, `qg-test`, `qg-config`, `qg-build-iso`, `qg-refresh`. Your settings live in `~/.config/qubes-guix`, which a refresh never touches; `qg-config` writes them by question and answer: your substitute server (picked from your list, its key fetched and shown by fingerprint), non-free software (nonguix), the desktop, the package list. See [Creating the qube](doc/install-stock-iso.md#creating-the-qube-dom0).
- **Building the ISO from dom0:** `qg-build-iso --template T` makes a builder StandaloneVM from a Guix template (its store kept between builds) and builds the ISO there with your settings; the ISO stays in it, ready for `qg-create`. See [Building it from dom0](doc/install-qubes-iso.md#building-it-from-dom0).
- **The default system:** no desktop environment: under Qubes each window is drawn in dom0's desktop. `xterm` (in DejaVu Sans Mono; your `~/.Xresources` is loaded at the session's start) and `%desktop-services`, without its graphical login, networking or NetworkManager applet. `qg-create --desktop xfce` installs Xfce as before. The core agent's GTK dialogs (a file chooser some dom0 tools open, `qvm-copy`'s error popups) are a package of their own, `qubes-zenity`, since zenity brings GTK 4 and GStreamer; `--desktop xfce` adds it. See [Configuring the system](doc/configuration.md).
- **A substitute server:** with your own ([guix-subs](https://github.com/BetoHydroxyButyrate/guix-subs)), qubes lock to the channel commits it built, so installs and updates come from it rather than being built locally. See [The full setup](doc/full-setup.md).
- **Updating:** `qubes-guix-update` pulls and reconfigures, through the Qubes updates proxy in templates; `--guix-commit server` locks every channel to the server's last build, `--channel NAME=…` moves one. See [Updating](doc/updating.md).
- **AppVMs:** `qubes-guix-profile` puts a user's packages back at each login, from `~/.config/guix/manifest.scm` (or a Guix Home). See [Software in AppVMs](doc/templates.md#software-in-appvms).
- **Testing:** `dom0/qubes-guix-test` (`qg-test`) smoke-tests a qube's Qubes integration (a template through a throwaway AppVM, or `--in-place`). See [Testing a qube](doc/testing.md). A [CI](ci/README.md) on a bare-metal Qubes machine builds the ISO at every push, installs a template from it, and tests it, a qube booted from an ISO kept in a Guix qube, and every kind of qube (template, AppVM, standalone; HVM and PVH).
- **Upstream fixes:** three Qubes bugs found while porting are patched here, and reported upstream. See [Internals](doc/internals.md).

### Requirements

- Qubes OS R4.3 (the agents are its branches; an older dom0 isn't supported).
- For PVH: dom0's `grub2-xen-pvh` (`/var/lib/qubes/vm-kernels/pvgrub2-pvh`). Without it, installs stay HVM.
- To build the installer ISO: a Guix template (`qg-build-iso`), any x86_64 Guix, or your substitute server.

### Not in this release

- **No prebuilt ISO.** At 2.8 GiB (with the channels' checkouts, for installs with no network) it's over GitHub's 2 GiB limit for a release file. Build it with `qg-build-iso` from dom0, `iso/qubes-guix-iso` (or `iso/qubes-guix-iso-remote` on your substitute server), or install from Guix's own ISO.
- **The Qubes Update tool** doesn't update Guix qubes: it knows only apt, dnf and pacman. `qubes-guix-create` sets `skip-update`; use `qubes-guix-update`.
- **PVH is new:** CI tests templates, AppVMs and StandaloneVMs in it (and in HVM) at every push, but it has seen less daily use than HVM. An install switches the qube to PVH and starts it in HVM instead if that fails; `--hvm` keeps it HVM.
- **AppVMs** work, and pass `qubes-guix-test`, but have seen less daily use than StandaloneVMs and templates.
- **The installer boots from an emulated CD,** which has returned bad data for large ISOs. An unattended install from a qubes-guix ISO built from this release, given as `NAME ISO_VM:ISO_PATH`, reads the store through a second, PV, disk instead.
- **A PVH qube's console** is Xen's (`sudo xl console NAME` in dom0, or `qvm-console-dispvm NAME`): it has no emulated VGA for `qvm-start-daemon --force-stubdomain` to show.

### Upgrading an existing qube

Qubes set up from earlier commits of this channel: `qubes-guix-update -r` brings them to this release (or `qubes-guix-update --guix-commit server` with a substitute server). To move one to PVH afterwards: shut it down, then in dom0 `qvm-prefs NAME virt_mode pvh; qvm-prefs NAME kernel pvgrub2-pvh`. An existing qube keeps its own `config.scm`, so an Xfce one stays Xfce; it loses the core agent's GTK dialogs unless you add `qubes-zenity` to its packages. A Guix qube that serves an ISO to another qube's boot (`qvm-start --cdrom=GUIXQUBE:/file.iso`) needs this release's `xen-driver-domain` service: update it and restart it. Qubes installed from an ISO built through the old `iso` branch follow that branch: change `"iso"` to `"main"` in their `/etc/config.scm` and run `qubes-guix-update -r`.

### Verifying

The tag is signed with the key that signs the channel's commits, fingerprint `9765 1FBD E504 F2D1 3DA9  88EB C0E8 4747 0C0B 2F22` (the channel introduction in [Configuring the system](doc/configuration.md#using-the-channel)): `git tag -v v0.1.0-rc1`.
