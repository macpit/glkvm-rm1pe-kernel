#!/bin/sh
# wlan-apply.sh - bring wlan0 into the mode stored in $D/mode.
#
# Called at boot by ap-start.sh (via /etc/init.d/S99wlan-ap) and by
# wlan-menu.py after a mode change. Runs detached, so it completes even
# if the SSH session that started it dies - which is exactly what happens
# when you switch from AP to client while connected over the AP.
#
# Client mode has a built-in watchdog: no association or no DHCP lease
# within the timeout and the device falls back to AP mode on its own.

D=/userdata/wlan-ap
STATE=$D/state
ASSOC_TIMEOUT=45
DHCP_TIMEOUT=15

set_state() { echo "$1" > "$STATE"; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# nginx keeps a server block on 192.192.193.1, which does not exist in
# client mode. Harmless as long as a generic "listen 80" sits next to it
# (measured 2026-09-01), but this costs nothing and covers the case where
# someone removes that block later.
sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1

load_driver() {
    lsmod | grep -q "^8188eu" || insmod /userdata/wlan-modules/8188eu.ko 2>/dev/null
    i=0
    while [ $i -lt 15 ]; do
        ip link show wlan0 >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

stop_all() {
    killall hostapd wpa_supplicant udhcpc 2>/dev/null
    [ -f /var/run/dnsmasq-ap.pid ] && kill "$(cat /var/run/dnsmasq-ap.pid)" 2>/dev/null
    killall dnsmasq 2>/dev/null
    sleep 1
    ip link set wlan0 down 2>/dev/null
    ip addr flush dev wlan0 2>/dev/null
}

start_ap() {
    log "starting AP mode"
    ip link set wlan0 down 2>/dev/null
    iw dev wlan0 set type __ap 2>/dev/null
    ip addr flush dev wlan0 2>/dev/null
    ip addr add 192.192.193.1/24 dev wlan0
    ip link set wlan0 up

    if ! "$D/hostapd" -B "$D/hostapd.conf"; then
        log "hostapd refused to start"
        set_state "failed:hostapd"
        return 1
    fi
    "$D/dnsmasq" -C "$D/dnsmasq.conf" --pid-file=/var/run/dnsmasq-ap.pid
    pgrep -f captive.py >/dev/null 2>&1 || \
        (setsid python3 "$D/captive.py" >/var/log/captive.log 2>&1 &)

    set_state "ap"
    log "AP running: SSID $(sed -n 's/^ssid=//p' "$D/hostapd.conf"), 192.192.193.1"
    return 0
}

start_client() {
    if [ ! -x "$D/wpa_supplicant" ]; then
        log "wpa_supplicant not present in $D - client mode unavailable"
        set_state "failed:no-wpa_supplicant"
        return 1
    fi
    if [ ! -f "$D/wifi-client.conf" ]; then
        log "no wifi-client.conf - nothing to connect to"
        set_state "failed:no-config"
        return 1
    fi

    log "starting client mode"
    ip link set wlan0 down 2>/dev/null
    iw dev wlan0 set type managed 2>/dev/null
    ip addr flush dev wlan0 2>/dev/null
    ip link set wlan0 up

    if ! "$D/wpa_supplicant" -B -i wlan0 -D nl80211 -c "$D/wifi-client.conf"; then
        log "wpa_supplicant refused to start"
        set_state "failed:supplicant"
        return 1
    fi

    set_state "connecting"
    i=0
    while [ $i -lt $ASSOC_TIMEOUT ]; do
        if iw dev wlan0 link 2>/dev/null | grep -q "Connected to"; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if ! iw dev wlan0 link 2>/dev/null | grep -q "Connected to"; then
        log "no association within ${ASSOC_TIMEOUT}s (wrong passphrase or out of range)"
        set_state "failed:no-association"
        return 1
    fi
    log "associated with $(iw dev wlan0 link | sed -n 's/.*SSID: //p')"

    udhcpc -i wlan0 -n -q -t 5 -T "$DHCP_TIMEOUT" >/dev/null 2>&1
    IP=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
    if [ -z "$IP" ]; then
        log "associated but no DHCP lease"
        set_state "failed:no-lease"
        return 1
    fi

    set_state "client"
    log "client mode up: $IP"
    return 0
}

# ---------------------------------------------------------------- main

MODE=$(cat "$D/mode" 2>/dev/null)
[ -n "$MODE" ] || MODE=ap

if ! load_driver; then
    log "wlan0 never appeared - is the adapter plugged in?"
    set_state "failed:no-device"
    exit 1
fi

stop_all

case "$MODE" in
client)
    if start_client; then
        exit 0
    fi
    # Watchdog. Whatever went wrong, do not leave the device unreachable.
    log "client mode failed - falling back to AP so the device stays reachable"
    echo ap > "$D/mode"
    stop_all
    start_ap
    exit 1
    ;;
*)
    start_ap
    ;;
esac
