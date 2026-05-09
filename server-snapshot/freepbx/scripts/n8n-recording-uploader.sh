#!/bin/sh
# Called by MixMonitor when a recording is closed.
# Uploads the WAV + uniqueid to n8n's Phase-2 webhook.
UNIQUEID=$1
REC=/var/spool/asterisk/monitor/${UNIQUEID}.wav
LOG=/var/log/asterisk/n8n-recording.log
URL='http://172.17.0.1:5678/webhook/freepbx-recording-ready'

# Wait briefly for Asterisk to flush+close the file (usually instant, allow up to 5s).
for i in 1 2 3 4 5; do
  [ -s "$REC" ] && break
  sleep 1
done

date '+%F %T' >> "$LOG"
echo "  uniqueid=$UNIQUEID rec=$REC" >> "$LOG"
ls -la "$REC" 2>>"$LOG" || true

if [ ! -s "$REC" ]; then
  echo "  REC missing or empty -> abort" >> "$LOG"
  exit 0
fi

curl -sS -m 120 -X POST \
  -F "uniqueid=$UNIQUEID" \
  -F "file=@$REC" \
  "$URL" >> "$LOG" 2>&1
echo " (curl rc=$?)" >> "$LOG"
exit 0
