#!/bin/bash
# copy_to_kindle.sh - put the dashboard files on the Kindle's USB disk.
#
# Run on any Linux box with the Kindle plugged in and showing USB drive mode.
# Finds the Kindle's FAT32 partition, checks it looks like a Kindle root, copies
# the files, verifies every byte on the way back, and unmounts. Never deletes
# anything, never touches another USB disk.
#
#   sudo bash tools/copy_to_kindle.sh                                  # files only
#   sudo bash tools/copy_to_kindle.sh --dry-run
#   sudo bash tools/copy_to_kindle.sh http://192.168.1.10:8099         # + server URL
#
# Exit 0 only when every file verified. The last line tells you whether it is
# safe to unplug, and what to run on the device next.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
MNT=${MNT:-/mnt/kindle}

DRY=""
URL=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=$arg ;;
        http*)     URL=$arg ;;
        *)         echo "usage: $0 [--dry-run] [http://server:port]" >&2; exit 2 ;;
    esac
done

# repo path : path on the Kindle
MAP=(
    "kindle/install.sh:install.sh"
    "kindle/dash.sh:kindle-dash/dash.sh"
    "kindle/dash-main.sh:kindle-dash/dash-main.sh"
    "kindle/init.d-dash:kindle-dash/init.d-dash"
)

die() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "[copy-to-kindle] $*"; }

for pair in "${MAP[@]}"; do
    src=${pair%%:*}
    [ -f "$REPO/$src" ] || die "missing $REPO/$src"
done
command -v mountpoint >/dev/null || die "mountpoint(1) missing"

if mountpoint -q "$MNT"; then
    die "$MNT is already mounted; unmount it first (umount $MNT)"
fi

# --- find candidate partitions on USB disks --------------------------------
mapfile -t usbdisks < <(lsblk -dno NAME,TRAN | awk '$2=="usb"{print $1}')
[ "${#usbdisks[@]}" -gt 0 ] || die "no USB disk attached (is the Kindle plugged in and showing USB drive mode?)"
say "usb disks: ${usbdisks[*]}"

cands=()
for d in "${usbdisks[@]}"; do
    while read -r name fstype; do
        [ "$fstype" = "vfat" ] && cands+=("/dev/$name")
    done < <(lsblk -rno NAME,FSTYPE "/dev/$d" 2>/dev/null)
done
[ "${#cands[@]}" -gt 0 ] || die "no FAT32 partition on the USB disk"

# --- mount each candidate, keep the one that looks like a Kindle -----------
mkdir -p "$MNT"
KINDLE=""
for c in "${cands[@]}"; do
    say "trying $c"
    if ! mount -t vfat -o rw,umask=000 "$c" "$MNT" 2>/dev/null; then
        say "$c: mount refused"
        continue
    fi
    if [ -d "$MNT/documents" ] || [ -d "$MNT/system" ] || [ -d "$MNT/.active_content_sandbox" ]; then
        KINDLE=$c
        break
    fi
    say "$c: mounted but not a Kindle root, unmounting"
    umount "$MNT"
done
[ -n "$KINDLE" ] || die "none of the FAT32 partitions looks like a Kindle root"

say "kindle: $KINDLE mounted on $MNT"
say "free before: $(df -h --output=avail "$MNT" | tail -1 | tr -d ' ')"

if [ "$DRY" = "--dry-run" ]; then
    say "dry run: would copy ${#MAP[@]} files to $MNT"
    [ -n "$URL" ] && say "dry run: would set $MNT/kindle-dash/url to $URL"
    umount "$MNT"
    exit 0
fi

# --- copy ------------------------------------------------------------------
fail=0
for pair in "${MAP[@]}"; do
    src=${pair%%:*}
    dst=${pair#*:}
    mkdir -p "$MNT/$(dirname "$dst")"
    # plain cp, not -a: FAT32 cannot hold ownership/modes, so -a always exits
    # non-zero here even when the copy is perfect (byte verification caught this)
    if cp "$REPO/$src" "$MNT/$dst" 2>/dev/null; then
        say "copied $dst"
    else
        say "COPY FAILED: $dst"
        fail=1
    fi
done

if [ -n "$URL" ]; then
    mkdir -p "$MNT/kindle-dash"
    printf '%s\n' "$URL" >"$MNT/kindle-dash/url" && say "set server url: $URL"
fi

sync
sleep 1   # let the FAT metadata settle before reading back

# --- verify every byte of what we actually copied --------------------------
for pair in "${MAP[@]}"; do
    src=${pair%%:*}
    dst=${pair#*:}
    want=$(sha256sum "$REPO/$src" | cut -d' ' -f1)
    got=$(sha256sum "$MNT/$dst" 2>/dev/null | cut -d' ' -f1)
    if [ "$want" = "$got" ]; then
        say "verified $dst"
    else
        say "MISMATCH $dst (want $want got ${got:-missing})"
        fail=1
    fi
done

say "listing of $MNT:"
ls -1 "$MNT" | sed 's/^/    /'

umount "$MNT" && say "unmounted $KINDLE"
if [ "$fail" = 0 ]; then
    echo "OK - SAFE TO UNPLUG."
    echo "On the device, from a root shell (USBNetwork): sh /mnt/us/install.sh"
    exit 0
fi
echo "FAILED - do not unplug yet, something did not verify." >&2
exit 1
