#!/usr/bin/env bash
# Runs in dom0, in ~/ci-run (pulled there from ci-ctl by qubes-ci-run.sh).
# Cleans up after the previous run, then, from what the payload holds:
#   *.iso + dom0/   qubes-guix: installs the Guix template $CI_QUBE from the
#                   installer ISO with dom0/qubes-guix-create --unattended
#                   --template --test (which also runs qubes-guix-test)
#   *.rpm           installs these templates with qvm-template
# then runs the Qubes integration test modules against the installed
# templates, then the project's own dom0-tests.sh.
#
# Env: CI_QUBE       name of the Guix template made from the ISO (ci-guix)
#      SYSTEM_TESTS  space-separated "module[:timeout-seconds]" list
#      TEST_TEMPLATES  templates to test; defaults to the ones installed here
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p results
export DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority
STATE=$HOME/.qubes-ci-templates
CI_QUBE=${CI_QUBE:-ci-guix}
failed=0

# --- leftovers from the previous run
# AppVMs first (test-guix-* are qubes-guix-test's), then the template.
for vm in $(qvm-ls --raw-list | grep -E '^test-(inst|cls|guix)-') \
          $(qvm-check -q "$CI_QUBE" 2>/dev/null && echo "$CI_QUBE"); do
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
# --- qubes-guix: a Guix template from the installer ISO, smoke-tested
for iso in ./*.iso; do
    [ -e "$iso" ] && [ -x dom0/qubes-guix-create ] || continue
    iso_path=$(pwd)/${iso#./}
    echo "==> qubes-guix-create --unattended --template --test $CI_QUBE from $iso"
    (cd dom0 && ./qubes-guix-create --yes --unattended --template --no-password --force --test \
        "$CI_QUBE" "dom0:$iso_path") </dev/null 2>&1 | tee results/qubes-guix-create.log
    if [ "${PIPESTATUS[0]}" != 0 ]; then
        failed=1
        # A failed install leaves the installer running, with its log in
        # /root; it has cat but few other tools, so fetch the whole log.
        if qvm-check -q --running "$CI_QUBE" 2>/dev/null; then
            timeout 120 qvm-run -q -u root --pass-io "$CI_QUBE" \
                'cat /root/qubes-guix-install.log' </dev/null \
                > results/qubes-guix-install.log 2>&1 &&
                echo "==> the installer's log is in results/qubes-guix-install.log"
        fi
    fi
    qvm-check -q "$CI_QUBE" 2>/dev/null && templates+=("$CI_QUBE")
    break
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
rm -f ./*.iso    # ~3 GB; dom0's root is small
exit $failed
