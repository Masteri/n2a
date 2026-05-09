# Deepgram

Used in **Phase 2** to transcribe + summarize call recordings before pushing them into HubSpot.

## Authentication

| What | Value |
| --- | --- |
| Auth type | API key |
| Header | `Authorization: Token <key>` *(NOT `Bearer`)* |
| Key location | `/home/masterok/n8n/KEYS.txt` (`DEEPGRAM_API_KEY=…`) |
| n8n credential | `deepgram-api-token` (Header Auth) |

## Endpoint we call

```
POST https://api.deepgram.com/v1/listen
  ?model=nova-2
  &punctuate=true
  &summarize=v2
  &utterances=true
  &diarize=true
  &detect_language=true
```

| Body | `Content-Type: audio/wav` (raw WAV bytes — NOT multipart) |
| Auth header | `Authorization: Token <key>` |
| Cost order | ~$0.0043/min for nova-2 + summarize |

> **Critical:** Deepgram's `/v1/listen` rejects multipart with `400 corrupt or unsupported data`. n8n's HTTP Request must be configured as `contentType: binaryData` + explicit `Content-Type: audio/wav` header — not `sendBinaryData: true` alone, which sends multipart.

## Response shape (the bits we read)

```json
{
  "metadata": { "duration": 29.5 },
  "results": {
    "summary": { "short": "..." },
    "channels": [{
      "alternatives": [{
        "transcript": "full punctuated transcript"
      }]
    }],
    "utterances": [
      {"start": 0.4, "end": 1.2, "speaker": 0, "transcript": "Congratulations."},
      ...
    ]
  }
}
```

n8n's Phase-2 Code node renders this into:

```
## Summary
{results.summary.short}

## Transcript ({metadata.duration:.1f}s)
[{utterance.start:.1f}s] Speaker {utterance.speaker}: {utterance.transcript}
[...]
```

## Configured features

| Feature | Setting | Why |
| --- | --- | --- |
| Model | `nova-2` | Latest English model, lowest cost-per-quality |
| Punctuation | `punctuate=true` | Readable transcript |
| Summary | `summarize=v2` | Free — saves a separate LLM round-trip |
| Diarization | `diarize=true` | Speaker labels in utterances |
| Language detection | `detect_language=true` | Auto-detect rather than hardcode `en` |
| Utterances | `utterances=true` | Speaker-segmented chunks with timestamps |

## Test directly (sanity check)

```bash
KEY=$(grep ^DEEPGRAM_API_KEY ~/n8n/KEYS.txt | cut -d= -f2)
curl -sS -X POST \
  "https://api.deepgram.com/v1/listen?model=nova-2&punctuate=true&summarize=v2&utterances=true" \
  -H "Authorization: Token $KEY" \
  -H "Content-Type: audio/wav" \
  --data-binary @/tmp/test.wav | jq '{summary: .results.summary.short, transcript: .results.channels[0].alternatives[0].transcript}'
```

## See also

- [`../topics/transcription-pipeline.md`](../topics/transcription-pipeline.md)
- `../n8n-freepbx-runbook.md` § 14
