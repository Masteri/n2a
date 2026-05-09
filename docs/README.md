# Stack documentation index

Living documentation for the **n8n + FreePBX + HubSpot + AVA + Deepgram** stack on host `u`
(Tailscale `100.99.173.52`, LAN `192.168.10.107`, Ubuntu 24.04, Docker 29.4).

Three companion artifacts live one directory up:

| File | What it is |
| --- | --- |
| [`../n8n-freepbx-runbook.md`](../n8n-freepbx-runbook.md) | Chronological narrative — every section, every gotcha, in build order |
| [`../n8n-freepbx-commands.sh`](../n8n-freepbx-commands.sh) | Copy-paste-ready shell command log |
| [`../n8n-freepbx-conversation.md`](../n8n-freepbx-conversation.md) | Full Claude Code session transcript |

The files in this `docs/` tree are **focused, current-state references** — short, up-to-date,
organized for "I need to know X about platform Y", not "tell me how we got here".

## Platforms

| File | Subject | Key state |
| --- | --- | --- |
| [`platforms/n8n.md`](platforms/n8n.md) | Workflow engine | 2 active workflows, Postgres-backed |
| [`platforms/freepbx-asterisk.md`](platforms/freepbx-asterisk.md) | PBX + dialplan | FreePBX 17, Asterisk 21, ARI on 8088 |
| [`platforms/ava.md`](platforms/ava.md) | AI voice agent | 0 errors, 2 cosmetic warnings |
| [`platforms/hubspot.md`](platforms/hubspot.md) | CRM | Service Key, 2-phase Call write |
| [`platforms/deepgram.md`](platforms/deepgram.md) | STT + summary | Used in Phase 2 transcription |
| [`platforms/baresip.md`](platforms/baresip.md) | Test softphone | Registered as ext 1001 |
| [`platforms/recordings-server.md`](platforms/recordings-server.md) | nginx file server | basic-auth on `:8082` |

## Topics

| File | Cross-cutting concern |
| --- | --- |
| [`topics/architecture.md`](topics/architecture.md) | Containers, networks, port map |
| [`topics/call-logging-pipeline.md`](topics/call-logging-pipeline.md) | Phase 1 — hangup-handler → n8n → HubSpot Call create |
| [`topics/transcription-pipeline.md`](topics/transcription-pipeline.md) | Phase 2 — MixMonitor → Deepgram → HubSpot PATCH |
| [`topics/credentials-and-secrets.md`](topics/credentials-and-secrets.md) | Where every secret lives |
| [`topics/troubleshooting.md`](topics/troubleshooting.md) | Symptom → cause → fix table |

## Runbooks

| File | When to read |
| --- | --- |
| [`runbooks/restart-services.md`](runbooks/restart-services.md) | Bringing things up/down |
| [`runbooks/add-extension.md`](runbooks/add-extension.md) | New SIP user |
| [`runbooks/test-end-to-end.md`](runbooks/test-end-to-end.md) | Full E2E smoke test |

## Top-level state at a glance

```
host u (192.168.10.107 LAN, 100.99.173.52 Tailscale)
├── /srv/docker/n8n/         — n8n + Postgres compose
├── /srv/docker/freepbx/     — FreePBX 17 + MariaDB compose
├── /srv/docker/ava/         — AVA AI voice agent
├── /srv/docker/recordings/  — nginx for recording downloads
└── /root/.baresip/          — CLI softphone config
```

Six containers, all healthy:
`n8n`, `n8n-postgres`, `freepbx-freepbx-1`, `freepbx-db-1`, `ai_engine`, `recordings`.

Two n8n workflows, both active:
`freepbx-hubspot-logger` (Phase 1) and `freepbx-recording-transcriber` (Phase 2).

## Maintenance rule

This documentation is **kept current with every infrastructure change**. See the
memory rule `docs-update-rule` for the standing instruction. After any task that
modifies a platform or its config, the relevant files here get updated alongside
the change — the runbook narrative stays append-only, these files stay current.
