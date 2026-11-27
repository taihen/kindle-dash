#!/bin/bash
# flip_kindle_usbnet_mode.sh: set USBNetwork to the no-auth mode while the
# Kindle is plugged in as a disk.
#
#   sudo bash tools/flip_kindle_usbnet_mode.sh          # telnet/blank-password mode
#   sudo bash tools/flip_kindle_usbnet_mode.sh wifi     # back to key-auth over WiFi
#
# Non-WiFi mode: Ethernet-over-USB, telnetd without a password, sshd that
# accepts any password. It is the documented bootstrap when key auth is not
# working yet. WiFi mode is what we want afterwards.
set -uo pipefail
MNT=${MNT:-/mnt/kindle}
MODE=${1:-usb}
die() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "[flip-mode] $*"; }

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
CFG="$MNT/usbnet/etc/config"
[ -f "$CFG" ] || die "usbnet not installed (no $CFG)"
say "kindle: $DEV"

case "$MODE" in
    usb)
        sed -i 's/^K3_WIFI=.*/K3_WIFI="false"/; s/^K3_WIFI_SSHD_ONLY=.*/K3_WIFI_SSHD_ONLY="false"/' "$CFG"
        say "mode: usb gadget + telnet, no password"
        ;;
    wifi)
        sed -i 's/^K3_WIFI=.*/K3_WIFI="true"/; s/^K3_WIFI_SSHD_ONLY=.*/K3_WIFI_SSHD_ONLY="true"/' "$CFG"
        say "mode: wifi sshd only, usb stays a disk, key auth"
        ;;
    *) die "usage: $0 [usb|wifi]" ;;
esac

grep -E '^HOST_IP|^KINDLE_IP|^K3_WIFI|^K3_WIFI_SSHD_ONLY|^USE_VOLUMD|^USE_OPENSSH' "$CFG" | sed 's/^/    /'
sync
umount "$MNT" && say "unmounted"
echo "OK - unplug, reboot if usbnet is currently running, then '~usbNetwork' once, then plug in."
