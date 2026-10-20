#!/usr/bin/env bash
# One-time setup of a DEDICATED bare-metal Qubes OS 4.3 CI machine.
#
# Creates a "ci-ctl" qube that keeps a reverse SSH tunnel open to the CI
# runner, and a qrexec service that lets ci-ctl run commands in dom0. dom0
# itself gets no network. Still: ci-ctl ends up with full control of dom0,
# so only do this on a machine that exists to run tests.
#
# Usage (as root in dom0):
#   bash qubes-ci-setup.sh <runner-host> <tunnel-user> <runner-ci-pubkey-file> [tunnel-private-key]
#   e.g. bash qubes-ci-setup.sh runner.lan qubesci-tunnel ./qubes_ci_ed25519.pub
#
# <runner-ci-pubkey-file> is the key the runner uses to SSH into ci-ctl.
# [tunnel-private-key] is the key ci-ctl dials the runner with; if omitted a
# new one is made. At the end this prints the line that goes on the runner.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root (sudo -i)"; exit 1; }
[ $# -ge 3 ] || { sed -n '9,10p' "$0"; exit 1; }
RUNNER_HOST=$1
TUNNEL_USER=$2
PUBKEY_FILE=$3
TUNNEL_KEY=${4:-}
TUNNEL_PORT=${TUNNEL_PORT:-2222}
CTL=ci-ctl
# ci-ctl is made from a Debian template: Fedora templates run SELinux
# enforcing, which stops a systemd service from running /usr/bin/ssh.
# CTL_TEMPLATE overrides; default: the newest installed debian-* template.
CTL_TEMPLATE=${CTL_TEMPLATE:-$(qvm-ls --raw-data --fields NAME,CLASS |
    awk -F'|' '$2 == "TemplateVM" && $1 ~ /^debian-[0-9]+/ {print $1}' | sort -V | tail -n1)}
[ -n "$CTL_TEMPLATE" ] || { echo "no Debian template installed: qvm-template install debian-13-xfce (or set CTL_TEMPLATE)"; exit 1; }
CI_USER=$(getent group qubes | cut -d: -f4 | cut -d, -f1)
[ -n "$CI_USER" ] || { echo "cannot find the Qubes desktop user"; exit 1; }

# --- dom0: qrexec service ci.Dom0Shell, callable only from ci-ctl
cat >/etc/qubes-rpc/ci.Dom0Shell <<EOF
#!/bin/bash
# Runs the script on stdin in dom0 as $CI_USER, with the desktop's X display.
export HOME=/home/$CI_USER DISPLAY=:0 XAUTHORITY=/home/$CI_USER/.Xauthority
cd "\$HOME"
if [ "\$(id -u)" = 0 ]; then exec runuser -u $CI_USER -- bash -s; else exec bash -s; fi
EOF
chmod 755 /etc/qubes-rpc/ci.Dom0Shell
cat >/etc/qubes/policy.d/30-qubes-ci.policy <<EOF
ci.Dom0Shell  *  $CTL  dom0  allow
EOF

# --- dom0: packages, autologin for GUI tests, no locker / cron interference
qubes-dom0-update -y python3-nose2
mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/50-qubes-ci-autologin.conf <<EOF
[Seat:*]
autologin-user=$CI_USER
autologin-user-timeout=0
EOF
groupadd -rf autologin
gpasswd -a "$CI_USER" autologin >/dev/null
systemctl disable --now crond 2>/dev/null || true
sudo -u "$CI_USER" xfconf-query -c xfce4-screensaver -p /saver/enabled -n -t bool -s false 2>/dev/null || true
sudo -u "$CI_USER" xfconf-query -c xfce4-screensaver -p /lock/enabled -n -t bool -s false 2>/dev/null || true
# Don't let the machine sleep between runs
sudo -u "$CI_USER" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-ac -n -t uint -s 0 2>/dev/null || true

# --- ci-ctl: a standalone qube (so installed packages persist), autostarted
if ! qvm-check -q "$CTL" 2>/dev/null; then
    qvm-create --class StandaloneVM --template "$CTL_TEMPLATE" --label black "$CTL"
fi
qvm-prefs "$CTL" autostart True
qvm-prefs "$CTL" netvm "$(qubes-prefs default_netvm)"
qvm-start --skip-if-running "$CTL"

as_root() { qvm-run -q -p -u root "$CTL" "$1"; }
as_root 'if command -v dnf >/dev/null; then dnf -y install openssh-server;
         else apt-get update && apt-get -y install openssh-server; fi'
as_root "install -d -m 700 -o user -g user /home/user/.ssh"
as_root "cat > /home/user/.ssh/authorized_keys && chown user:user /home/user/.ssh/authorized_keys && chmod 600 /home/user/.ssh/authorized_keys" <"$PUBKEY_FILE"
as_root "cat > /etc/ssh/sshd_config.d/50-qubes-ci.conf" <<'EOF'
ListenAddress 127.0.0.1
PasswordAuthentication no
PermitRootLogin no
AllowUsers user
EOF
as_root "mkdir -p -m 700 /root/.ssh"
if [ -n "$TUNNEL_KEY" ]; then
    as_root "umask 077; cat > /root/.ssh/qubes_ci_tunnel" <"$TUNNEL_KEY"
    as_root "ssh-keygen -y -f /root/.ssh/qubes_ci_tunnel > /root/.ssh/qubes_ci_tunnel.pub"
else
    as_root "test -f /root/.ssh/qubes_ci_tunnel || ssh-keygen -q -t ed25519 -N '' -C ci-ctl-tunnel -f /root/.ssh/qubes_ci_tunnel"
fi
as_root "cat > /etc/systemd/system/qubes-ci-tunnel.service" <<EOF
[Unit]
Description=CI: reverse SSH tunnel to the runner
After=network-online.target sshd.service ssh.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/ssh -N -i /root/.ssh/qubes_ci_tunnel \\
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
    -o StrictHostKeyChecking=accept-new \\
    -R 127.0.0.1:$TUNNEL_PORT:127.0.0.1:22 $TUNNEL_USER@$RUNNER_HOST
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
as_root "systemctl daemon-reload; systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh; systemctl enable --now qubes-ci-tunnel"

echo
echo "Done. On the runner, add this line to ~$TUNNEL_USER/.ssh/authorized_keys:"
echo
echo "restrict,port-forwarding,permitlisten=\"127.0.0.1:$TUNNEL_PORT\" $(as_root 'cat /root/.ssh/qubes_ci_tunnel.pub')"
echo
echo "Then reboot dom0 and check from the runner:  ssh -p $TUNNEL_PORT user@127.0.0.1 hostname"
