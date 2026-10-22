# Templates and AppVMs

[← README](../README.md)

*Tested:* on guix-tmpl, the private volume, `/home` on `/rw/home`, swap, passwordless sudo, and substitutes through the updates proxy with no netvm all work. AppVMs work too (`qubes-guix-test` makes one from the template), but have seen little use so far: expect to find a few Guix issues. A template works like a Debian or Fedora one:
- **Root is the template's.** An AppVM's root (with `/gnu/store` and `/var/guix`) is a fresh copy of the template's at every start. `guix install` in an AppVM lasts until shutdown, like `apt install`. Software that should stay goes in the template's `config.scm`. A manifest kept in your home (`guix shell -m manifest.scm`) survives, because home is on the private volume; its packages come back from substitutes.
- **`/home` is per qube,** on the private volume (`/rw/home`). On a qube's first start it's seeded from the template's `/home`.

Create it with `--template`, then set it up with `--template`:

```
./qubes-guix-create --template guix-tmpl untrusted:/path/to/guix-system-install.iso   # dom0
./qubes-guix-create --finish-install --template --run guix-tmpl                        # dom0, at "Installation complete"
qubes-guix/guest/qubes-guix-setup --template                                           # or: in the template, after its first boot
```

Install with a single root partition: no separate `/home`, because the template mounts its own `/home`. `qubes-guix-setup --template` also prints the dom0 steps that follow. After a `sudo shutdown` and one test start:

```
qvm-create --template guix-tmpl --label red \
    --property virt_mode=hvm --property kernel='' \
    --property memory=4000 --property maxmem=4000 work
```

An AppVM needs more than Qubes gives one by default: its kernel from the template's disk (`virt_mode hvm` with `kernel ''`, or [PVH](#pvh) with `kernel pvgrub2-pvh`; Qubes' default, PVH with dom0's kernel, can't boot Guix), more than the default 400 MiB, a longer `qrexec_timeout`, and, for memory balancing, `maxmem` above `memory` and the `meminfo-writer` service. `qubes-guix-create --appvm` sets all of that, its Qubes menu (the template's `default-menu-items`: the usual applications the template has, see [Options](configuration.md#options)), and with `--split-ssh` / `--split-gpg` / `--ctap` the vault clients' tag and services and the U2F/CTAP proxy (the same options work when installing a template or StandaloneVM, for that qube):

```
qubes-guix-create --appvm guix-tmpl -n sys-firewall work            # 2000 MiB, balancing up to 6000
qubes-guix-create --appvm guix-tmpl --test work 4000 8000           # then test it with qubes-guix-test
qubes-guix-create --appvm guix-tmpl --split-ssh --split-gpg --ctap --test work
```

### PVH

A Guix qube can boot in PVH instead of HVM: no emulated PC, so no QEMU and no stub domain for it (Qubes' default for its own qubes, for that reason), and faster boots, also with memory balancing (HVM's populate-on-demand makes those slow). dom0 boots it with `pvgrub2-pvh`, a GRUB that runs in the qube and boots the qube's own kernel and initrd from its own disk, so reconfigures and rollbacks work as before, and dom0 reads nothing from the qube. It needs dom0's `grub2-xen-pvh` package (`sudo qubes-dom0-update grub2-xen-pvh` if `/var/lib/qubes/vm-kernels/pvgrub2-pvh` is missing).

- **The guest** is ready by default: `qubes-operating-system` puts the system console on the Xen console, `hvc0` (`console=tty0 console=hvc0`; the getty there serves `xl console` and `qvm-console-dispvm`), and GRUB in text mode, which pvgrub2-pvh needs. Under HVM both still work. `#:pvh? #f` leaves both out. Guix's kernel already has PVH and the Xen frontends built in.
- **New qubes are PVH:** `qubes-guix-create --unattended …` installs (the installer boots in HVM) and switches the qube to PVH before its first start; if it doesn't boot in PVH (a system from an older ISO's channel), it's started in HVM instead. `--hvm` keeps it HVM. Without `pvgrub2-pvh` in dom0 it stays HVM, with a note. `--appvm` makes a PVH AppVM when its template is PVH (`--pvh`/`--hvm` to choose), and `qubes-guix-test`'s throwaway AppVM follows its template too.
- **Measured** (time to the agent): PVH 18 s with memory balancing (1000/4000 MiB); HVM 24 s without (8000/8000), 83 s with (8000/32542).
- **An existing qube:** reconfigure it with this channel (for the console and GRUB), shut it down, then in dom0 `qvm-prefs NAME virt_mode pvh; qvm-prefs NAME kernel pvgrub2-pvh`. Back: `virt_mode hvm`, `kernel ''`.
- **The boot** shows in `/var/log/xen/console/guest-NAME.log`: GRUB, the kernel, the initrd, Shepherd. There's no console window.

By hand, memory balancing is `qvm-prefs NAME maxmem MiB` (above `memory`), and nothing else: Qubes runs the `meminfo-writer` service by `maxmem`, and setting that service (`qvm-service NAME meminfo-writer on`) resets `maxmem` to 0, unticking "Include in memory balancing". **`memory` and `maxmem` take effect at the next start:** a running qube keeps the ceiling it booted with (`static-max` in xenstore), so restart it after changing them.

Keep the template's netvm until the updates proxy works. dom0 normally enables `updates-proxy-setup` for templates; if not, run `qvm-service guix-tmpl updates-proxy-setup on`. Start the template and check `herd status qubes-updates-proxy` in it. guix-daemon should then have the proxy in its environment: `sudo cat /proc/$(pgrep -o guix-daemon)/environ | tr '\0' '\n' | grep proxy`. Only then, if you want the template offline, run `qvm-prefs guix-tmpl netvm ''`. Substitutes then come through the proxy. `guix pull` fetches git in your own process, not through the daemon, so offline it needs `http_proxy` and `https_proxy` set to `http://127.0.0.1:8082` (tested: libgit2 honours them). `qubes-guix-update` does that for you (see [Updating](updating.md)), and so does `pguix`: `pguix pull`, `pguix time-machine …` and so on run `guix` with the proxy set whenever the qube has `updates-proxy-setup`, and run plain `guix` otherwise. Commands that go through guix-daemon, such as `guix install`, `guix shell` and `guix build`, need nothing: the daemon already uses the proxy.

`#:template? #t` (in `qubes-operating-system`, or the `template?` field of `qubes-guest-configuration`) adds:
- `qubes-rwdev`: formats a blank private volume, seeds `/rw/home`, then `/rw` and the `/home` bind mount before `user-homes` runs;
- `qubes-volatile-swap`: 1 GiB of swap on the volatile volume, made at every boot;
- `qubes-hostname`: the host name from the qube's name, since AppVMs share the template's `config.scm`;
- `qubes-updates-proxy`: when dom0 enables `updates-proxy-setup` (templates), `127.0.0.1:8082` is forwarded over `qubes.UpdatesProxy` and guix-daemon uses it for substitutes. AppVMs keep their direct network. For `guix pull` without a netvm, set `http_proxy` and `https_proxy` to `http://127.0.0.1:8082`.
