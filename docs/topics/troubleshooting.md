# Troubleshooting — symptom → cause → fix

A flat lookup of every gotcha hit during the build, plus the diagnostic that points at the right cause.

## n8n / workflows

| Symptom | Cause | Fix |
| --- | --- | --- |
| Workflow import fails: `null value in column "id"` | n8n CLI requires a top-level `id` field on the workflow JSON | Add `"id": "some-stable-id"` to the workflow root |
| Credential import fails: same error | same on `credentials_entity` table | Add `"id"` to each credential object |
| `update:workflow --active=true` succeeds but webhook still 404 | `n8n` process must be restarted to pick up DB activation | `docker compose -f /srv/docker/n8n/docker-compose.yml restart n8n` |
| `.env` change ignored after `docker compose restart n8n` | `restart` doesn't re-read `env_file` | `docker compose up -d --force-recreate n8n` |
| Browser shows "Your n8n server is configured to use a secure cookie…" | We're on plain HTTP, n8n 2.x defaults to `N8N_SECURE_COOKIE=true` | Set `N8N_SECURE_COOKIE: "false"` (testing) or put HTTPS in front (prod) |
| Webhook returns 404 from Asterisk but 200 from `curl` | n8n binding excludes the IP Asterisk uses | Add port mapping for `172.17.0.1:5678:5678` to docker-compose.yml |
| Phase 2 Deepgram step fails with `400 corrupt or unsupported data` | n8n sends multipart instead of raw audio body | Configure HTTP Request node with `contentType: binaryData` + explicit `Content-Type: audio/wav` header |

## FreePBX / Asterisk

| Symptom | Cause | Fix |
| --- | --- | --- |
| `MixMonitor` produces 44-byte WAV (header only) | Channel runs `Wait()` (no audio frames) | Use `Echo()`, `Playback()`, `Read()`, `Dial()`, or `Bridge()` instead |
| Same — for endpoint-to-endpoint calls | `direct_media: yes` makes RTP go peer-to-peer | `INSERT INTO sip(...,'direct_media','no'...) ON DUPLICATE KEY UPDATE data='no';` then `fwconsole reload` |
| ARI returns 401 even with right user/pass | ARI user defined but `module reload res_ari` didn't pick up `#include` change | `asterisk -rx 'core restart now'` (full restart re-parses includes) |
| `http show status` shows "Server Disabled" despite `http_custom.conf` | duplicate `[general]` sections; `http_additional.conf` (FreePBX-managed) wins on key conflicts | Edit `http_additional.conf` directly — accept that `fwconsole reload` will revert it |
| `module reload http` says success but bind doesn't change | http server already configured at startup; reload merges but bindaddr is one-shot | `core restart now` |
| Asterisk disconnects channel "for lack of audio RTP activity in 30 seconds" | RTP isn't reaching Asterisk — usually direct_media or NAT mismatch | Check `direct_media` setting; for SIP UAs across LAN, ensure SDP advertises a reachable IP |
| `chan_local.so: cannot open shared object file` warning at boot | Module file missing from this image; Local channel driver still works (registered via builtin) | Cosmetic — ignore |
| Hangup-handler doesn't fire on calls | FreePBX 17 renamed predial-hooks. `macro-exten-vm-predial-hook` is the OLD name. | Use FreePBX 17 names: `macro-dialout-one-predial-hook`, `macro-dial-ringall-predial-hook`, `macro-dial-hunt-predial-hook` |
| `macro-dial-one` exits at `nodial` before the predial-hook fires | DSTRING is empty because `PJSIP_DIAL_CONTACTS()` returns nothing — no SIP device registered to the extension | Register a real softphone, OR attach hangup handler directly in the test dialplan (bypassing the macros) |
| `live_dangerously` warnings or `System()` silently doesn't run | Asterisk 21 default is `live_dangerously=no`, blocks System() invocations from originate-spawned channels | `sed -i 's/^;live_dangerously = no/live_dangerously = yes/' /etc/asterisk/asterisk.conf` + restart |
| `Unable to register extension 's' priority 1 in 'macro-X-predial-hook', already in use` warning | The predial-hook contexts get registered twice (once empty by FreePBX core, once by your custom file) | Cosmetic — your version still loads at priority 1 because `from-internal-custom` is included before `from-internal-additional` |

## AVA

| Symptom | Cause | Fix |
| --- | --- | --- |
| Engine logs `Failed to connect to ARI` retrying with backoff | `http_additional.conf` got reverted by an earlier `fwconsole reload` | Re-apply `enabled=yes`, `bindaddr=0.0.0.0` and reload http module |
| `endpoint=AudioSocket/127.0.0.1:8090/...` and Asterisk says "Connection refused" | AVA advertises bind host `127.0.0.1` but Asterisk-in-container has its own loopback | Set `AUDIOSOCKET_ADVERTISE_HOST=172.30.0.1` in `.env` (or `audiosocket.advertise_host` in YAML) |
| `No caller found for Local channel` then immediate hangup | AVA expects the Stasis channel to be a real PJSIP channel, not a synthetic Local originate | Use a real SIP UA (baresip) registered to FreePBX |
| `AudioSocket UUID not recognized` ~150 ms after StasisStart | Race between AVA registering the session and the chan_audiosocket TCP handshake arriving | Code-level — workarounds suggested in runbook § 13g, none yet applied |
| `Pipeline 'X' cannot resolve component 'Y' (placeholder adapter)` | A pipeline references a provider whose API key is missing | Either supply the key, disable the pipeline (remove from `ai-agent.yaml`), or disable the provider in `ai-agent.local.yaml` |
| Admin UI restart-loops with `PermissionError: '/app/project/.env'` | bind-mounted `.env` is `chmod 600` root-owned but admin_ui runs as `appuser` | `chmod 644 /srv/docker/ava/.env` |
| Admin UI restart-loops with `PermissionError: '/app/project/config/users.json'` | `config/` dir not writable by `appuser` | `chmod -R a+rwX /srv/docker/ava/config /srv/docker/ava/data /srv/docker/ava/asterisk_media` |
| MiniMax + ElevenLabs warnings every boot | Hardcoded adapter scan in `src/pipelines/orchestrator.py` runs **before** any `enabled` check | Code-level only; cosmetic |

## baresip

| Symptom | Cause | Fix |
| --- | --- | --- |
| `audio_decoder_set error: No such device` and call drops | `aubridge` audio module needs a paired instance, doesn't work standalone for codec negotiation | Use `aufile,/path/to.wav` for `audio_source` + `aufile` for `audio_player` + load `g711.so` |
| `command not found (dial)` | `menu.so` not loaded | Add `module menu.so` to `/root/.baresip/config` |
| `epoll_ctl: EPOLL_CTL_ADD: fd=0 (Operation not permitted)` and exits | `stdio.so` requires a TTY; SSH non-interactive doesn't have one | Don't load `stdio.so` for headless runs |
| `ua: outbound requires valid UUID!` | `;sipnat=outbound` in account URL needs a UUID | Drop `sipnat=outbound` (auth + symmetric RTP work without it) |
| Registers 200 OK but `pjsip show endpoint 1001` still shows Unavailable | RTP/SDP mismatch (often direct_media on the FreePBX side) | Set `direct_media=no` in the `sip` table for ext 1001 |

## HubSpot

| Symptom | Cause | Fix |
| --- | --- | --- |
| Phase 1 errors: `freepbx-ava was not a valid number / INVALID_INTEGER` | `hs_call_app_id` is a HubSpot internal app id (integer), not a string label | Drop `hs_call_app_id` and `hs_call_source` — only useful with HubSpot Calling Extensions |
| Phase 2 search returns no Call when one was just created in Phase 1 | HubSpot search index lag (~5–30s) | Phase 2 should retry the search with backoff; today it doesn't and returns `no_call_match` |
| Setup wizard asks for "Redirect URL / Client ID / Client secret" | You're on the OAuth public-app flow, not Service Keys | Settings → Integrations → Private Apps → "Use Service Keys instead" |
| `crm.objects.calls.*` scope doesn't exist in the picker | HubSpot gates Calls under contacts scopes — there is no separate Calls scope | Select `crm.objects.contacts.read` + `crm.objects.contacts.write` |
| `INVALID_EMAIL` when creating a test contact with `*.invalid` TLD | HubSpot validates email TLD against IANA list | Use `example.com` or omit the email field |

## Networking / Docker

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Network freepbx_defaultnet ... already exists` or subnet conflict | Upstream `escomputers/freepbx-docker` uses `172.18.0.0/16` which collides with `docker_gwbridge` | `sed -i 's/172.18/172.30/g' docker-compose.yaml run.sh` (we did this at clone time) |
| FreePBX container can't reach n8n on `127.0.0.1:5678` | Container has its own loopback; host's 127.0.0.1 isn't visible | Use docker0 gateway `172.17.0.1:5678` from inside the container |
| Asterisk's RTP doesn't reach the container | iptables DNAT rules not in place | Re-run `cd /srv/docker/freepbx && bash run.sh --rtp 10000-20000` |

## SSH

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ssh-copy-id` fails with `ssh_askpass: exec(/usr/bin/ssh-askpass): No such file or directory` | Running through Claude's `!` shell which has no TTY | Run from a real terminal app, OR install `ssh-askpass-gnome`, OR use `sshpass` |

## Deepgram

| Symptom | Cause | Fix |
| --- | --- | --- |
| Deepgram returns **HTTP 400 with empty body** for every request, no error message | The API key has a stray non-printable byte (e.g. `\026` SYN, `\r`, BOM) at the start, copy-pasted from a terminal/clipboard | Strip control chars: `tr -d '[:cntrl:]' < KEYS.txt > KEYS.cleaned.txt`. Verify with `od -An -c <(grep ^DEEPGRAM_API_KEY KEYS.txt \| cut -d= -f2)` — first byte should be a hex digit. Re-import the n8n credential with the cleaned value. |
| Same key worked yesterday, doesn't today | Free tier credits exhausted, or rate-limit | Check Deepgram console; key body would contain a JSON error in this case. Empty body usually means invalid key (vs throttled). |

## n8n v3 workflow + GVoIPC (MiRTA PBX) integration

| Symptom | Cause | Fix |
| --- | --- | --- |
| HubSpot Call body permanently shows `(transcript pending)` after the 10-min `POLL_WAIT_MINUTES` window | The `GET Recording (GVoIPC)` node passes the uniqueid as posted by `pbx4fl` (`pbx4fl-<sec>_<seq>`), but MiRTA PBX (the platform GVoIPC runs on) stores recordings with the Asterisk-native dot separator (`pbx4fl-<sec>.<seq>`). The `id=` lookup misses → empty body → no recording → no Deepgram → no transcript. Verified by hitting the `info=recording` endpoint with both forms: underscore returns 0 bytes / `text/html`; dot returns the actual MP3 (`audio/mpeg`, ~64 KB). | In the workflow's `GET Recording (GVoIPC)` node, change the `id` expression from `{{ encodeURIComponent($('Normalize').item.json.uniqueid) }}` to `{{ encodeURIComponent($('Normalize').item.json.uniqueid.replace(/_/g,'.')) }}`. Keep the underscore form for `hs_call_external_id` (HubSpot is fine with either). |
| `GET CDR (GVoIPC)` returns empty body for every call | The workflow uses `info=SIMPLECDRS` with `direction=in&uniqueid=…`, but per the [MiRTA proxyapi docs](https://www.mirtapbx.com/manual/index.php/Proxyapi) `SIMPLECDRS` only accepts `tenant`, `calleridnum`, `start`, `end` — uniqueid filtering is not a parameter for that endpoint. | Either switch the node to `reqtype=CDR` (separate top-level reqtype that does take uniqueid), or use SIMPLECDRS with the documented params (`calleridnum=<src>&start=<call_date>&end=<call_date>`). Out of scope for the current transcription fix — but worth fixing if you want CDR enrichment to populate the body. |
| GVoIPC's API returns `Too bad... you mistaken the security api key.` for `info=VERSION` or `info=TENANTS` | These are admin/full-access endpoints that a read-only key (`API_READ_ONLY` per the customer's naming) is **not authorized** to hit. **This is NOT a sign that the key is invalid for SIMPLECDRS or recording lookups.** The same key works fine for `info=recording`. | Don't probe admin endpoints with a read-only key — and don't infer key validity from their response. Test the specific endpoint your workflow uses. |
| GVoIPC's API silently returns `HTTP 200, Content-Length: 0` for many error paths | MiRTA's `proxyapi.php` returns empty bodies (rather than error messages) for: invalid `info=` value, missing query params for that endpoint, lookup miss on a valid endpoint, missing-permission for some endpoints. | Don't infer "auth failure" from empty body. Cross-check by hitting an endpoint your key IS authorized for; if THAT also returns empty, look at the query params. Look at the docs first to verify param names. |

## See also

- `../n8n-freepbx-runbook.md` — original chronological narrative with every dead end
- `../n8n-freepbx-conversation.md` — full session transcript
