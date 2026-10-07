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
        (url "https://github.com/<you>/<repo>")          ; TODO: published URL
        (branch "main")
        (introduction
         (make-channel-introduction
          "<INTRODUCTION-COMMIT>"                          ; TODO
          (openpgp-fingerprint
           "F9BE 45DF A380 E9C8 8D47  4E96 6767 C5ED 20D3 1AEA"))))
       %default-channels)
```

Then `guix pull`. Commits are signed. Guix verifies them against `.guix-authorizations` and the key on the `keyring` branch.

## System configuration

The minimum in `/etc/config.scm`:

```scheme
(use-modules (gnu) (qubes services agent))

(operating-system
  ;; ...
  (kernel-arguments (append %qubes-kernel-arguments '("quiet")))
  (users (cons (user-account
                (name "user")
                (group "users")
                (supplementary-groups '("wheel" "audio" "video" "qubes")))
               %base-user-accounts))
  (services (cons (service qubes-guest-service-type)
                  %desktop-services)))     ; or %base-services
```

- **`%qubes-kernel-arguments`:** this is `xen_privcmd.unrestricted=1`. Without it, recent kernels refuse the hypercalls that vchan needs.
- **The default user must be in the `qubes` group:** it needs the Xen device nodes, `/var/run/qubes`, and the CTAP hidraw device.
- **Don't also use `static-networking-service-type`:** the Qubes service provides `networking` itself, from QubesDB.
- **A local desktop (e.g. XFCE on `:0`) can coexist:** the Qubes GUI agent runs its own X server on `:1`, with no VT.

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

Outline: create a StandaloneVM in HVM mode, then install Guix from the Guix System ISO.

```
qvm-create --class StandaloneVM --label purple --property virt_mode=hvm guix
qvm-prefs guix kernel ''
qvm-volume extend guix:root 60g
qvm-start guix --cdrom=<qube>:/path/to/guix-system-install.iso
```

Install as usual. Then add the channel, and reconfigure with the configuration above. On first boot with the agent, dom0 hides the emulated VGA window once the Qubes GUI agent connects. If you need the console back, run `qvm-start-daemon --force-stubdomain guix`.

Recommended dom0 settings:

```
qvm-features guix skip-update 1             # the Qubes Update tool can't update Guix
qvm-prefs guix memory 2000; qvm-prefs guix maxmem 8000   # then enable memory balancing in Qube settings
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
  echo no-autostart >> ~/.gnupg/gpg.conf    # never fall back to an empty local agent
  gpg --import pubkey.asc                    # the PUBLIC key (qvm-copy it from the vault)
  gpg -K                                     # sec# + ssb lines = working
  ```
  A warning that the agent "is older than us" is harmless. It just means the vault's GnuPG is older than Guix's.

## Updating

There are two cases:
- **Updating the system:** run `guix pull` then `sudo guix system reconfigure /etc/config.scm`.
- **Working on the channel itself:** use `sudo guix system reconfigure -L /path/to/checkout /etc/config.scm`. `-L` puts the checkout ahead of the pulled channel, so you can test before committing.

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
