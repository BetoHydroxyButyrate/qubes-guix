#!/bin/bash
# Writes a kickstart file for an unattended Qubes OS 4.3 install of the CI
# machine, with the CI setup (ci/dom0/qubes-ci-setup.sh) run automatically on
# first boot.
#
# Put the result as ks.cfg on a partition labelled QUBES_OEM (a second USB
# stick is easiest); the Qubes installer then offers an OEM install entry
# that uses it. See ci/README.md.
#
# Usage: make-oem-ks.sh <out.ks> <runner-host> <tunnel-user> <runner-ci-pubkey-file>
# Env:   DISK=nvme0n1  CI_USER=user  TIMEZONE=Australia/Brisbane  KEYMAP=us
#        CI_PASSWORD (prompted for if unset; dom0 login password)
set -euo pipefail

[ $# -eq 4 ] || { sed -n '11,13p' "$0"; exit 1; }
OUT=$1 RUNNER_HOST=$2 TUNNEL_USER=$3 PUBKEY_FILE=$4
DISK=${DISK:-nvme0n1}
CI_USER=${CI_USER:-user}
TIMEZONE=${TIMEZONE:-Australia/Brisbane}
KEYMAP=${KEYMAP:-us}
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -z "${CI_PASSWORD:-}" ]; then
    read -rsp "dom0 password for $CI_USER: " CI_PASSWORD; echo
fi
PWHASH=$(openssl passwd -6 "$CI_PASSWORD")
SETUP_B64=$(base64 -w0 "$HERE/../dom0/qubes-ci-setup.sh")
PUBKEY_B64=$(base64 -w0 "$PUBKEY_FILE")
# The tunnel key is kept next to the generated ks, so every reinstall reuses
# it and the runner's authorized_keys line stays valid.
TUNNEL_KEY=$(dirname "$OUT")/qubes_ci_tunnel
[ -f "$TUNNEL_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C ci-ctl-tunnel -f "$TUNNEL_KEY"
TUNNEL_KEY_B64=$(base64 -w0 "$TUNNEL_KEY")

cat >"$OUT" <<EOF
# Qubes OS 4.3 CI machine - unattended install. WIPES /dev/$DISK.
graphical
zerombr
ignoredisk --only-use=$DISK
clearpart --all --initlabel --drives=$DISK
# Qubes' installer defaults autopart to encrypted (encrypted = True in its
# anaconda profile) and a bare 'autopart' doesn't turn that off. Explicit
# partitions are unencrypted unless they say --encrypted, so lay out what
# autopart would: dom0 root on the root-pool thin pool, swap, and the rest of
# the VG left free for the vm-pool that initial setup creates.
part /boot/efi --fstype=efi --size=600 --ondisk=$DISK
part /boot --fstype=ext4 --size=1024 --ondisk=$DISK
part pv.01 --size=1 --grow --ondisk=$DISK
volgroup qubes_dom0 pv.01
logvol none --vgname=qubes_dom0 --thinpool --name=root-pool --size=20480
logvol / --vgname=qubes_dom0 --thin --poolname=root-pool --name=root --fstype=ext4 --size=19456
logvol swap --vgname=qubes_dom0 --name=swap --fstype=swap --size=4096
bootloader --location=mbr --boot-drive=$DISK
keyboard --vckeymap=$KEYMAP --xlayouts='$KEYMAP'
lang en_US.UTF-8
timezone $TIMEZONE --utc
network --hostname=dom0
rootpw --lock
user --name=$CI_USER --groups=wheel,qubes --password='$PWHASH' --iscrypted
xconfig --startxonboot
reboot

%packages
@^qubes-xfce
%end

%addon org_qubes_os_initial_setup
system_vms true
default_vms true
disp_firewallvm_and_usbvm true
usbvm true
allow_usb_keyboard true
allow_usb_mouse true
whonix_vms false
%end

%post --erroronfail
mkdir -p /root/qubes-ci /var/lib/qubes-ci
echo '$SETUP_B64' | base64 -d > /root/qubes-ci/qubes-ci-setup.sh
echo '$PUBKEY_B64' | base64 -d > /root/qubes-ci/runner-ci.pub
(umask 077; echo '$TUNNEL_KEY_B64' | base64 -d > /root/qubes-ci/tunnel-key)
cat > /root/qubes-ci/firstboot <<'FB'
#!/bin/bash
# Waits for initial setup to have created the default qubes, then runs the CI setup.
for _ in \$(seq 180); do
    qvm-check -q --running sys-firewall 2>/dev/null && break
    qvm-check -q sys-firewall 2>/dev/null && qvm-start --skip-if-running sys-firewall
    sleep 10
done
bash /root/qubes-ci/qubes-ci-setup.sh '$RUNNER_HOST' '$TUNNEL_USER' /root/qubes-ci/runner-ci.pub /root/qubes-ci/tunnel-key \\
    > /var/lib/qubes-ci/setup.log 2>&1 && touch /var/lib/qubes-ci/setup-done
FB
chmod +x /root/qubes-ci/firstboot
cat > /etc/systemd/system/qubes-ci-firstboot.service <<'UNIT'
[Unit]
Description=CI: one-time setup after Qubes initial setup
After=initial-setup.service qubesd.service
Wants=qubesd.service
ConditionPathExists=!/var/lib/qubes-ci/setup-done

[Service]
Type=oneshot
ExecStart=/root/qubes-ci/firstboot
TimeoutStartSec=3h

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable qubes-ci-firstboot.service
%end
EOF
chmod 600 "$OUT"
echo "wrote $OUT. It contains the password hash and the tunnel private key: keep it off shared storage."
echo
echo "On the runner, ~$TUNNEL_USER/.ssh/authorized_keys needs (once; it survives reinstalls):"
echo "restrict,port-forwarding,permitlisten=\"127.0.0.1:2222\" $(cat "$TUNNEL_KEY.pub")"
