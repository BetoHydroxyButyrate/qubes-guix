#!@SH@
# qubes-guix-update [-r|--reconfigure] [--guix-commit C | --head |
#                   --channel NAME=C ...] [--allow-downgrades] [GUIX-PULL-ARGS...]
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
#   --channel NAME=C move ONE channel's lock, the others staying where they
#                    are (repeatable): C a full commit, 'server' (the
#                    commit your substitute server last built it at), or
#                    'head' (unlocked: it follows its branch). E.g.
#                    --channel nonguix=server, --channel qubes=head.
#                    Builds of the others still match the server's; mixing
#                    commits the server never built together can mean
#                    building here (a nonguix newer than its Guix, say)
#   --gc             after the reconfigure: old system generations (and their
#                    GRUB entries) and every profile's old ones deleted, the
#                    garbage collected, identical files shared, and the freed
#                    blocks returned to dom0 (fstrim). E.g. in a template
#                    before shutting it down: its root is every AppVM's
#   --allow-downgrades  for the pull AND the reconfigure: needed once after a
#                    channel's history was rewritten
#   --no-monitor     from a terminal, it runs under a monitor (tmux: this
#                    update above, htop and what's being built or fetched
#                    below; its output also in /var/log/qubes-guix-update.log):
#                    this runs it plain instead. Without a terminal (qvm-run,
#                    qubes-guix-create) it always runs plain
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

# From a terminal, and not already in tmux: run this again under the
# monitor (tmux: this update above, htop and below right what's being
# built or fetched; in a qube with a netvm, the traffic per address).
monitor=@MONITOR@
use_monitor=1
for a in "$@"; do
    case $a in --no-monitor|-h|--help) use_monitor=0;; esac
done
if [ "$use_monitor" = 1 ] && [ -t 0 ] && [ -t 1 ] && [ -z "${TMUX:-}" ] &&
   [ -x "$monitor" ]; then
    right=netacct
    [ "$(@QUBESDB_READ@ /qubes-service/updates-proxy-setup 2>/dev/null)" = 1 ] &&
        right=builds     # all through the updates proxy: no per-address traffic
    QUBES_GUIX_MONITOR_SESSION=qubes-guix-update \
    QUBES_GUIX_MONITOR_LOG=/var/log/qubes-guix-update.log \
    QUBES_GUIX_MONITOR_RIGHT=$right \
        exec "$monitor" "$0" "$@"
fi

reconfigure=0
pin=
chans=
heads=
gc=0
downgrades=
while [ $# -gt 0 ]; do
    case $1 in
        -r|--reconfigure) reconfigure=1; shift;;
        --guix-commit) [ $# -ge 2 ] || die "$1 needs a commit"
                       pin=$2; reconfigure=1; shift 2;;
        --guix-commit=*) pin=${1#*=}; reconfigure=1; shift;;
        --head) pin='head'; reconfigure=1; shift;;
        --channel) [ $# -ge 2 ] || die "$1 needs NAME=COMMIT, NAME=server or NAME=head"
                   chans="$chans $2"; reconfigure=1; shift 2;;
        --channel=*) chans="$chans ${1#*=}"; reconfigure=1; shift;;
        --allow-downgrades) downgrades=--allow-downgrades; shift;;
        --gc) gc=1; reconfigure=1; shift;;
        --no-monitor) shift;;
        -h|--help) sed -n '2,/^# Installed by/p' "$0"; exit 0;;
        *) break;;
    esac
done
[ -n "$chans" ] && [ -n "$pin" ] &&
    die "--channel moves one channel's lock: not with --guix-commit or --head"
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
    proxy=1
else
    proxy=0
fi

# Building Guix itself (when the pull or the reconfigure finds no substitute
# for it) takes several GB of memory. Warn a small qube now, rather than have
# that build killed by the kernel (out of memory) an hour in.
qube=$(@QUBESDB_READ@ /name 2>/dev/null || echo "<this qube>")
mem=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
if [ "${mem:-0}" -lt 3800 ]; then
    echo "$prog: warning: this qube has $mem MiB. If Guix has to be built here
(no substitute for it), that needs several GB, and the build can be killed for
lack of memory. To be safe, shut it down and in dom0:
  qvm-prefs $qube memory 8000; qvm-prefs $qube maxmem 8000" >&2
fi

# STATUS WHAT: after a failed pull or reconfigure. 137 is SIGKILL, from the
# kernel's out-of-memory killer as a rule: say so, rather than leave a bare
# "Killed".
failed() {
    if [ "$1" = 137 ]; then
        echo "$prog: $2 was killed (SIGKILL): most likely out of memory
(sudo dmesg | grep -i 'killed process'). Shut this qube down, give it more
memory, and run this again. In dom0:
  qvm-prefs $qube memory 8000; qvm-prefs $qube maxmem 8000" >&2
    fi
    exit "$1"
}

# Root's pulled Guix once there is one, else the system's.
current=/root/.config/guix/current/bin/guix
guix=$current
[ -x "$guix" ] || guix=/run/current-system/profile/bin/guix

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One test request through the updates proxy before the pull. When dom0's
# policy denies qubes.UpdatesProxy, the qrexec client's "Request refused"
# comes back where the HTTP answer should be, and the pull dies with a
# backtrace ("http parser error", "Bad Response-Line"): say why instead.
if [ "$proxy" = 1 ]; then
    cat > "$tmp/probe.scm" <<'PROBE'
(use-modules (ice-9 rdelim))
(display
 (catch #t
   (lambda ()
     (let ((s (socket PF_INET SOCK_STREAM 0)))
       (false-if-exception (setsockopt s SOL_SOCKET SO_RCVTIMEO '(60 . 0)))
       (connect s AF_INET (inet-pton AF_INET "127.0.0.1") 8082)
       (display "CONNECT git.guix.gnu.org:443 HTTP/1.1\r\nHost: git.guix.gnu.org:443\r\n\r\n" s)
       (force-output s)
       (let ((line (read-line s)))
         (close-port s)
         (if (eof-object? line) "" (string-trim-right line #\return)))))
   (lambda _ "")))
(newline)
PROBE
    answer=$("$guix" repl -- "$tmp/probe.scm" 2>/dev/null) || answer=
    case $answer in
        HTTP/*' 200'*) ;;
        'Request refused'*)
            die "dom0's policy refuses this qube's updates proxy calls
(qubes.UpdatesProxy answered 'Request refused'). dom0's default policy allows
them for templates (@type:TemplateVM). For a qube of another class, add a rule
for it in /etc/qubes/policy.d, or give it a netvm and turn the proxy off:
  qvm-prefs <qube> netvm <netvm>; qvm-service <qube> updates-proxy-setup off";;
        *)
            echo "$prog: warning: a test request through the updates proxy got:
  ${answer:-no answer}
The UpdateVM may not reach the Internet (or the proxy isn't running there):
the pull may fail." >&2;;
    esac
fi

# --guix-commit server: the commits the substitute server last built, one
# "NAME COMMIT" line per channel (its /channel-commits), or Guix's alone
# (/guix-commit, from servers that publish only that). Fetched with
# 'guix download' (through the proxy, if any): no curl needed.
commits=
srv_commits=
case " $chans " in *=server\ *) need_server=1;; *) need_server=0;; esac
if [ "$pin" = server ] || [ "$need_server" = 1 ]; then
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
        if [ "$need_server" = 1 ]; then
            # --channel NAME=server: only the commits named, below.
            srv_commits=$commits
            commits=
        else
            pin=$(printf '%s\n' "$commits" | awk '$1 == "guix" {print $2; exit}')
            [ -n "$pin" ] || die "$server/channel-commits: no guix line"
            echo "$prog: $server last built these channels; locking to them:"
            printf '%s\n' "$commits" | sed 's/^/    /'
        fi
    else
        [ "$need_server" = 0 ] ||
            die "--channel NAME=server: $server publishes no /channel-commits"
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
# --channel NAME=C: that channel's lock alone, in #:channel-commits (and in
# #:guix-commit, which wins for guix, if the config has one).
if [ -n "$chans" ]; then
    new=$(QUBES_IN="$tmp/config.scm" QUBES_PRINT=channel-commits "$guix" repl -- @WRAP_CONFIG@) ||
        die "couldn't read #:channel-commits from $config"
    for spec in $chans; do
        name=${spec%%=*} c=${spec#*=}
        { [ "$name" != "$spec" ] && [ -n "$name" ] && [ -n "$c" ]; } ||
            die "--channel $spec: NAME=COMMIT, NAME=server or NAME=head"
        case $name in *[!a-z0-9-]*) die "--channel: bad channel name '$name'";; esac
        case $c in
            server)
                c=$(printf '%s\n' "$srv_commits" | awk -v n="$name" '$1 == n {print $2; exit}')
                [ -n "$c" ] || die "--channel $spec: $server publishes no commit for '$name'";;
            head) ;;
            *[!0-9a-f]*) die "--channel $spec: '$c' isn't a commit hash (or server, head)";;
            *) [ ${#c} -eq 40 ] || die "--channel $spec: a full 40-digit commit hash, please";;
        esac
        new=$(printf '%s\n' "$new" | awk -v n="$name" 'NF && $1 != n')
        if [ "$c" = head ]; then
            heads="$heads $name"
            echo "$prog: $name: unlocked, follows its branch head"
            v='#f'
        else
            new=$(printf '%s\n%s %s\n' "$new" "$name" "$c" | awk NF)
            echo "$prog: $name: locked at $c"
            v="\"$c\""
        fi
        if [ "$name" = guix ] && grep -q '#:guix-commit' "$tmp/config.scm"; then
            sed 's/#:guix-commit[[:space:]]*\("[0-9a-f]*"\|#f\)/#:guix-commit '"$(printf '%s' "$v" | sed 's/[\&/]/\\&/g')"'/' \
                "$tmp/config.scm" > "$tmp/config.new"
            grep -q "#:guix-commit $v" "$tmp/config.new" ||
                die "couldn't change #:guix-commit in $config; edit it by hand"
            mv "$tmp/config.new" "$tmp/config.scm"
        fi
    done
    wrap_config QUBES_CHANNEL_COMMITS="$new" ||
        die "couldn't set #:channel-commits in $config"
    commits=$new
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
# --channel NAME=head: those follow their head in this pull (and, unlocked,
# from the reconfigure on).
if [ -n "$heads" ] && [ "$follow" != all ]; then
    follow=$(echo $follow $heads)
fi
if [ -n "$commits" ]; then
    pins=$(printf '%s\n' "$commits" | awk '{printf "(%s . \"%s\") ", $1, $2}')
elif [ -n "$pin" ] && [ "$pin" != head ]; then
    pins="(guix . $value)"
elif [ "$pin" != head ]; then
    # The config's own locks, so channels new to it (below: not yet in
    # /etc/guix/channels.scm) are pulled at their locked commits too. Not
    # guix's when #:guix-commit is there: that wins, and the file has it.
    pins=$(QUBES_IN=$config QUBES_PRINT=channel-commits "$guix" repl -- @WRAP_CONFIG@ |
           if grep -q '#:guix-commit[[:space:]]*"' "$config"; then awk '$1 != "guix"'; else cat; fi |
           awk 'NF == 2 {printf "(%s . \"%s\") ", $1, $2}') ||
        die "couldn't read #:channel-commits from $config"
else
    pins=
fi
# The config's #:extra-channels, also in this pull: /etc/guix/channels.scm
# only has them from the reconfigure on, so a channel just added to the
# config would otherwise be pulled only by the next update, and this
# reconfigure built without it (its packages skipped, the system's guix
# without the channel).
extra=$(QUBES_IN=$config QUBES_PRINT=extra-channels "$guix" repl -- @WRAP_CONFIG@) ||
    die "couldn't read #:extra-channels from $config"
if [ -z "$pins" ] && [ -z "$follow" ] && [ -z "$extra" ]; then
    "$guix" pull -C /etc/guix/channels.scm ${downgrades:+"$downgrades"} "$@" ||
        failed $? "guix pull"
else
    [ -n "$follow" ] && echo "$prog: following the branch head: $follow"
    case $follow in
        all) follow_scm="'all";;
        *)   follow_scm="'($follow)";;
    esac
    [ -n "$follow" ] || follow_scm="'()"
    { printf '%s\n' "(let* ((pins '($pins))" \
          "       (follow $follow_scm)" \
          "       (extra ${extra:-(list)})" \
          "       (base"
      cat /etc/guix/channels.scm
      printf '%s\n' "        )" \
          "       ;; The config's extra channels that channels.scm hasn't yet." \
          "       (all (append base" \
          "                    (filter (lambda (c)" \
          "                              (not (memq (channel-name c)" \
          "                                         (map channel-name base))))" \
          "                            extra))))" \
          "  (map (lambda (c)" \
          "         (let ((pin (assq-ref pins (channel-name c))))" \
          "           (cond ((or (eq? follow 'all) (memq (channel-name c) follow))" \
          "                  (channel (inherit c) (commit #f)))" \
          "                 (pin (channel (inherit c) (commit pin)))" \
          "                 (else c))))" \
          "       all))"
    } > "$tmp/channels.scm"
    "$guix" pull -C "$tmp/channels.scm" ${downgrades:+"$downgrades"} "$@" ||
        failed $? "guix pull"
fi

if [ "$reconfigure" = 1 ]; then
    "$current" system reconfigure ${downgrades:+"$downgrades"} "$config" ||
        failed $? "guix system reconfigure"

    # The Qubes menu, as other templates' package managers do after an
    # install: advertise default-menu-items again (from the new system's
    # applications), and send dom0 the list of applications
    # (qubes.SyncAppMenus, fed by qubes.GetAppmenus). Without it, dom0's
    # list is whatever it read at the first boot.
    herd start qubes-features-request >/dev/null 2>&1 || true
    if @QREXEC_CLIENT_VM@ dom0 qubes.SyncAppMenus @GET_APPMENUS@ \
           </dev/null >/dev/null 2>&1; then
        echo "$prog: sent dom0 this qube's applications (the Qubes menu)"
    else
        echo "$prog: note: couldn't send dom0 the applications for the Qubes
menu (policy?); in dom0: qvm-sync-appmenus <this qube>" >&2
    fi
fi

# --gc: what this and earlier updates left behind. 'guix system
# delete-generations' first, which also drops their GRUB entries (a plain
# 'guix gc -d' would leave entries pointing at nothing).
if [ "$gc" = 1 ]; then
    used() { df -B1M --output=used / | tail -n1 | tr -d ' '; }
    before=$(used)
    echo "$prog: cleaning the store: old generations, garbage, identical files shared"
    "$current" system delete-generations || echo "$prog: note: guix system delete-generations failed" >&2
    "$current" gc --delete-generations || echo "$prog: note: guix gc -d failed" >&2
    "$current" gc --optimize >/dev/null || echo "$prog: note: guix gc --optimize failed" >&2
    "$(command -v fstrim || echo /run/current-system/profile/sbin/fstrim)" -a >/dev/null 2>&1 || echo "$prog: note: fstrim failed (freed blocks stay allocated in dom0)" >&2
    echo "$prog: the root uses ${before} MiB before, $(used) MiB after; freed blocks returned to dom0"
fi
