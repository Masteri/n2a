#!/bin/sh
# Posts FreePBX hangup info to the n8n webhook.
# Args: 1=uniqueid 2=src 3=dst 4=callerid 5=billsec 6=disposition 7=start 8=direction
URL='http://172.17.0.1:5678/webhook/freepbx-call-end'
LOG=/var/log/asterisk/n8n-hook.log

PHONE=$4
[ -z "$PHONE" ] && PHONE=$2

# Build JSON safely. Treat all values as strings except duration.
DURATION=${5:-0}
case "$DURATION" in ''|*[!0-9]*) DURATION=0 ;; esac

JSON=$(printf '{"uniqueid":"%s","src":"%s","dst":"%s","phone":"%s","duration":%s,"disposition":"%s","start_time":"%s","direction":"%s"}' \
  "$1" "$2" "$3" "$PHONE" "$DURATION" "$6" "$7" "$8")

date '+%F %T' >> "$LOG"
echo "POST $URL  $JSON" >> "$LOG"
curl -sS -m 5 -X POST -H 'Content-Type: application/json' -d "$JSON" "$URL" >> "$LOG" 2>&1
RC=$?
echo " (curl rc=$RC)" >> "$LOG"
exit 0
