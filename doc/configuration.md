# Configuring the system

[← README](../README.md)

## Using the channel

Add it to `~/.config/guix/channels.scm`:

```scheme
(cons* (channel
        (name 'qubes)
        (url "https://github.com/BetoHydroxyButyrate/qubes-guix")
        (branch "main")
        (introduction
         (make-channel-introduction
          "1101f87885074cb3ac8bddc314f274cfeba84e76"
          (openpgp-fingerprint            ; the signing SUBKEY (see .guix-authorizations)
           "9765 1FBD E504 F2D1 3DA9  88EB C0E8 4747 0C0B 2F22"))))
       %default-channels)
```

Then `guix pull`. Once the system is built with `qubes-operating-system` (below), you can skip this: the channel is also in the system-wide `/etc/guix/channels.scm`, which `guix pull` uses when you have no `~/.config/guix/channels.scm`. Commits are signed. Guix verifies them against `.guix-authorizations` and the key on the `keyring` branch.

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

- **Passwordless `sudo` for the `qubes` group,** unless you pass `#:passwordless-sudo? #f`. This is the Qubes convention (upstream's `qubes-core-agent-passwordless-root`): the qube is the security boundary.
- **The qubes channel in `/etc/guix/channels.scm`** (Guix's default channels plus this one), unless you pass `#:system-channels? #f`. `guix pull` uses it for root and for every user without a `~/.config/guix/channels.scm`. `#:channel-branch "BRANCH"` records a branch other than `main`. If the `guix-service-type` configuration already lists channels, the qubes one is added to them, unless one named `qubes` is already there.
- **The system's own `guix` includes the qubes channel,** unless you pass `#:system-guix? #f`. It's built from the channels of the Guix doing the build (`guix-for-channels`), so `guix describe` lists qubes from the first boot, and `sudo guix system reconfigure` works before any user `guix pull`. Building it makes root fetch the channels. In a template without a netvm, reconfigure with `qubes-guix-update -r`, which passes the updates proxy through `sudo`; a plain `sudo guix system reconfigure` can't reach the channels there.
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
          (split-gpg2 qubes-split-gpg2-client)  ; #f: no split-gpg2 client
          (split-ssh qubes-split-ssh-client)    ; #f: no split-ssh client
          (usb-proxy qubes-usb-proxy)           ; #f: no USB devices from sys-usb
          (default-menu-items '("xfce4-terminal.desktop" "thunar.desktop"))
          (features-request? #t)))      ; #f: don't advertise features to
                                       ; dom0 (the installer ISO)
                                       ; what dom0 shows in the Qubes menu by
                                       ; default (only the installed ones)
```

Package fields (`qrexec`, `qubesdb`, `core-agent`, `gui-agent`, `ctap`) can be overridden too.

## Extra packages and channels

These dom0 files are read at install time (`--unattended`, `--finish-install` and `--bootstrap`), by either ISO. Each comes from the current directory, else `~/.config/qubes-guix/`, else the repository's sample next to the scripts (where `qubes-guix-refresh` puts them; it never touches `~/.config`). `qg-config` writes the `~/.config/qubes-guix/` ones by question and answer ([how](install-stock-iso.md#creating-the-qube-dom0)).

**Desktop:** none by default: the system has `xterm` and `%desktop-services`, and each application's window is drawn in dom0's desktop. `qg-create --unattended --desktop xfce` (or `xfce` in `~/.config/qubes-guix/qubes-guix-desktop`, as `qg-config` writes it) installs the Xfce desktop as before. Xfce isn't on the qubes-guix ISO, so that install downloads it.

**Extra packages:** list them in `dom0/qubes-guix-packages`, one or more per line, with `#` for comments. Copy it to `~/.config/qubes-guix/` in dom0 and edit it there, or pass another file with `--packages FILE`. Without one you get `git`. They go into the qube's `config.scm` as `#:extra-packages '("git" …)` in the `(qubes-operating-system …)` form. A name Guix doesn't have is skipped with a warning, never an error, both at install time and at every later reconfigure. To change the set, edit that list in `/etc/config.scm`, then run `qubes-guix-update -r`. `--finish-install` and `--bootstrap` read the same file.

**Extra channels:** put `(channel …)` forms in `dom0/qubes-guix-channels`, copied to `~/.config/qubes-guix/` in dom0, or pass a file with `--channels FILE`. The template file has everything commented out. They go into `config.scm` as `#:extra-channels`, so pulls and the system's own `guix` include them. `--unattended` and `--finish-install` also build with them, so the packages file can name their packages, for example `firefox-esr` from nonguix. Take each channel's introduction from its own documentation. A channel with its own substitute server also needs `#:extra-substitute-urls` and `#:extra-authorized-keys` in `config.scm`; otherwise its packages build from source. To add a channel to an existing qube, add it to `#:extra-channels` in `/etc/config.scm` and run `qubes-guix-update -r` twice. The first run records the channel in `/etc/guix/channels.scm`. The second pulls it and builds its packages.
