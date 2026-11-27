#!/bin/sh
# Unit test for the daily-wash decision in kindle/dash-main.sh.
#   sh tests/wash_due.sh
# Runs with dash/ash only: no Pillow, no network, no device.

set -u
here=$(cd "$(dirname "$0")" && pwd)

# stub the clock before the script defines anything that reads it
FAKE_H=00
FAKE_D=2026-11-27
date() {
    case "${1:-}" in
        +%H) echo "$FAKE_H" ;;
        +%F) echo "$FAKE_D" ;;
        *)   command date "$@" ;;
    esac
}

DASH_LIB_ONLY=1
DASH_LOG=${DASH_LOG:-/dev/null}
. "$here/../kindle/dash-main.sh"

fail=0
expect() {  # $1 want(due|no)  $2 hour  $3 date  $4 washed-today
    FAKE_H=$2
    FAKE_D=$3
    washed=$4
    if wash_due; then got=due; else got=no; fi
    if [ "$got" = "$1" ]; then
        printf 'ok    hour=%s date=%s washed=%s -> %s\n' "$2" "$3" "${4:-none}" "$got"
    else
        printf 'FAIL  hour=%s date=%s washed=%s -> %s (wanted %s)\n' \
               "$2" "$3" "${4:-none}" "$got" "$1"
        fail=1
    fi
}

echo "WASH_HOUR=$WASH_HOUR WASH_WINDOW=$WASH_WINDOW"
expect no  02 2026-11-27 ""
expect due 03 2026-11-27 ""
expect due 03 2026-11-27 none            # 03:00, and again later in the hour
expect due 04 2026-11-27 ""              # inside the 2 hour window
expect no  05 2026-11-27 ""              # window closed, skip to tomorrow
expect no  03 2026-11-27 2026-11-27      # already washed today
expect due 03 2026-11-27 2026-11-26      # washed yesterday, due again
expect no  23 2026-11-27 ""              # never at 23:00
expect due 04 2026-11-28 ""              # next day, fresh
expect no  00 2026-11-28 2026-11-27      # new day but before the window: waits for 03:00

# custom hour, including an unpadded value (10# must handle 8 and 9)
WASH_HOUR=9 WASH_WINDOW=1
expect no  08 2026-11-27 ""
expect due 09 2026-11-27 ""
expect no  10 2026-11-27 ""

WASH_HOUR=3 WASH_WINDOW=1
expect no  02 2026-11-27 ""
expect due 03 2026-11-27 ""

[ "$fail" = 0 ] && echo "all cases passed" || echo "FAILURES"
exit "$fail"
