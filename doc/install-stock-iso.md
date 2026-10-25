# Installing from the stock Guix ISO

[← README](../README.md) · the other ways in: [the qubes-guix ISO](install-qubes-iso.md), [the full setup](full-setup.md)

For trying qubes-guix with nothing to build first. It installs from Guix's own installer ISO, so some things are left to do by hand that [the qubes-guix ISO](install-qubes-iso.md) does for you: a GRUB edit, the installer's network, and building the Qubes agents in the new qube, from source, which takes a while.

In short, in dom0:

1. Get the dom0 scripts into dom0 ([how](#creating-the-qube-dom0)), and create the qube from the ISO: `qg-create guix QUBE:/path/to/guix-system-install.iso`.
2. At the installer's GRUB menu, add `nomodeset` to the kernel line ([how](#creating-the-qube-dom0)).
3. Then either `qg-create --unattended guix` for an install with no dialogs, or the installer's dialogs followed by `qg-create --finish-install --run guix` ([before the first reboot](#before-the-first-reboot-recommended)).

Or all of it in one command: `qg-create --unattended guix QUBE:/path/to/guix-system-install.iso` (with whatever options the install takes). It lists what it will do and asks, explains the GRUB step, and starts the qube when you press Enter. You do the GRUB edit in its console, then press Enter in the dom0 terminal once the installer's first screen is up; the rest is typed into the installer, and the qube is started, updated and tested as with `--unattended guix`.

Add `--template` throughout for a template ([templates and AppVMs](templates.md)).

## Creating the qube (dom0)

`dom0/qubes-guix-create` creates the qube and boots it from an installer ISO: the qubes-guix one ([its own page](install-qubes-iso.md)), or the stock Guix System installer ISO, which this section is about. Download the ISO from [guix.gnu.org](https://guix.gnu.org/en/download/) into any qube, then get the dom0 scripts into dom0. Read them first: anything you copy into dom0 runs with full control of the machine, and whoever controls the qube with your checkout controls these scripts.

The first time, copy `dom0/` by hand and run its `qubes-guix-refresh`, giving it your checkout as QUBE:PATH:

```
# dom0 — <qube> is where you cloned this repository
qvm-run --pass-io <qube> 'tar c -C ~/qubes-guix dom0' | tar x -C /tmp
/tmp/dom0/qubes-guix-refresh <qube>:~/qubes-guix
qg-create guix untrusted:/home/user/Downloads/guix-system-install-1.5.0.x86_64-linux.iso
```

`qubes-guix-refresh` shows the checkout's commit, its signature and any local changes to `dom0/`, and asks before going on. It then copies `dom0/` to `~/.local/share/qubes-guix` and links each script into `~/bin`, twice: by its name, and short (`qg-create`, `qg-test`, `qg-refresh`). It remembers QUBE:PATH, so after a `git pull` in that qube, `qg-refresh` alone brings dom0 up to date. Keep your own settings (`qubes-guix-packages`, `-channels`, `-substitutes`) in `~/.config/qubes-guix`, which a refresh never touches. The scripts look for each in the current directory, then there, then for the repository's sample next to them.

`qg-config` writes those settings for you, by question and answer: a substitute server of your own (its URL, and its signing key, fetched through a qube with network and shown by fingerprint for you to check), non-free software (the nonguix channel, with its substitute server and key), a desktop (none, the default: xterm, with each window drawn in dom0's desktop; or Xfce, which `qg-create --desktop xfce` also gives), and the package list, with optional groups (Xfce's applications without its desktop, a browser), then your editor. `qg-config --show` prints what's set.

```
qubes-guix-create [options] NAME ISO_VM:ISO_PATH [VCPUS [MEMORY [MAXMEM]]]
  defaults: 2 vCPUs, 4000 MiB, MAXMEM = MEMORY (no balancing); -s root size (60g), -l label, -n netvm, --dry-run
```

It checks everything before changing anything, and removes the qube again if a step fails. It creates a StandaloneVM in HVM mode that boots its own kernel, grows the root volume, sets `skip-update` (the Qubes Update tool runs `/usr/bin/python3` in the qube and knows only apt, dnf and pacman: Guix updates with [`qubes-guix-update`](updating.md)), raises `qrexec_timeout` to 300 s, and turns on memory balancing when MAXMEM > MEMORY. Then it boots the installer and prints the qube's network settings. Qubes networking is static, so you may need these in the installer and in your first `config.scm`. Until the agent runs, the qube has exactly MEMORY, which is why the default is 4000 MiB: `guix system init` needs it.

**Under HVM, memory balancing makes every boot slower.** (An unattended install switches the qube to [PVH](templates.md#pvh) afterwards, where it doesn't: 18 s at 1000/4000. The installer itself boots in HVM.) An HVM whose MAXMEM is above MEMORY boots in Xen's populate-on-demand mode, and a Guix boot then takes much longer to reach the qrexec agent. Measured: 24 s at 8000/8000, 83 s at 8000/32542. Past the default 60 s `qrexec_timeout`, `qvm-start` gives up and kills the qube, uncleanly. So the script leaves balancing off by default and sets the timeout to 300 s either way. If you want balancing, keep the gap between MEMORY and MAXMEM small. You can change it later in the qube's settings ("Include in memory balancing"); it takes effect when the qube next starts.

The installer needs three manual steps under Qubes, and the script prints them with this qube's values:
1. **In GRUB:** with **GNU Guix installation** highlighted, press `e`:

   ![The installer's GRUB menu, one entry: GNU Guix installation 1.5.0](grub-menu.png)

   This shows the boot commands. Move to the end of the `linux` line (it wraps; it ends with `modprobe.blacklist=radeon,amdgpu`):

   ![The boot commands before the edit](grub-edit.png)

   Add ` nomodeset` there, then press Ctrl+X to boot:

   ![The linux line ending in nomodeset](grub-nomodeset.png)

   Without `nomodeset`, the console on VT3 doesn't work. Only the installer needs it: the installed system boots fine without it.
2. **Network:** Qubes has no DHCP, so the network is set by hand, in the root shell on VT3. In dom0, `./qubes-guix-create --type-network guix` does it: it finds the qube's console window by its title (the qube's name), switches it to VT3 (Ctrl+Alt+F3) and types the commands with this qube's address, gateway and DNS, showing each line as it's sent. **Don't touch the keyboard or mouse until it says DONE:** the key presses go to whichever window has the focus. Clicking elsewhere stops the typing at the next line, so to cancel, click the dom0 terminal (then Ctrl+C if it's still running). If the window isn't found, it asks you to click it. By hand it's `ip addr add <ip>/8 dev eth0`, `ip link set eth0 up`, `ip route add default via <gateway>` and the DNS servers in `/etc/resolv.conf`. The **/8** puts the gateway on-link.
3. **Back to the installer:** dom0's desktop keeps Ctrl+Alt+Fn for itself, so switch the qube's console from dom0: `./qubes-guix-create --vt 1 guix` (`--vt 3` for the root shell).

Then install as usual, up to the **Installation complete** screen, and **don't reboot yet**: the next section makes the new system a qube before its first boot.

### Unattended install (instead of the installer's dialogs)

After the GRUB step, at the installer's first screen, run in dom0:

```
./qubes-guix-create --unattended guix          # add --template for a template, -b BRANCH to test a branch
```

It asks for one password, used for both `user` and root. Only a hash of it is typed into the qube. With `--no-password`, both accounts are left as after a manual Guix install; `qvm-run` works either way. Then it finds the qube's console window, as `--type-network` does. On VT3 it types:
- the network setup;
- a clone of this repository;
- the command to run `guest/qubes-guix-install`, under a monitor: tmux, with the install above, and `htop` and the network traffic per remote address below, as on the qubes-guix ISO. tmux, htop and nftables come from `guix shell` first. Ctrl-b d leaves tmux, `tmux attach` goes back. The install's output is also kept in `/root/qubes-guix-monitor.log`.

**Extra packages and channels, your own substitute server:** see [Extra packages and channels](configuration.md#extra-packages-and-channels) and [the full setup](full-setup.md#installing-with-your-server).

A TemplateVM is detected even without `--template`. It gets `updates-proxy-setup` when it's created, and loses its netvm after the install. From then on, it updates through the Qubes updates proxy like other templates. `qubes-guix-update` handles `guix pull`, and guix-daemon handles substitutes.

That script:
1. **Disk:** partitions `/dev/xvda` as GPT, with a 1 MiB BIOS boot partition and an ext4 root labelled `guix-root`. It refuses a disk that already has partitions unless you pass `--force`.
2. **Configuration:** writes `/etc/config.scm` with xterm and no desktop environment (each window is drawn in dom0's desktop), `%desktop-services`, the user `user`, dom0's timezone, and the qube's name as host name.
3. **Build:** runs `qubes-guix-finish-install`.
4. **Power off:** sets the passwords and powers off.

`qubes-guix-create` waits for the qube to stop, then starts it from its disk. Use `--no-wait` to skip that. The only manual steps left are the GRUB edit, the password and one click.

## Setting up the guest

### Before the first reboot (recommended)

At the installer's **Installation complete** screen, with the installer's network still up from `--type-network`, run in dom0:

```
./qubes-guix-create --finish-install --run guix   # add --template for a template, -b BRANCH to test a branch
```

On VT3 this clones the repository into `/root/qubes-guix` (git comes from `guix shell`) and runs `guest/qubes-guix-finish-install` as root. That script wraps `/mnt/etc/config.scm` in `(qubes-operating-system ...)` (the original stays as `config.scm.pre-qubes`), checks it, and rebuilds `/mnt` with `guix system init` from a Guix that includes the qubes channel (`guix time-machine`). If the installer has already unmounted the new system, the script mounts it again; that works for a single unencrypted root partition. The first run builds a Guix and then the Qubes agents, so it takes a while, but nothing waits for a password. Without `--run` it only clones and shows the command, for you to review and type.

When VT3 says **Done**, reboot. That's the last manual step. The first boot has:
- the network from QubesDB;
- qrexec and the GUI agent;
- passwordless `sudo` for the `qubes` group;
- the qubes channel in `/etc/guix/channels.scm`.

Run `guix pull` before your first `sudo guix system reconfigure /etc/config.scm`.

### After the first boot

If you've already rebooted into the plain installed system, log in as root on its console (VT3) and run this in dom0:

```
./qubes-guix-create --bootstrap guix            # add --template for a template, -b BRANCH to test a branch
```

This types a short script into `/tmp/qubes-guix-bootstrap.sh` on the qube and shows it there, without running it. Read it, then run `sh /tmp/qubes-guix-bootstrap.sh`. The script sets the network, then runs `qubes-guix-setup` as the uid-1000 user.

`sudo` asks for that user's password **at the start**, before the long `guix pull`. A background loop then keeps sudo's timestamp fresh until the script ends. So you can walk away, and the `sudo` steps an hour later won't time out waiting for a password. From then on, passwordless sudo is part of the system.

Or by hand, as your normal user in the new system:

```
guix shell git -- git clone https://github.com/BetoHydroxyButyrate/qubes-guix
qubes-guix/guest/qubes-guix-setup
sudo reboot
```

`qubes-guix-setup`:
1. adds the qubes channel to `~/.config/guix/channels.scm` and runs `guix pull`;
2. wraps `/etc/config.scm` in `(qubes-operating-system ...)` and saves the old one as `/etc/config.scm.pre-qubes`;
3. checks the new configuration with a dry-run build before installing it, then runs `guix system reconfigure`. That builds the Qubes agents from source, so it takes a while.

If any step fails it stops, and `/etc/config.scm` is left as it was. Running it again is safe, since steps already done are skipped.

After the reboot the network comes from QubesDB, and dom0 hides the emulated VGA window once the Qubes GUI agent connects. If you need the console back, run `qvm-start-daemon --force-stubdomain guix`. Check from dom0:

```
qvm-run --pass-io guix 'ip -br addr'
qvm-features guix          # qrexec, gui, os-distribution=guix, ...
qvm-run guix alacritty     # or anything installed
```
