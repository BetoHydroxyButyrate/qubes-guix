#!/usr/bin/env bash
# Runs in dom0, in ~/ci-run (pulled there from ci-ctl by qubes-ci-run.sh,
# all but the installer ISO, which stays in ci-ctl).
# Cleans up after the previous run, then, from what the payload holds:
#   ISO + dom0/     qubes-guix: installs the Guix template $CI_QUBE from the
#                   installer ISO $ISO_QUBE:$ISO_PATH with
#                   dom0/qubes-guix-create --unattended --template --test
#                   (which also runs qubes-guix-test)
#   *.rpm           installs these templates with qvm-template
# then runs the Qubes integration test modules against the installed
# templates, then the project's own dom0-tests.sh.
#
# After a good install, test-variants.sh (next to this) tests the other kinds
# of Guix qube made from the template: HVM and PVH, template, AppVM and
# StandaloneVM.
#
# Env: ISO_QUBE, ISO_PATH  where the installer ISO is (empty: none sent)
#      CI_QUBE       name of the Guix template made from the ISO (ci-guix)
#      VARIANTS      0: skip test-variants.sh (default 1)
#      SYSTEM_TESTS  space-separated "module[:timeout-seconds]" list
#      TEST_TEMPLATES  templates to test; defaults to the ones installed here
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p results
export DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority

# Every step's outcome, for the summary at the end (and results/summary.txt):
# step NAME PASS|FAIL [NOTE]. A FAIL fails the run. Each step's time is
# from the step before it (the first: from the end of the setup).
steps=()
last=$SECONDS
hms() { printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); }
step() {
    steps+=("$(printf '%-5s %s  %s%s' "$2" "$(hms $((SECONDS - last)))" "$1" "${3:+  ($3)}")")
    last=$SECONDS
    [ "$2" = FAIL ] && failed=1
    return 0
}
STATE=$HOME/.qubes-ci-templates
CI_QUBE=${CI_QUBE:-ci-guix}
VARIANTS=${VARIANTS:-1}
failed=0

# --- leftovers from the previous run: test qubes (test-guix-* are
# qubes-guix-test's), $CI_QUBE and the variants made from it ($CI_QUBE-*).
# Templates last: their AppVMs have to go first.
leftovers=$(qvm-ls --raw-list | grep -E "^test-(inst|cls|guix)-|^$CI_QUBE(-|\$)")
for pass in qubes templates; do
    for vm in $leftovers; do
        qvm-check -q "$vm" 2>/dev/null || continue
        is_tpl=0; [ "$(qvm-prefs "$vm" klass 2>/dev/null)" = TemplateVM ] && is_tpl=1
        [ "$pass" = qubes ] && [ $is_tpl = 1 ] && continue
        echo "==> removing leftover $vm"
        qvm-kill "$vm" 2>/dev/null
        qvm-remove -f "$vm"
    done
done

# --- PVH needs pvgrub2-pvh (dom0 package grub2-xen-pvh); try to install it
# once, as the variants skip PVH without it. Not fatal: dom0 updates go
# through the UpdateVM, which may not manage it.
if [ "$VARIANTS" = 1 ] && [ ! -e /var/lib/qubes/vm-kernels/pvgrub2-pvh ]; then
    echo "==> no pvgrub2-pvh in dom0: trying qubes-dom0-update grub2-xen-pvh"
    sudo qubes-dom0-update -y grub2-xen-pvh </dev/null ||
        echo "==> couldn't install grub2-xen-pvh: the PVH variants will be skipped"
fi
if [ -f "$STATE" ]; then
    while read -r t; do
        [ -n "$t" ] && qvm-check -q "$t" 2>/dev/null || continue
        echo "==> removing template $t from the previous run"
        qvm-template --yes remove "$t" || qvm-remove -f "$t"
    done <"$STATE"
    rm -f "$STATE"
fi

setup=$SECONDS last=$SECONDS

# --- install this run's templates
templates=()
for rpm in ./*.rpm; do
    [ -e "$rpm" ] || continue
    name=$(rpm -qp --qf '%{NAME}' "$rpm" 2>/dev/null)
    name=${name#qubes-template-}
    echo "==> installing template $name from $rpm"
    qvm-template install --nogpgcheck "$rpm" || { step "install $name (RPM)" FAIL; continue; }
    step "install $name (RPM)" PASS
    echo "$name" >>"$STATE"
    templates+=("$name")
done
# --- qubes-guix: a Guix template from the installer ISO, smoke-tested.
# The ISO stays in the qube it was sent to (3-4 GB; dom0's root is small):
# qubes-guix-create reads it from there. An ISO sent but missing, or no
# qubes-guix-create to install it with, fails the run rather than leaving
# nothing tested.
ISO_QUBE=${ISO_QUBE:-} ISO_PATH=${ISO_PATH:-}
while [ -n "$ISO_PATH" ]; do
    if ! qvm-run -q -p "$ISO_QUBE" "test -s '$ISO_PATH'" </dev/null; then
        echo "==> FAIL: no installer ISO at $ISO_QUBE:$ISO_PATH"
        step "install $CI_QUBE" FAIL "no installer ISO at $ISO_QUBE:$ISO_PATH"; break
    fi
    if [ ! -x dom0/qubes-guix-create ]; then
        echo "==> FAIL: an installer ISO, but no dom0/qubes-guix-create in the payload"
        step "install $CI_QUBE" FAIL "no dom0/qubes-guix-create in the payload"; break
    fi
    echo "==> qubes-guix-create --unattended --template --test $CI_QUBE from $ISO_QUBE:$ISO_PATH"
    (cd dom0 && ./qubes-guix-create --yes --unattended --template --no-password --force --test \
        "$CI_QUBE" "$ISO_QUBE:$ISO_PATH") </dev/null 2>&1 | tee results/qubes-guix-create.log
    rc=${PIPESTATUS[0]}
    # No resume on failure: a failed install leaves the installer with
    # nothing on root's PATH (no setsid, ls, ...), so qubes-guix-create can't
    # resume it. The next run starts over. ISO_OFFLINE=1 on the runner keeps
    # the install off the network, the usual cause.
    if [ "$rc" = 0 ]; then
        step "install $CI_QUBE, and qubes-guix-test on an AppVM of it" PASS
    else
        step "install $CI_QUBE, and qubes-guix-test on an AppVM of it" FAIL \
            "exit $rc; results/qubes-guix-create.log"
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
    # Booting from an ISO kept in a Guix qube (qvm-start --cdrom=QUBE:FILE),
    # with this run's installer ISO: qubes-guix-test --cdrom-iso, on an
    # AppVM of the new template.
    if [ "$rc" = 0 ]; then
        echo "==> qubes-guix-test --cdrom-iso $ISO_QUBE:$ISO_PATH $CI_QUBE"
        (cd dom0 && ./qubes-guix-test --cdrom-iso "$ISO_QUBE:$ISO_PATH" "$CI_QUBE") </dev/null 2>&1 |
            tee results/qubes-guix-test-cdrom.log
        if [ "${PIPESTATUS[0]}" = 0 ]; then
            step "boot a qube from an ISO in a Guix AppVM (--cdrom-iso)" PASS
        else
            step "boot a qube from an ISO in a Guix AppVM (--cdrom-iso)" FAIL \
                "results/qubes-guix-test-cdrom.log"
        fi
    fi
    if [ "$rc" = 0 ] && [ "$VARIANTS" = 1 ] && [ -x ./test-variants.sh ]; then
        ./test-variants.sh "$CI_QUBE" dom0 results
        n=$?
        if [ "$n" = 0 ]; then
            step "variants: template, AppVM, standalone; HVM, PVH" PASS "results/variants-summary.txt"
        else
            step "variants: template, AppVM, standalone; HVM, PVH" FAIL "$n failed; results/variants-summary.txt"
        fi
    fi
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
    if run_module "${spec%%:*}" "$( [[ $spec == *:* ]] && echo "${spec##*:}" || echo 3600 )"; then
        step "${spec%%:*}" PASS
    else
        step "${spec%%:*}" FAIL "results/${spec%%:*}.log"
    fi
done

if [ -x ./dom0-tests.sh ]; then
    echo "==> project dom0-tests.sh"
    if ./dom0-tests.sh > results/dom0-tests.log 2>&1; then
        step "dom0-tests.sh" PASS
    else
        step "dom0-tests.sh" FAIL "results/dom0-tests.log"
    fi
    tail -20 results/dom0-tests.log
fi

sudo journalctl -b --no-pager --since "-12h" > results/dom0-journal.log 2>/dev/null
sudo cp -r /var/log/xen/console results/xen-console 2>/dev/null
sudo cp -r /var/log/qubes results/qubes-logs 2>/dev/null
sudo chown -R "$(id -u):$(id -g)" results

echo
echo "==> summary"
{
    if [ ${#steps[@]} = 0 ]; then
        echo "    (nothing tested: an empty payload)"
    else
        printf '    %s\n' "${steps[@]}"
    fi
    echo "    in dom0: $(hms $SECONDS) (setup: leftovers removed, dom0 packages: $(hms "$setup"))"
} | tee results/summary.txt
exit $failed
