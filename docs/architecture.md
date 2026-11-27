# How it works

## Division of labour

| | server | device |
|---|---|---|
| knows about Home Assistant | yes | no |
| holds a token | yes | no |
| composes the layout | yes (Pillow) | no |
| speaks TLS | n/a | no (plain HTTP on the LAN) |
| runs a shell loop | no | yes |
| does something interesting | render | `curl` + `eips` |

The device is deliberately incurious. It never parses a response, never evaluates a
template, and never needs updating when the dashboard content changes.

## Server

`render.py` makes three Home Assistant calls per render:

| call | why |
|---|---|
| `GET /api/states` | everything at once: weather, power, doors, tariff, sun |
| `POST /api/services/weather/get_forecasts?return_response=true` | five-day high/low/condition |
| `GET /api/history/period/<local midnight>` | the counters' value at midnight |

Energy "today" is `now - value_at(midnight)`, computed from cumulative counters, so it
survives a restart of anything and needs no statistics queries.

Drawing is a straight cursor-based sequence at 2× scale, downsampled and quantised to 16
greys, saved as an 8-bit greyscale PNG. No layout engine, no dithering:

```
header ─ date / time ─ rule
  [OPEN bar]                 only when a door is open
weather ─ temp, condition glyph, feels/humidity/wind, 5-day strip
energy  ─ POWER / GAS with cost, tariff + daylight line
consumers ─ biggest instantaneous draws that fit
footer  ─ updated HH:MM · doors closed / footer name
```

`server.py` is a `ThreadingHTTPServer` with a lock around rendering: a request renders
only if the cached PNG is older than `refresh_seconds`, so device retries cannot stampede
Home Assistant. If rendering throws, it serves the **last good frame** from disk, so the
device never sees an error page. Burn-in variants (`dx`, `dy`, `invert`) are rendered per
request and never cached.

## Device

Three files, in order of execution:

| file | role |
|---|---|
| `/etc/init.d/dash` | boot/manual entry point; waits for `/mnt/us` to be mounted |
| `/mnt/us/kindle-dash/dash.sh` | launcher: logs, self-updates, syntax-gates, execs |
| `/mnt/us/kindle-dash/dash-main.sh` | the loop itself |

The boot chain is plain sysvinit: `si::sysinit:/etc/init.d/rcS` iterates
`/etc/rcS.d/S*`, so `S99dash → ../init.d/dash` runs last, after the userstore is
mounted.

The launcher exists so that "the hook never fired" and "the script died instantly" are
distinguishable from the log alone: it writes `launcher: start` before doing anything
else. It then fetches `dash-main.sh` from `<server>/files/dash-main.sh`, runs `sh -n` on
it, and only replaces the local copy if it parses, so a bad upload cannot brick the
panel, and a fix ships with a reboot.

### One cycle

```
ui_down     stop the reader framework if it is running; preventScreenSaver 1
drift       pick this cycle's offset (0,0) → (2,1) → (-1,2) → (-2,-1), every 12 cycles
wash?       if inside the 03:00 window and not washed today: draw inverted, hold 120 s
pull        curl -sf -m 30 -o /tmp/kindle-dash.png.new  ;  mv
show        eips -g /tmp/kindle-dash.png -f  ;  md5 /dev/fb0 ; compare with last-frame
log         refreshed <bytes> bytes [<query>] cycle=N
wait        5 × 60 s ticks: if md5(/dev/fb0) != what we drew → ui_down + redraw
```

Timing: one frame every 5 minutes (288/day, ~19 KB each ≈ 5 MB/day on the LAN), one
full e-ink flash per frame, one inverted frame per day.

### Why the wait is a guard loop, not a sleep

`checkpmond` runs from cron every 15 minutes and can resurrect the reader framework;
`powerd` can blank the screen. A fixed sleep would leave the panel showing the home
screen until the next scheduled refresh. Hashing the framebuffer every minute and
redrawing on mismatch keeps the worst case at 60 seconds.

### Verification

`eips` on this firmware returns 0 while drawing nothing (see
[pitfalls](pitfalls.md#3-eips--w-gc16-returns-success-and-draws-nothing)), so the draw is
verified by hashing the framebuffer. Because "redrawing the frame that is already on
screen" legitimately changes nothing, the expected hash is persisted per frame:

```
/mnt/us/kindle-dash/last-frame     <png md5> <fb hash>
```

If a *new* frame produces a framebuffer hash different from the recorded one for that
same frame, the draw is reported as failed.

## Failure behaviour

| failure | what the panel does |
|---|---|
| Home Assistant down | last good frame, refreshed on schedule, error in the server log |
| renderer exception | serves the previous PNG from disk |
| server/container down | device keeps its last frame, retries every 30 s |
| device reboot | boot chain redraws ~15–20 s after rcS completes |
| UI or `powerd` takes the screen | back within 60 s |
| `eips` silently no-ops | logged as `draw did not take`, previous frame stays |
| corrupt/partial download | `curl -f` fails, `.new` is discarded, previous frame stays |
| bad `dash-main.sh` upload | `sh -n` rejects it, the working copy keeps running |

## Logs

| where | content |
|---|---|
| `journalctl -u kindle-dash` | one line per HTTP request with the client address, plus render errors |
| `/mnt/us/kindle-dash/dash.log` | per-boot launcher fingerprint, per-cycle refresh, UI takeovers, wash, draw failures; rotated to `.1` at 64 KB |

The device-side log is the only debugging channel that does not require a shell on the
device, which is why it is verbose about state transitions and silent about
steady-state ticks.
