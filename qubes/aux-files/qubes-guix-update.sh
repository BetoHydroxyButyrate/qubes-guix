#!@SH@
# qubes-guix-update [-r|--reconfigure] [--guix-commit C | --head] [--allow-downgrades]
#                   [GUIX-PULL-ARGS...]
#   As root (it uses sudo if needed): guix pull, through the Qubes updates
#   proxy when this qube has one (a template with updates-proxy-setup);
#   with -r, then guix system reconfigure ${QUBES_GUIX_CONFIG:-/etc/config.scm}
#   --guix-commit C  lock this system's Guix at commit C: sets #:guix-commit
#                    in the config, pulls Guix at C and reconfigures
#   --guix-commit server  lock EVERY channel at the commits your substitute
#                    server last built (its /channel-commits; the server is
#                    the first of #:extra-substitute-urls), so its builds
#                    match: sets #:channel-commits (and #:guix-commit, if
#                    the config has one); Guix alone from /guix-commit if the
#                    server doesn't publish /channel-commits
#   --head           unlock: every channel follows its branch head again
#                    (#:guix-commit #f, #:channel-commits '())
#   --allow-downgrades  for the pull AND the reconfigure: needed once after a
#                    channel's history was rewritten
#   Channels in the config's #:follow-head always follow their branch head,
#   in this pull too: e.g. set #:follow-head '(qubes), then run with -r.
# Installed by the qubes channel (qubes/services/agent.scm).
#
# Root does the update, as for other Qubes templates: one Guix checkout and
# pulled Guix (root's, on the root volume), from which the reconfigure
# builds the system's guix. Users, in the template and in AppVMs, use that
# system guix: the level the template was updated to.
set -eu

prog=${0##*/}
die() { echo "$prog: $*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    # -H: root's HOME, so root's ~/.cache/guix and ~/.config/guix.
    exec sudo -H QUBES_GUIX_CONFIG="${QUBES_GUIX_CONFIG:-}" "$0" "$@"
fi

reconfigure=0
pin=
downgrades=
while [ $# -gt 0 ]; do
    case $1 in
        -r|--reconfigure) reconfigure=1; shift;;
        --guix-commit) [ $# -ge 2 ] || die "$1 needs a commit"
                       pin=$2; reconfigure=1; shift 2;;
        --guix-commit=*) pin=${1#*=}; reconfigure=1; shift;;
        --head) pin='head'; reconfigure=1; shift;;
        --allow-downgrades) downgrades=--allow-downgrades; shift;;
        -h|--help) sed -n '2,20p' "$0"; exit 0;;
        *) break;;
    esac
done
config=${QUBES_GUIX_CONFIG:-}
[ -n "$config" ] || config=/etc/config.scm
[ -f "$config" ] || die "no such file: $config"

# A user's own pulled Guix (~/.config/guix/current, which their PATH puts
# first) overrides the system's for that user, and no longer follows the
# template's updates. (The profile it points to, under
# /var/guix/profiles/per-user, stays after the link is removed: harmless,
# so check the link.)
for p in /var/guix/profiles/per-user/*/current-guix; do
    [ -e "$p" ] || continue
    u=${p#/var/guix/profiles/per-user/}; u=${u%%/*}
    [ "$u" = root ] && continue
    # (Not getent: glibc's tools aren't in the system profile.)
    h=$(grep "^$u:" /etc/passwd | cut -d: -f6)
    [ -n "$h" ] && [ -e "$h/.config/guix/current" ] || continue
    echo "$prog: note: user '$u' has their own pulled Guix, which overrides the
system's for them. To use the system's: rm ~$u/.config/guix/current (as $u)." >&2
done

if [ "$(@QUBESDB_READ@ /qubes-service/updates-proxy-setup 2>/dev/null)" = 1 ]; then
    # Right after boot (e.g. qubes-guix-create --unattended's first update)
    # the proxy may still be starting: give it a minute. Look for the
    # listening socket (127.0.0.1:8082 = 0100007F:1F92, state 0A = LISTEN)
    # rather than connecting: each connection starts a qubes.UpdatesProxy call.
    i=0
    while ! grep -q ' 0100007F:1F92 00000000:0000 0A ' /proc/net/tcp; do
        i=$((i + 1))
        [ "$i" -lt 60 ] || die "the Qubes updates proxy (127.0.0.1:8082) isn't
listening; see: herd status qubes-updates-proxy"
        sleep 1
    done
    # For the pull (libgit2, in this process) and for the reconfigure, which
    # fetches the channels again to build the system's guix. Substitutes go
    # through guix-daemon, which qubes-updates-proxy already pointed here.
    http_proxy=http://127.0.0.1:8082
    https_proxy=$http_proxy
    export http_proxy https_proxy
    echo "$prog: through the Qubes updates proxy ($http_proxy)"
fi

# Root's pulled Guix once there is one, else the system's.
current=/root/.config/guix/current/bin/guix
guix=$current
[ -x "$guix" ] || guix=/run/current-system/profile/bin/guix

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --guix-commit server: the commits the substitute server last built, one
# "NAME COMMIT" line per channel (its /channel-commits), or Guix's alone
# (/guix-commit, from servers that publish only that). Fetched with
# 'guix download' (through the proxy, if any): no curl needed.
commits=
if [ "$pin" = server ]; then
    urls=/etc/qubes-guix-substitute-urls
    [ -s "$urls" ] || die "--guix-commit server: no substitute server in the
config (#:extra-substitute-urls) to ask"
    server=$(head -n1 "$urls")
    server=${server%/}
    file=$("$guix" download "$server/channel-commits" 2>/dev/null | head -n1) ||
        file=
    if [ -n "$file" ] && [ -f "$file" ]; then
        commits=$(grep -v '^[[:space:]]*$' "$file")
        printf '%s\n' "$commits" | while read -r name c rest; do
            case $c in
                *[!0-9a-f]*|'') die "$server/channel-commits: '$name $c' isn't NAME COMMIT";;
            esac
            [ ${#c} -eq 40 ] && [ -z "$rest" ] ||
                die "$server/channel-commits: '$name $c $rest' isn't NAME COMMIT"
        done || exit 1
        pin=$(printf '%s\n' "$commits" | awk '$1 == "guix" {print $2; exit}')
        [ -n "$pin" ] || die "$server/channel-commits: no guix line"
        echo "$prog: $server last built these channels; locking to them:"
        printf '%s\n' "$commits" | sed 's/^/    /'
    else
        file=$("$guix" download "$server/guix-commit" 2>/dev/null | head -n1) ||
            file=
        [ -n "$file" ] && [ -f "$file" ] ||
            die "--guix-commit server: couldn't fetch $server/channel-commits or /guix-commit"
        pin=$(tr -d ' \n' < "$file")
        case $pin in
            *[!0-9a-f]*|'') die "$server/guix-commit: '$pin' isn't a commit hash";;
        esac
        [ ${#pin} -eq 40 ] || die "$server/guix-commit: '$pin' isn't a full commit hash"
        echo "$prog: $server publishes only /guix-commit; locking Guix alone, to $pin"
    fi
fi

# wrap_config OUT-ENV...: run wrap-config.guile on $tmp/config.scm with the
# given QUBES_* settings; its result replaces $tmp/config.scm. Status 3
# (nothing to change) is fine.
wrap_config() {
    set +e
    env QUBES_IN="$tmp/config.scm" QUBES_OUT="$tmp/config.new" "$@" \
        "$guix" repl -- @WRAP_CONFIG@ >/dev/null
    status=$?
    set -e
    case $status in
        0) mv "$tmp/config.new" "$tmp/config.scm";;
        3) ;;
        *) return 1;;
    esac
}

cp "$config" "$tmp/config.scm"
if [ -n "$pin" ]; then
    case $pin in
        head) value='#f';;
        *[!0-9a-f]*) die "--guix-commit: '$pin' isn't a commit hash";;
        *) [ ${#pin} -ge 7 ] || die "--guix-commit: '$pin' is too short (7+ hex digits)"
           value="\"$pin\"";;
    esac

    # 1. The locks in the configuration. #:guix-commit: changed if it's
    # there; added for --guix-commit C (with all the server's commits, the
    # Guix one is in #:channel-commits).
    if grep -q '#:guix-commit' "$tmp/config.scm"; then
        sed 's/#:guix-commit[[:space:]]*\("[0-9a-f]*"\|#f\)/#:guix-commit '"$(printf '%s' "$value" | sed 's/[\&/]/\\&/g')"'/' \
            "$tmp/config.scm" > "$tmp/config.new"
        grep -q "#:guix-commit $value" "$tmp/config.new" ||
            die "couldn't change #:guix-commit in $config; edit it by hand"
        mv "$tmp/config.new" "$tmp/config.scm"
    elif [ "$pin" != head ] && [ -z "$commits" ]; then
        wrap_config QUBES_GUIX_COMMIT="$pin" ||
            die "couldn't add #:guix-commit to $config: add
 #:guix-commit \"$pin\" to its (qubes-operating-system ...) form by hand"
    fi
    # #:channel-commits: the server's (replaced, or added), or '() for --head.
    if [ -n "$commits" ]; then
        wrap_config QUBES_CHANNEL_COMMITS="$commits" ||
            die "couldn't set #:channel-commits in $config: set it by hand to
 '((NAME . \"COMMIT\") ...) from $server/channel-commits"
    elif [ "$pin" = head ] && grep -q '#:channel-commits' "$tmp/config.scm"; then
        wrap_config QUBES_CHANNEL_COMMITS= ||
            die "couldn't clear #:channel-commits in $config; set it to '() by hand"
    fi
fi
if ! cmp -s "$config" "$tmp/config.scm"; then
    echo "$prog: $config: locks updated (old one: $config.bak)"
    cp "$config" "$config.bak"
    cp "$tmp/config.scm" "$config"
fi

# 2. This pull: the system's channels, with the new locks and #:follow-head
# applied (until the reconfigure below, /etc/guix/channels.scm still has the
# old ones). /etc/guix/channels.scm is one (list (channel ...) ...)
# expression: wrap its text, rather than reading the file from inside the
# channels file (Guix evaluates those without file access: no
# call-with-input-file).
follow=$(QUBES_IN=$config QUBES_PRINT=follow-head "$guix" repl -- @WRAP_CONFIG@) ||
    die "couldn't read #:follow-head from $config"
[ "$pin" = head ] && follow=all
if [ -n "$commits" ]; then
    pins=$(printf '%s\n' "$commits" | awk '{printf "(%s . \"%s\") ", $1, $2}')
elif [ -n "$pin" ] && [ "$pin" != head ]; then
    pins="(guix . $value)"
else
    pins=
fi
if [ -z "$pins" ] && [ -z "$follow" ]; then
    "$guix" pull -C /etc/guix/channels.scm ${downgrades:+"$downgrades"} "$@"
else
    [ -n "$follow" ] && echo "$prog: following the branch head: $follow"
    case $follow in
        all) follow_scm="'all";;
        *)   follow_scm="'($follow)";;
    esac
    { printf '%s\n' "(let ((pins '($pins))" \
          "      (follow $follow_scm))" \
          "  (map (lambda (c)" \
          "         (let ((pin (assq-ref pins (channel-name c))))" \
          "           (cond ((or (eq? follow 'all) (memq (channel-name c) follow))" \
          "                  (channel (inherit c) (commit #f)))" \
          "                 (pin (channel (inherit c) (commit pin)))" \
          "                 (else c))))"
      cat /etc/guix/channels.scm
      printf '%s\n' "))"
    } > "$tmp/channels.scm"
    "$guix" pull -C "$tmp/channels.scm" ${downgrades:+"$downgrades"} "$@"
fi

if [ "$reconfigure" = 1 ]; then
    "$current" system reconfigure ${downgrades:+"$downgrades"} "$config"
fi
