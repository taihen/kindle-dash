#!/bin/sh
# kindle-dash device side - runs on a jailbroken Kindle 4 (firmware 4.1.x).
#
# Each cycle: stop the reader UI, pull one PNG over plain HTTP, blit it to the
# framebuffer with eips, then sleep until the next refresh. Between refreshes it
# watches the framebuffer and takes the screen back if anything repaints it.
#
# Why plain HTTP: the *main* rootfs (/dev/mmcblk0p1) is a full Debian userland
# with /usr/bin/curl, wget, nc and ssh. Probes run from the jailbreak's
# runme.sh see the diags rootfs instead and report no HTTP client at all, which
# is what sent an earlier version down an ssh-forced-command path.
#
# Burn-in / retained-image handling:
#   1. every update is a full refresh (`eips -g FILE -f`). Do NOT pass
#      `-w gc16`: this eips does not support it, prints pixel_in_range errors,
#      draws NOTHING and still exits 0;
#   2. the whole layout drifts a pixel or two every hour, so no glyph edge
#      sits on the same pixels for weeks;
#   3. once a day, from 03:00, the panel gets an inverted frame for two minutes,
#      which drives the pixels that are normally white.
#
# Written for the shell this device actually has: no awk, no `grep -w`, no
# `grep -E`, no `command -v`. Case/read loops and explicit binary paths only.

INTERVAL="${DASH_INTERVAL:-300}"        # seconds between refreshes
OFFSET_EVERY="${DASH_OFFSET_EVERY:-12}" # refreshes between layout drift steps
WASH_HOUR="${DASH_WASH_HOUR:-03}"       # local hour of the daily inverted frame
WASH_WINDOW="${DASH_WASH_WINDOW:-2}"    # hours after that in which a missed wash still runs
WASH_HOLD="${DASH_WASH_HOLD:-120}"      # seconds the inverted frame stays up
# 0 = plain sleep between refreshes. 1 = suspend to RAM, which needs a working
# RTC wake AND a resume path the firmware is happy with: on this K4, suspending
# with the reader framework killed produced a full reboot every cycle (the panel
# only ever showed the boot splash), so sleep is the default.
SUSPEND="${DASH_SUSPEND:-0}"

BASE=/mnt/us/kindle-dash
PNG=/tmp/kindle-dash.png
STATE=$BASE/last-frame
LOG=$BASE/dash.log
URL_BASE=${DASH_URL_BASE:-}
# The server URL lives in /mnt/us/kindle-dash/url (one line, e.g.
# http://192.168.1.10:8099), so moving the renderer is a file edit rather than a
# script redeploy - and so this repo has no hardcoded host in it.
if [ -f "$BASE/url" ]; then
    URL_OVERRIDE=$(cat "$BASE/url" 2>/dev/null | tr -d '\r\n ')
    [ -n "$URL_OVERRIDE" ] && URL_BASE=$URL_OVERRIDE
fi

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH
export PATH

EIPS=""
for c in /usr/sbin/eips /usr/bin/eips /sbin/eips /bin/eips; do
    [ -x "$c" ] && EIPS=$c && break
done
[ -n "$EIPS" ] || EIPS=eips

CURL=""
for c in /usr/bin/curl /bin/curl /usr/local/bin/curl; do
    [ -x "$c" ] && CURL=$c && break
done
[ -n "$CURL" ] || CURL=curl

log() {
    # cheap log rotation: this file is the only debugging channel without SSH
    [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 65536 ] && mv "$LOG" "$LOG.1"
    echo "$(date '+%F %T') $*" >>"$LOG"
}

# ---------------------------------------------------------------- transport
# $1 = path+query on the server, e.g. "dash.png?dx=2&dy=1"
# The real rootfs ships curl (2020) and wget; the diags rootfs does not, which is
# what made every earlier probe look like "no HTTP client on this device".
pull() {
    "$CURL" -sf -m 30 -o "$PNG.new" "$URL_BASE/$1" 2>>"$LOG" || {
        rc=$?
        log "curl failed (rc=$rc) for $1"
        rm -f "$PNG.new"
        return 1
    }
    if [ ! -s "$PNG.new" ]; then
        log "pull produced an empty file for $1"
        rm -f "$PNG.new"
        return 1
    fi
    mv "$PNG.new" "$PNG"
}

fb_hash() {
    md5sum /dev/fb0 2>/dev/null | cut -d' ' -f1
}

show() {
    # `-w gc16` is NOT supported by the eips on 4.1.x: it prints
    # "pixel_in_range> ... not in range" and draws nothing, while still
    # returning 0. So: no waveform flag, and verify the framebuffer actually
    # changed instead of trusting the exit code.
    #
    # The verification compares against the framebuffer hash produced the last
    # time THIS frame was drawn, kept on the FAT partition so a restart does not
    # mistake "already showing" for "draw failed".
    md5=$(md5sum "$PNG" 2>/dev/null | cut -d' ' -f1)
    seen_png=""
    seen_fb=""
    [ -f "$STATE" ] && read -r seen_png seen_fb <"$STATE"

    "$EIPS" -g "$PNG" -f >>"$LOG" 2>&1
    rc=$?
    after=$(fb_hash)
    if [ "$rc" != "0" ]; then
        log "eips failed (rc=$rc)"
        return 1
    fi
    if [ "$md5" = "$seen_png" ] && [ "$after" != "$seen_fb" ]; then
        log "draw did not take: fb=$after but this frame produced $seen_fb before"
        return 1
    fi
    echo "$md5 $after" >"$STATE"
    FB_EXPECTED=$after
    return 0
}

# The reader UI must be stopped, not killed: cvm is supervised by pmond, so
# `kill` gets it respawned within seconds and the home screen repaints over the
# frame. /etc/init.d/framework stop is the supported path and it clears the
# screen; killing is only the fallback when a cvm survives that.
cvm_pids() {
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
        case "$c" in
            *cvm*) echo "${p#/proc/}" ;;
        esac
    done
}

ui_down() {
    pids=$(cvm_pids)
    if [ -n "$pids" ]; then
        if [ -x /etc/init.d/framework ]; then
            /etc/init.d/framework stop >>"$LOG" 2>&1 &&
                log "ui: framework stop (cvm was:$(echo $pids))"
        fi
        sleep 2
        pids=$(cvm_pids)
        if [ -n "$pids" ]; then
            # shellcheck disable=SC2086
            kill $pids 2>/dev/null && log "ui: killed cvm that survived stop:$(echo $pids)"
        fi
    fi
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
}

# ---------------------------------------------------------------- rtc/suspend
RTC=""
for node in /sys/class/rtc/rtc1 /sys/class/rtc/rtc0; do
    [ -d "$node" ] && RTC="$node" && break
done

schedule_wake() {
    [ -n "$RTC" ] || return 1
    target=$(( $(date +%s) + INTERVAL ))
    echo 0 >"$RTC/wakealarm" 2>/dev/null
    echo "$target" >"$RTC/wakealarm" 2>/dev/null || return 1
    [ -n "$(cat "$RTC/wakealarm" 2>/dev/null)" ]
}

sleep_or_suspend() {
    if [ "$SUSPEND" = "1" ] && schedule_wake; then
        # note: this reboots the device on this firmware, which is why it is off
        log "suspending for ${INTERVAL}s (rtc=$RTC)"
        echo mem >/sys/power/state 2>>"$LOG" || sleep "$INTERVAL"
    else
        sleep "$INTERVAL"
    fi
}

drift() {
    case $(( cycle / OFFSET_EVERY % 4 )) in
        1) DX=2;  DY=1 ;;
        2) DX=-1; DY=2 ;;
        3) DX=-2; DY=-1 ;;
        *) DX=0;  DY=0 ;;
    esac
    if [ "$DX" = 0 ] && [ "$DY" = 0 ]; then
        QUERY="dash.png"
    else
        QUERY="dash.png?dx=$DX&dy=$DY"
    fi
}

# Once per calendar day, at WASH_HOUR, plus a window of a couple of hours so a
# missed wake (suspend, reboot, flat battery) does not skip the whole day.
# Leading zeros are stripped rather than using base#N arithmetic: dash rejects
# `10#03`, and the device shell differs from the one on the server.
wash_due() {
    [ "$washed" = "$(date +%F)" ] && return 1
    hour=$(date +%H)
    hour=${hour#0}
    start=${WASH_HOUR#0}
    [ "$hour" -ge "$start" ] && [ "$hour" -lt "$(( start + WASH_WINDOW ))" ]
}

# Source-only mode, so tests can exercise the logic without touching hardware:
#   DASH_LIB_ONLY=1 . ./dash.sh
if [ "${DASH_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------- main
log "=== start $(date '+%F %T') eips=$EIPS curl=$CURL rtc=${RTC:-none} suspend=$SUSPEND url=$URL_BASE ==="

if [ -z "$URL_BASE" ]; then
    log "ABORT: no server URL. Put one line in $BASE/url, e.g. http://192.168.1.10:8099"
    exit 1
fi

cycle=0
washed=""
FB_EXPECTED=""

# First frame immediately: stopping the framework clears the screen, so waiting
# for the settle phase leaves the panel blank, which reads as "it broke".
ui_down
drift
pull "$QUERY" && show && log "refreshed $(wc -c <"$PNG") bytes [$QUERY] cycle=0"

# The framework can finish starting after us, so keep checking for a bit.
n=0
while [ "$n" -lt 6 ]; do
    ui_down
    n=$((n + 1))
    sleep 5
done
log "ui: settle finished"

while :; do
    ui_down
    drift

    if wash_due; then
        # inverted frame, held for a couple of minutes at 03:00 (nobody looking),
        # then a white clear and the normal frame on the next pass
        if pull "dash.png?invert=1" && show; then
            washed=$(date +%F)
            log "wash: inverted frame at $(date +%H:%M), holding ${WASH_HOLD}s"
            sleep "$WASH_HOLD"
            # no `eips -c` here: on this firmware it does not touch the
            # framebuffer. The normal frame is drawn on the next pass anyway.
        else
            log "wash pull failed, will retry on the next pass"
        fi
    fi

    if pull "$QUERY" && show; then
        cycle=$((cycle + 1))
        log "refreshed $(wc -c <"$PNG") bytes [$QUERY] cycle=$cycle"
    else
        log "refresh failed, keeping last frame"
        sleep 30
        continue
    fi

    if [ "$SUSPEND" = "1" ]; then
        sleep_or_suspend
        continue
    fi

    # Wait out the interval, but keep watching the panel. checkpmond runs from
    # cron every 15 min and can resurrect the framework, and powerd can blank
    # the screen; if the framebuffer no longer holds our frame, take it back
    # instead of waiting up to five minutes for the next pull.
    waited=0
    while [ "$waited" -lt "$INTERVAL" ]; do
        sleep 60
        waited=$((waited + 60))
        now=$(fb_hash)
        if [ "$now" != "$FB_EXPECTED" ]; then
            log "panel was taken over (fb=$now expected=$FB_EXPECTED), taking it back"
            ui_down
            show || log "redraw failed"
        fi
    done
done
