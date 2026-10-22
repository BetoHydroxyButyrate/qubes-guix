# Features: U2F/FIDO2, split-gpg2, split-ssh, USB

[← README](../README.md)

## U2F / FIDO2 (CTAP proxy)

- **sys-usb:** its template needs the `qubes-ctap` package. Stock Fedora and Debian templates usually have it.
- **dom0:** run `qvm-service guix qubes-ctap-proxy on` and enable guix in **Qubes Global Config → USB Devices → U2F Proxy**. Global Config only allows the U2F (`u2f.*`) calls. For FIDO2 (passkeys, PINs), also add to `/etc/qubes/policy.d/30-user.policy`:
  ```
  ctap.GetInfo    *  guix  sys-usb  allow
  ctap.ClientPin  *  guix  sys-usb  allow
  ```
- **guix:** reboot after the first install. A reconfigure doesn't make the running udev reload its rules, so the virtual key's hidraw node would keep the wrong group.

## split-gpg2

- **Vault qube** (e.g. `gpg-admin`): install `split-gpg2` in its template. It coexists with split-gpg v1. The key needs **signing subkeys**: by default split-gpg2 exposes subkeys only, never the primary key.
- **dom0:**
  ```
  # /etc/qubes/policy.d/30-user.policy
  qubes.Gpg2  *  guix  @default  allow target=gpg-admin
  ```
  ```
  qvm-service guix split-gpg2-client on
  ```
  With several identities, a vault per identity (`gpg-work`, `gpg-personal`, …), and a tag per identity on the qubes that should have it, one line each:
  ```
  qubes.Gpg2  *  @tag:gpg-work      @default  allow target=gpg-work
  qubes.Gpg2  *  @tag:gpg-personal  @default  allow target=gpg-personal
  ```
  ```
  qvm-tags guix add gpg-work
  ```
  A qube asks one vault: the first matching line wins, so give each qube one of these tags.
- **guix:**
  ```
  # never start an empty local gpg-agent (keyboxd must still autostart, so not `no-autostart`)
  echo 'agent-program /run/current-system/profile/libexec/split-gpg2/gpg-agent-placeholder' >> ~/.gnupg/gpg.conf
  gpg --import pubkey.asc                    # the PUBLIC key (qvm-copy it from the vault)
  gpg -K                                     # sec# + ssb lines = working
  ```
  A warning that the agent "is older than us" is harmless. It just means the vault's GnuPG is older than Guix's.

## Split SSH

The SSH keys stay in a vault qube; Guix qubes use them through its `ssh-agent`, over qrexec (`qubes.SshAgent`). Every Guix qube with the GUI has the client: its session's `SSH_AUTH_SOCK` is `~/.ssh/qubes-agent.sock`, forwarded to whichever vault dom0's policy names. So enrolling a qube is only a policy line.

- **Vault qube** (e.g. `ssh-vault`, no netvm): its agent on a fixed socket, with the keys added; `-c` asks for confirmation at each use. For example, in its `~/.bashrc`, so opening a terminal there once after boot starts the agent and adds the key (or put it in an autostart entry):
  ```sh
  export SSH_AUTH_SOCK=$HOME/.ssh/agent.sock
  ssh-add -l >/dev/null 2>&1; [ $? -eq 2 ] && { rm -f "$SSH_AUTH_SOCK"; ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null; }
  ssh-add -l >/dev/null 2>&1 || ssh-add -c ~/.ssh/id_ed25519
  ```
  And the service, in the vault's template (or `/usr/local/etc/qubes-rpc/` in the vault itself):
  ```sh
  # /etc/qubes-rpc/qubes.SshAgent
  #!/bin/sh
  notify-send "SSH agent used by $QREXEC_REMOTE_DOMAIN" 2>/dev/null
  exec socat - "UNIX-CONNECT:$HOME/.ssh/agent.sock"
  ```
  (`chmod +x`; `socat` must be installed.)
- **dom0:** which qubes may use it. Tag the Guix AppVMs (`qvm-tags NAME add split-ssh`), or allow any qube and answer each prompt:
  ```
  # /etc/qubes/policy.d/30-user-split-ssh.policy
  qubes.SshAgent  *  @tag:split-ssh  @default  allow target=ssh-vault
  qubes.SshAgent  *  @anyvm          @default  ask default_target=ssh-vault
  ```
- **Guix qube:** nothing. `ssh-add -l` lists the vault's keys (after a prompt, with `ask`). If the session already has `SSH_AUTH_SOCK` (another agent), that one is used instead.

## USB devices (qvm-usb)

A USB device in sys-usb can be attached to a Guix qube as to any other: the devices widget, or in dom0 `qvm-usb attach QUBE sys-usb:BUSID` (`qvm-usb` lists them). The device then appears in the qube as a local USB device. It goes over qrexec (`qubes.USBAttach` here, `qubes.USB` in sys-usb) into the kernel's USB/IP virtual host controller, `vhci-hcd`, which is loaded on the first attach.

- **dom0, sys-usb:** nothing beyond the usual Qubes USB setup. Each attach allows itself in dom0's policy for that one call.
- **Guix qube:** nothing; `qubes-usb-proxy` is in every qube (`(usb-proxy #f)` leaves it out). The kernel must have `vhci-hcd`: `qubes-guix-test` checks it.
- **Detach:** the widget, or `qvm-usb detach QUBE sys-usb:BUSID`.

Only the qube side is packaged: a Guix qube can receive USB devices, not be the USB backend (sys-usb).

Tested with a YubiKey's smart card (PIV, `yubico-piv-tool -a status`). Smart cards need `pcscd`, which isn't part of qubes-guix, and Guix's pcsc-lite asks polkit whether a user may use the reader. polkit doesn't know pcsc-lite's actions unless they're registered, so every client is refused, root included ("Action org.debian.pcsc-lite.access_pcsc is not registered"). In `config.scm`:

```scheme
(use-service-modules dbus security-token)
(use-package-modules security-token)       ; pcsc-lite

(define pcsc-polkit-rule                   ; members of "users" may use readers and cards
  (file-union "pcsc-polkit-rule"
    `(("share/polkit-1/rules.d/50-pcsc.rules"
       ,(plain-file "50-pcsc.rules" "\
polkit.addRule(function(action, subject) {
  if ((action.id == \"org.debian.pcsc-lite.access_pcsc\" ||
       action.id == \"org.debian.pcsc-lite.access_card\") &&
      subject.isInGroup(\"users\")) {
    return polkit.Result.YES;
  }
});
")))))

;; in (services ...):
(service pcscd-service-type)
(simple-service 'pcsc-polkit polkit-service-type
                (list pcsc-lite pcsc-polkit-rule))
```

After the reconfigure, polkit (started on demand by D-Bus, not a Shepherd service) must reread its actions: reboot, or `sudo pkill polkitd; sudo herd restart pcscd`. While a key is attached to a qube, sys-usb doesn't have it: U2F/FIDO2 through the CTAP proxy needs it detached again.
