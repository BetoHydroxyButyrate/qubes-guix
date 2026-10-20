# The full setup: the ISO and your own substitute server

[← README](../README.md) · the other ways in: [the stock Guix ISO](install-stock-iso.md), [the qubes-guix ISO](install-qubes-iso.md)

[guix-subs](https://github.com/BetoHydroxyButyrate/guix-subs) is a Guix System VM (on Proxmox, for example) that builds Guix, this channel and any others you use, at one set of commits, and serves the results as substitutes. It publishes those commits too (`/channel-commits`). An ISO built from it, and every qube installed from that ISO, are locked to the same commits: installs and updates fetch from your LAN instead of building anything, or downloading it from the internet.

![The installer's monitor during an unattended install: 2.2 GiB received from the substitute server on the LAN, a few MiB from everything else](install-traffic.png)

That is the installer's monitor (tty1) near the end of an unattended StandaloneVM install, from an ISO built with `--server`: 2.2 GiB came from guix-subs on the LAN (192.168.3.113), and under 4 MiB from everywhere else. `10.139.1.1` is the Qubes DNS.

In short:

1. Set up [guix-subs](https://github.com/BetoHydroxyButyrate/guix-subs) (its README). The server must build this channel at a commit with ISO support.
2. In the checkout you build the ISO from, put the server's `url` and `key` in `dom0/qubes-guix-substitutes`. Its key must be authorized on the build machine.
3. Build the ISO on the server, at its own commits: `iso/qubes-guix-iso --server https://guix-subs.example` there, or `iso/qubes-guix-iso-remote` from your working checkout ([building it](install-qubes-iso.md#the-iso)).
4. In dom0: `./qubes-guix-create --unattended guix QUBE:/path/to/qubes-guix-installer.iso` (add `--template` for a template). dom0 needs no substitutes file: the ISO carries it.
5. Later, `qubes-guix-update --guix-commit server` in a qube (or its template) moves it to the server's latest build.

## Building the ISO from your server

```
qubes-guix/iso/qubes-guix-iso --server https://guix-subs.example   # at the commits your server last built
```

`--server URL` builds every channel at the commits the server last built (its `/channel-commits`, as [guix-subs](https://github.com/BetoHydroxyButyrate/guix-subs) publishes) and fetches from it first. Nearly everything then comes from your server, and so does the rest of an install, such as Xfce. The substitute servers come from a file like dom0's, `--substitutes FILE`, by default the checkout's `dom0/qubes-guix-substitutes`: all its `url`s are tried before the default servers (their keys must already be authorized on the build machine). Without `--server`, the file's first `url` is the server; `--no-server` builds at the branch head instead. An install locked to the same server ([below](#installing-with-your-server)) then uses the ISO's Guix as it is. The ISO also carries the substitutes file: its own guix-daemon uses those servers, and an install that gets no substitutes from dom0 uses the ISO's, records them in `config.scm`, and, unless told otherwise, locks to the ISO's own channel commits. So an ISO built from your server installs and updates from it with nothing extra in dom0. The server must be up to date: one that last built qubes-guix from before the ISO support can't build an ISO.

## Installing with your server

With the stock ISO, or a server the ISO doesn't carry, put `url` and `key` lines in `dom0/qubes-guix-substitutes`, copied into dom0 (the current directory, or next to `qubes-guix-create`), or pass a file with `--substitutes FILE`. The template file has everything commented out. A server can be your own `guix publish`, or a cache of bordeaux and ci. The install tries these servers before the default ones, with its keys authorized in the installer. They also go into `config.scm` as `#:extra-substitute-urls` and `#:extra-authorized-keys`, so updates use them too. With a server, `--unattended` locks the qube to it (`--guix-commit server`) unless you say otherwise: `--guix-commit C` for a Guix commit, or `--guix-commit head` to follow the head. `--guix-commit server` needs a server that publishes its commits ([guix-subs](https://github.com/BetoHydroxyButyrate/guix-subs) does): every channel the qube shares with the server, qubes and nonguix included, is then locked at the server's commit (`/channel-commits`, recorded as `#:channel-commits`), so nearly everything comes from your server. A server that publishes only `/guix-commit` locks Guix alone. Later, `qubes-guix-update --guix-commit server` moves the qube to the server's latest build. The installer's netvm must reach the server, and so must a template's UpdateVM.

## Keeping qubes in step with the server

A qube locked to the server stays at its commits until you move it: see [locking to a substitute server](updating.md#following-the-head-or-locking-guix-at-a-commit).
