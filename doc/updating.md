# Updating

[← README](../README.md)

There are two cases:
- **Updating the system:** run `qubes-guix-update -r`. It runs as root, through `sudo` if you aren't. It does root's `guix pull`, then `guix system reconfigure /etc/config.scm` with the Guix it just pulled. In a template with `updates-proxy-setup`, both go through the Qubes updates proxy, so the template needs no netvm. Without `-r` it only pulls. Other arguments go to `guix pull`, and `QUBES_GUIX_CONFIG` names another config file. `--guix-commit C` and `--head` move the Guix lock (below). Root does the update, as in other Qubes templates. Its pulled Guix and its checkout, in `/root`, are the only ones, and the reconfigure builds the system's `guix` from them. Users don't need to pull: their `guix` is the system's, at the level the template was updated to. A user's own `guix pull` (`~/.config/guix/current`) would override that for them, and `qubes-guix-update` points it out. Remove the link to go back to the system's.
- **Working on the channel itself:** use `sudo guix system reconfigure -L /path/to/checkout /etc/config.scm`. `-L` puts the checkout ahead of the pulled channel, so you can test before committing.

## Following the head, or locking Guix at a commit

There are no substitutes for this channel's packages, so they're built from source on your machine. They are built against whatever Guix provides (gcc, glibc, python, Xorg…). Each pull that moves the Guix channel changes those inputs, and the next reconfigure rebuilds every Qubes package, which takes a long time.

So a qube, typically a template, does one of two things:
- **Follows the head** (the default): every `qubes-guix-update -r` pulls current Guix master and rebuilds. You get fixes as they land, and occasionally breakage.
- **Is locked at a commit:** `#:guix-commit "C"` on its `qubes-operating-system` form pins Guix at C in `/etc/guix/channels.scm`. Every `guix pull` and `qubes-guix-update` stays there, so reconfigures only rebuild when this channel changes. Choosing C, and testing it, is up to whoever builds the template. A commit you've already run, from `guix describe`, is a good start.
- **Is locked to a substitute server:** `#:channel-commits '((guix . "C1") (qubes . "C2") …)` pins each channel it names, the way `#:guix-commit` pins Guix. `qubes-guix-update --guix-commit server` writes it from the server's `/channel-commits`. Then the Qubes packages, and those of other channels, are the server's builds too, not built here. (`#:guix-commit`, if set, wins for Guix.)

Moving between them:

```
qubes-guix-update --guix-commit C   # lock at C (or move the lock): edits config.scm, pulls C, reconfigures
qubes-guix-update --guix-commit server  # lock every channel at your server's last build
qubes-guix-update --head            # unlock: every channel back to following the head
qubes-guix-update --channel nonguix=server   # move ONE channel: to the server's last build of it
qubes-guix-update --channel qubes=C          # ... to commit C (a full hash)
qubes-guix-update --channel qubes=head       # ... or unlock it: it follows its branch
```

`--channel NAME=…` (repeatable) moves that channel's lock alone, in `#:channel-commits` (and `#:guix-commit` for `guix=…`, if the config has one), pulls and reconfigures; the other channels stay where they're locked. Mind the pairings: the server built its channels together, so moving one away from the others can mean building here what it never built, typically nonguix's packages against an older or newer Guix than it had. `#:follow-head '(NAME)` is the lasting version of `NAME=head`: that channel follows its branch even through a later `--guix-commit server`.

**Working on a channel while locked:** `#:follow-head '(qubes)` makes the channels it names follow their branch even though `#:channel-commits` pins them (`#t`: all of them). Set it and run `qubes-guix-update -r`: that pull and the reconfigure already use the head. The lock stays recorded; remove the name, and the next `qubes-guix-update -r` goes back to it.

`qubes-guix-create --unattended --guix-commit C` records the lock at install time. The install itself always builds with the installer's own Guix, which is fast because nearly everything comes from substitutes. Then `--unattended` starts the qube and runs `qubes-guix-update -r` once, which takes it to the head or to C. A template is then shut down, ready. `--no-update` skips that step.

With `#:guix-commit` alone, the qubes channel isn't locked: it follows its branch. For a one-off build at another commit, without moving the lock, there's `guix time-machine --commit=C -- …`.

**AppVMs follow their template, with nothing to configure.** An AppVM's root, including `/gnu/store` and `/var/guix`, comes from the template at every boot, and its `guix` is the template's system Guix. Its home is its own: on first start it's made fresh, from the skeleton files, not copied from the template's `/home`, as in upstream Qubes. So a template's caches and dotfiles stay in the template. An updated template means an updated Guix in the AppVM at its next boot. `guix pull` in an AppVM gives a newer one until shutdown, like `apt` in a Debian AppVM. Its first pull is slow, because it builds its own `~/.cache/guix` from scratch.

## Firefox ESR (nonguix)

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
