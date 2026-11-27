#!/bin/bash
# read_kindle_logs.sh: mount the Kindle read-only and dump what the jailbreak
# and the dashboard left behind. The only debugging channel that does not need
# SSH on the device.
#
#   sudo bash tools/read_kindle_logs.sh

set -uo pipefail
MNT=${MNT:-/mnt/kindle-ro}
die() { echo "FAIL: $*" >&2; exit 1; }

mountpoint -q "$MNT" && die "$MNT already mounted"

mapfile -t usbdisks < <(lsblk -dno NAME,TRAN | awk '$2=="usb"{print $1}')
cands=()
for d in "${usbdisks[@]}"; do
    while read -r name fstype; do
        [ "$fstype" = "vfat" ] && cands+=("/dev/$name")
    done < <(lsblk -rno NAME,FSTYPE "/dev/$d" 2>/dev/null)
done
[ "${#cands[@]}" -gt 0 ] || die "no USB disk with a FAT32 partition (is the Kindle plugged in on the USB-drive screen?)"

mkdir -p "$MNT"
DEV=""
for c in "${cands[@]}"; do
    mount -t vfat -o ro "$c" "$MNT" 2>/dev/null || continue
    if [ -d "$MNT/system" ] || [ -d "$MNT/documents" ]; then DEV=$c; break; fi
    umount "$MNT"
done
[ -n "$DEV" ] || die "no Kindle root found"

echo "=== device $DEV on $MNT ==="
echo
echo "=== root listing ==="
ls -1 "$MNT"
echo
echo "=== /mnt/us/kindle-dash ==="
ls -la "$MNT/kindle-dash" 2>/dev/null || echo "(missing)"
for f in provision.log dash.log dash.log.1; do
    if [ -f "$MNT/kindle-dash/$f" ]; then
        echo
        echo "=== $f (last 80 lines, $(wc -l <"$MNT/kindle-dash/$f") total) ==="
        tail -80 "$MNT/kindle-dash/$f"
    fi
done
echo
echo "=== creating plain copies for later diffing ==="
for f in provision.log dash.log; do
    [ -f "$MNT/kindle-dash/$f" ] && cp -f "$MNT/kindle-dash/$f" "/tmp/kindle-$f" && echo "saved /tmp/kindle-$f"
done

umount "$MNT" && echo "unmounted (read-only, nothing written)"
