#!/bin/sh
# Build the zip you drag onto the Kindle's USB drive.
#
#   sh tools/make_payload.sh kindle-dash-k4.zip
#
# Layout matches /mnt/us on the device:
#   install.sh                 run on the device, from a shell in the main system
#   kindle-dash/dash.sh        launcher (self-updates and execs the loop)
#   kindle-dash/dash-main.sh   refresh loop
#   kindle-dash/init.d-dash    init script
#
# The jailbreak itself is third-party and is not vendored here; get it from the
# Kindle modding community for your firmware version.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: make_payload.sh <out.zip>}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/kindle-dash"
cp "$root/kindle/install.sh" "$stage/"
cp "$root/kindle/dash.sh" "$root/kindle/dash-main.sh" "$root/kindle/init.d-dash" "$stage/kindle-dash/"
chmod +x "$stage/install.sh" "$stage"/kindle-dash/*

if command -v zip >/dev/null 2>&1; then
    ( cd "$stage" && zip -qrX "$out" . )
else
    # no zip on this host; zipfile keeps the same flat layout (FAT32 has no exec bits)
    python3 - "$stage" "$out" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for base, _, files in os.walk(stage):
        for name in sorted(files):
            full = os.path.join(base, name)
            z.write(full, os.path.relpath(full, stage))
PY
fi
echo "wrote $out"
python3 -m zipfile -l "$out"
