#!/usr/bin/env bash
# Runs in dom0, from run-in-dom0.sh, once the Guix template TEMPLATE is
# installed. Makes the other kinds of Guix qube from it, without another
# install, and runs qubes-guix-test on each. For each boot mode (HVM, and
# PVH when dom0 has pvgrub2-pvh):
#
#   template    TEMPLATE itself for the mode it's in, else a clone of it
#               (TEMPLATE-pvh / TEMPLATE-hvm) switched to the mode;
#               qubes-guix-test --in-place
#   AppVM       TEMPLATE-app-MODE on that template:
#               qubes-guix-create --appvm T --MODE --test
#   standalone  TEMPLATE-sa-MODE, a StandaloneVM copied from that template
#               (qvm-create --class StandaloneVM --template T); qubes-guix-test
#
# This covers how each kind of qube runs, not qubes-guix-create's own
# --unattended paths for a StandaloneVM or PVH install.
#
# Usage: test-variants.sh TEMPLATE TOOLS_DIR RESULTS_DIR
#   TOOLS_DIR: where qubes-guix-create and qubes-guix-test are (dom0/)
# Exit status: the number of variants that failed (skips don't count).
set -uo pipefail

[ $# -eq 3 ] || { sed -n '18,19p' "$0"; exit 2; }
tpl=$1 tools=$(cd "$2" && pwd) results=$3
pvgrub=/var/lib/qubes/vm-kernels/pvgrub2-pvh
summary=()
failed=0

# Each variant's time: from the one before (so making its qube counts).
last=$SECONDS
record() {  # LABEL PASS|FAIL|SKIP [why]
    summary+=("$(printf '%-5s %3dm  %s%s' "$2" $(((SECONDS - last) / 60)) "$1" "${3:+  ($3)}")")
    last=$SECONDS
    [ "$2" = FAIL ] && failed=$((failed + 1))
    return 0
}

# LABEL CMD...: run CMD (from TOOLS_DIR, where qubes-guix-create looks for
# its files), its output to the job log and results/variant-LABEL.log.
variant() {
    local label=$1; shift
    echo
    echo "==> variant $label: $*"
    (cd "$tools" && "$@") </dev/null 2>&1 | tee "$results/variant-$label.log"
    if [ "${PIPESTATUS[0]}" = 0 ]; then record "$label" PASS; else record "$label" FAIL; fi
}

set_mode() {  # QUBE hvm|pvh
    if [ "$2" = pvh ]; then
        qvm-prefs "$1" virt_mode pvh && qvm-prefs "$1" kernel pvgrub2-pvh
    else
        qvm-prefs "$1" virt_mode hvm && qvm-prefs "$1" kernel ''
    fi
}

base_mode=$(qvm-prefs "$tpl" virt_mode)
for mode in hvm pvh; do
    if [ "$mode" = pvh ] && [ ! -e "$pvgrub" ]; then
        for kind in template appvm standalone; do
            record "pvh-$kind" SKIP "no $pvgrub in dom0: package grub2-xen-pvh"
        done
        continue
    fi

    # The template for this mode.
    t=$tpl
    if [ "$mode" != "$base_mode" ]; then
        t=$tpl-$mode
        echo
        echo "==> cloning $tpl to $t, switched to ${mode^^}"
        if ! { qvm-clone -q "$tpl" "$t" && set_mode "$t" "$mode"; }; then
            for kind in template appvm standalone; do
                record "$mode-$kind" FAIL "couldn't make $t"
            done
            continue
        fi
    fi

    variant "$mode-template" ./qubes-guix-test --in-place "$t"

    variant "$mode-appvm" ./qubes-guix-create --yes --appvm "$t" --"$mode" --test "$tpl-app-$mode"

    # A StandaloneVM gets a copy of the template's disk. Its settings are
    # the template's (what a Guix qube needs: HVM's kernel '', PVH's
    # pvgrub2-pvh, memory, a longer qrexec timeout), except its netvm: it
    # copies the template's, none, so set it back to the default one.
    sa=$tpl-sa-$mode
    echo
    echo "==> making $sa: a StandaloneVM copied from $t"
    if qvm-create -q --class StandaloneVM --template "$t" --label purple "$sa"; then
        for p in virt_mode kernel vcpus memory maxmem qrexec_timeout; do
            qvm-prefs "$sa" "$p" "$(qvm-prefs "$t" "$p")"
        done
        qvm-prefs "$sa" netvm --default
        variant "$mode-standalone" ./qubes-guix-test "$sa"
    else
        record "$mode-standalone" FAIL "couldn't make $sa"
    fi
done

echo
echo "==> variants of $tpl:"
printf '    %s\n' "${summary[@]}" | tee "$results/variants-summary.txt"
exit "$failed"
