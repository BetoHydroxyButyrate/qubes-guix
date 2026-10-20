#!/usr/bin/env bash
# Makes the Qubes CI machine reinstall itself from the OEM USB stick.
#
# Removes Qubes' bootloader from the internal disk's EFI system partition and
# reboots, so the firmware falls through to the USB stick. Its OEM kickstart
# then wipes the disk and installs a fresh Qubes with the CI setup.
#
# Needs: the USB stick(s) plugged in, and USB after the internal disk in the
# BIOS boot order. Afterwards, someone presses F12 on the first-boot screen
# (see ci/README.md); the CI setup then runs by itself.
#
# Usage: qubes-ci-reinstall.sh --yes-wipe-the-ci-machine
set -euo pipefail

[ "${1:-}" = --yes-wipe-the-ci-machine ] || { sed -n '2,12p' "$0"; exit 1; }
[ -f /etc/qubes-ci/runner.env ] && . /etc/qubes-ci/runner.env
TUNNEL_PORT=${TUNNEL_PORT:-2222}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/qubes_ci_ed25519}

ssh -i "$SSH_KEY" -o BatchMode=yes -o HostKeyAlias=qubes-ci-ctl -p "$TUNNEL_PORT" \
    user@127.0.0.1 "qrexec-client-vm dom0 ci.Dom0Shell" <<'EOF'
set -e
# USB sticks show up in sys-usb, not dom0
if ! { lsblk -no LABEL; qvm-run -q -p sys-usb 'lsblk -no LABEL' 2>/dev/null; } </dev/null | grep -qx QUBES_OEM; then
    echo "no QUBES_OEM stick found: not wiping"; exit 1
fi
for n in $(sudo efibootmgr </dev/null | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\? .*[Qq]ubes.*/\1/p'); do
    sudo efibootmgr -q -b "$n" -B </dev/null
done
sudo rm -rf /boot/efi/EFI/qubes /boot/efi/EFI/BOOT
echo "bootloader removed; rebooting into the installer"
sudo systemctl reboot </dev/null
EOF
echo "The machine is rebooting into the installer. The tunnel comes back once"
echo "first boot has been confirmed and the CI setup has run (~30-60 min)."
