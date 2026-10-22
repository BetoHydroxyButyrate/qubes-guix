#!/usr/bin/env bash
# Runs on the CI runner. Builds the qubes-guix installer ISO on the Guix
# build host (guix-subs) at one commit, and copies it back here.
#
# On the host, the commit is fetched into its checkout and built in a
# throwaway git worktree, so the checkout itself (its branch, any local
# work) is left alone. The build is iso/qubes-guix-iso -b BRANCH
# --qubes-commit SHA --server URL: qubes exactly at SHA, the other channels
# at the commits URL last built (URL is the first url in the commit's
# dom0/qubes-guix-substitutes). Pinning qubes to SHA means the "server last
# built an older qubes" check doesn't stop the build.
#
# Usage: build-iso-remote.sh <branch> <sha> <out.iso>
#
# Config (env, or /etc/qubes-ci/runner.env):
#   ISO_HOST       guix-subs            ssh destination (user@host)
#   ISO_DIR        proj/qubes-guix      the checkout on ISO_HOST, under its home
#   ISO_SSH_KEY    ~/.ssh/qubes_ci_ed25519
#   ISO_OFFLINE    1: build with --offline, so the ISO carries the channels'
#                  git checkouts and the install needs no network for them
#                  (a bigger ISO, a longer copy; fewer network flakes)
#   ISO_SYNC_CMD   run on ISO_HOST before the build, so the server has built
#                  the head and the other channels' commits match it (empty:
#                  skip). Default: guix-subs' own build script, through
#                  passwordless sudo (see ci/README.md)
set -euo pipefail

[ -f /etc/qubes-ci/runner.env ] && . /etc/qubes-ci/runner.env
[ $# -eq 3 ] || { sed -n '13p' "$0"; exit 1; }
BRANCH=$1 SHA=$2 OUT=$3
ISO_HOST=${ISO_HOST:-guix-subs}
ISO_DIR=${ISO_DIR:-proj/qubes-guix}
ISO_SSH_KEY=${ISO_SSH_KEY:-$HOME/.ssh/qubes_ci_ed25519}
ISO_OFFLINE=${ISO_OFFLINE:-0}
ISO_SYNC_CMD=${ISO_SYNC_CMD-sudo -n /etc/guix-subs/build-qubes.sh 2>&1 | sudo -n tee -a /var/log/qubes-builds.log}
SSH_OPTS=(-i "$ISO_SSH_KEY" -o BatchMode=yes -o ServerAliveInterval=60)

[[ $SHA =~ ^[0-9a-f]{40}$ ]] || { echo "not a full commit hash: $SHA"; exit 1; }
[[ $BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "bad branch name: $BRANCH"; exit 1; }

# Everything after the ssh destination is one quoted command line; the
# script itself goes over stdin.
ssh "${SSH_OPTS[@]}" "$ISO_HOST" \
    "bash -s -- $(printf '%q ' "$ISO_DIR" "$BRANCH" "$SHA" "$ISO_SYNC_CMD" "$ISO_OFFLINE")" <<'EOF'
set -euo pipefail
dir=$HOME/$1 branch=$2 sha=$3 sync=$4 offline=$5
out=$HOME/ci-iso
cd "$dir"
url=$(sed -n 's/.*(url "\(.*\)").*/\1/p' guest/channels.scm.txt | head -n1)
git fetch -q "$url" "$branch"
git cat-file -e "$sha^{commit}" || { echo "$url $branch has no commit $sha"; exit 1; }
if [ -n "$sync" ]; then
    echo "==> on $(hostname): $sync"
    bash -o pipefail -c "$sync" </dev/null
fi
wt=$out/worktree
mkdir -p "$out"
git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
git worktree prune
git worktree add -q --detach "$wt" "$sha"
trap 'git -C "$dir" worktree remove --force "$wt" 2>/dev/null || :' EXIT
cd "$wt"
server=$(sed -n 's/^[[:space:]]*url[[:space:]]\{1,\}//p' dom0/qubes-guix-substitutes 2>/dev/null | head -n1)
echo "==> on $(hostname): qubes-guix-iso at $(git log -1 --format='%h %s')"
rm -f "$out/qubes-guix-installer.iso" "$out/qubes-guix-installer.iso.channels"
iso/qubes-guix-iso -b "$branch" --qubes-commit "$sha" ${server:+--server "$server"} \
    $( [ "$offline" = 1 ] && echo --offline ) \
    -o "$out/qubes-guix-installer.iso" </dev/null
EOF

mkdir -p "$(dirname "$OUT")"
scp "${SSH_OPTS[@]}" -q "$ISO_HOST:ci-iso/qubes-guix-installer.iso" "$OUT"
scp "${SSH_OPTS[@]}" -q "$ISO_HOST:ci-iso/qubes-guix-installer.iso.channels" "$OUT.channels" || :
echo "ISO: $OUT ($(du -h "$OUT" | cut -f1))"
