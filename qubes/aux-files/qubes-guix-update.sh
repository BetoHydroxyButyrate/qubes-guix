#!@SH@
# qubes-guix-update [-r|--reconfigure] [--guix-commit C | --head] [GUIX-PULL-ARGS...]
#   guix pull, through the Qubes updates proxy when this qube has one (a
#   template with updates-proxy-setup); with -r, then also
#   sudo guix system reconfigure ${QUBES_GUIX_CONFIG:-/etc/config.scm}
#   --guix-commit C  lock this system's Guix at commit C: sets #:guix-commit
#                    in the config, pulls Guix at C and reconfigures
#   --head           unlock: follow the branch head again (likewise)
# Installed by the qubes channel (qubes/services/agent.scm).
set -eu

prog=${0##*/}
die() { echo "$prog: $*" >&2; exit 1; }

reconfigure=0
pin=
while [ $# -gt 0 ]; do
    case $1 in
        -r|--reconfigure) reconfigure=1; shift;;
        --guix-commit) [ $# -ge 2 ] || die "$1 needs a commit"
                       pin=$2; reconfigure=1; shift 2;;
        --guix-commit=*) pin=${1#*=}; reconfigure=1; shift;;
        --head) pin='head'; reconfigure=1; shift;;
        -h|--help) sed -n '2,8p' "$0"; exit 0;;
        *) break;;
    esac
done
config=${QUBES_GUIX_CONFIG:-/etc/config.scm}

proxy=0
[ "$(@QUBESDB_READ@ /qubes-service/updates-proxy-setup 2>/dev/null)" = 1 ] && proxy=1
if [ "$proxy" = 1 ]; then
    # Right after boot (e.g. qubes-guix-create --unattended's first update)
    # the proxy may still be starting: give it a minute.
    # Look for the listening socket (127.0.0.1:8082 = 0100007F:1F92, state
    # 0A = LISTEN) rather than connecting: bash-minimal has no /dev/tcp, and
    # each connection would start a qubes.UpdatesProxy call.
    i=0
    while ! grep -q ' 0100007F:1F92 00000000:0000 0A ' /proc/net/tcp; do
        i=$((i + 1))
        [ "$i" -lt 60 ] || die "the Qubes updates proxy (127.0.0.1:8082) isn't
listening; see: sudo herd status qubes-updates-proxy"
        sleep 1
    done
fi

if [ -n "$pin" ]; then
    case $pin in
        head) value='#f';;
        *[!0-9a-f]*) die "--guix-commit: '$pin' isn't a commit hash";;
        *) [ ${#pin} -ge 7 ] || die "--guix-commit: '$pin' is too short (7+ hex digits)"
           value="\"$pin\"";;
    esac
    [ -f "$config" ] || die "no such file: $config"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    # 1. The lock in the configuration: #:guix-commit on qubes-operating-system.
    if grep -q '#:guix-commit' "$config"; then
        sed 's/#:guix-commit[[:space:]]*\("[0-9a-f]*"\|#f\)/#:guix-commit '"$(printf '%s' "$value" | sed 's/[\&/]/\\&/g')"'/' \
            "$config" > "$tmp/config.scm"
        grep -q "#:guix-commit $value" "$tmp/config.scm" ||
            die "couldn't change #:guix-commit in $config; edit it by hand"
    elif [ "$pin" = head ]; then
        cp "$config" "$tmp/config.scm"         # not locked: nothing to change
    else
        set +e
        QUBES_IN=$config QUBES_OUT=$tmp/config.scm QUBES_GUIX_COMMIT=$pin \
            guix repl -- @WRAP_CONFIG@ >/dev/null
        status=$?
        set -e
        [ "$status" = 0 ] || die "couldn't add #:guix-commit to $config: add
 #:guix-commit \"$pin\" to its (qubes-operating-system ...) form by hand"
    fi
    if ! cmp -s "$config" "$tmp/config.scm"; then
        echo "$prog: $config: #:guix-commit $value (old one: $config.bak)"
        sudo cp "$config" "$config.bak"
        sudo cp "$tmp/config.scm" "$config"
    fi

    # 2. This pull: the system's channels with Guix at the new lock. (Until
    # the reconfigure below, /etc/guix/channels.scm still has the old one.)
    cat > "$tmp/channels.scm" <<SCM
(map (lambda (c)
       (if (eq? (channel-name c) 'guix)
           (channel (inherit c) (commit $value))
           c))
     (call-with-input-file "/etc/guix/channels.scm"
       (lambda (port)
         (let loop ((value '()))
           (let ((form (read port)))
             (if (eof-object? form)
                 value
                 (loop (eval form (current-module)))))))))
SCM
    pguix pull -C "$tmp/channels.scm" "$@"
else
    pguix pull "$@"
fi

if [ "$reconfigure" = 1 ]; then
    guix=$HOME/.config/guix/current/bin/guix
    [ -x "$guix" ] || guix=guix
    # Builds and substitutes go through guix-daemon, which has the proxy.
    # But (qubes system) builds the system's own guix from the channels
    # (guix-for-channels), which makes root fetch them into its own cache:
    # in a template, through the proxy, which sudo would otherwise drop.
    set --
    if [ "$proxy" = 1 ]; then
        set -- http_proxy=http://127.0.0.1:8082 https_proxy=http://127.0.0.1:8082
    fi
    sudo env "$@" "$guix" system reconfigure "$config"
fi
