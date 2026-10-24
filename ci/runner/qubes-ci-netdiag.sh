#!/usr/bin/env bash
# Runs on the CI runner, as ci, from a checkout. Measures the data paths a
# CI run uses, to find what holds them to a few MB/s, and writes it all to
# one log (printed too):
#
#   1. runner -> ci-ctl through the tunnel (ssh, as qubes-ci-run.sh's scp),
#      with dom0's xentop sampled meanwhile (CPU of sys-net, sys-firewall,
#      ci-ctl);
#   2. runner -> ci-ctl as plain HTTP over the LAN (no ssh, no tunnel): a
#      file served from the runner, fetched in ci-ctl through sys-firewall
#      and sys-net;
#   3. a nar from the substitute server: fetched on the runner, then in
#      ci-ctl (what installs and updates download);
#   4. ci-ctl's own disk, and sys-net's link and the qubes' memory/vCPUs.
#
# Usage: qubes-ci-netdiag.sh [LOG]   (default: ./netdiag-DATE.log)
# Config: as qubes-ci-run.sh (TUNNEL_PORT, SSH_KEY), build-iso-remote.sh
# (ISO_HOST, ISO_SSH_KEY); /etc/qubes-ci/runner.env.
#   MB      size of each transfer, MiB (500)
#   PORT    the runner's port for test 2 (8099)
set -uo pipefail

[ -f /etc/qubes-ci/runner.env ] && . /etc/qubes-ci/runner.env
HERE=$(cd "$(dirname "$0")" && pwd)
LOG=${1:-./netdiag-$(date +%Y%m%d-%H%M%S).log}
TUNNEL_PORT=${TUNNEL_PORT:-2222}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/qubes_ci_ed25519}
ISO_HOST=${ISO_HOST:-guix-subs}
ISO_SSH_KEY=${ISO_SSH_KEY:-$HOME/.ssh/qubes_ci_ed25519}
MB=${MB:-500}
PORT=${PORT:-8099}
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10
          -o StrictHostKeyChecking=accept-new -o HostKeyAlias=qubes-ci-ctl)
ctl()  { ssh "${SSH_OPTS[@]}" -p "$TUNNEL_PORT" user@127.0.0.1 "$@"; }
dom0() { ctl "qrexec-client-vm dom0 ci.Dom0Shell"; }   # script on stdin
mbs()  { awk -v b="$1" -v s="$2" 'BEGIN { if (s > 0) printf "%.1f MB/s", b / s / 1e6; else print "?" }'; }
now()  { date +%s.%N; }
tmp=$(mktemp -d)
srv=
trap '[ -n "$srv" ] && kill "$srv" 2>/dev/null; rm -rf "$tmp"' EXIT

exec > >(tee "$LOG") 2>&1
echo "== qubes-ci-netdiag $(date -Is), $MB MiB per transfer"
ctl true || { echo "no tunnel to ci-ctl"; exit 1; }
bytes=$((MB * 1048576))

echo
echo "== 1. runner -> ci-ctl through the tunnel (ssh), xentop in dom0 meanwhile"
printf 'xentop -b -d 3 -i 6 | grep -E "NAME|sys-|ci-ctl|Domain-0"\n' | dom0 > "$tmp/xentop" 2>&1 &
xt=$!
sleep 1
t0=$(now)
head -c "$bytes" /dev/zero | ctl 'cat > /dev/null'
t1=$(now)
secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.1f", b - a}')
echo "tunnel: $(mbs "$bytes" "$secs") ($secs s)"
wait "$xt"
echo "-- dom0 xentop, 3 s apart, during the transfer:"
cat "$tmp/xentop"

echo
echo "== 2. runner -> ci-ctl as plain HTTP over the LAN"
ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
head -c "$bytes" /dev/zero > "$tmp/blob"
(cd "$tmp" && exec python3 -m http.server "$PORT" --bind 0.0.0.0) >/dev/null 2>&1 &
srv=$!
sleep 1
echo "runner at $ip:$PORT"
echo "local (runner itself): $(curl -s -o /dev/null -w '%{speed_download}' "http://127.0.0.1:$PORT/blob" | awk '{printf "%.1f MB/s", $1 / 1e6}')"
echo "ci-ctl: $(ctl "curl -s -o /dev/null --max-time 300 -w '%{speed_download} %{http_code}' http://$ip:$PORT/blob" |
                awk '{printf "%.1f MB/s (HTTP %s)", $1 / 1e6, $2}')"
kill "$srv" 2>/dev/null; srv=
rm -f "$tmp/blob"

echo
echo "== 3. a nar from the substitute server"
url=$(sed -n 's/^[[:space:]]*url[[:space:]]\{1,\}//p' "$HERE/../../dom0/qubes-guix-substitutes" 2>/dev/null | head -n1)
item=$(ssh -i "$ISO_SSH_KEY" -o BatchMode=yes "$ISO_HOST" \
       'ls -d /gnu/store/*-linux-libre-[0-9]* 2>/dev/null | grep -v "\.drv$" | head -n1')
if [ -z "$url" ] || [ -z "$item" ]; then
    echo "skipped: no substitute url ($url) or no linux-libre item on $ISO_HOST ($item)"
else
    h=$(basename "$item" | cut -c1-32)
    nar=$(curl -s "$url/$h.narinfo" | awk '$1 == "URL:" {print $2; exit}')
    size=$(curl -s "$url/$h.narinfo" | awk '$1 == "FileSize:" {print $2; exit}')
    if [ -z "$nar" ]; then
        echo "skipped: $url has no narinfo for $item"
    else
        echo "$url/$nar ($((size / 1048576)) MiB compressed)"
        echo "runner: $(curl -s -o /dev/null -w '%{speed_download}' "$url/$nar" | awk '{printf "%.1f MB/s", $1 / 1e6}')"
        echo "ci-ctl: $(ctl "curl -s -o /dev/null --max-time 300 -w '%{speed_download}' '$url/$nar'" | awk '{printf "%.1f MB/s", $1 / 1e6}')"
        echo "ci-ctl, again (server cache warm): $(ctl "curl -s -o /dev/null --max-time 300 -w '%{speed_download}' '$url/$nar'" | awk '{printf "%.1f MB/s", $1 / 1e6}')"
    fi
fi

echo
echo "== 4. ci-ctl's disk, sys-net's link, the qubes"
ctl "dd if=/dev/zero of=\$HOME/netdiag.tmp bs=1M count=$MB oflag=direct 2>&1 | tail -n1; rm -f \$HOME/netdiag.tmp"
dom0 <<'EOF' 2>&1
for q in sys-net sys-firewall ci-ctl; do
    printf '%-13s %s, %s vCPU, memory %s, maxmem %s, netvm %s\n' "$q" \
        "$(qvm-prefs $q virt_mode)" "$(qvm-prefs $q vcpus)" "$(qvm-prefs $q memory)" \
        "$(qvm-prefs $q maxmem)" "$(qvm-prefs $q netvm)"
done
qvm-run -q -u root --pass-io --no-gui sys-net '
for i in $(ls /sys/class/net | grep -v -e "^lo$" -e "^vif"); do
    echo "sys-net $i: $(cat /sys/class/net/$i/speed 2>/dev/null) Mb/s, $(cat /sys/class/net/$i/duplex 2>/dev/null), driver $(basename $(readlink /sys/class/net/$i/device/driver) 2>/dev/null)"
done
ethtool -k $(ls /sys/class/net | grep -v -e "^lo$" -e "^vif" | head -n1) 2>/dev/null | grep -E "^(tcp-segmentation|generic-receive|scatter-gather)"' </dev/null
EOF

echo
echo "== done: $LOG"
