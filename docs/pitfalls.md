# Pitfalls

Everything here cost real time to find, and every item failed *silently*: the log said
it worked while the panel stayed blank. If your dashboard is not drawing, read this
before adding code.

## 1. The jailbreak's `runme.sh` runs in the wrong filesystem

**Symptom:** the installer reports success (`installed /etc/init.d/dash`, `boot hook
created`), the device reboots normally, and nothing ever starts. Probes from that same
script also report that `curl`, `wget` and `/etc/init.d/framework` do not exist.

**Cause:** `runme.sh` is executed by the jailbreak inside the **diags** system, which has
its own root filesystem (cut-down busybox, no curl). It writes `/etc/init.d/dash` and
`/etc/rcS.d/S99dash` into *that* filesystem. The normal boot reads `/dev/mmcblk0p1`, a
full Debian-ish userland with curl, wget, nc, ssh, openssl and `/etc/init.d/framework`.
Hooks written in diags are invisible; capability probes run there lie.

**Fix:** install from a shell in the *running, normally booted* system, which is what
`kindle/install.sh` does. It refuses to run unless `/etc/rcS.d` and `/usr/sbin/eips`
exist, which is true only in the main system.

**Confirm:** `ls -l /etc/init.d/framework` in the main system shows a 6.6 KB script
(2011). If `ls /etc/init.d` shows only `halt rcS`, you are in diags.

## 2. `kill cvm` does not stop the reader UI

**Symptom:** you kill the UI, draw your frame, and seconds later the home screen is back,
often with a flash every few minutes, which looks like the device rebooting.

**Cause:** `/opt/amazon/ebook/bin/start.sh` supervises the Java reader (`cvm`):

```sh
while [ ! -f ${FRAMEWORK_STOP_FILE} ]; do ... start cvm ... done   # /tmp/.framework_stop
```

Kill `cvm` and the loop starts it again immediately, repainting the screen.

**Fix:** `/etc/init.d/framework stop`. It sets the stop file, the supervisor exits, and
the UI stays down. Keep a `cvm` kill only as a fallback for a process that survives that.

**Confirm:** `for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' <$p; done | grep java/bin/cvm`
returns nothing, and `uptime` keeps climbing instead of resetting every five minutes.

## 3. `eips -w gc16` returns success and draws nothing

**Symptom:** the loop logs `refreshed 19003 bytes [dash.png]` every five minutes and the
panel is blank.

**Cause:** the `eips` on 4.1.x does not support the `-w` waveform flag. It prints

```
eips: pixel_in_range> (108, 6020) pixel not in range (0..600, 0..800)
```

and exits **0**. A shell `a || b` fallback therefore never runs, and every truthiness
check on the exit code lies.

**Fix:** `eips -g FILE -f`, no waveform flag, and verify the framebuffer changed rather
than trusting the exit status:

```sh
md5sum /dev/fb0     # 8bpp, 600x800, readable before and after the draw
```

Related: `eips -c` does **not** clear the framebuffer on this firmware either (the hash is
unchanged), so do not build on it.

## 4. Stopping the framework clears the screen

`/etc/init.d/framework stop` blanks the panel as part of stopping. If you stop the UI and
then wait 60 s for things to settle before drawing, the panel sits blank for a minute,
which reads as "it broke". Draw the first frame immediately after stopping the UI, then
settle.

## 5. Cron and powerd fight you for the screen

`/etc/crontab/root` contains `*/15 * * * * /usr/sbin/checkpmond`, which can bring the
framework back within 15 minutes, and `powerd` can blank the screen. A fixed refresh
interval therefore loses the panel for up to that interval.

**Fix:** hash `/dev/fb0` once a minute and redraw when it no longer matches the frame you
drew. This is the `guard` loop in `dash-main.sh`. Also set

```sh
lipc-set-prop com.lab126.powerd preventScreenSaver 1
```

(`lipc-get-prop com.lab126.powerd preventScreenSaver` confirms it took; `powerd` logs
"Prevent screen saver set").

## 6. `pkill -f` kills your own shell

**Symptom:** a command that starts with `pkill -f dash-main ...` produces no output at
all, and the restart it was supposed to perform never happened.

**Cause:** `pkill -f` matches **the whole command line**, including the shell running your
command, which contains the pattern you just typed. It kills itself mid-command.

**Fix:** kill by PID from the pidfile, or anchor the pattern (`^/bin/sh
/mnt/us/kindle-dash/dash-main\.sh$`), or put the pkill in a separate invocation from the
restart.

## 7. Frame verification needs state on disk

Comparing "did the framebuffer change?" is not enough on its own: redrawing a frame that
is already on screen legitimately changes nothing, and after a restart the process has no
memory of what it drew. Persist the pairing in
`/mnt/us/kindle-dash/last-frame` as `<png md5> <fb hash>`, and verify against that.

## 8. A bare container has no fonts

**Symptom:** `OSError: cannot open resource` from inside PIL, pointing at
`DejaVuSans.ttf`.

**Cause:** the renderer needs DejaVu, and a minimal Debian container ships no fonts at
all.

**Fix:** `apt-get install fonts-dejavu-core`. The renderer searches a few known
directories, honours `[display].font_dir`, and exits with an actionable message.

## 9. A missing glyph is a hollow box, not an error

DejaVu has no `U+26C5` (sun behind cloud). PIL draws `.notdef`, which on e-ink looks like
a deliberate design element, so "partly cloudy" showed a rectangle for an afternoon.
"Partly cloudy" is drawn as sun + cloud (`\u2600\u2601`) instead, and `tests/glyphs.py`
fails if any icon glyph is missing from the font.

## 10. TOML dotted keys in `[consumers]`

```toml
[consumers]
sensor.fridge_power = "Fridge"     # WRONG: parsed as a nested table
"sensor.fridge_power" = "Fridge"   # right
```

The symptom is a panel where the consumer list is silently empty.

## 11. `dash` rejects `10#03`

`hour=$((10#$H))` is a bashism; the device shell fails with
`arithmetic expression: expecting EOF: " 10#02 "`. Strip leading zeros instead:

```sh
hour=${hour#0}
```

The wash-decision test (`tests/wash_due.sh`) exists because this class of bug only shows
up at 03:00.

## 12. The device shell is not the shell you are used to

On 4.1.x there is no `awk` in the loop script's environment, no `grep -E`, no `grep -w`,
no `command -v`, and `ps` lists only tty processes (use `ps.procps -ef`, or read
`/proc/*/cmdline`). Write `case`/`read` loops with explicit binary paths.

Two more traps: `od` is missing, and `ps | grep` misses daemons. `/proc/*/cmdline` is the
reliable source.

## 13. The USBNetwork gadget is not an Amazon device

In Ethernet-over-USB mode the Kindle enumerates as `0525:a4a2` (Netchip RNDIS gadget),
**not** `1949:0004` (Amazon mass storage). A host-side helper that filters on the Amazon
vendor id will find nothing.

Host side: `192.168.15.201/24`, device `192.168.15.244`, telnet on port 23 with no
password. Enable/disable gadget mode from the device's search bar: `;debugOn`, then
`~usbNetwork` (it is a toggle), then reboot or replug.

## 14. A telnet client must read until quiet, not until prompt

The shell prompt arrives *before* the command output, so a client that stops at the first
`#` returns an empty result and looks like "the command produced nothing". Read until the
stream has been silent for a second or two. `tools/kindle_sh.py` does this.

## 15. The device clock can be oddly offset

`date` on this unit reported `GMT+01:37`. Nothing breaks, but anything clock-driven (the
03:00 wash) fires at that clock's 03:00, roughly half an hour off real time.

## 16. Do not fix the burn-in by keeping a black area on screen

The inverse **OPEN** bar is the most visually dominant element, and it is exactly the kind
of static high-contrast region that e-ink retains. It only exists while a door is actually
open, which is the point: rare, and when it appears it means something.
