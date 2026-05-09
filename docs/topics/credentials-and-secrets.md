# Credentials and secrets — where everything lives

| Secret | Type | Location | Used by |
| --- | --- | --- | --- |
| OpenAI API key | `sk-proj-…` | `/home/masterok/n8n/KEYS.txt` (laptop, chmod 600) → `/srv/docker/ava/.env` (server) | AVA Realtime + Phase-2 (TTS for tests), n8n Code nodes, OpenAI TTS for test WAV generation |
| Deepgram API key | 41-char | `/home/masterok/n8n/KEYS.txt` → `/srv/docker/ava/.env` + n8n credential `deepgram-api-token` | Phase 2 transcription, AVA Deepgram provider (disabled but key present) |
| xAI API key | `xai-…` | `/home/masterok/n8n/KEYS.txt` (not currently wired in) | reserved |
| HubSpot Service Key | `pat-naX-…` | `/home/masterok/n8n/private_key.txt` (laptop, chmod 600) → n8n credential `hubspot-private-app-token` | Phase 1 + Phase 2 HubSpot calls |
| Asterisk ARI password | 32-hex | `/srv/docker/freepbx/asterisk/.ari-credentials.txt` (root, chmod 600) → `/srv/docker/ava/.env` (`ASTERISK_ARI_PASSWORD`) → in-container `/etc/asterisk/ari_custom.conf` | AVA → Asterisk authentication |
| FreePBX ext 1001 secret | `<EXT_1001_SECRET>` (test value) | MariaDB `sip` table + baresip's `/root/.baresip/accounts` | SIP UA registration |
| MariaDB root password | 32-hex | `/srv/docker/freepbx/mysql_root_password.txt` (Docker secret) + `.credentials.txt` mirror | FreePBX schema |
| MariaDB freepbxuser password | 32-hex | `/srv/docker/freepbx/freepbxuser_password.txt` (Docker secret) + `.credentials.txt` mirror | FreePBX runtime |
| n8n Postgres password | 32-hex | `/srv/docker/n8n/.env` (`POSTGRES_PASSWORD`) | n8n service |
| n8n encryption key | 64-hex | `/srv/docker/n8n/.env` (`N8N_ENCRYPTION_KEY`) | n8n credential storage at-rest encryption |
| n8n basic auth password | 24-hex | `/srv/docker/n8n/.env` (`N8N_BASIC_AUTH_PASSWORD`) | unused (n8n's own user-management replaces it) |
| AVA admin UI admin password | bcrypt | `/srv/docker/ava/config/users.json` (default `admin`/`admin`, force-change on first login) | admin UI auth |
| AVA JWT secret | 64-hex | `/srv/docker/ava/.env` (`JWT_SECRET`) | admin UI session tokens |
| Recordings nginx basic auth | random | `/srv/docker/recordings/.password.txt` (root, plain) + `/srv/docker/recordings/.htpasswd` (bcrypt) | recordings file server |
| FreePBX admin (web UI) | first-run | set via FreePBX UI initial wizard | FreePBX UI |
| n8n owner | first-run | set via n8n UI initial wizard | n8n UI |
| SSH | ed25519 keypair | `~/.ssh/id_ed25519{,.pub}` (laptop) → `/root/.ssh/authorized_keys` (server) | shell access |

## Where keys flow into containers

| Container | env source | mount source |
| --- | --- | --- |
| `n8n` | `/srv/docker/n8n/.env` (env_file) | `/srv/docker/n8n/workflows/` (read-only conventional) |
| `n8n-postgres` | `/srv/docker/n8n/.env` | `n8n_postgres_data` volume |
| `freepbx-freepbx-1` | `/srv/docker/freepbx/.env` (`TIMEZONE` etc) | `mysql_root_password.txt`, `freepbxuser_password.txt` Docker secrets |
| `freepbx-db-1` | `/srv/docker/freepbx/.env` | same Docker secrets |
| `ai_engine` | `/srv/docker/ava/.env` (env_file) | `/srv/docker/ava/{src,config,data,scripts,models}` bind mounts |
| `admin_ui` | `/srv/docker/ava/.env` (env_file) | `/srv/docker/ava` bind-mounted at `/app/project` |
| `recordings` | none | `/srv/docker/recordings/{nginx.conf,.htpasswd}` + `freepbx_var_data:/srv:ro` |

## Rotation playbook (when a key leaks)

| Key | Rotation steps |
| --- | --- |
| HubSpot Service Key | Rotate in HubSpot UI → update `/home/masterok/n8n/private_key.txt` → re-run the credential build script in n8n: `cat ~/n8n/private_key.txt \| ssh root@u 'cat > /tmp/key && python3 .../cred-builder.py && docker cp ...; docker exec n8n n8n import:credentials --input=...'` → `docker compose -f /srv/docker/n8n/docker-compose.yml up -d --force-recreate n8n` |
| OpenAI / Deepgram API key | Rotate in respective UI → update `/home/masterok/n8n/KEYS.txt` → push to `/srv/docker/ava/.env` → `docker compose -f /srv/docker/ava/docker-compose.yml up -d --force-recreate ai_engine` → for n8n's Deepgram credential, re-run the Deepgram cred builder |
| ARI password | Generate new (`openssl rand -hex 16`) → update `/srv/docker/freepbx/asterisk/.ari-credentials.txt` → update `/etc/asterisk/ari_custom.conf` (via `docker cp` from host) → `docker exec freepbx-freepbx-1 asterisk -rx 'module reload res_ari'` → update `ASTERISK_ARI_PASSWORD` in `/srv/docker/ava/.env` → recreate ai_engine |
| ext 1001 SIP secret | FreePBX UI → Extensions → 1001 → Edit → save → update `/root/.baresip/accounts` |
| Recordings password | Regenerate htpasswd via `docker run --rm httpd:alpine htpasswd -nbB recordings <new>` → write to `/srv/docker/recordings/.htpasswd` → also overwrite `.password.txt` → `docker exec recordings nginx -s reload` |
| MariaDB / Postgres passwords | Painful — change in DB AND in `.env`/secret files AND restart consumers. Avoid unless leaked. |

## What's NOT in version control

Everything in this table is **on the box only**. None of it is committed to git anywhere on the laptop. Backup individually if you care about preservation across host rebuild.

## See also

- [`architecture.md`](architecture.md) — where each container reads its env from
- [`troubleshooting.md`](troubleshooting.md) — what symptoms imply which credential is wrong
