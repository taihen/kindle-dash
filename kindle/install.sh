#!/bin/sh
# install.sh - install kindle-dash on a jailbroken Kindle 4.
#
# Run this ON THE DEVICE, from a shell that is in the normal (main) root filesystem
# - i.e. after booting the Kindle normally and getting root over USBNetwork. It is
# additive and reversible: it writes one file to /etc/init.d, one symlink into
# /etc/rcS.d, and touches nothing else.
#
#   sh /mnt/us/kindle-dash/install.sh          # install + start
#   sh /mnt/us/kindle-dash/install.sh status
#   sh /mnt/us/kindle-dash/install.sh remove   # unhook and stop
#
# Do NOT run this from the jailbreak's runme.sh: that executes in the *diags*
# system, whose /etc is a different filesystem. Hooks written there are invisible
# to the normal boot, which looks exactly like "the installer did nothing".

set -u
BASE=/mnt/us/kindle-dash
DAEMON=$BASE/dash.sh
INIT=/etc/init.d/dash
HOOK=/etc/rcS.d/S99dash

say() { echo "kindle-dash: $*"; }

# --- are we in the main system? -------------------------------------------------
if [ ! -d /etc/rcS.d ] || [ ! -x /usr/sbin/eips ]; then
    say "ERROR: this does not look like the main Kindle system"
    say "  (/etc/rcS.d and /usr/sbin/eips are missing - are you in diags?)"
    exit 1
fi
if [ ! -x "$DAEMON" ]; then
    chmod +x "$DAEMON" 2>/dev/null
fi
if [ ! -f "$DAEMON" ]; then
    say "ERROR: $DAEMON is missing - copy the kindle-dash files to the Kindle first"
    exit 1
fi

rootfs_rw()  { mntroot rw >/dev/null 2>&1 || true; }
rootfs_ro()  { mntroot ro >/dev/null 2>&1 || true; }

do_install() {
    rootfs_rw
    cp -f "$BASE/init.d-dash" "$INIT" || { say "copy to $INIT failed"; rootfs_ro; exit 1; }
    chmod 755 "$INIT"
    ln -sf ../init.d/dash "$HOOK"
    rootfs_ro
    say "installed $INIT and $HOOK"
    "$INIT" start
    sleep 2
    "$INIT" status
    say "first frame in ~10s; log: $BASE/dash.log"
}

do_remove() {
    "$INIT" stop 2>/dev/null || true
    rootfs_rw
    rm -f "$HOOK" "$INIT"
    rootfs_ro
    say "removed $INIT and $HOOK (files in $BASE are untouched)"
}

case "${1:-install}" in
    install) do_install ;;
    remove)  do_remove ;;
    status)  [ -x "$INIT" ] && "$INIT" status || say "not installed" ;;
    *) echo "usage: $0 [install|remove|status]" >&2; exit 2 ;;
esac
