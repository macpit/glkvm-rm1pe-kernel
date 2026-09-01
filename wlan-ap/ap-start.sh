#!/bin/sh
# Entry point kept under its old name, because the autostart hook in
# /etc/init.d/S99zerotier calls it and existing installs point at it.
#
# The work happens in wlan-apply.sh, which brings wlan0 into whichever mode is
# recorded in /userdata/wlan-ap/mode ("ap" or "client"). With no mode file it
# starts the access point, which is what this script always did.
exec /userdata/wlan-ap/wlan-apply.sh "$@"
