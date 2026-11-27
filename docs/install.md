# Install

Two halves: a server that renders, and a device that displays. Do the server first.
You can prove it works with `curl` before touching the Kindle.

## 1. Server

Any always-on Linux box will do (a small container or VM is plenty: the reference
deployment is Debian 13 with 512 MB RAM, one core).

```sh
sudo apt-get install -y python3-venv fonts-dejavu-core
sudo useradd --system --home /opt/kindle-dash --shell /usr/sbin/nologin kindle-dash
sudo mkdir -p /opt/kindle-dash
sudo rsync -a --exclude .venv --exclude out --exclude .git ./ /opt/kindle-dash/
sudo -u kindle-dash python3 -m venv /opt/kindle-dash/.venv
sudo -u kindle-dash /opt/kindle-dash/.venv/bin/pip install --upgrade pip Pillow
```

`fonts-dejavu-core` is not optional. Without it the renderer exits with
`DejaVuSans.ttf not found`. A bare container has no fonts at all.

Configuration:

```sh
sudo -u kindle-dash cp /opt/kindle-dash/config.example.toml /opt/kindle-dash/config.toml
sudo -u kindle-dash "${EDITOR:-vi}" /opt/kindle-dash/config.toml
```

Point `[ha].url` at Home Assistant, then fill in your own entities. Quote sensor keys in
`[consumers]` and `[doors]`. Energy counters must be cumulative.

Token: create a long-lived token in Home Assistant (profile → Security → Long-lived
access tokens) and keep it out of the repo:

```sh
sudo install -m 640 -o root -g kindle-dash /dev/null /etc/kindle-dash.env
printf 'HASS_TOKEN=%s\n' 'paste-token-here' | sudo tee /etc/kindle-dash.env >/dev/null
```

Service:

```sh
sudo cp systemd/kindle-dash.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kindle-dash
curl -s -o /tmp/p.png -w '%{http_code} %{size_download}\n' http://127.0.0.1:8099/dash.png
```

A `200` and ~19 KB means the panel is being rendered from your real data. If it is a
`500`, read `journalctl -u kindle-dash`. The error names the failing entity or config
key.

## 2. Jailbreak the Kindle

Needed for two reasons: a framebuffer loop needs a shell, and the stock screensaver will
otherwise paint over the panel.

Model matters. A **Kindle 4 / Kindle Touch** (firmware 4.0.0–4.1.4, 2011) uses the
legacy path described here. Newer Kindles use different jailbreaks and different init;
the device script would need changes, so this project targets the legacy devices.

The physical procedure (from the MobileRead
[K4 hacking wiki](https://wiki.mobileread.com/wiki/Kindle4NTHacking) and the
[jailbreak thread](http://www.mobileread.com/forums/showthread.php?t=191158)):

1. Charge it fully and note the serial number (Settings → Device Info).
2. Download the K4 jailbreak package and unzip it on your computer.
3. Over USB, copy `data.tar.gz`, `ENABLE_DIAGS` and the `diagnostic_logs` folder to the
   **root** of the Kindle drive.
4. Eject, then Menu → Settings → Menu → Restart. It boots into Diagnostics.
5. Walk the diags menu: `D) Exit, Reboot or Disable Diags` → `R) Reboot System` →
   `Q) To continue`. ("FW Left" means press left on the 5-way pad.)
6. Wait ~20 s. A jailbreak screen appears, then it reboots normally and a book titled
   "You are Jailbroken" appears. Do not unplug or power off mid-flash.

Then install **USBNetwork** (from the
[USBNetwork thread](http://www.mobileread.com/forums/showthread.php?t=88004)): copy the
`kindle-usbnetwork-*.zip` contents to the Kindle root and apply it with
Menu → Settings → Menu → Update Your Kindle.

Do not install this project's files from the jailbreak's `runme.sh`. That script runs in
the **diags** filesystem, and hooks installed there never execute on a normal boot. See
[pitfalls #1](pitfalls.md#1-the-jailbreaks-runmesh-runs-in-the-wrong-filesystem).

## 3. Put the files on the device

Plug the Kindle in and wait for USB drive mode, then from the repo root:

```sh
sudo bash tools/copy_to_kindle.sh http://192.168.1.10:8099
```

It finds the Kindle's FAT partition (refusing anything that is not a Kindle root), copies
`install.sh` and `kindle-dash/{dash.sh,dash-main.sh,init.d-dash}`, writes the server URL to
`kindle-dash/url`, verifies every byte by sha256, and unmounts. `--dry-run` shows what it
would do.

The URL file is the only place the server address appears: moving the renderer later is a
one-line edit and a reboot, not a script redeploy.

## 4. Install on the device

You need a root shell on the Kindle over USBNetwork. Two options:

- **Ethernet over USB** (works even with no Wi-Fi configured): on the device open the
  search bar, type `;debugOn`, press enter, then `~usbNetwork`, press enter. Replug the
  cable. On the host: `sudo ip addr add 192.168.15.201/24 dev <iface>` (the interface is
  the `enx…` one that appeared; the gadget enumerates as `0525:a4a2`), then
  `telnet 192.168.15.244` (no password), or use `python3 tools/kindle_sh.py 'command'`.
- **Wi-Fi SSH**, if USBNetwork's config enables it and you have a key installed.

Then, *in the normally booted system*:

```sh
sh /mnt/us/install.sh
```

This writes `/etc/init.d/dash`, symlinks `/etc/rcS.d/S99dash → ../init.d/dash`, starts the
loop and prints its status. It refuses to run if it does not see `/etc/rcS.d` and
`/usr/sbin/eips`, which is how it detects "you are in diags".

Verify:

```sh
tail -5 /mnt/us/kindle-dash/dash.log
```

Expect, within ~15 s:

```
launcher: start
launcher: dash-main.sh parses, handing over
=== start ... eips=/usr/sbin/eips curl=/usr/bin/curl ... url=http://192.168.1.10:8099 ===
refreshed 19003 bytes [dash.png] cycle=0
```

and on the server, a request from the Kindle's address every five minutes.

## 5. Day-to-day

| task | how |
|---|---|
| stop the panel and get the reader UI back | `/etc/init.d/dash stop; /etc/init.d/framework start` |
| start it again | `/etc/init.d/dash start` |
| status | `/etc/init.d/dash status` |
| update the device script | copy the new `dash-main.sh` to the server's `files/` dir, then reboot the Kindle (the launcher self-updates) |
| see what the device is doing | `tail -f /mnt/us/kindle-dash/dash.log` |
| change the server URL | edit `/mnt/us/kindle-dash/url`, reboot |
| uninstall | `sh /mnt/us/install.sh remove` |
| reboot the device | hold the power switch ~20 s (the UI is stopped, so menus are unavailable) |

The framework being stopped is why the on-screen menus do not respond while the dashboard
is running. `install.sh remove` plus `/etc/init.d/framework start` returns the device to a
normal Kindle.
