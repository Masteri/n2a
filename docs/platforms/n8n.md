# n8n

Workflow engine running both the call-logging (Phase 1) and recording-transcription (Phase 2) workflows.

## Where things live

| Path | Purpose |
| --- | --- |
| `/srv/docker/n8n/docker-compose.yml` | Stack definition (n8n + Postgres) |
| `/srv/docker/n8n/.env` | Secrets (POSTGRES_PASSWORD, N8N_ENCRYPTION_KEY, …) |
| `/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json` | Phase 1 workflow source |
| `/srv/docker/n8n/workflows/freepbx-recording-transcriber.json` | Phase 2 workflow source |

Workflows + credentials live inside the Postgres `n8n` database (volume `n8n_postgres_data`).
The JSON files are the authoritative source — re-import to recover.

## Containers

| Container | Image | Status |
| --- | --- | --- |
| `n8n` | `n8nio/n8n:latest` (pinned at v2.19.5 build time) | Up, healthy |
| `n8n-postgres` | `postgres:16-alpine` | Up, healthy |

## Network bindings

n8n listens on `5678/tcp` bound to:

- `100.99.173.52:5678` (Tailscale)
- `172.17.0.1:5678` (docker0 — for FreePBX container reach)
- `192.168.10.107:5678` (LAN)

## Active workflows

| ID | Name | Webhook path | Trigger |
| --- | --- | --- | --- |
| `freepbx-hubspot-logger` | FreePBX → HubSpot Call Logger | `/webhook/freepbx-call-end` | hangup-handler script |
| `freepbx-recording-transcriber` | FreePBX Recording → Deepgram → HubSpot | `/webhook/freepbx-recording-ready` | MixMonitor close-script |

## Credentials (n8n-side)

| ID | Name | Type | Used by |
| --- | --- | --- | --- |
| `hubspot-private-app-token` | HubSpot Private App Token | Header Auth | both workflows |
| `deepgram-api-token` | Deepgram API Token | Header Auth | Phase 2 only |

Both are `Authorization: <scheme> <key>` headers. HubSpot uses `Bearer pat-…`; Deepgram uses `Token …`.

## Common operations

```bash
# Tail logs
docker logs -f n8n

# Apply a workflow JSON change
docker cp /srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json n8n:/tmp/wf.json
docker exec -u root n8n chmod 644 /tmp/wf.json
docker exec n8n n8n import:workflow --input=/tmp/wf.json
docker exec n8n n8n update:workflow --id=freepbx-hubspot-logger --active=true
# IMPORTANT: changes do NOT take effect on a running n8n
docker compose -f /srv/docker/n8n/docker-compose.yml restart n8n

# Apply a .env change (env_file is NOT re-read on restart)
docker compose -f /srv/docker/n8n/docker-compose.yml up -d --force-recreate n8n

# Inspect executions
docker exec n8n-postgres psql -U n8n -d n8n -tAc \
  'SELECT id, status, mode, "workflowId" FROM execution_entity ORDER BY id DESC LIMIT 5;'

# Inspect a specific execution's data
docker exec n8n-postgres psql -U n8n -d n8n -tAc \
  'SELECT data FROM execution_data WHERE "executionId"=<N>;'
```

## Gotchas (still alive in our setup)

- **`docker compose restart` does not re-read `env_file`** — use `up -d --force-recreate`.
- **Workflow imports require a top-level `id` field**; without it, Postgres rejects with `null in column "id"`.
- **`update:workflow --active=true` does not take effect on a running n8n** — restart required.
- **`N8N_SECURE_COOKIE=false`** is set explicitly because we serve over HTTP. Flip to `true` (or remove) the moment you put HTTPS in front.
- **Editor URL forced to `100.99.173.52`** via `WEBHOOK_URL` env. If you move the box, update.

## See also

- [`../topics/call-logging-pipeline.md`](../topics/call-logging-pipeline.md) — Phase 1 design
- [`../topics/transcription-pipeline.md`](../topics/transcription-pipeline.md) — Phase 2 design
- `../n8n-freepbx-runbook.md` § 4, § 9, § 10 — historical narrative
