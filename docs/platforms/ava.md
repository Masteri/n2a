# AVA AI Voice Agent

`hkjarral/AVA-AI-Voice-Agent-for-Asterisk` v6.4.2. Connects to Asterisk via ARI; bridges audio via AudioSocket. Currently active provider: **OpenAI Realtime**.

## Where things live

| Path | Purpose |
| --- | --- |
| `/srv/docker/ava/` | Cloned upstream repo |
| `/srv/docker/ava/.env` | All credentials + persona settings |
| `/srv/docker/ava/config/ai-agent.yaml` | Base config (lightly patched: removed broken pipelines) |
| `/srv/docker/ava/config/ai-agent.local.yaml` | Operator override (the file the wizard writes) |
| `/srv/docker/ava/data/` | call-history sqlite + other runtime data (chmod a+rwX) |

`.env` and `config/*` are bind-mounted into the container at `/app/`.

## Containers

| Container | Image | Notes |
| --- | --- | --- |
| `ai_engine` | `asterisk-ai-voice-agent-ai-engine:latest` (built locally) | host networking |
| `admin_ui` | `asterisk-ai-voice-agent-admin-ui:latest` (built locally) | host networking, port 3003 |

`local_ai_server` is **not run** — we use cloud APIs.

## Network

Host networking. AVA listens on:

| Port | Service | Bind |
| --- | --- | --- |
| `15000/tcp` | `ai_engine` health + Prometheus metrics | `0.0.0.0` |
| `8090/tcp` | AudioSocket (audio bridge from Asterisk) | `172.30.0.1` |
| `18080/tcp` | ExternalMedia RTP (unused but bound) | `172.30.0.1` |
| `3003/tcp` | `admin_ui` | `0.0.0.0` |

`172.30.0.1` is the freepbx-network bridge gateway = host as seen from inside the FreePBX container.

## Configured persona

Set via `.env` and `ai-agent.local.yaml`'s `contexts.default`:

| Setting | Value |
| --- | --- |
| `AI_NAME` | `Ava` |
| `AI_ROLE` | "Helpful receptionist for our company. Be concise, friendly, and professional. If a caller wants to schedule a meeting, request a demo, or speak with a specific person, capture their name, phone number, and reason for calling. Confirm details before ending. Keep responses under three sentences when possible" |
| `GREETING` | "Hello, you've reached Ava. How can I help you today?" |
| `default_provider` | `openai_realtime` |
| `active_pipeline` | `default` (Whisper → GPT → TTS-1, valid even though realtime override wins per-context) |

## Admin UI

| URL | Network |
| --- | --- |
| http://192.168.10.107:3003 | LAN |
| http://100.99.173.52:3003 | Tailscale |

Login: **`admin / admin`** (forced password change on first login).
Auth state stored in `/srv/docker/ava/config/users.json` (pbkdf2_sha256 hash).

## Health snapshot

```
status:           healthy
ari_connected:    true
audiosocket:      bind=172.30.0.1, advertise=172.30.0.1, port 8090
providers:        openai_realtime (ready), local (ready)
pipelines:        default { stt: openai_stt, llm: openai_llm, tts: openai_tts }
config_warnings:  []
```

## Common operations

```bash
# Restart engine (forces .env reload)
docker compose -f /srv/docker/ava/docker-compose.yml up -d --force-recreate ai_engine

# Restart admin UI
docker compose -f /srv/docker/ava/docker-compose.yml restart admin_ui

# Health
curl -sS http://127.0.0.1:15000/health | jq

# What Stasis apps does Asterisk see?
ARI_PASS=$(grep ARI_PASSWORD /srv/docker/freepbx/asterisk/.ari-credentials.txt | cut -d= -f2)
curl -sS -u "ava:$ARI_PASS" http://127.0.0.1:8088/ari/applications | jq

# Tail engine logs
docker logs -f ai_engine

# Switch active provider — edit ai-agent.local.yaml's contexts.default.provider, then restart
```

## Known issues

| Issue | Status |
| --- | --- |
| **AudioSocket UUID race** — TCP handshake from FreePBX → AVA arrives ~3 ms before AVA registers the session, so AVA rejects the UUID and the audio bridge tears down. CRM logging still works (caller channel persists). | code-level, not yet patched |
| **MiniMax + ElevenLabs adapter registration warnings** | Hardcoded discovery scan in `src/pipelines/orchestrator.py`. 2 warnings at every boot. Cosmetic. |

## Files touched (operator-managed, persist across image rebuilds)

| File | Why |
| --- | --- |
| `.env` | API keys, persona, ARI creds, `AUDIOSOCKET_ADVERTISE_HOST` |
| `config/ai-agent.local.yaml` | Provider toggles, default pipeline, contexts.default |
| `config/ai-agent.yaml` | **Base config edited** — removed 3 broken pipelines (`local_hybrid`, `local_hybrid_groq`, `hybrid_elevenlabs`). `.bak.<ts>` retained. |
| `config/users.json` | admin_ui auth |

## See also

- [`../topics/architecture.md`](../topics/architecture.md) — how AVA fits in the network/container layout
- [`../topics/troubleshooting.md`](../topics/troubleshooting.md) — known races + their workarounds
- `../n8n-freepbx-runbook.md` § 13, § 14 — historical narrative
