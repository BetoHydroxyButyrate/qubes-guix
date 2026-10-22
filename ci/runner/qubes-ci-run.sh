#!/usr/bin/env bash
# Runs on the CI runner. Reaches the Qubes CI machine through the reverse
# SSH tunnel that its ci-ctl qube keeps open, copies the payload in, runs
# the tests in dom0 (via the ci.Dom0Shell qrexec service) and fetches results.
#
# Usage: qubes-ci-run.sh <payload-dir> [results-dir]
#   payload-dir: template *.rpm files and/or an executable dom0-tests.sh
#
# Config (env, or /etc/qubes-ci/runner.env):
#   TUNNEL_PORT    2222   port ci-ctl's tunnel listens on, on this machine
#   SSH_KEY        ~/.ssh/qubes_ci_ed25519
#   SYSTEM_TESTS   Qubes test modules, e.g. "qubes.tests.integ.basic" (default: none)
#   TEST_TEMPLATES (optional) override which templates are tested
#   VARIANTS       0: don't test the HVM/PVH template/AppVM/standalone variants
#   CONNECT_TIMEOUT 600   seconds to wait for the tunnel (e.g. after a reboot)
set -euo pipefail

[ -f /etc/qubes-ci/runner.env ] && . /etc/qubes-ci/runner.env
PAYLOAD=${1:?usage: $0 <payload-dir> [results-dir]}
RESULTS=${2:-./qubes-results}
TUNNEL_PORT=${TUNNEL_PORT:-2222}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/qubes_ci_ed25519}
SYSTEM_TESTS=${SYSTEM_TESTS:-}
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-600}
HERE=$(cd "$(dirname "$0")" && pwd)

# ci-ctl gets a new host key with every reinstall, so its key isn't checked:
# 127.0.0.1:$TUNNEL_PORT can only be opened by the tunnel key (permitlisten
# in the tunnel user's authorized_keys), which is what vouches for it.
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ServerAliveInterval=30)
ctl()  { ssh "${SSH_OPTS[@]}" -p "$TUNNEL_PORT" user@127.0.0.1 "$@"; }
log()  { echo "[$(date +%H:%M:%S)] $*"; }

deadline=$((SECONDS + CONNECT_TIMEOUT))
until ctl true 2>/dev/null; do
    [ $SECONDS -lt $deadline ] || { log "no tunnel from ci-ctl after ${CONNECT_TIMEOUT}s"; exit 1; }
    sleep 10
done
log "connected to ci-ctl"

# 1. stage the payload in ci-ctl
ctl 'rm -rf ci-run && mkdir -p ci-run'
scp "${SSH_OPTS[@]}" -P "$TUNNEL_PORT" -q "$HERE/../dom0/run-in-dom0.sh" "$HERE/../dom0/test-variants.sh" \
    user@127.0.0.1:ci-run/
if compgen -G "$PAYLOAD/*" >/dev/null; then
    scp "${SSH_OPTS[@]}" -P "$TUNNEL_PORT" -q -r "$PAYLOAD"/* user@127.0.0.1:ci-run/
fi

# 2. dom0 pulls it from ci-ctl, runs it, pushes results back. The exit code
#    is echoed as a marker rather than relying on qrexec to carry it.
#    The script arrives on stdin, so every command in it gets </dev/null:
#    qvm-run -p would otherwise swallow the rest of the script.
log "running in dom0 (Qubes test modules: ${SYSTEM_TESTS:-none})"
set +e
ctl "qrexec-client-vm dom0 ci.Dom0Shell" <<EOF | tee "${RESULTS%/}.console.log"
rm -rf ~/ci-run && mkdir -p ~/ci-run
qvm-run -q -p ci-ctl 'tar c -C ci-run .' </dev/null | tar x -C ~/ci-run
qvm-run -q -p ci-ctl 'rm -f ci-run/*.iso' </dev/null    # dom0 has it now
SYSTEM_TESTS='$SYSTEM_TESTS' TEST_TEMPLATES='${TEST_TEMPLATES:-}' VARIANTS='${VARIANTS:-1}' bash ~/ci-run/run-in-dom0.sh </dev/null
rc=\$?
tar c -C ~/ci-run results | qvm-run -q -p ci-ctl 'rm -rf ci-run/results; tar x -C ci-run'
echo "QUBES_CI_EXIT=\$rc"
EOF
set -e
status=$(grep -a -o 'QUBES_CI_EXIT=[0-9]*' "${RESULTS%/}.console.log" | tail -1 | cut -d= -f2)
status=${status:-255}

# 3. fetch results
mkdir -p "$RESULTS"
scp "${SSH_OPTS[@]}" -P "$TUNNEL_PORT" -q -r user@127.0.0.1:ci-run/results/. "$RESULTS/" || log "could not fetch results"
mv "${RESULTS%/}.console.log" "$RESULTS/console.log"
log "results in $RESULTS, exit $status"
exit "$status"
