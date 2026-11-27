#!/bin/sh
# kindle-dash launcher - the file /etc/init.d/dash execs.
#
# Three jobs, deliberately small:
#   1. log that it ran (without this, a silent failure is indistinguishable from
#      a boot hook that never fired);
#   2. self-update dash-main.sh from the server, syntax-checked, so a fix ships
#      with a reboot instead of another USB trip;
#   3. hand over to dash-main.sh.

BASE=/mnt/us/kindle-dash
LOG=$BASE/dash.log
MAIN=$BASE/dash-main.sh
URL_BASE=$(cat "$BASE/url" 2>/dev/null | tr -d '\r\n ')

echo "$(date '+%F %T') launcher: start" >>"$LOG"

if [ -n "$URL_BASE" ]; then
    if /usr/bin/curl -sf -m 20 -o "$MAIN.new" "$URL_BASE/files/dash-main.sh" 2>>"$LOG"; then
        if [ -s "$MAIN.new" ] && /bin/sh -n "$MAIN.new" 2>>"$LOG"; then
            if cmp -s "$MAIN.new" "$MAIN"; then
                echo "$(date '+%F %T') launcher: dash-main.sh unchanged" >>"$LOG"
            else
                mv "$MAIN.new" "$MAIN" && chmod 755 "$MAIN" &&
                    echo "$(date '+%F %T') launcher: dash-main.sh updated from $URL_BASE" >>"$LOG"
            fi
        else
            echo "$(date '+%F %T') launcher: downloaded dash-main.sh failed the syntax check, keeping the old one" >>"$LOG"
        fi
        rm -f "$MAIN.new"
    else
        echo "$(date '+%F %T') launcher: no update available from ${URL_BASE:-nowhere}" >>"$LOG"
    fi
fi

if [ ! -f "$MAIN" ]; then
    echo "$(date '+%F %T') launcher: ABORT, $MAIN missing" >>"$LOG"
    exit 1
fi
if /bin/sh -n "$MAIN" 2>>"$LOG"; then
    echo "$(date '+%F %T') launcher: $MAIN parses, handing over" >>"$LOG"
else
    echo "$(date '+%F %T') launcher: SYNTAX ERROR in $MAIN" >>"$LOG"
    exit 1
fi

exec /bin/sh "$MAIN" </dev/null >>"$LOG" 2>&1
