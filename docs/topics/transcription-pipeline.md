# Phase 2 — Recording transcription pipeline

Fires after `MixMonitor` closes the WAV (~5–20 s after hangup). Sends the audio to Deepgram, writes the resulting summary + diarized transcript onto the **same** HubSpot Call engagement Phase 1 created.

## Trigger

`MixMonitor`'s third argument is a command that runs **after** the recording stops:

```asterisk
MixMonitor(${UNIQUEID}.wav,,/etc/asterisk/scripts/n8n-recording-uploader.sh ${UNIQUEID})
```

(Empty options field. The `b` "wait for bridge" option is intentionally omitted — it didn't behave well with Stasis bridges.)

## Uploader script

`/etc/asterisk/scripts/n8n-recording-uploader.sh`:

```bash
UNIQUEID=$1
REC=/var/spool/asterisk/monitor/${UNIQUEID}.wav

# Wait up to 5s for Asterisk to flush the file
for i in 1 2 3 4 5; do [ -s "$REC" ] && break; sleep 1; done

curl -sS -m 120 -X POST \
  -F "uniqueid=$UNIQUEID" \
  -F "file=@$REC" \
  http://172.17.0.1:5678/webhook/freepbx-recording-ready
```

Logs to `/var/log/asterisk/n8n-recording.log`.

## n8n workflow `freepbx-recording-transcriber`

```
Webhook POST /webhook/freepbx-recording-ready
   multipart fields: uniqueid (text), file (binary WAV)
   │
   ▼
HTTP "Deepgram Transcribe+Summarize"
   POST https://api.deepgram.com/v1/listen
     ?model=nova-2&punctuate=true&summarize=v2&utterances=true&diarize=true&detect_language=true
     Authorization: Token <DEEPGRAM_API_KEY>
     Content-Type: audio/wav
     body: <raw WAV bytes>          ← NOT multipart, NOT JSON
   │
   ▼
Code "Compose HubSpot Body"
   builds:
     ## Summary
     {results.summary.short}

     ## Transcript ({metadata.duration:.1f}s)
     [t] Speaker N: {transcript}
     ...
   truncates to 65 000 chars (HubSpot hs_call_body limit)
   │
   ▼
HTTP "HubSpot Search Call"
   POST /crm/v3/objects/calls/search
     filterGroups: hs_call_external_id EQ <uniqueid>
   │
   ▼
IF "Found?"
   ├── yes → HTTP "HubSpot PATCH Call"
   │           PATCH /crm/v3/objects/calls/{found_id}
   │             properties.hs_call_body = <composed body>
   │         → "Respond Updated" {status, hubspot_call_id, body_chars, summary_present}
   │
   └── no → "Respond No Match" {status, uniqueid, hint}
```

## Why raw audio body, not multipart

Deepgram's `/v1/listen` rejects multipart with `400 corrupt or unsupported data`. The n8n HTTP Request node must be configured:

```json
"sendBody": true,
"contentType": "binaryData",
"inputDataFieldName": "file",
"headerParameters": { "parameters": [
  { "name": "Content-Type", "value": "audio/wav" }
]}
```

`sendBinaryData: true` alone produces multipart and fails.

## What it produces in HubSpot

`hs_call_body` of an existing Call gets rewritten from `"(transcript pending)"` to:

```
## Summary
The agent congratulates the customer on their successful implementation of
Asterisk Open Source PBX and provides information on how to use the dial
answer and hang up commands for the demonstration.

## Transcript (29.5s)
[0.4s] Speaker 0: Congratulations.
[1.5s] Speaker 0: You have successfully installed and executed the Asterisk Open Source PBX.
...
```

## Why MixMonitor sometimes records 44 bytes (just header)

| Cause | Fix |
| --- | --- |
| Channel uses an app that doesn't pump audio frames (`Wait()`) | Use `Echo()`, `Playback()`, `Read()`, `Dial()`, or `Bridge()` |
| `direct_media: yes` on PJSIP endpoint → RTP goes peer-to-peer | Set `direct_media=no` in `sip` table for the endpoint |
| `MixMonitor(...,b,...)` waits for a bridge that never forms (e.g. Stasis) | Drop the `b` option |
| File still being written when uploader fires | Already handled — uploader waits up to 5 s for non-zero file size |

## Manual replay (Phase 2 alone)

If Phase 2 errored on a recording but the WAV is still on disk, replay without making a new call:

```bash
ssh root@u 'UNIQUEID=$(docker exec freepbx-freepbx-1 ls -t /var/spool/asterisk/monitor | head -1 | sed "s/.wav$//")
            docker exec freepbx-freepbx-1 /etc/asterisk/scripts/n8n-recording-uploader.sh "$UNIQUEID"'
```

## Files of interest

| Path | Owner | What |
| --- | --- | --- |
| `/srv/docker/freepbx/dialplan/extensions_custom.conf` | host | source for the MixMonitor stanza |
| `/srv/docker/freepbx/scripts/n8n-recording-uploader.sh` | host | source for the uploader |
| inside container: `/var/log/asterisk/n8n-recording.log` | asterisk:asterisk | uploader log |
| inside container: `/var/spool/asterisk/monitor/<UNIQUEID>.wav` | asterisk:asterisk | the recording itself |
| `/srv/docker/n8n/workflows/freepbx-recording-transcriber.json` | host | n8n workflow source |

## See also

- [`../platforms/deepgram.md`](../platforms/deepgram.md)
- [`../platforms/recordings-server.md`](../platforms/recordings-server.md)
- `../n8n-freepbx-runbook.md` § 14
