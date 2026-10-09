# guix-qubes

A [Guix](https://guix.gnu.org) channel that turns **Guix System** into a properly integrated [Qubes OS](https://www.qubes-os.org) qube. It packages the Qubes R4.3 guest agents and wires them into Guix System as one service, `qubes-guest-service-type`.

Status: a daily-driven StandaloneVM (HVM) on Qubes R4.3. Everything below has been verified unless it says otherwise.

| Feature | Status |
|---|---|
| qrexec (`qvm-run`, services, user switching via PAM) | ✅ |
| QubesDB | ✅ |
| File copy (`qvm-copy` both ways, receive into `~/QubesIncoming`) | ✅ |
| Seamless GUI (windows, clipboard, keyboard incl. full Apple layout, app menus, window icons) | ✅ |
| Monitor layout changes | ✅ |
| Audio out and microphone (PulseAudio vchan sink/source) | ✅ |
| Networking from QubesDB (IP, gateway, DNS) | ✅ |
| `qvm-shutdown` / `qvm-restart` | ✅ |
| Memory balancing (meminfo-writer, memory hotplug) | ✅ |
| Feature advertisement (`qvm-features`, Services tab) | ✅ |
| U2F **and** FIDO2/passkeys via the CTAP proxy (sys-usb) | ✅ |
| split-gpg2 client (`gpg`, `git commit -S` with keys in a vault qube) | ✅ |
| TemplateVM / AppVM based on a Guix template | ❌ not yet |
| PVH | ❌ not yet |
| Qubes Update tool | ❌ by design (use `guix pull` + reconfigure; see below) |

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
qubes/services/agent.scm        qubes-guest-service-type — the integration
qubes/system.scm                qubes-operating-system — adds all of it to any operating-system
dom0/qubes-guix-create          dom0: create the qube and boot the installer
guest/qubes-guix-setup          guest: channel, guix pull, config.scm, reconfigure
PORT-NOTES.md                   the porting log: every problem hit and why things are the way they are
```

The service runs everything under Shepherd. That covers QubesDB, the qrexec agent, the GUI agent, networking, feature advertisement, meminfo-writer and the CTAP proxy. It also provides:
- PAM stacks;
- `/etc/qubes-rpc`;
- the setuid `qfile-unpacker`;
- udev rules and kernel modules;
- the `qubes` group;
- the `/sbin/poweroff` and `/sbin/reboot` links that Xen's shutdown path calls.

## Using the channel

Add it to `~/.config/guix/channels.scm`:

```scheme
(cons* (channel
        (name 'qubes)
        (url "https://github.com/BetoHydroxyButyrate/qubes-guix")
        (branch "main")
        (introduction
         (make-channel-introduction
          "ea33fcb13bff41db38017f9ec385565f66f88fae"
          (openpgp-fingerprint            ; the signing SUBKEY (see .guix-authorizations)
           "1607 721B 3110 F370 9497  F436 B548 D5A5 665F D366"))))
       %default-channels)
```

Then `guix pull`. Commits are signed. Guix verifies them against `.guix-authorizations` and the key on the `keyring` branch.

## System configuration

The simplest way is to wrap your whole `operating-system` (the one the installer wrote, for example) in `qubes-operating-system`. `guest/qubes-guix-setup` does exactly this edit for you:

```scheme
(use-modules (gnu) (qubes system))

(qubes-operating-system
 (operating-system
   ;; ... unchanged ...
   ))
```

It adds what a qube needs and nothing else:
- **`%qubes-kernel-arguments`:** this is `xen_privcmd.unrestricted=1`. Without it, recent kernels refuse the hypercalls that vchan needs.
- **The `qubes` group for every regular user:** they need it for the Xen device nodes, `/var/run/qubes` and the CTAP hidraw device.
- **`qubes-guest-service-type`,** which provides `networking` itself, from QubesDB.
- **No NetworkManager, connman or DHCP client,** because they provide `networking` too, and Shepherd refuses two providers. A `static-networking` service for `eth0` has to go as well; the setup leaves `static-networking` alone, since `%base-services` uses it for loopback.

- **No graphical login (display manager),** unless you pass `#:display-manager? #t`. `%desktop-services` always includes GDM, whatever desktop you chose. In a qube, the Qubes GUI agent provides the windows, and GDM refuses a console login while the agent's session for that user is open ("Session Already Running"). The console becomes a text login, and your desktop's packages (XFCE etc.) stay installed. Services that extend the display manager, such as the installer's `set-xorg-configuration`, are removed with it.

To pass options, use `(qubes-operating-system os #:config (qubes-guest-configuration ...))`. It is idempotent: applying it to an `operating-system` that already has the service changes nothing more.

To write it out by hand instead:

```scheme
(use-modules (gnu) (qubes services agent))
(use-service-modules networking)

(operating-system
  ;; ...
  (kernel-arguments (append %qubes-kernel-arguments %default-kernel-arguments))
  (users (cons (user-account
                (name "user")
                (group "users")
                (supplementary-groups '("wheel" "audio" "video" "qubes")))
               %base-user-accounts))
  (services (cons (service qubes-guest-service-type)
                  (modify-services %desktop-services     ; or %base-services
                    (delete network-manager-service-type)))))
```

A local desktop (e.g. XFCE on `:0`) can coexist: the Qubes GUI agent runs its own X server on `:1`, with no VT.

### Options

```scheme
(service qubes-guest-service-type
         (qubes-guest-configuration
          (gui? #t)                    ; #f: headless (qrexec, qubesdb, file copy only)
          (network? #t)                ; configure the uplink from QubesDB
          (network-interface "eth0")
          (ctap-backend "sys-usb")     ; #f: no U2F/FIDO2 proxy
          (split-gpg2 qubes-split-gpg2-client)))  ; #f: no split-gpg2 client
```

Package fields (`qrexec`, `qubesdb`, `core-agent`, `gui-agent`, `ctap`) can be overridden too.

## Creating the qube (dom0)

`dom0/qubes-guix-create` creates the qube and boots it from the Guix System installer ISO. Download the ISO from [guix.gnu.org](https://guix.gnu.org/en/download/) into any qube, then copy the script into dom0. Read it first: anything you copy into dom0 runs with full control of the machine.

```
# dom0 — <qube> is where you cloned this repository
qvm-run --pass-io <qube> 'cat qubes-guix/dom0/qubes-guix-create' > qubes-guix-create
chmod +x qubes-guix-create
./qubes-guix-create guix untrusted:/home/user/Downloads/guix-system-install-1.5.0.x86_64-linux.iso
```

```
qubes-guix-create [options] NAME ISO_VM:ISO_PATH [VCPUS [MEMORY [MAXMEM]]]
  defaults: 2 vCPUs, 4000 MiB, 8000 MiB max; -s root size (60g), -l label, -n netvm, --dry-run
```

It checks everything before changing anything, and removes the qube again if a step fails. It creates a StandaloneVM in HVM mode that boots its own kernel, grows the root volume, sets `skip-update` (the Qubes Update tool can't update Guix) and turns on memory balancing when MAXMEM > MEMORY. Then it boots the installer and prints the qube's network settings. Qubes networking is static, so you may need these in the installer and in your first `config.scm`. Until the agent runs, the qube has exactly MEMORY, which is why the default is 4000 MiB: `guix system init` needs it.

The installer needs three manual steps under Qubes, and the script prints them with this qube's values:
1. **In GRUB:** pick the non-graphical install entry, press `e`, and add `nomodeset` to the `linux` line.
2. **In the shell:** set the network by hand (Qubes has no DHCP). Use a **/8** address so the gateway is on-link: `ip addr add <ip>/8 dev eth0`, then `ip link set eth0 up`, `ip route add default via <gateway>`, and the DNS servers in `/etc/resolv.conf`.
3. **Back to the installer:** dom0's desktop grabs Alt+Fn, so switch consoles from dom0 with `xdotool key --window $(xdotool selectwindow) alt+F2` and click the qube's window.

Install as usual, then reboot into the new system. Its network isn't configured yet, so run the same `ip` commands as root once more (stop NetworkManager first if the installer added it: `sudo herd stop NetworkManager`).

## Setting up the guest

As your normal user in the new system:

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

## Feature setup

### U2F / FIDO2 (CTAP proxy)

- **sys-usb:** its template needs the `qubes-ctap` package. Stock Fedora and Debian templates usually have it.
- **dom0:** run `qvm-service guix qubes-ctap-proxy on` and enable guix in **Qubes Global Config → USB Devices → U2F Proxy**. Global Config only allows the U2F (`u2f.*`) calls. For FIDO2 (passkeys, PINs), also add to `/etc/qubes/policy.d/30-user.policy`:
  ```
  ctap.GetInfo    *  guix  sys-usb  allow
  ctap.ClientPin  *  guix  sys-usb  allow
  ```
- **guix:** reboot after the first install. A reconfigure doesn't make the running udev reload its rules, so the virtual key's hidraw node would keep the wrong group.

### split-gpg2

- **Vault qube** (e.g. `gpg-admin`): install `split-gpg2` in its template. It coexists with split-gpg v1. The key needs **signing subkeys**: by default split-gpg2 exposes subkeys only, never the primary key.
- **dom0:**
  ```
  # /etc/qubes/policy.d/30-user.policy
  qubes.Gpg2  *  guix  @default  allow target=gpg-admin
  ```
  ```
  qvm-service guix split-gpg2-client on
  ```
- **guix:**
  ```
  # never start an empty local gpg-agent (keyboxd must still autostart, so not `no-autostart`)
  echo 'agent-program /run/current-system/profile/libexec/split-gpg2/gpg-agent-placeholder' >> ~/.gnupg/gpg.conf
  gpg --import pubkey.asc                    # the PUBLIC key (qvm-copy it from the vault)
  gpg -K                                     # sec# + ssb lines = working
  ```
  A warning that the agent "is older than us" is harmless. It just means the vault's GnuPG is older than Guix's.

## Updating

There are two cases:
- **Updating the system:** run `guix pull` then `sudo guix system reconfigure /etc/config.scm`.
- **Working on the channel itself:** use `sudo guix system reconfigure -L /path/to/checkout /etc/config.scm`. `-L` puts the checkout ahead of the pulled channel, so you can test before committing.

### Pinning Guix (or: why reconfigure rebuilds everything)

There are no substitutes for this channel's packages, so they're built from source on your machine. They are built against whatever Guix provides (gcc, glibc, python, Xorg…). Each `guix pull` that moves the Guix channel changes those inputs, and the next reconfigure rebuilds every Qubes package, which takes a long time.

Pinning the Guix channel to a commit keeps those inputs fixed. A reconfigure then only rebuilds when this channel itself changes. The cost is that you get Guix updates (including security fixes) only when you move the pin, so do that deliberately and often enough.

The easy way is to record what you have now and pin everything except this channel:

```
guix describe -f channels > ~/.config/guix/channels.scm
```

Then delete the `(commit "…")` line from the `qubes` channel entry, so that one keeps following `main`. Keep the `(commit …)` lines for `guix` (and `nonguix`, if you use it). To move the pin later, edit the commit, or rerun the command above after an unpinned `guix pull`.

### Firefox ESR (nonguix)

GNU IceCat is the browser Guix ships. If you'd rather have Firefox ESR, it's in the [nonguix](https://gitlab.com/nonguix/nonguix) channel, which carries non-free software. Add it next to the qubes channel in `~/.config/guix/channels.scm`. Take the `introduction` from the nonguix README rather than from here, so you check it at its source:

```scheme
(channel
 (name 'nonguix)
 (url "https://gitlab.com/nonguix/nonguix")
 (introduction
  (make-channel-introduction
   "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
   (openpgp-fingerprint
    "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
```

- **Use its substitute server.** Building Firefox yourself takes hours. The nonguix README explains how to authorize it: in `config.scm`, modify `guix-service-type` to add the server to `substitute-urls` and its key to `authorized-keys`.
- **Install it system-wide**, in `config.scm`'s `packages` field with `(use-modules (nongnu packages mozilla))`. Then its `.desktop` file is in the system profile, where `qubes.GetAppmenus` finds it. After reconfiguring, run `qvm-appmenus --update guix` in dom0 and Firefox ESR appears in the qube's menu.
- **If you pin Guix, pin nonguix too.** nonguix follows current Guix, so an old Guix commit with the newest nonguix may not build. Move the two pins together.

## Upstream bugs found (patched here)

Each fix is a build phase in the relevant package, with a comment. Reports are being filed with QubesOS/qubes-issues.

- **qrexec-agent:** `env_buf[64]`. **qubes-gui-runuser:** `env_buf[256]`. Both abort the PAM session when `SHELL` or `PATH` is long; store paths are.
- **qubes-app-u2f:** replies to CTAPHID_CBOR requests are framed as CTAPHID_MSG, which breaks spec-compliant FIDO2 clients.
- **qubes-app-u2f:** a makeCredential request without `rp.name` is rejected, although CTAP2 allows that.
- **qubes-linux-utils (main):** meminfo-writer exits when `memory/swapinfo` can't be written, i.e. on an R4.3 dom0. This channel builds the R4.3 branch, which doesn't have the change.

## Gotchas worth knowing

- **`/var/run` is not `/run` on Guix, and `/var/run` survives reboots.** Stale pidfiles bite.
- **There is no `/sbin`.** The service creates the two links Xen's shutdown path needs.
- **Services in packages other than core-agent are linked into `/run/qubes-rpc`.** The qrexec agent searches there first.
- **Packages can add their own session start-up hooks.** `qubes-session` runs every executable in `/run/current-system/profile/lib/qubes/session.d/` (the split-gpg2 client uses this). This replaces XDG autostart.

See `PORT-NOTES.md` for the full story.

## License

The packaged software is GPL-2.0-or-later (Qubes OS upstream). Channel code: TODO — see `COPYING`.
