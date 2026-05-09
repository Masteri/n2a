# n2a — n8n + FreePBX + AVA voice-AI + HubSpot CRM, glued together

Self-contained reference for an AI-augmented PBX:

- **FreePBX 17 / Asterisk 21** in Docker — extensions, dialplan, MixMonitor, ARI
- **n8n** (Postgres-backed) — two workflows that bridge Asterisk events into HubSpot
- **AVA AI Voice Agent** (`hkjarral/AVA-AI-Voice-Agent-for-Asterisk`) — handles real conversations
- **Deepgram** — call recording → transcript + summary
- **HubSpot Service Key** — CRM destination, two-phase Call write
- **baresip** — headless CLI softphone for testing

## What's in this repo

```
.
├── docs/                    structured reference, organized by platform and topic
│   ├── README.md              start here
│   ├── platforms/             one file per service
│   ├── topics/                cross-cutting (architecture, pipelines, secrets, troubleshooting)
│   └── runbooks/              short action playbooks
├── server-snapshot/         current configs from the live host (sanitized)
│   ├── n8n/{docker-compose.yml, workflows/}
│   ├── freepbx/{docker-compose.yaml, dialplan/, scripts/}
│   ├── ava/ai-agent.local.yaml
│   └── recordings/{docker-compose.yaml, nginx.conf}
├── RUNBOOK.md               chronological narrative (every gotcha hit during the build)
└── commands.sh              flat copy-paste-ready command log
```

## Two pipelines, one stack

```
┌─ Phase 1 (immediate, ~50 ms after hangup) ───────────┐
│ Asterisk hangup-handler  →  n8n webhook  →  HubSpot  │
│   creates Call engagement with hs_call_external_id   │
└──────────────────────────────────────────────────────┘
┌─ Phase 2 (~5–20 s after hangup) ─────────────────────┐
│ MixMonitor closes WAV  →  uploader  →  n8n webhook   │
│   →  Deepgram (transcript + summary)                 │
│   →  HubSpot PATCH the same Call                     │
└──────────────────────────────────────────────────────┘
```

The shared key is Asterisk's `${UNIQUEID}` written to HubSpot as `hs_call_external_id`.

## Read order

1. [`docs/README.md`](docs/README.md) — top-level index
2. [`docs/topics/architecture.md`](docs/topics/architecture.md) — containers, networks, ports
3. [`docs/topics/call-logging-pipeline.md`](docs/topics/call-logging-pipeline.md) and [`docs/topics/transcription-pipeline.md`](docs/topics/transcription-pipeline.md) — how the data flows
4. [`docs/topics/troubleshooting.md`](docs/topics/troubleshooting.md) — every symptom we hit, and the fix
5. `RUNBOOK.md` if you want the full historical narrative

## What's deliberately NOT here

- Live API keys, ARI passwords, SIP secrets, SSH keys — all `.gitignore`'d
- Call recordings — too large + privacy-sensitive
- The full session transcript — contained tool-output fragments of secrets that are too risky to scrub line-by-line

## Reproducing this on a fresh host

The shortest path:

1. Read [`docs/topics/architecture.md`](docs/topics/architecture.md) to understand layout.
2. Use `commands.sh` as a section-by-section script — each step labelled.
3. Run with eyes open at sections marked **"Trap"** in `RUNBOOK.md`.
4. After each major step, update the relevant `docs/` file (this is the project's working norm).

## License

MIT — see [`LICENSE`](LICENSE) (or pick whatever).
