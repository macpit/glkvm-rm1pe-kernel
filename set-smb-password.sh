#!/bin/sh
# Set (or change) the password of the SMB user "admin" -- the only account
# allowed to write to the KVM's ISO share.  Run on the KVM:
#
#     sh /userdata/smb/set-smb-password.sh            # prompts twice
#     sh /userdata/smb/set-smb-password.sh 'secret'   # non-interactive
#
# Guests can read the share without any password.

DIR=/userdata/smb
USERS=$DIR/ksmbdpwd.db
USER=admin

set -e
[ -x "$DIR/ksmbd.adduser" ] || { echo "ksmbd-tools not installed in $DIR" >&2; exit 1; }
touch "$USERS"

if [ -n "$1" ]; then
    pw=$1
else
    printf 'New SMB password for %s: ' "$USER"; stty -echo; read -r pw; stty echo; echo
    printf 'Repeat: '; stty -echo; read -r pw2; stty echo; echo
    [ "$pw" = "$pw2" ] || { echo "passwords differ" >&2; exit 1; }
fi
[ ${#pw} -ge 4 ] || { echo "password too short" >&2; exit 1; }

if grep -q "^$USER:" "$USERS" 2>/dev/null; then
    "$DIR/ksmbd.adduser" -P "$USERS" -p "$pw" -u "$USER"
else
    "$DIR/ksmbd.adduser" -P "$USERS" -p "$pw" -a "$USER"
fi
chmod 600 "$USERS"

# Tell a running ksmbd.mountd to re-read the user database.
if pgrep -f "$DIR/ksmbd.mountd" >/dev/null 2>&1; then
    "$DIR/ksmbd.control" -r >/dev/null 2>&1 || true
fi
echo "SMB user $USER updated. Connect as smb://$USER@$(hostname).local/media"
