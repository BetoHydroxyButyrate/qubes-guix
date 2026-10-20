#!/usr/bin/env bash
# Runs in dom0, in ~/ci-run (pulled there from ci-ctl by qubes-ci-run.sh).
# Cleans up after the previous run, installs any template RPMs, runs the
# Qubes integration tests against them, then the project's own dom0-tests.sh.
#
# Env: SYSTEM_TESTS  space-separated "module[:timeout-seconds]" list
#      TEST_TEMPLATES  templates to test; defaults to the ones installed here
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p results
export DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority
STATE=$HOME/.qubes-ci-templates
failed=0

# --- leftovers from the previous run
for vm in $(qvm-ls --raw-list | grep -E '^test-(inst|cls)-'); do
    echo "==> removing leftover $vm"
    qvm-kill "$vm" 2>/dev/null
    qvm-remove -f "$vm"
done
if [ -f "$STATE" ]; then
    while read -r t; do
        [ -n "$t" ] && qvm-check -q "$t" 2>/dev/null || continue
        echo "==> removing template $t from the previous run"
        qvm-template --yes remove "$t" || qvm-remove -f "$t"
    done <"$STATE"
    rm -f "$STATE"
fi

# --- install this run's templates
templates=()
for rpm in ./*.rpm; do
    [ -e "$rpm" ] || continue
    name=$(rpm -qp --qf '%{NAME}' "$rpm" 2>/dev/null)
    name=${name#qubes-template-}
    echo "==> installing template $name from $rpm"
    qvm-template install --nogpgcheck "$rpm" || { failed=1; continue; }
    echo "$name" >>"$STATE"
    templates+=("$name")
done
# Must be unset, not empty, to mean "all templates" (an empty value means none)
QUBES_TEST_TEMPLATES=${TEST_TEMPLATES:-${templates[*]}}
if [ -n "$QUBES_TEST_TEMPLATES" ]; then export QUBES_TEST_TEMPLATES; else unset QUBES_TEST_TEMPLATES; fi
echo "==> templates under test: ${QUBES_TEST_TEMPLATES:-<all installed>}"

run_module() {
    local mod=$1 timeout=$2 prefix=
    if ! python3 -c "import $mod" 2>/dev/null; then
        echo "==> skipping $mod (not importable in this dom0)"
        return 0
    fi
    echo "==> $mod (timeout ${timeout}s)"
    # Qubes' own CI stops qubesd for qubes.tests.* - the tests start their own
    if [[ $mod == qubes.tests.* ]]; then
        sudo systemctl stop qubesd
        prefix="sudo -E"
    fi
    rm -f nose2-junit.xml
    $prefix timeout "$timeout" nose2 -v \
        --plugin nose2.plugins.loader.loadtests \
        --plugin nose2.plugins.junitxml -X "$mod" \
        > "results/$mod.log" 2>&1
    local rc=$?
    [[ $mod == qubes.tests.* ]] && sudo systemctl start qubesd
    [ -f nose2-junit.xml ] && sudo mv nose2-junit.xml "results/junit-$mod.xml"
    tail -5 "results/$mod.log"
    return $rc
}

for spec in ${SYSTEM_TESTS:-}; do
    run_module "${spec%%:*}" "$( [[ $spec == *:* ]] && echo "${spec##*:}" || echo 3600 )" || failed=1
done

if [ -x ./dom0-tests.sh ]; then
    echo "==> project dom0-tests.sh"
    ./dom0-tests.sh > results/dom0-tests.log 2>&1 || failed=1
    tail -20 results/dom0-tests.log
fi

sudo journalctl -b --no-pager --since "-12h" > results/dom0-journal.log 2>/dev/null
sudo cp -r /var/log/xen/console results/xen-console 2>/dev/null
sudo cp -r /var/log/qubes results/qubes-logs 2>/dev/null
sudo chown -R "$(id -u):$(id -g)" results
exit $failed
