# End-to-end smoke test

Three independent ways to exercise the integration. The webhook test is fastest; the recording test is most representative.

## A. Webhook test (no Asterisk needed) — proves Phase 1 + Phase 2

```bash
UNIQUEID="manual-$(date +%s).$$"
HOST=192.168.10.107
KEY=$(grep ^OPENAI_API_KEY ~/n8n/KEYS.txt | cut -d= -f2)

# 1. Create a HubSpot contact whose phone matches what we'll send below (one time, then reuse)
HKEY=$(tr -d '\n\r ' < ~/n8n/private_key.txt)
curl -sS -X POST https://api.hubapi.com/crm/v3/objects/contacts \
  -H "Authorization: Bearer $HKEY" -H 'Content-Type: application/json' \
  -d '{"properties":{"phone":"+15551001001","firstname":"Smoke","lastname":"Test"}}'

# Wait ~10s for HubSpot search index, then…

# 2. Generate a small TTS WAV
curl -sS -X POST https://api.openai.com/v1/audio/speech \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"tts-1","voice":"alloy","input":"Hi, this is a smoke test.","response_format":"wav"}' \
  -o /tmp/t-24k.wav
ffmpeg -y -i /tmp/t-24k.wav -ar 8000 -ac 1 -sample_fmt s16 /tmp/t.wav

# 3. Phase 1 — fire the hangup-handler-equivalent
curl -sS -X POST "http://$HOST:5678/webhook/freepbx-call-end" \
  -H 'Content-Type: application/json' \
  -d "{\"uniqueid\":\"$UNIQUEID\",\"src\":\"15551001001\",\"dst\":\"*98\",\"phone\":\"15551001001\",\"duration\":12,\"disposition\":\"ANSWERED\",\"start_time\":\"$(date -u +'%Y-%m-%d %H:%M:%S')\",\"direction\":\"inbound\"}"

# 4. Phase 2 — fire the recording-uploader-equivalent
curl -sS -X POST "http://$HOST:5678/webhook/freepbx-recording-ready" \
  -F "uniqueid=$UNIQUEID" -F "file=@/tmp/t.wav"
```

Expected: HubSpot Call appears immediately (Phase 1), then is updated with summary + transcript ~5s later (Phase 2).

## B. Recording-only test from softphone — proves the dialplan + MixMonitor + Phase 2 are wired

Register a SIP softphone (or use baresip) as ext 1001, then dial **`*98`**.

- Asterisk plays demo prompts
- `MixMonitor` captures audio to `${UNIQUEID}.wav`
- Hangup → Phase 1 logs the Call
- File close → Phase 2 transcribes and PATCHes the Call body

Watch live:

```bash
ssh root@u 'docker exec freepbx-freepbx-1 tail -f /var/log/asterisk/n8n-hook.log /var/log/asterisk/n8n-recording.log'
```

## C. AVA test from softphone — proves AI agent path

Dial **`*99`**.

Currently CRM logging works ✅; the AI conversation hits the AudioSocket UUID race ⚠️. See [`../topics/troubleshooting.md`](../topics/troubleshooting.md).

## D. Headless baresip from the server (no real softphone needed)

```bash
ssh root@u 'pkill -9 baresip 2>/dev/null; sleep 1
docker exec freepbx-freepbx-1 sh -c ":> /var/log/asterisk/n8n-hook.log; :> /var/log/asterisk/n8n-recording.log; rm -f /var/spool/asterisk/monitor/*.wav"
nohup baresip -t 30 -e "/dial *98" > /tmp/baresip.log 2>&1 &
sleep 25
pkill -INT baresip; sleep 3; pkill -9 baresip
echo "--- baresip ---"; grep -E "established|terminated|duration" /tmp/baresip.log
echo "--- hook  ---";  docker exec freepbx-freepbx-1 cat /var/log/asterisk/n8n-hook.log
echo "--- rec   ---";  docker exec freepbx-freepbx-1 cat /var/log/asterisk/n8n-recording.log'
```

## E. Replay an existing recording (Phase 2 alone)

```bash
ssh root@u 'UNIQUEID=$(docker exec freepbx-freepbx-1 ls -t /var/spool/asterisk/monitor 2>/dev/null | head -1 | sed "s/.wav$//")
docker exec freepbx-freepbx-1 /etc/asterisk/scripts/n8n-recording-uploader.sh "$UNIQUEID"
docker exec freepbx-freepbx-1 cat /var/log/asterisk/n8n-recording.log | tail -3'
```

## Verify in HubSpot

```bash
KEY=$(tr -d '\n\r ' < ~/n8n/private_key.txt)

# Search the Call by its Asterisk UNIQUEID
curl -sS -X POST "https://api.hubapi.com/crm/v3/objects/calls/search" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "{\"filterGroups\":[{\"filters\":[{\"propertyName\":\"hs_call_external_id\",\"operator\":\"EQ\",\"value\":\"<UNIQUEID>\"}]}],\"properties\":[\"hs_call_body\",\"hs_call_from_number\"],\"limit\":1}" \
  | jq
```
