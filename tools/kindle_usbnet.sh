#!/bin/bash
# kindle_usbnet.sh: bring up the USBNetwork link from the host side, then prove
# the Kindle answers. Kindle 4 defaults: host 192.168.15.201, device .244.
#
# Finds the interface by walking up /sys to the USB device and checking that its
# idVendor is 1949 (Lab126/Amazon) - name-based guessing picked the wrong NIC
# (a USB ethernet adapter on the LAN) the first time round.
set -uo pipefail
HOST_IP=${HOST_IP:-192.168.15.201/24}
KINDLE_IP=${KINDLE_IP:-192.168.15.244}

find_iface() {
    for if in /sys/class/net/*; do
        name=$(basename "$if")
        [ "$name" = "lo" ] && continue
        p=$(readlink -f "$if" 2>/dev/null) || continue
        case "$p" in *"/usb"*) ;; *) continue ;; esac
        q=$p
        while [ "$q" != "/" ]; do
            if [ -f "$q/idVendor" ] && [ "$(cat "$q/idVendor" 2>/dev/null)" = "1949" ]; then
                echo "$name"
                return 0
            fi
            q=$(dirname "$q")
        done
    done
    return 1
}

iface=$(find_iface) || {
    echo "no Amazon USB network interface yet (usbNetwork on? cable in?)"
    echo "usb devices: $(lsusb | grep -i 1949 || echo none)"
    exit 1
}
echo "interface: $iface ($(cat /sys/class/net/$iface/address))"
ip addr replace "$HOST_IP" dev "$iface"
ip link set "$iface" up
sleep 2
ip -br addr show "$iface"

if ping -c2 -W2 "$KINDLE_IP" >/dev/null 2>&1; then
    echo "ping ok -> $KINDLE_IP"
else
    echo "no ping answer from $KINDLE_IP (telnetd drops ICMP sometimes; trying anyway)"
fi

echo "--- telnet port ---"
timeout 5 bash -c "echo > /dev/tcp/$KINDLE_IP/23" 2>/dev/null && echo "tcp/23 open" || echo "tcp/23 closed"
echo "--- ssh port ---"
timeout 5 bash -c "echo > /dev/tcp/$KINDLE_IP/22" 2>/dev/null && echo "tcp/22 open" || echo "tcp/22 closed"
