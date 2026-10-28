#!@SH@
# qubes-guix-profile — your own Guix packages back after an AppVM restarts.
#
#   qubes-guix-profile            restore them now, if they need it
#   qubes-guix-profile --check    say what a restore would download or build
#   qubes-guix-profile --force    restore even if they look current
#
# An AppVM's root, /gnu/store and /var/guix included, is a fresh copy of its
# template's at every start; only your home is kept. So what 'guix install'
# put in ~/.guix-profile is gone, and ~/.guix-profile (in home) points at
# nothing. Describe it in files in your home instead, and this puts it back:
#
#   ~/.config/guix/manifest.scm   packages: guix package -m (~/.guix-profile)
#   ~/.config/guix/home.scm       a Guix Home: guix home reconfigure
#                                 (~/.guix-home)
#
# Each is restored when its profile points at nothing (after a restart) or
# is older than the file. qubes-session runs this at login (in the
# background, logging to ~/.cache/qubes-guix-profile.log, with a desktop
# notification when it's done). Open a new terminal afterwards.
#
# It uses the system's guix: the template's, locked like it (to your
# substitute server's commits, with one). Then what the server built comes
# from there, and what the template has is already here. Anything else is
# BUILT here, at every restart: a restore warns about those. Add them to
# the server's package list, or to the template.
#
# Environment: QUBES_GUIX_MANIFEST, QUBES_GUIX_HOME: other files.

set -u
export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:${PATH:-/bin}
prog=${0##*/}
guix=/run/current-system/profile/bin/guix
manifest=${QUBES_GUIX_MANIFEST:-$HOME/.config/guix/manifest.scm}
home_scm=${QUBES_GUIX_HOME:-$HOME/.config/guix/home.scm}
mode=restore session=0
case ${1:-} in
    '') ;;
    --check) mode=check;;
    --force) mode=force;;
    --session) session=1;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0;;
    *) echo "$prog: unknown argument $1 (--check, --force)" >&2; exit 2;;
esac

if [ "$session" = 1 ]; then
    mkdir -p "$HOME/.cache"
    exec >>"$HOME/.cache/qubes-guix-profile.log" 2>&1
    echo "== $(date)"
fi

notify() {
    [ "$session" = 1 ] && command -v notify-send >/dev/null 2>&1 &&
        notify-send -a "Guix" "$@" 2>/dev/null
    return 0
}

# needs FILE LINK: whether LINK's profile needs (re)building from FILE.
needs() {
    [ -f "$1" ] || return 1
    [ "$mode" = force ] && return 0
    [ -e "$2" ] || return 0                     # points at nothing
    # FILE changed since the profile last switched: compared with the
    # profile's own link (/var/guix/profiles/per-user/USER/guix-profile),
    # replaced at each switch. Not with what it points to: store items all
    # date from 1970.
    link=$(readlink "$2") || return 0
    [ "$(stat -c %Y "$1")" -gt "$(stat -c %Y "$link")" ]
}

# What a build of these would download, and what it would build here:
# guix's dry run, reduced to the names to be built.
built_here() {
    "$guix" "$@" --dry-run 2>&1 |
        sed -n '/would be built:/,/would be downloaded:/p' |
        sed -n 's|^ *[^ ]*/[a-z0-9]\{32\}-\(.*\)\.drv$|\1|p'
}

warn_built() {   # warn_built WHAT GUIX-ARGS...: say what would be built here
    local what=$1 b
    shift
    b=$(built_here "$@")
    if [ -n "$b" ]; then
        echo "$prog: $what: these aren't substitutes, so they're BUILT here (at every"
        echo "AppVM restart): add them to your substitute server's packages, or to"
        echo "the template:"
        printf '%s\n' "$b" | sed 's/^/  /'
        notify "Building Guix packages here" "$(printf '%s\n' "$b" | head -n 5)"
    fi
}

# --check: for each file there, whether a restore is due, and what it would
# build here rather than download.
check_one() {   # check_one FILE LINK GUIX-ARGS...
    f=$1 l=$2
    shift 2
    [ -f "$f" ] || return 0
    if needs "$f" "$l"; then state="a restore is due"; else state="the profile is current"; fi
    b=$(built_here "$@")
    if [ -n "$b" ]; then
        echo "$f: $state; a restore would BUILD here:"
        printf '%s\n' "$b" | sed 's/^/  /'
    else
        echo "$f: $state; a restore builds nothing here (substitutes, or already here)."
    fi
}
if [ "$mode" = check ]; then
    [ -f "$manifest" ] || [ -f "$home_scm" ] ||
        echo "Neither $manifest nor $home_scm: nothing to restore."
    check_one "$manifest" "$HOME/.guix-profile" build -m "$manifest"
    check_one "$home_scm" "$HOME/.guix-home" home build "$home_scm"
    exit 0
fi

status=0 did=
if needs "$manifest" "$HOME/.guix-profile"; then
    {
        echo "Restoring ~/.guix-profile from $manifest"
        notify "Restoring your Guix packages" "from ${manifest#"$HOME"/}"
        warn_built "$manifest" build -m "$manifest"
        if "$guix" package -m "$manifest"; then
            did="$did packages"
        else
            echo "$prog: guix package -m $manifest failed"
            status=1
        fi
    }
fi
if needs "$home_scm" "$HOME/.guix-home"; then
    {
        echo "Restoring ~/.guix-home from $home_scm"
        notify "Restoring your Guix Home" "from ${home_scm#"$HOME"/}"
        warn_built "$home_scm" home build "$home_scm"
        if "$guix" home reconfigure "$home_scm"; then
            did="$did home"
        else
            echo "$prog: guix home reconfigure $home_scm failed"
            status=1
        fi
    }
fi

if [ "$status" != 0 ]; then
    notify -u critical "Restoring your Guix packages failed" "See ~/.cache/qubes-guix-profile.log"
elif [ -n "$did" ]; then
    echo "Restored:$did. Open a new terminal for them."
    notify "Your Guix packages are back" "Open a new terminal for them."
elif [ "$mode" != check ] && [ "$session" = 0 ]; then
    echo "Nothing to restore (no manifest or home.scm, or they're current)."
fi
exit "$status"
