#!/bin/sh
# Neustart ueber PID-Datei statt pkill: ein Mustertreffer wuerde sonst auch
# die aufrufende SSH-Sitzung erwischen, weil der Pfad in deren Kommandozeile steht.
D=/userdata/wlan-ap
PIDF=/var/run/captive.pid
[ -f "$PIDF" ] && kill "$(cat $PIDF)" 2>/dev/null
sleep 1
setsid python3 $D/captive.py > /var/log/captive.log 2>&1 &
echo $! > "$PIDF"
sleep 2
kill -0 "$(cat $PIDF)" 2>/dev/null && echo "captive laeuft, PID $(cat $PIDF)" || echo "START FEHLGESCHLAGEN"
