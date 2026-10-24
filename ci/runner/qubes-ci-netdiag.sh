#!/usr/bin/env bash
# Runs on the CI runner, as ci, from a checkout. Measures the data paths a
# CI run uses, to find what holds them to a few MB/s, and writes it all to
# one log (printed too):
#
#   1. runner -> ci-ctl through the tunnel (ssh, as qubes-ci-run.sh's scp),
#      with dom0's xentop sampled meanwhile (CPU of sys-net, sys-firewall,
#      ci-ctl);
#   2. plain TCP over the LAN (no ssh, no tunnel), runner -> qube and
#      qube -> runner, 30 s each, from ci-ctl, sys-firewall and sys-net
#      itself (with its NIC's counters around), to see which hop and which
#      direction is slow;
#   3. a nar from the substitute server: fetched on the runner, then in
#      ci-ctl (what installs and updates download);
#   4. ci-ctl's own disk; sys-net's link, address, routes, qdiscs and NIC
#      counters; the qubes' memory/vCPUs;
#   5. (TESTS=5) sys-net receiving from the runner: its NIC's interrupt and
#      packet rates meanwhile, MSI, e1000e's parameters, EEE, pause, rings,
#      coalescing and offloads (ethtool installed in sys-net for this boot);
#   6. (TESTS=6) sys-net receiving: the runner's socket (ss) and sys-net's
#      TCP counters (nstat) during a download, then e1000e settings tried
#      one at a time (GRO, TSO/GSO, rx-usecs, rings, flow control), each
#      put back after.
#
# Usage: qubes-ci-netdiag.sh [LOG]   (default: ./netdiag-DATE.log)
# Config: as qubes-ci-run.sh (TUNNEL_PORT, SSH_KEY), build-iso-remote.sh
# (ISO_HOST, ISO_SSH_KEY); /etc/qubes-ci/runner.env.
#   TESTS   which of the sections below to run (1 2 3 4; 5, 6 on request)
#   MB      size of each transfer, MiB (500)
#   PORT    the runner's port for test 2 (8099)
#   SUBS_URL  the substitute server (default: the first url in the
#           checkout's dom0/qubes-guix-substitutes, else https://ISO_HOST)
set -uo pipefail

[ -f /etc/qubes-ci/runner.env ] && . /etc/qubes-ci/runner.env
HERE=$(cd "$(dirname "$0")" && pwd)
LOG=${1:-./netdiag-$(date +%Y%m%d-%H%M%S).log}
TUNNEL_PORT=${TUNNEL_PORT:-2222}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/qubes_ci_ed25519}
ISO_HOST=${ISO_HOST:-guix-subs}
ISO_SSH_KEY=${ISO_SSH_KEY:-$HOME/.ssh/qubes_ci_ed25519}
MB=${MB:-500}
TESTS=${TESTS:-1 2 3 4}
want() { case " $TESTS " in *" $1 "*) return 0;; esac; return 1; }
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

# Tests 2 and 5: a TCP server on the runner, and the client each qube runs
# (python3, sent on stdin): it reads (down: runner -> qube) or writes (up:
# qube -> runner) for 30 s and prints the rate.
ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
cat > "$tmp/server.py" <<'PY'
import socket, sys, threading
def serve(c):
    with c:
        if c.recv(4) == b"down":           # send zeros until the client hangs up
            buf = bytes(1 << 20)
            try:
                while True:
                    c.sendall(buf)
            except OSError:
                pass
        else:                              # "up ": read and discard
            while c.recv(1 << 20):
                pass
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1])))
s.listen(8)
while True:
    threading.Thread(target=serve, args=(s.accept()[0],), daemon=True).start()
PY
cat > "$tmp/client.py" <<'PY'
import socket, sys, time
host, port, way = sys.argv[1], int(sys.argv[2]), sys.argv[3]
secs = float(sys.argv[4]) if len(sys.argv) > 4 else 30
s = socket.create_connection((host, port), timeout=10)
s.sendall(b"down" if way == "down" else b"up  ")
n, buf, t0 = 0, bytes(1 << 20), time.time()
while time.time() - t0 < secs:
    if way == "down":
        b = s.recv(1 << 20)
        if not b:
            break
        n += len(b)
    else:
        s.sendall(buf)
        n += len(buf)
dt = time.time() - t0
print("%5s %.1f MB/s (%d MB in %.0f s)" % (way, n / dt / 1e6, n // 1000000, dt))
PY
start_server() {
    [ -n "$srv" ] && return 0
    python3 "$tmp/server.py" "$PORT" >/dev/null 2>&1 &
    srv=$!
    sleep 1
}
echo "== qubes-ci-netdiag $(date -Is), $MB MiB per transfer, tests: $TESTS"
ctl true || { echo "no tunnel to ci-ctl"; exit 1; }
bytes=$((MB * 1048576))

if want 1; then
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

fi
if want 2; then
echo
echo "== 2. plain TCP over the LAN, both ways (no ssh, no tunnel), 30 s each"
# From each qube, both ways. sys-net's NIC counters are read around its
# own transfers.
start_server
echo "runner at $ip:$PORT"
echo "-- runner to itself:"
python3 "$tmp/client.py" 127.0.0.1 "$PORT" down
echo "-- ci-ctl (through sys-firewall and sys-net):"
for way in down up; do ctl "python3 - $ip $PORT $way" < "$tmp/client.py"; done
counters='for c in rx_bytes rx_dropped rx_errors rx_missed_errors tx_errors; do printf "%s=%s " $c $(cat /sys/class/net/ens6/statistics/$c); done; echo'
for q in sys-firewall sys-net; do
    echo "-- $q:"
    {
        printf 'c=%q\n' "$counters"
        printf 'py=%q\n' "$(cat "$tmp/client.py")"
        [ "$q" = sys-net ] && echo 'echo "   before: $(qvm-run -q -u root --pass-io --no-gui sys-net "$c" </dev/null)"'
        for way in down up; do
            printf 'printf "%%s\\n" "$py" | qvm-run -q -u root --pass-io --no-gui %s "python3 - %s %s %s"\n' \
                "$q" "$ip" "$PORT" "$way"
        done
        [ "$q" = sys-net ] && echo 'echo "   after:  $(qvm-run -q -u root --pass-io --no-gui sys-net "$c" </dev/null)"'
    } | dom0 2>&1
done
kill "$srv" 2>/dev/null; srv=

fi
if want 3; then
echo
echo "== 3. a nar from the substitute server"
url=${SUBS_URL:-$(sed -n 's/^[[:space:]]*url[[:space:]]\{1,\}//p' "$HERE/../../dom0/qubes-guix-substitutes" 2>/dev/null | head -n1)}
# Not in a checkout: the build host's own guix publish, at https://HOST.
url=${url:-https://${ISO_HOST#*@}}
item=$(ssh -i "$ISO_SSH_KEY" -o BatchMode=yes "$ISO_HOST" \
       'ls -d /gnu/store/*-linux-libre-[0-9]* 2>/dev/null | grep -E -- "-linux-libre-[0-9.]+$" | head -n1')
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

fi
if want 4; then
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
nic=$(ls /sys/class/net | grep -v -e "^lo$" -e "^vif" | head -n1)
echo "-- addresses, routes, qdiscs:"
ip -4 -br addr; ip -4 route; tc qdisc show 2>/dev/null
echo "-- $nic counters (errors, drops, pause, crc):"
for f in /sys/class/net/$nic/statistics/*; do
    case ${f##*/} in *err*|*drop*|*collision*|rx_bytes|tx_bytes) echo "${f##*/} $(cat $f)";; esac
done
ethtool -S $nic 2>/dev/null | grep -iE "err|drop|pause|crc|miss|fifo" | grep -v ": 0$"
ethtool $nic 2>/dev/null | grep -iE "speed|duplex|auto-neg|link detected"
ethtool -a $nic 2>/dev/null
ethtool -k $nic 2>/dev/null | grep -E "^(tcp-segmentation|generic-receive|generic-segmentation|scatter-gather|rx-checksumming|tx-checksumming):"
command -v ethtool >/dev/null || echo "(no ethtool in sys-net)"
echo "-- kernel messages about $nic / e1000e:"
dmesg 2>/dev/null | grep -iE "$nic|e1000e" | tail -n 15' </dev/null
EOF

fi
if want 5; then
echo
echo "== 5. sys-net receiving: its NIC's interrupts, MSI, EEE, rings, coalescing"
# ethtool, for this boot of sys-net only (apt, through its own network).
start_server
cat > "$tmp/sysnet.sh" <<EOF
nic=\$(ls /sys/class/net | grep -v -e '^lo\$' -e '^vif' | head -n1)
command -v ethtool >/dev/null ||
    { apt-get install -y -qq ethtool >/dev/null 2>&1 || dnf install -y -q ethtool >/dev/null 2>&1; }
command -v ethtool >/dev/null || echo "(couldn't install ethtool in sys-net)"
echo "-- \$nic: driver \$(ethtool -i \$nic 2>/dev/null | awk '/^(version|firmware)/ {printf "%s ", \$0}')"
echo "-- kernel command line: \$(cat /proc/cmdline)"
echo "-- e1000e module parameters:"
for f in /sys/module/e1000e/parameters/*; do [ -e "\$f" ] && echo "   \${f##*/}=\$(cat \$f)"; done
dev=\$(basename \$(readlink -f /sys/class/net/\$nic/device))
echo "-- PCI \$dev: MSI/MSI-X, power:"
lspci -vv -s \$dev 2>/dev/null | grep -E "MSI|LnkSta|LnkCtl" || echo "   (no lspci)"
echo "   power/control=\$(cat /sys/class/net/\$nic/device/power/control 2>/dev/null) msi_irqs=\$(ls /sys/class/net/\$nic/device/msi_irqs 2>/dev/null | xargs)"
echo "-- EEE:"; ethtool --show-eee \$nic 2>&1 | sed 's/^/   /'
echo "-- pause:"; ethtool -a \$nic 2>&1 | sed 's/^/   /'
echo "-- rings:"; ethtool -g \$nic 2>&1 | sed 's/^/   /'
echo "-- coalescing:"; ethtool -c \$nic 2>&1 | grep -E "rx-usecs|tx-usecs|Adaptive" | sed 's/^/   /'
echo "-- offloads:"; ethtool -k \$nic 2>&1 | grep -E "^(tcp-segmentation-offload|generic-receive-offload|generic-segmentation-offload|large-receive-offload|rx-checksumming|scatter-gather):" | sed 's/^/   /'
ints() { grep -E "\$nic|e1000e" /proc/interrupts | awk '{for (i = 2; i <= NF; i++) if (\$i ~ /^[0-9]+\$/) s += \$i} END {print s + 0}'; }
echo "-- /proc/interrupts lines for the NIC:"; grep -E "\$nic|e1000e" /proc/interrupts | sed 's/^/   /'
cat > /tmp/netdiag-client.py <<'PY'
$(cat "$tmp/client.py")
PY
i0=\$(ints); r0=\$(cat /sys/class/net/\$nic/statistics/rx_packets); t0=\$(date +%s)
python3 /tmp/netdiag-client.py $ip $PORT down
i1=\$(ints); r1=\$(cat /sys/class/net/\$nic/statistics/rx_packets); t1=\$(date +%s)
dt=\$((t1 - t0)); [ \$dt -gt 0 ] || dt=1
echo "-- during that: \$(( (i1 - i0) / dt )) NIC interrupts/s, \$(( (r1 - r0) / dt )) packets/s received"
EOF
printf 'qvm-run -q -u root --pass-io --no-gui sys-net "bash -s" <<'"'"'SYSNET'"'"'\n%s\nSYSNET\n' "$(cat "$tmp/sysnet.sh")" | dom0 2>&1
fi

if want 6; then
echo
echo "== 6. sys-net receiving: TCP's view, then e1000e settings tried one at a time"
# A 20 s download into sys-net with, meanwhile, the sending socket's state
# on the runner (ss: congestion window, retransmits, RTT) and sys-net's TCP
# counters (nstat: duplicates, out of order, drops). Then 15 s downloads,
# each with one NIC setting changed, and put back after. Changing rings or
# flow control resets the link for a few seconds; sys-net's log is also
# kept in its /tmp/netdiag6.log in case this connection doesn't survive.
start_server
( sleep 12; echo "-- the runner's sending socket, 12 s in:"; ss -tin "( sport = :$PORT )" | sed 's/^/   /' ) > "$tmp/ss" &
ssp=$!
cat > "$tmp/sysnet6.sh" <<EOF
exec > >(tee /tmp/netdiag6.log) 2>&1
nic=\$(ls /sys/class/net | grep -v -e '^lo\$' -e '^vif' | head -n1)
command -v ethtool >/dev/null ||
    { apt-get install -y -qq ethtool >/dev/null 2>&1 || dnf install -y -q ethtool >/dev/null 2>&1; }
command -v ethtool >/dev/null || { echo "(no ethtool in sys-net)"; exit 1; }
cat > /tmp/netdiag-client.py <<'PY'
$(cat "$tmp/client.py")
PY
down() { python3 /tmp/netdiag-client.py $ip $PORT down "\$1"; }
echo "-- baseline, 20 s:"
nstat -n 2>/dev/null
down 20
echo "-- sys-net's TCP counters over it (non-zero):"
nstat 2>/dev/null | grep -E '^(Tcp|TcpExt|IpExt)' | sed 's/^/   /' || echo "   (no nstat)"
rx=\$(ethtool -c \$nic | awk '\$1 == "rx-usecs:" {print \$2}')
rr=\$(ethtool -g \$nic | awk '/^Current/ {c = 1} c && \$1 == "RX:" {print \$2; exit}')
tr=\$(ethtool -g \$nic | awk '/^Current/ {c = 1} c && \$1 == "TX:" {print \$2; exit}')
try() {  # NAME SETTLE "CHANGE" "RESTORE"
    eval "\$3" >/dev/null 2>&1 || { printf '   %-34s (setting refused)\n' "\$1"; return; }
    sleep "\$2"
    printf '   %-34s ' "\$1"; down 15
    eval "\$4" >/dev/null 2>&1
    sleep "\$2"
}
echo "-- one setting at a time (15 s each):"
try "gro off"                    1 "ethtool -K \$nic gro off"                "ethtool -K \$nic gro on"
try "tso, gso off"               1 "ethtool -K \$nic tso off gso off"        "ethtool -K \$nic tso on gso on"
try "rx-usecs 0 (was \$rx)"       1 "ethtool -C \$nic rx-usecs 0"             "ethtool -C \$nic rx-usecs \$rx"
try "rings 4096 (were \$rr/\$tr)" 8 "ethtool -G \$nic rx 4096 tx 4096"        "ethtool -G \$nic rx \$rr tx \$tr"
try "flow control off"           8 "ethtool -A \$nic autoneg off rx off tx off" "ethtool -A \$nic autoneg on rx on tx on"
echo "-- baseline again, 15 s:"
down 15
EOF
printf 'qvm-run -q -u root --pass-io --no-gui sys-net "bash -s" <<'"'"'SYSNET'"'"'\n%s\nSYSNET\n' "$(cat "$tmp/sysnet6.sh")" | dom0 2>&1
wait "$ssp"
cat "$tmp/ss"
fi

echo
echo "== done: $LOG"
