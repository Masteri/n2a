# Architecture — containers, networks, ports

Everything runs on one Ubuntu host (`u`). Six Docker containers across three Docker Compose projects, plus baresip on the bare host.

## Containers

```
host: u (Ubuntu 24.04)
│
├── /srv/docker/n8n/             docker compose project: n8n
│     ├── n8n               (n8nio/n8n:latest)         host:5678 (Tailscale + LAN + docker0)
│     └── n8n-postgres      (postgres:16-alpine)       network: n8n_internal (172.19.0.0/16)
│
├── /srv/docker/freepbx/         docker compose project: freepbx
│     ├── freepbx-freepbx-1 (escomputers/freepbx:17)   host:80, 443, 5060/udp, 8088
│     │                                                network: freepbx_defaultnet (172.30.0.0/16)
│     │                                                container IP: 172.30.0.20
│     │                                                iptables DNAT 10000-20000/udp → 172.30.0.20
│     └── freepbx-db-1      (mariadb:10.11)            same network, IP 172.30.0.10
│
├── /srv/docker/ava/             docker compose project: asterisk-ai-voice-agent
│     ├── ai_engine         (built locally)            HOST NETWORKING; binds 15000, 8090, 18080
│     └── admin_ui          (built locally)            HOST NETWORKING; binds 3003
│
├── /srv/docker/recordings/      docker compose project: recordings
│     └── recordings        (nginx:alpine)             host:8082 (LAN + Tailscale)
│                                                      mounts freepbx_var_data ro
│
└── baresip on bare host                               registers SIP UDP to 127.0.0.1:5060
```

## Networks

| Network | CIDR | Members |
| --- | --- | --- |
| host network | 192.168.10.107 (LAN), 100.99.173.52 (Tailscale) | host services + ai_engine + admin_ui + baresip |
| docker0 (default bridge) | 172.17.0.0/16 | n/a (just the gateway exists) |
| docker_gwbridge | 172.18.0.0/16 | Swarm overlay (pre-existing, untouched) |
| n8n_internal | 172.19.0.0/16 | n8n ↔ Postgres |
| freepbx_defaultnet | 172.30.0.0/16 | freepbx-freepbx-1 ↔ freepbx-db-1 |

> **Why 172.30 not 172.18:** the upstream `escomputers/freepbx-docker` compose targets 172.18 but that collides with Docker's `docker_gwbridge` on this host. We `sed`'d the compose to 172.30 at clone time.

## Inter-container reach matrix

The "freepbx → host" is the trickiest leg, used by both Phase 1 and Phase 2.

| From | To | Address used | Notes |
| --- | --- | --- | --- |
| `n8n` | host | `host.docker.internal` doesn't exist on Linux; uses docker0 gateway `172.17.0.1` | n8n itself listens on docker0:5678 |
| `freepbx-freepbx-1` | n8n | `http://172.17.0.1:5678` | docker0 gateway → host's n8n binding |
| `freepbx-freepbx-1` | host (for AVA AudioSocket) | `172.30.0.1:8090` | freepbx-net gateway → host where ai_engine listens |
| `ai_engine` (host net) | freepbx ARI | `127.0.0.1:8088` | Asterisk's port mapped to host |
| `recordings` (default bridge) | freepbx volume | bind-mount only — no network reach needed | |
| baresip (host) | Asterisk SIP | `127.0.0.1:5060` UDP | host's port mapping |

## Host port map (everything you can reach from the LAN/Tailscale)

| Port | Service | Auth |
| --- | --- | --- |
| 22 | sshd | key (root@u) |
| 80 / 443 | FreePBX web UI | first-run wizard then admin user |
| 5060/udp | SIP (PJSIP) | SIP auth (ext 1001 etc) |
| 8088 | Asterisk ARI | basic auth (`ava:<ari-pass>`) |
| 5678 | n8n editor + webhook | n8n owner login (UI) / unauthenticated (webhooks) |
| 15000 | AVA `ai_engine` health | none |
| 3003 | AVA admin UI | basic auth (`admin:<set-on-first-login>`) |
| 8082 | recordings nginx | basic auth (`recordings:<password>`) |
| 8080 | open-webui (pre-existing snap, not part of this project) | n/a |
| 10000-20000/udp | RTP | iptables DNAT to FreePBX |

## End-to-end packet flow for a call to `*99` (AVA path)

```
baresip → 127.0.0.1:5060           (SIP INVITE)
       → 127.0.0.1:10000-20000     (RTP)
                ↓
            FreePBX container 172.30.0.20:5060
            ↓
            from-internal-custom *99
              → from-ai-agent
                → MixMonitor( UNIQUEID.wav, … )
                → Stasis(asterisk-ai-voice-agent)
                          ↓ (ARI WebSocket)
                       ai_engine on host:15000
                          ↓ (ARI HTTP POST channels)
                       AudioSocket originate
                          → 172.30.0.1:8090     ← AVA listens here
                                ↓ (TCP)
                             ai_engine bridges PJSIP ↔ AudioSocket
                                ↓
                          OpenAI Realtime over WebSocket
            ↓
            Hangup → predial-hook → freepbx-n8n-logger
                                  → /etc/asterisk/scripts/n8n-call-logger.sh
                                          ↓
                                  POST http://172.17.0.1:5678/webhook/freepbx-call-end
                                          ↓
                                       n8n Phase-1 workflow
                                          ↓
                                       HubSpot Calls API (create)
            ↓
            MixMonitor closes WAV
                          → /etc/asterisk/scripts/n8n-recording-uploader.sh
                                ↓
                          POST http://172.17.0.1:5678/webhook/freepbx-recording-ready (multipart)
                                ↓
                             n8n Phase-2 workflow
                                ↓
                             Deepgram /v1/listen (raw audio body)
                                ↓
                             HubSpot Calls API (PATCH the same Call by external_id)
```

## See also

- [`../topics/call-logging-pipeline.md`](../topics/call-logging-pipeline.md)
- [`../topics/transcription-pipeline.md`](../topics/transcription-pipeline.md)
