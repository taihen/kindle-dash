#!/bin/bash
# usb_update.sh: refresh the device-side scripts over USB and optionally drop
# update packages (.bin) on the Kindle root. Used while the device is plugged
# into the host; no shell needed on the Kindle.
#
#   sudo bash tools/usb_update.sh [extra-file.bin ...]
#
# Removes the jailbreak leftovers from the root (data.tar.gz, ENABLE_DIAGS,
# diagnostic_logs, runme.sh) so a later reboot cannot fall back into diags.
set -uo pipefail
MNT=${MNT:-/mnt/kindle}
SRC=${SRC:-$(cd "$(dirname "$0")/.." && pwd)/kindle}
die() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "[usb-update] $*"; }

mountpoint -q "$MNT" && die "$MNT already mounted"
mapfile -t usbdisks < <(lsblk -dno NAME,TRAN | awk '$2=="usb"{print $1}')
cands=()
for d in "${usbdisks[@]}"; do
    while read -r name fstype; do
        [ "$fstype" = "vfat" ] && cands+=("/dev/$name")
    done < <(lsblk -rno NAME,FSTYPE "/dev/$d" 2>/dev/null)
done
[ "${#cands[@]}" -gt 0 ] || die "no FAT32 USB partition (Kindle plugged in on the USB-drive screen?)"

mkdir -p "$MNT"
DEV=""
for c in "${cands[@]}"; do
    mount -t vfat -o rw,umask=000 "$c" "$MNT" 2>/dev/null || continue
    if [ -d "$MNT/system" ] || [ -d "$MNT/documents" ]; then DEV=$c; break; fi
    umount "$MNT"
done
[ -n "$DEV" ] || die "no Kindle root found"
say "kindle: $DEV"

fail=0
for f in dash.sh init.d-dash; do
    cp -f "$SRC/$f" "$MNT/kindle-dash/$f" || { say "copy failed: $f"; fail=1; }
    chmod 755 "$MNT/kindle-dash/$f" 2>/dev/null
    a=$(sha256sum "$SRC/$f" | cut -d' ' -f1)
    b=$(sha256sum "$MNT/kindle-dash/$f" | cut -d' ' -f1)
    [ "$a" = "$b" ] && say "updated $f" || { say "MISMATCH $f"; fail=1; }
done

for junk in data.tar.gz ENABLE_DIAGS diagnostic_logs runme.sh; do
    if [ -e "$MNT/$junk" ]; then
        rm -rf "$MNT/$junk" && say "removed $junk (jailbreak leftover)"
    fi
done

for bin in "$@"; do
    [ -f "$bin" ] || { say "missing $bin"; fail=1; continue; }
    cp -f "$bin" "$MNT/" && say "staged $(basename "$bin") on the root"
done

sync
sleep 1
say "root now:"
ls -1 "$MNT" | sed 's/^/    /'
umount "$MNT" && say "unmounted"
[ "$fail" = 0 ] && echo "OK - SAFE TO UNPLUG" || { echo "FAILED" >&2; exit 1; }
