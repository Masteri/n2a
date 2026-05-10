# baresip — headless test softphone

Installed on the host (not in a container) to register as ext 1001 and place test calls without needing a real phone.

## Why

AVA's StasisStart handler validates that the caller channel isn't a bare `Local/...@...` originate (it expects a real PJSIP/SIP channel paired with a session AVA itself created). Direct CLI originates fail with "No caller found for Local channel". A registered SIP UA fixes this.

## Where things live

| Path | Purpose |
| --- | --- |
| `/usr/bin/baresip` | binary (Ubuntu apt package) |
| `/usr/lib/baresip/modules/` | shared-object plugins |
| `/root/.baresip/config` | Module list + audio config |
| `/root/.baresip/accounts` | SIP credentials (auth_pass for ext 1001) |
| `/tmp/test-speech.wav` | 8 kHz mono PCM16 audio source for tests |
| `/tmp/baresip.log` | nohup output from background runs |

## Account

```
<sip:1001@127.0.0.1>;auth_user=1001;auth_pass=t3st-1001-secret;answermode=auto;regint=60
```

Registers UDP to FreePBX at `127.0.0.1:5060`.

## Modules loaded (the working combination)

```
ice, turn, stun, presence, mwi, account,
ctrl_tcp, menu,        ← /dial command
srtp, aufile,          ← play wav as audio source
g711                   ← PCMU/PCMA codecs
```

> **Don't** load `stdio.so` in non-TTY contexts (SSH non-interactive) — it crashes with `epoll_ctl: Operation not permitted`.
> **Don't** rely on `aubridge.so` alone — it pairs with itself for two-instance bridging; we use `aufile` to play a known WAV.

## Place a test call

```bash
# Clear old logs, kill stragglers
ssh root@u 'pkill -9 baresip 2>/dev/null; sleep 1; \
  docker exec freepbx-freepbx-1 sh -c ":> /var/log/asterisk/n8n-hook.log; :> /var/log/asterisk/n8n-recording.log"'

# Place call to *98 (recording-only test) and let WAV finish (~17 s)
ssh root@u 'nohup baresip -t 30 -e "/dial *98" > /tmp/baresip.log 2>&1 &
            sleep 25; pkill -INT baresip; sleep 3; pkill -9 baresip'

# Check what the call looked like
ssh root@u 'grep -E "established|terminated|duration" /tmp/baresip.log'
```

## Generate a fresh test WAV

If you want a different test phrase, regenerate via OpenAI TTS + ffmpeg:

```bash
KEY=$(grep ^OPENAI_API_KEY ~/n8n/KEYS.txt | cut -d= -f2)
curl -sS -X POST https://api.openai.com/v1/audio/speech \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"tts-1","voice":"alloy","input":"<your text>","response_format":"wav"}' \
  -o /tmp/t-24k.wav

ffmpeg -y -i /tmp/t-24k.wav -ar 8000 -ac 1 -sample_fmt s16 /tmp/test-speech.wav
```

baresip's config points at `/tmp/test-speech.wav` — drop the file in and any subsequent `/dial` plays it.

## Common gotchas

- `audio_decoder_set error: No such device` → you removed `g711.so` or `aufile.so` from the module list, or the WAV isn't 8 kHz mono PCM16.
- `command not found (dial)` → forgot `module menu.so`.
- `outbound requires valid UUID!` → don't put `;sipnat=outbound` in the accounts line unless you set a UUID in config.

## See also

- [`../runbooks/test-end-to-end.md`](../runbooks/test-end-to-end.md)
- `../n8n-freepbx-runbook.md` § 13e
