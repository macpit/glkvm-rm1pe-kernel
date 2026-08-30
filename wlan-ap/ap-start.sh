#!/bin/sh
D=/userdata/wlan-ap
lsmod | grep -q "^8188eu" || insmod /userdata/wlan-modules/8188eu.ko
sleep 2
ip link set wlan0 down 2>/dev/null
ip addr flush dev wlan0 2>/dev/null
ip addr add 192.192.193.1/24 dev wlan0
ip link set wlan0 up
$D/hostapd -B $D/hostapd.conf || exit 1
$D/dnsmasq -C $D/dnsmasq.conf --pid-file=/var/run/dnsmasq-ap.pid
pgrep -f captive.py >/dev/null 2>&1 || (setsid python3 $D/captive.py >/var/log/captive.log 2>&1 &)
echo "AP laeuft: SSID marv-kvm, 192.192.193.1"
