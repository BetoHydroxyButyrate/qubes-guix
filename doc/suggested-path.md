# The suggested path: from Guix's own ISO to the qubes-guix ISO

[← README](../README.md)

You don't need a Guix machine to start, and you'll want the qubes-guix ISO for every qube after the first: installs from it need nothing done by hand, and its Qubes agents are already built. So:

1. **The dom0 scripts.** Clone this repository in a qube, then copy its `dom0/` into dom0 and run `qubes-guix-refresh` ([how](install-stock-iso.md#creating-the-qube-dom0)). It names them `qg-create`, `qg-get-iso`, `qg-build-iso`, `qg-config`, `qg-test`. Then `qg-config`, for what new qubes get (your substitute server, if you have one; the desktop; packages).
2. **Guix's own ISO, checked.**
   ```
   qg-get-iso untrusted
   ```
   downloads it into `untrusted` (any qube with network will do) and checks its OpenPGP signature against Guix's release keys, pinned by fingerprint in the script: a valid signature from another key is refused too. The check runs in that qube, which also keeps the ISO.
3. **A first Guix template, from it.**
   ```
   qg-create --template --unattended guix-tmpl untrusted:/home/user/Downloads/guix-system-install-1.5.0.x86_64-linux.iso
   ```
   One command, with one thing by hand: the GRUB edit, which it explains before the qube starts. This install builds the Qubes agents from source (without a substitute server that has them), so it's the slow one; [details](install-stock-iso.md).
4. **The qubes-guix ISO, built in a qube made from that template.**
   ```
   qg-build-iso --template guix-tmpl
   ```
   makes `qg-iso-builder`, a StandaloneVM (its Guix store kept, so later builds are quicker), and builds the ISO there with your settings. The ISO stays in it; [details](install-qubes-iso.md#building-it-from-dom0).
5. **Every qube after that, from the qubes-guix ISO,** with nothing by hand:
   ```
   qg-create --template --unattended guix-work-tmpl qg-iso-builder:/home/user/qubes-guix-installer.iso
   qg-create --appvm guix-work-tmpl work
   qg-test work
   ```
   StandaloneVMs without `--template`. They boot in PVH.
6. **Later:** `qg-build-iso` again for a newer ISO (the builder reuses its store), and `qubes-guix-update -r` in each template (or StandaloneVM) to update it. With many qubes, your own substitute server makes all of this come from your LAN: [the full setup](full-setup.md).

The template from step 3 can stay as the builder's template, or go once the builder exists: the builder is a StandaloneVM, with its own copy of the system.
