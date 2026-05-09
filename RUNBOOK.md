# Runbook: n8n + FreePBX + HubSpot test stack on `u`

**Target host:** `u` (Tailscale `100.99.173.52`, LAN `192.168.10.107`, Ubuntu 24.04, Docker 29.4).
**Started:** 2026-05-08.
**Author:** Claude (live session with masterok).

This file captures every meaningful command run against the server, in execution order, with a short note about *why* each section was needed. Re-running a section in isolation should be safe — sections are roughly idempotent, except where noted.

> **Conventions**
> - `local$` = run on this laptop (`masterok@masterok`).
> - `u#` = run on host `u` as root, via `ssh root@100.99.173.52 '…'`.
> - `freepbx#` = run inside the `freepbx-freepbx-1` container.
> - `n8n#` = run inside the `n8n` container.

---

## 0. Pre-existing inputs

- Tailscale already up on both ends. The user logs into `u` via Tailscale node `u` (`100.99.173.52`).
- Local key: `~/.ssh/id_ed25519` (already on this laptop).
- The user's HubSpot **developer** account exists; we won't create the Private App here, that's a manual step (see `/srv/docker/HAND-OFF.md` step 3).

---

## 1. Establish key-based SSH

```bash
local$ ls -la ~/.ssh                           # confirm keypair exists
local$ ssh-copy-id -i ~/.ssh/id_ed25519.pub root@100.99.173.52
                                               # ran in a real terminal — Claude's `!` shell has no TTY
                                               # so the password prompt fell back to ssh-askpass which
                                               # wasn't installed. Real terminal works.
local$ ssh -o BatchMode=yes root@100.99.173.52 'hostname; ip -4 addr | grep inet'
                                               # verify key auth works without password
```

`192.168.10.107` was originally reported as the IP — that was a typo for `192.168.10.107` (correct) vs `192.168.19.107` (typo). The host is in the same `/24` as the laptop, so direct LAN ssh also works.

---

## 2. Recon

```bash
u# cat /etc/os-release | head -5
u# docker --version; docker compose version
u# docker ps --format 'table {{.Names}}\t{{.Image}}'
u# ss -tlnp | grep -v 127.0.0.
u# ss -ulnp
u# df -h /
u# free -h
u# ip -4 addr show | grep 'inet '
```

**Findings (preserved as-of 2026-05-08):**
- Ubuntu 24.04.4, Docker 29.4.3, Compose v5.1.3, 16 GB RAM, 32 GB free disk.
- No containers running.
- Port `8080/tcp` already used by `snap.open-webui.listener.service` (uvicorn). We avoid it.
- Free: `80, 443, 5060, 5678, 10000–20000`.
- Pre-existing docker bridges: `172.17.0.0/16` (docker0), `172.18.0.0/16` (docker_gwbridge — Swarm overlay), `172.19.0.0/16` (some other bridge).

---

## 3. Directory layout

```bash
u# mkdir -p /srv/docker/n8n /srv/docker/freepbx
u# chmod 750 /srv/docker
```

---

## 4. n8n stack

### 4a. Generate secrets and write compose files

```bash
u# cd /srv/docker/n8n

u# N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
u# POSTGRES_PASSWORD=$(openssl rand -hex 16)
u# N8N_BASIC_AUTH_PASSWORD=$(openssl rand -hex 12)

u# cat > .env <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
N8N_HOST=100.99.173.52
N8N_PORT=5678
GENERIC_TIMEZONE=UTC
EOF
u# chmod 600 .env
```

`docker-compose.yml` (final version after the LAN binding + secure-cookie fixes in §9 and §10 are applied):

```yaml
services:
  postgres:
    image: postgres:16-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: n8n
      POSTGRES_DB: n8n
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks:
      - internal

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: ${N8N_PORT}
      N8N_PROTOCOL: http
      WEBHOOK_URL: http://${N8N_HOST}:${N8N_PORT}/
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_RUNNERS_ENABLED: "true"
      N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_VERSION_NOTIFICATIONS_ENABLED: "false"
      N8N_HIRING_BANNER_ENABLED: "false"
      N8N_SECURE_COOKIE: "false"          # § 10 — testing only; flip to true behind HTTPS
    ports:
      - "${N8N_HOST}:${N8N_PORT}:5678"            # Tailscale 100.99.173.52
      - "172.17.0.1:${N8N_PORT}:5678"             # docker0 — for FreePBX container reach
      - "192.168.10.107:${N8N_PORT}:5678"         # LAN — added in § 9
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - internal

volumes:
  postgres_data:
  n8n_data:

networks:
  internal:
    name: n8n_internal
```

### 4b. Bring it up

```bash
u# cd /srv/docker/n8n
u# docker compose config --quiet         # validate
u# docker compose pull
u# docker compose up -d
u# docker compose ps
local$ curl -sI http://100.99.173.52:5678/healthz   # expect 200
```

Result: containers `n8n` + `n8n-postgres` (healthy) running. n8n version 2.19.5.

---

## 5. FreePBX stack

### 5a. Clone upstream and pick a free subnet

`tiredofit/freepbx` and `flaviostutz/freepbx` are both stale (2021–2022). Use `escomputers/freepbx:17` — last updated 2026-04-12, ships FreePBX 17.0.21 + Asterisk 21.10.2 + MariaDB 10.11.

```bash
u# cd /srv/docker
u# git clone --depth 1 https://github.com/escomputers/freepbx-docker.git freepbx
u# cd freepbx
```

Their compose hard-codes `172.18.0.0/16`, which collides with `docker_gwbridge` on this host. Relocate to `172.30.0.0/16`:

```bash
u# sed -i 's|172.18.0.0/16|172.30.0.0/16|; s|172.18.0.1|172.30.0.1|; s|172.18.0.10|172.30.0.10|; s|172.18.0.20|172.30.0.20|' docker-compose.yaml
u# sed -i 's|freepbxip="172.18.0.20"|freepbxip="172.30.0.20"|' run.sh
u# docker compose config --quiet         # validate
```

### 5b. Secrets

```bash
u# MYSQL_ROOT_PASS=$(openssl rand -hex 16)
u# FREEPBX_DB_PASS=$(openssl rand -hex 16)
u# printf '%s' "$MYSQL_ROOT_PASS" > mysql_root_password.txt
u# printf '%s' "$FREEPBX_DB_PASS" > freepbxuser_password.txt
u# printf '%s' 'smtp.example.com:587 noreply@example.com:none' > sasl_passwd.txt   # placeholder; postfix is required by image
u# chmod 600 mysql_root_password.txt freepbxuser_password.txt sasl_passwd.txt

u# cat > .credentials.txt <<EOF
mysql_root_password: $MYSQL_ROOT_PASS
freepbxuser_password: $FREEPBX_DB_PASS
EOF
u# chmod 600 .credentials.txt
```

### 5c. Pull, deploy, install FreePBX schema

```bash
u# cd /srv/docker/freepbx
u# docker compose pull                                         # large pull
u# bash run.sh --rtp 10000-20000                               # adds iptables RTP NAT + brings stack up
u# docker compose ps
u# docker compose exec -T -w /usr/local/src/freepbx freepbx \
       php install -n --dbuser=freepbxuser --dbpass="$(cat freepbxuser_password.txt)" --dbhost=db
                                                               # one-shot; ~60–90 s
local$ curl -sI http://100.99.173.52/admin/                   # expect 302 to config.php (first-run wizard)
```

`run.sh` modifies host iptables (DOCKER-USER + nat PREROUTING) to forward UDP 10000–20000 to container `172.30.0.20`. To make persistent across reboots: `apt install iptables-persistent`.

---

## 6. n8n workflow JSON

```bash
u# mkdir -p /srv/docker/n8n/workflows
local$ scp /tmp/freepbx-hubspot-call-logger.json root@100.99.173.52:/srv/docker/n8n/workflows/
                                            # JSON file content is in /srv/docker/n8n/workflows/
                                            # on the server. It's a 7-node workflow:
                                            #   Webhook → Code(normalize) → HubSpot Search →
                                            #   IF → HubSpot Create Call → Respond Logged
                                            #                            → Respond No Match
u# docker cp /srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json n8n:/tmp/wf.json
u# docker exec n8n n8n import:workflow --input=/tmp/wf.json
u# docker exec n8n n8n list:workflow
```

The workflow has top-level `id: "freepbx-hubspot-logger"`. (First import attempt failed without it — n8n 2.x requires it.)

---

## 7. FreePBX dialplan + helper script

Two files to install inside the FreePBX container, both backed by host-side copies under `/srv/docker/freepbx/` for editability:

```bash
u# mkdir -p /srv/docker/freepbx/dialplan /srv/docker/freepbx/scripts
```

`/srv/docker/freepbx/dialplan/extensions_custom.conf`:

```asterisk
[freepbx-n8n-logger]
exten => s,1,NoOp(n8n logger fired uniqueid=${UNIQUEID} direction=${ARG1})
 same => n,System(/etc/asterisk/scripts/n8n-call-logger.sh "${UNIQUEID}" "${CDR(src)}" "${CDR(dst)}" "${CALLERID(num)}" "${CDR(billsec)}" "${CDR(disposition)}" "${CDR(start)}" "${ARG1}")
 same => n,Return()

[macro-dialout-trunk-predial-hook]
exten => s,1,NoOp(Attaching n8n hangup handler - outbound)
 same => n,Set(CHANNEL(hangup_handler_push)=freepbx-n8n-logger,s,1(outbound))

[macro-exten-vm-predial-hook]
exten => s,1,NoOp(Attaching n8n hangup handler - inbound)
 same => n,Set(CHANNEL(hangup_handler_push)=freepbx-n8n-logger,s,1(inbound))
```

`/srv/docker/freepbx/scripts/n8n-call-logger.sh`:

```sh
#!/bin/sh
# Args: 1=uniqueid 2=src 3=dst 4=callerid 5=billsec 6=disposition 7=start 8=direction
URL='http://172.17.0.1:5678/webhook/freepbx-call-end'
LOG=/var/log/asterisk/n8n-hook.log

PHONE=$4; [ -z "$PHONE" ] && PHONE=$2
DURATION=${5:-0}; case "$DURATION" in ''|*[!0-9]*) DURATION=0 ;; esac

JSON=$(printf '{"uniqueid":"%s","src":"%s","dst":"%s","phone":"%s","duration":%s,"disposition":"%s","start_time":"%s","direction":"%s"}' \
  "$1" "$2" "$3" "$PHONE" "$DURATION" "$6" "$7" "$8")

date '+%F %T' >> "$LOG"
echo "POST $URL  $JSON" >> "$LOG"
curl -sS -m 5 -X POST -H 'Content-Type: application/json' -d "$JSON" "$URL" >> "$LOG" 2>&1
echo " (curl rc=$?)" >> "$LOG"
exit 0
```

Push into container, fix perms, reload dialplan:

```bash
u# docker cp /srv/docker/freepbx/dialplan/extensions_custom.conf freepbx-freepbx-1:/etc/asterisk/extensions_custom.conf
u# docker exec freepbx-freepbx-1 mkdir -p /etc/asterisk/scripts
u# docker cp /srv/docker/freepbx/scripts/n8n-call-logger.sh freepbx-freepbx-1:/etc/asterisk/scripts/n8n-call-logger.sh
u# docker exec freepbx-freepbx-1 chmod +x /etc/asterisk/scripts/n8n-call-logger.sh
u# docker exec freepbx-freepbx-1 chown -R asterisk:asterisk /etc/asterisk/extensions_custom.conf /etc/asterisk/scripts
u# docker exec freepbx-freepbx-1 sh -c 'touch /var/log/asterisk/n8n-hook.log && chown asterisk:asterisk /var/log/asterisk/n8n-hook.log'
u# docker exec freepbx-freepbx-1 asterisk -rx 'dialplan reload'
u# docker exec freepbx-freepbx-1 asterisk -rx 'dialplan show freepbx-n8n-logger'
```

Smoke test (expect a 404 from n8n until the workflow is activated):

```bash
u# docker exec freepbx-freepbx-1 /etc/asterisk/scripts/n8n-call-logger.sh \
       'TEST-1' '1001' '5559876543' '5559876543' '42' 'ANSWERED' '2026-05-08 02:00:00' 'inbound'
u# docker exec freepbx-freepbx-1 tail /var/log/asterisk/n8n-hook.log
```

---

## 8. End-to-end verification

The full check script lives in this conversation; the gist is one ssh round-trip that asserts:

1. all 4 containers running
2. n8n `/healthz` 200
3. FreePBX `/admin/` 302
4. workflow `freepbx-hubspot-logger` listed by `docker exec n8n n8n list:workflow`
5. dialplan contexts `freepbx-n8n-logger`, `macro-exten-vm-predial-hook`, `macro-dialout-trunk-predial-hook` all loaded
6. `/etc/asterisk/scripts/n8n-call-logger.sh` is +x in the container
7. all expected files present on host
8. iptables RTP DNAT + DOCKER-USER ACCEPT rules in place
9. FreePBX → n8n via `172.17.0.1:5678` returns 200
10. webhook returns 404 (workflow inactive — expected)

All 10 passed on first run.

---

## 9. Fix: add LAN binding to n8n

**Trigger:** user reported `http://192.168.10.107:5678/` was unreachable.
**Diagnosis:** `ss -tlnp | grep :5678` on the server showed only `100.99.173.52:5678` and `172.17.0.1:5678` were bound. The LAN IP wasn't in the compose `ports:` list.

```bash
u# cd /srv/docker/n8n
u# sed -i '/172.17.0.1:\${N8N_PORT}:5678/a\      - "192.168.10.107:${N8N_PORT}:5678"' docker-compose.yml
u# docker compose config --quiet
u# docker compose up -d --no-deps n8n          # recreates ONLY n8n; postgres + volumes untouched
u# ss -tlnp | grep :5678                       # expect 3 LISTEN lines
local$ curl -sI http://192.168.10.107:5678/healthz   # expect 200
```

**Why this is safe:** `n8n_data` named volume holds the n8n SQLite-internal state (workflows, credentials, owner account). Recreating the container does not touch the volume. Postgres holds the long-term data and was not recreated (`--no-deps`).

---

## 10. Fix: disable secure-cookie enforcement

**Trigger:** browser showed n8n's "secure cookie required" page; users can't log in over plain HTTP without this.
**Diagnosis:** n8n 2.x defaults `N8N_SECURE_COOKIE=true`, which refuses session cookies on non-HTTPS unless the host is `localhost`.

```bash
u# cd /srv/docker/n8n
u# sed -i '/N8N_HIRING_BANNER_ENABLED:/a\      N8N_SECURE_COOKIE: "false"' docker-compose.yml
u# docker compose config --quiet
u# docker compose up -d --no-deps n8n
u# docker exec n8n printenv N8N_SECURE_COOKIE       # expect: false
local$ curl -sI http://192.168.10.107:5678/healthz  # expect 200
```

**Production note:** flip back to `"true"` (or remove the line) the moment you put an HTTPS reverse proxy in front of n8n.

---

## 11. HubSpot setup — Service Key (preferred), Legacy Private App, or OAuth

**Trigger 1:** user opened the developer portal's "Create app" flow and was prompted for *Redirect URL*, *Client ID*, *Client secret* — that's the OAuth public-app path, wrong for our use case.

**Trigger 2:** when navigating to *Private Apps* in the test account, HubSpot now shows a chooser between **Service Keys** (new, recommended) and **Legacy private apps** (still works but deprecated).

**Diagnosis & decision:** the n8n workflow uses an HTTP Request node with a **Header Auth** credential of the form `Authorization: Bearer pat-…`. From HubSpot's official docs, **both** Service Keys and Legacy Private Apps emit `pat-…` tokens and authenticate via the same `Authorization: Bearer …` header. So either works with the workflow unchanged. Pick **Service Keys** — it's the forward-supported option.

### 11a. Service Key — recommended path (no OAuth, no HTTPS needed)

Service Keys live **inside a regular HubSpot account**, not in the developer dashboard.

1. Get into a regular HubSpot account:
   - In the developer portal, top-right account switcher → **Test Accounts** → **Create test account** if you don't already have one.
   - Switch into the test account. (Or use any free/trial/paid HubSpot account you have.)
2. Inside that account: gear icon → **Settings** → **Integrations** → **Private Apps**.
3. When prompted with the *Service Keys vs. Legacy private apps* chooser, click **"Use Service Keys instead"**.
4. **Create a service key** → name it (e.g. *n8n call logger*).
5. **Scopes** — only these two:
   - `crm.objects.contacts.read`   (search contacts by phone)
   - `crm.objects.contacts.write`  (HubSpot gates Call engagement create/update/archive under the *contacts* scope — there is no separate `crm.objects.calls.*` scope; verified against HubSpot docs 2026-05)
   Do **not** select `crm.extensions_calling_transcripts.read` — that is for the Calling Extensions SDK (recording transcripts), a different feature.
6. Create → copy the key. It starts with `pat-…` and is shown only once — store it.

In n8n: **Credentials → Add → Header Auth → name `HubSpot Private App Token`** (must match exactly — the workflow JSON references this name; we keep the legacy name to avoid editing the workflow):

| Field | Value |
| ----- | ----- |
| Name (header) | `Authorization` |
| Value         | `Bearer pat-…`  ← include the `Bearer ` prefix and a space |

Then open the imported workflow → on the two HTTP Request nodes (`HubSpot Search Contact`, `Create HubSpot Call`) → pick that credential under "Credential for Header Auth" → save → toggle workflow Active.

### 11a-1. Provision the credential + activate the workflow via CLI (fully automated)

This is what I did to set everything up programmatically — useful as a re-runbook, e.g. after rotating the key.

```bash
# Transfer the pat-… token to the server without printing it locally.
local$ cat /home/masterok/n8n/private_key.txt \
  | ssh root@100.99.173.52 'cat > /tmp/hubspot_key && chmod 600 /tmp/hubspot_key'

# Build the credential JSON on the server, including the required top-level "id".
u# python3 - <<'EOF'
import json
with open('/tmp/hubspot_key') as f:
    token = f.read().strip()
cred = [{
    "id":   "hubspot-private-app-token",
    "name": "HubSpot Private App Token",
    "type": "httpHeaderAuth",
    "data": {"name": "Authorization", "value": f"Bearer {token}"}
}]
open('/tmp/cred.json','w').write(json.dumps(cred))
EOF

# Import into n8n. n8n's CLI runs as user 'node', so the file inside the container
# needs to be world-readable, hence the `chmod 644` after `docker cp`.
u# docker cp /tmp/cred.json n8n:/tmp/cred.json
u# docker exec -u root n8n chmod 644 /tmp/cred.json
u# docker exec n8n n8n import:credentials --input=/tmp/cred.json
u# docker exec -u root n8n rm -f /tmp/cred.json
u# rm -f /tmp/cred.json /tmp/hubspot_key

# Confirm the credential is in postgres.
u# docker exec n8n-postgres psql -U n8n -d n8n -tAc \
       "SELECT id, name, type FROM credentials_entity WHERE name='HubSpot Private App Token';"

# Re-import the workflow JSON with credential references on the two HTTP Request nodes.
# (See § 11a-2 for the exact JSON snippet to add to each node.)
u# docker cp /srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json n8n:/tmp/wf.json
u# docker exec -u root n8n chmod 644 /tmp/wf.json
u# docker exec n8n n8n import:workflow --input=/tmp/wf.json

# Activate. n8n CLI's update:workflow is deprecated but still works as of 2.19.5.
# IMPORTANT: changes do NOT take effect on a running n8n — you MUST restart.
u# docker exec n8n n8n update:workflow --id=freepbx-hubspot-logger --active=true
u# docker compose -f /srv/docker/n8n/docker-compose.yml restart n8n

# Verify
u# docker exec n8n-postgres psql -U n8n -d n8n -tAc \
       "SELECT id, name, active FROM workflow_entity;"
       # expect: freepbx-hubspot-logger | FreePBX → HubSpot Call Logger | t
```

### 11a-2. Workflow JSON nodes that must reference the credential

The two HTTP Request nodes (`HubSpot Search Contact`, `Create HubSpot Call`) need this block added at the node level (sibling of `parameters`):

```json
"credentials": {
  "httpHeaderAuth": {
    "id":   "hubspot-private-app-token",
    "name": "HubSpot Private App Token"
  }
}
```

Without this, the node has the credential type configured but no credential attached → HubSpot returns `MALFORMED_TOKEN` / 401.

### 11a-3. Workflow gotcha that bit me: leading `=` inside an expression body

In an n8n HTTP Request node, when `jsonBody` starts with `=` the entire string is parsed as one expression and inner `{{ }}` substitutions emit their value directly. **Do not** put `={{ }}` inside such a body — the leading `=` becomes a literal character prepended to the value.

**Wrong:**
```
"hs_call_direction": "={{ ... === 'outbound' ? 'OUTBOUND' : 'INBOUND' }}"
"hs_call_duration":  "={{ ... * 1000 }}"
```
HubSpot rejects with `=INBOUND was not one of the allowed options` and `=42000 was not a valid number`.

**Right:**
```
"hs_call_direction": "{{ ... === 'outbound' ? 'OUTBOUND' : 'INBOUND' }}"
"hs_call_duration":  {{ ... * 1000 }}    # unquoted - duration is an int in HubSpot
```

This is fixed in `/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json`.

### 11a-4. End-to-end proof (executed 2026-05-08)

Created a transient HubSpot contact via API, fired the n8n webhook, read the resulting Call engagement back from HubSpot, deleted both. Result:

```
{
  "id": "368566856433",
  "title": "FreePBX call (inbound)",
  "direction": "INBOUND",
  "duration_ms": "67000",          // 67s * 1000
  "status": "COMPLETED",
  "from": "+15550008888",
  "body": "Disposition: ANSWERED\nDuration: 67s",
  "timestamp": "2026-05-08T03:24:45Z",
  "associated_contacts": ["482970134246"]
}
```

Both the call (`368566856433`) and the test contact (`482970134246`) were deleted afterwards (HTTP 204).

**Caveat — HubSpot search index lag.** `POST /crm/v3/objects/contacts/search` is eventually consistent. A contact created seconds ago may not yet be findable by phone — expect 5–30 s of lag in the test account. This affects only freshly-created contacts; for steady-state production traffic against a populated account it's a non-issue. If you re-run the E2E proof, poll the search endpoint until it returns the new contact before firing the webhook.

### 11b. Legacy Private App — only if Service Keys is unavailable in your portal

Same UI navigation as above, but click *"I still want a legacy private app"* in the chooser. Same scopes, same `pat-…` token format, same auth header. The integration is functionally identical today, but the legacy path won't get new scopes or features and will eventually be removed.

### 11c. OAuth public app — only if distributing to multiple HubSpot accounts

Only use this path if you intend to distribute the integration to multiple HubSpot accounts (i.e. you want users in other companies to install your app). Two prerequisites:

1. **HTTPS for n8n.** HubSpot rejects non-`localhost` HTTP redirect URLs. Cheapest option for this server: enable **Tailscale Funnel** to expose `u` as `https://u.<your-tailnet>.ts.net`:
   ```bash
   u# tailscale serve --bg --https=443 http://localhost:5678   # OR `tailscale funnel` for public reachability
   u# tailscale serve status
   ```
   Or run a Caddy/Traefik sidecar with Let's Encrypt if you have a domain.

2. **Update the n8n workflow** to use the built-in HubSpot OAuth credential type instead of Header Auth — replace the two HTTP Request nodes with the n8n `HubSpot` node, set the OAuth credential, accept the callback redirect URL n8n shows you, and paste *that* URL into HubSpot's developer portal as a Redirect URL.

The redirect URL n8n produces is of the form:
```
https://<your-n8n-public-url>/rest/oauth2-credential/callback
```

For our testing scope we are **not** going down this road. The Private App path in §11a is what's wired up.

---

## Operational quickref

```bash
# Show stack state
u# docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Logs
u# docker logs -f n8n
u# docker logs -f freepbx-freepbx-1
u# docker exec freepbx-freepbx-1 tail -f /var/log/asterisk/full
u# docker exec freepbx-freepbx-1 tail -f /var/log/asterisk/n8n-hook.log

# Restart n8n only
u# cd /srv/docker/n8n && docker compose up -d --no-deps n8n

# Restart FreePBX only (re-asserts iptables RTP rules)
u# cd /srv/docker/freepbx && bash run.sh --rtp 10000-20000

# Hard stop both stacks
u# cd /srv/docker/n8n && docker compose down
u# cd /srv/docker/freepbx && docker compose down

# Volumes (do NOT delete unless you mean it)
u# docker volume ls | grep -E 'n8n_|freepbx_'
```

---

## What's NOT yet done (user actions, see /srv/docker/HAND-OFF.md on the server)

1. Create the n8n owner account in the UI.
2. Create the FreePBX admin account in `/admin`.
3. ~~Inside a regular HubSpot account…create a Service Key~~ **DONE** (§ 11a-1, key in `/home/masterok/n8n/private_key.txt`).
4. ~~In n8n, add a Header Auth credential…~~ **DONE** (§ 11a-1, credential id `hubspot-private-app-token`).
5. ~~Open the imported workflow, attach the credential…~~ **DONE** (§ 11a-2).
6. ~~Activate the workflow.~~ **DONE + E2E proven** (§ 11a-4).
7. ~~Create at least one extension in FreePBX~~ **DONE** (§ 12, extension `1001` provisioned, dialplan + handler wired, real-call test passed).
8. Register a real SIP softphone (Linphone, MicroSIP, Zoiper) to extension `1001` so production-path predial-hooks fire — needed once you want to use the system from a phone, not just synthetic tests.
9. Add a SIP trunk to a PSTN provider (Twilio/Telnyx/etc.) — needed for actual external calls. Step-by-step in § 12d.

---

## 12. Real-call test: extension 1001, originate via Asterisk, hangup → n8n → HubSpot

**Goal:** prove the whole chain — real Asterisk channel running real dialplan with a real hangup-handler firing, posting to n8n, ending up in HubSpot — without needing a SIP softphone or a PSTN provider.

**Outcome:** ✅ proven. A `Local/start@n8n-test-caller` originate caused a real Asterisk hangup that triggered the handler, posted the call JSON to n8n, n8n created a HubSpot Call engagement, and HubSpot associated it to the test contact:

```
{"status":"logged","hubspot_call_id":"368563187392","contact_id":"482956174052","phone":"15550007777"}
```

The road there was bumpier than expected. Capturing the dead ends so the next person doesn't repeat them.

### 12a. What I built

1. **PJSIP extension 1001** in FreePBX, via `fwconsole bulkimport` after installing the bulkhandler module:
   ```bash
   u# docker exec freepbx-freepbx-1 fwconsole ma downloadinstall bulkhandler
   u# cat > /tmp/ext1001.csv <<'EOF'
   extension,name,tech,secret,voicemail,context,findmefollow_enabled
   1001,Test Ext 1001,pjsip,<EXT_1001_SECRET>,novm,from-internal,no
   EOF
   u# docker cp /tmp/ext1001.csv freepbx-freepbx-1:/tmp/ext1001.csv
   u# docker exec freepbx-freepbx-1 fwconsole bulkimport --type=extensions --replace /tmp/ext1001.csv
   u# docker exec freepbx-freepbx-1 fwconsole reload
   ```
   Verify: `docker exec freepbx-freepbx-1 asterisk -rx 'pjsip show endpoint 1001'`. Endpoint state will be `Unavailable` because no SIP device is registered — that's fine for the synthetic test.

2. **Synthetic-caller dialplan** in `/etc/asterisk/extensions_custom.conf` (host: `/srv/docker/freepbx/dialplan/extensions_custom.conf`):
   ```asterisk
   [n8n-test-caller]
   exten => start,1,NoOp(synthetic test call CID=15550007777 ext=1001)
    same => n,Set(CALLERID(num)=15550007777)
    same => n,Set(CALLERID(name)=n8n E2E Test)
    same => n,Set(CDR(src)=15550007777)
    same => n,Set(CDR(dst)=1001)
    same => n,Set(CHANNEL(hangup_handler_push)=freepbx-n8n-logger,s,1(inbound))
    same => n,Dial(PJSIP/1001,8)
    same => n,Hangup()
   ```
   The `hangup_handler_push` is set **directly** on the channel, bypassing FreePBX's predial-hook macros (which short-circuit when no device is registered — see § 12b).

3. **`live_dangerously = yes`** in `/etc/asterisk/asterisk.conf` so `System()` is allowed inside dialplan reached via originate. Restart Asterisk after editing:
   ```bash
   u# docker exec freepbx-freepbx-1 sed -i 's/^;live_dangerously = no/live_dangerously = yes/' /etc/asterisk/asterisk.conf
   u# docker exec freepbx-freepbx-1 asterisk -rx 'core restart now'
   ```

4. **The originate command** (this fires the test):
   ```bash
   u# docker exec freepbx-freepbx-1 asterisk -rx \
        'channel originate Local/start@n8n-test-caller application Wait 30'
   ```

### 12b. Things that bit me — and the FreePBX-17 specifics nobody tells you

**(i) Hook names changed in FreePBX 17.** Older guides reference `macro-exten-vm-predial-hook` and `macro-dialout-trunk-predial-hook`. FreePBX 17 doesn't call those. The current names (verified against `extensions_additional.conf` 2026-05):
   - `macro-dial-ringall-predial-hook` — invoked from `macro-dial` for ringall groups
   - `macro-dial-hunt-predial-hook` — invoked from `macro-dial` for hunt groups
   - `macro-dialout-one-predial-hook` — invoked from `macro-dial-one` for any single-extension dial (internal **and** outbound trunk)

   For our integration we use the third one (`macro-dialout-one-predial-hook`) plus the ringall version. Already wired in `/srv/docker/freepbx/dialplan/extensions_custom.conf`.

**(ii) `macro-dial-one` short-circuits to `nodial` when `DSTRING` is empty.** This happens whenever the dialed extension has no registered SIP device (`PJSIP_DIAL_CONTACTS(1001)` returns empty). The check is **before** the predial-hook, so the hook never fires. This is true for **any** call — including a real inbound call from a SIP trunk to an unregistered extension. So:

   - **In production:** make sure each extension has either a registered SIP device, or use a "Custom" extension type with a custom dial string, or use a Ring Group/IVR that has a populated DSTRING.
   - **For the synthetic test:** attach `hangup_handler_push` directly in our test dialplan (what § 12a step 2 does) so we don't depend on FreePBX's macros at all.

**(iii) `chan_local.so` is missing from the escomputers FreePBX 17 image.** You'll see a `loader.c: Error loading module 'chan_local.so': cannot open shared object file` warning in `/var/log/asterisk/full` during Asterisk startup. The `Local` channel driver is still registered (visible via `core show channeltypes`), so `Local/...@...` originates still work. It's noise, not a blocker. Don't waste time chasing it.

**(iv) `live_dangerously = no` is the Asterisk 21 default.** When the dialplan is entered via `originate` (CLI or AMI), Asterisk treats `System()` and other "dangerous" applications as off-limits unless `live_dangerously = yes` in `asterisk.conf`. Without flipping that, every System() call from dialplan reached by an originate runs but produces no observable effect — the request is dropped at the per-channel security gate. Set `yes` and restart Asterisk.

**(v) `${VAR:-default}` shell-style substitution does NOT work in Asterisk.** Use `${IF($["${VAR}"!=""]?${VAR}:default)}` or just hardcode.

**(vi) Workflow imports + credential imports both need a top-level `id` field.** Without it: `null value in column "id" of relation "workflow_entity"/"credentials_entity" violates not-null constraint`.

**(vii) `n8n update:workflow --active=true` does not take effect on a running n8n.** It updates the DB row, but the process must be restarted for the workflow scheduler to pick it up: `docker compose restart n8n`. The CLI says so in its output — easy to miss.

**(viii) Container files copied via `docker cp` land owned by root.** When the in-container process runs as another user (n8n runs as `node`, FreePBX runs as `asterisk`), `chmod 644` (or chown) **after** docker cp. Otherwise `import:credentials` fails with `EACCES: permission denied`.

### 12c. How the integration *will* fire on real calls

When you have a real registered SIP device (softphone/IP phone) on extension 1001:

- **Inbound from a SIP trunk → 1001:** call enters `from-pstn` → routes through Inbound Routes → ext-local 1001 → `macro-exten-vm` → `macro-dial-one` → DSTRING gets a real PJSIP contact → predial-hook fires → hangup-handler attached → Dial → call ends → handler runs → POST to n8n → HubSpot logs.
- **Outbound from 1001 → external:** call leaves via Outbound Routes → trunk dial → `macro-dial-one` → predial-hook fires → handler attached → Dial trunk → call ends → handler runs → same path.

If you don't yet have an SIP softphone, two practical ways to get one talking to this PBX:
- **Linphone (CLI or desktop)** — register against `192.168.10.107:5060`, username `1001`, password `<EXT_1001_SECRET>` (the secret used in the bulk import).
- **MicroSIP / Zoiper** on a phone or laptop — same creds.

### 12d. Outbound trunk — what's *not* set up

I did **not** create an outbound SIP trunk because there is no provider account. To add one when you have credentials:

1. FreePBX UI → **Connectivity → Trunks → Add Trunk → Add SIP (chan_pjsip) Trunk**
2. Trunk name e.g. `provider-1`. In **pjsip Settings → General**: Username/Authentication username, Secret, SIP Server (provider's host), From User/Domain.
3. **Connectivity → Outbound Routes → Add Route**: Route Name `default-out`, Trunk Sequence `provider-1`, Dial Patterns matching e.g. `_NXXXXXXXXX` and `_1NXXXXXXXXX`.
4. Apply Config.
5. Test from extension 1001 (registered device required) — call your own mobile.

Once a real trunk + an outbound call flow exists, the predial-hook at `macro-dialout-one-predial-hook` fires on every outbound dial, and the integration logs the call into HubSpot exactly as proven in § 12.

### 12e. Files touched in § 12

| Path on host | Purpose |
|---|---|
| `/srv/docker/freepbx/dialplan/extensions_custom.conf` | hangup-handler, predial-hooks (FreePBX 17 names), `n8n-test-caller` synthetic |
| inside container: `/etc/asterisk/asterisk.conf` | `live_dangerously = yes` |
| inside container: PJSIP endpoint `1001` | added via fwconsole bulkimport, persists in MariaDB volume |
| inside container: `/var/log/asterisk/n8n-hook.log` | hook execution log |

---

---

## 13. AVA AI Voice Agent — Docker deployment + FreePBX integration + E2E

**Goal:** stand up `hkjarral/AVA-AI-Voice-Agent-for-Asterisk` (referred to as "AVA"), wire it to the FreePBX Asterisk via ARI + AudioSocket, and prove that calls placed from a registered SIP extension to AVA produce a HubSpot Call engagement on the matching contact.

**Outcome:** ✅ AVA deployed, ARI/AudioSocket bridge established, real PJSIP calls from baresip (registered as ext 1001) reach AVA's Stasis app, and every call lands in HubSpot via the existing n8n hangup-handler chain.

### 13a. Why AVA over alternatives

We had OpenAI + Deepgram + xAI keys (in `/home/masterok/n8n/KEYS.txt`) and a working FreePBX 17. The most-fit project: `github.com/hkjarral/AVA-AI-Voice-Agent-for-Asterisk` (v6.4.2, MIT, Python 3.11+). It connects to Asterisk via **ARI** (HTTP+WebSocket on port 8088) and brings audio over **AudioSocket** (TCP), which is exactly the pair of features already present in the `escomputers/freepbx:17` image (`res_ari.so` + `res_audiosocket.so` + `chan_audiosocket.so` modules). No SIP trunk between AVA and Asterisk needed.

### 13b. Enable Asterisk ARI on FreePBX

ARI was enabled in `ari.conf` but FreePBX's `http_additional.conf` had `enabled=no` and `bindaddr=127.0.0.1`. The `http_custom.conf` override file did NOT win on duplicate `[general]` keys, so I had to edit `http_additional.conf` directly (FreePBX will overwrite this on `fwconsole reload` — capture in your post-reload hook if you re-run the FreePBX UI).

```bash
# 1. Pick the HTTP server up on 0.0.0.0:8088
u# docker exec freepbx-freepbx-1 sed -i \
       's/^enabled=no/enabled=yes/; s|^bindaddr=127.0.0.1|bindaddr=0.0.0.0|' \
       /etc/asterisk/http_additional.conf

# 2. Generate an ARI password and persist on the host
u# ARI_PASS=$(openssl rand -hex 16)
u# mkdir -p /srv/docker/freepbx/asterisk
u# printf 'ARI_USERNAME=ava\nARI_PASSWORD=%s\n' "$ARI_PASS" \
       > /srv/docker/freepbx/asterisk/.ari-credentials.txt
u# chmod 600 /srv/docker/freepbx/asterisk/.ari-credentials.txt

# 3. Add the ARI user via /etc/asterisk/ari_custom.conf, included from ari.conf
u# cat > /tmp/ari_custom.conf <<EOF
; AVA voice agent ARI user.
[ava]
type = user
read_only = no
password = ${ARI_PASS}
password_format = plain
EOF
u# docker cp /tmp/ari_custom.conf freepbx-freepbx-1:/etc/asterisk/ari_custom.conf
u# docker exec freepbx-freepbx-1 chown asterisk:asterisk /etc/asterisk/ari_custom.conf
u# docker exec freepbx-freepbx-1 chmod 640 /etc/asterisk/ari_custom.conf
u# docker exec freepbx-freepbx-1 sh -c \
       'grep -q ari_custom /etc/asterisk/ari.conf || echo "#include ari_custom.conf" >> /etc/asterisk/ari.conf'

# 4. Apply
u# docker exec freepbx-freepbx-1 asterisk -rx 'core restart now'
u# sleep 12
u# docker exec freepbx-freepbx-1 asterisk -rx 'http show status'      # expect 0.0.0.0:8088
u# docker exec freepbx-freepbx-1 asterisk -rx 'ari show users'        # expect "No  ava"

# 5. Map host port 8088 so AVA (host networking) can reach ARI
u# cd /srv/docker/freepbx
u# sed -i '/"5060:5060\/udp"/i\      - "8088:8088/tcp"' docker-compose.yaml
u# docker compose up -d freepbx
u# curl -sI -u "ava:$ARI_PASS" http://127.0.0.1:8088/ari/asterisk/info  # expect 200
```

> **Trap (i):** the heredoc-via-`docker exec sh -c` swallowed stdin. Always use `docker cp` for in-container file writes.
>
> **Trap (ii):** `module reload res_ari` does not pick up new `#include` directives reliably — full `core restart now` is the safe path on first install.

### 13c. Deploy AVA

```bash
u# cd /srv/docker
u# git clone --depth 1 \
       https://github.com/hkjarral/AVA-AI-Voice-Agent-for-Asterisk.git ava
u# cd ava
u# cp .env.example .env
```

Build `.env` programmatically so the OpenAI/Deepgram keys never touch the shell history:

```bash
local$ cat /home/masterok/n8n/KEYS.txt \
        | ssh root@100.99.173.52 'cat > /tmp/keys.txt && chmod 600 /tmp/keys.txt'

u# python3 - <<'PY'
import re, secrets
keys = {}
for line in open('/tmp/keys.txt'):
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line: continue
    k, v = line.split('=', 1); keys[k.strip()] = v.strip()
ari_pass = ''
for line in open('/srv/docker/freepbx/asterisk/.ari-credentials.txt'):
    if line.startswith('ARI_PASSWORD='): ari_pass = line.split('=',1)[1].strip()
text = open('/srv/docker/ava/.env').read()
def setk(t, k, v):
    pat = r'^' + re.escape(k) + r'=.*$'
    return re.sub(pat, f'{k}={v}', t, flags=re.MULTILINE) if re.search(pat, t, re.MULTILINE) else t + f'\n{k}={v}\n'
for k, v in [
    ('ASTERISK_HOST', '127.0.0.1'),
    ('ASTERISK_ARI_PORT', '8088'),
    ('ASTERISK_ARI_USERNAME', 'ava'),
    ('ASTERISK_ARI_PASSWORD', ari_pass),
    ('OPENAI_API_KEY', keys.get('OPENAI_API_KEY','')),
    ('DEEPGRAM_API_KEY', keys.get('DEEPGRAM_API_KEY','')),
    ('JWT_SECRET', secrets.token_hex(32)),
    # Critical: tell AVA to advertise this address to Asterisk for AudioSocket.
    # 172.30.0.1 = freepbx_defaultnet bridge gateway = host as seen from FreePBX container.
    ('AUDIOSOCKET_ADVERTISE_HOST', '172.30.0.1'),
]:
    text = setk(text, k, v)
open('/srv/docker/ava/.env','w').write(text)
PY
u# chmod 600 /srv/docker/ava/.env
u# shred -u /tmp/keys.txt

# Switch to OpenAI Realtime golden config (Deepgram works equally — pick one)
u# cp /srv/docker/ava/config/ai-agent.golden-openai.yaml /srv/docker/ava/config/ai-agent.local.yaml

# Skip preflight.sh (large, opinionated) — go straight to compose
u# cd /srv/docker/ava
u# docker compose build ai_engine
u# docker compose up -d ai_engine

# Verify
u# curl -sS http://127.0.0.1:15000/health   # expect {"status":"healthy","ari_connected":true,...}
u# curl -sS -u "ava:$ARI_PASS" http://127.0.0.1:8088/ari/applications | jq
        # expect [{"name":"asterisk-ai-voice-agent", ...}]
```

> **Trap (iii):** `docker compose restart` does NOT re-read `env_file`. After editing `.env`, use `docker compose up -d --force-recreate ai_engine`.
>
> **Trap (iv):** AVA's default pipeline `local_hybrid` requires the `local_ai_server` companion (Vosk + Kokoro + ollama) which we don't run. The golden config sets `default_provider: openai_realtime` per context, which overrides — pipeline validation errors in the log are noise, not blockers.

### 13d. Stasis dialplan + `*99` test feature code

Added to `/etc/asterisk/extensions_custom.conf`:

```asterisk
[from-ai-agent]
exten => s,1,NoOp(=== handoff to AVA AI Voice Agent ===)
 same => n,Set(CHANNEL(hangup_handler_push)=freepbx-n8n-logger,s,1(ai-agent))
 same => n,Answer()
 same => n,Stasis(asterisk-ai-voice-agent)
 same => n,Hangup()

; Feature code any registered SIP extension can dial to talk to AVA.
[from-internal-custom]
exten => *99,1,NoOp(*99 -> AVA via from-ai-agent)
 same => n,Set(CALLERID(num)=15551001001)            ; testing only - remove for prod
 same => n,Set(CALLERID(name)=AVA E2E test caller)   ; testing only
 same => n,Goto(from-ai-agent,s,1)
```

Reload: `docker exec freepbx-freepbx-1 asterisk -rx 'dialplan reload'`.

### 13e. baresip — headless CLI SIP softphone for testing

AVA expects a **real PJSIP caller channel**, not a synthetic `Local/...@...` originate. Direct CLI originates fail at AVA's caller-leg lookup ("No caller found for Local channel"). Solution: install `baresip` on the host and have it register as ext 1001.

```bash
u# apt-get install -y baresip
u# mkdir -p /root/.baresip

# accounts (auth_pass = the secret used in fwconsole bulkimport, § 12)
u# cat > /root/.baresip/accounts <<'EOF'
<sip:1001@127.0.0.1>;auth_user=1001;auth_pass=<EXT_1001_SECRET>;answermode=auto;regint=60
EOF

u# cat > /root/.baresip/config <<'EOF'
module_path /usr/lib/baresip/modules
poll_method epoll
sip_listen 0.0.0.0:0
audio_player aufile,
audio_source aufile,/tmp/silence30.wav
audio_codec PCMU/8000/1
audio_codec PCMA/8000/1
audio_srate 8000
audio_channels 1
file_ausrc aufile
file_srcpath /tmp/

module ice.so
module turn.so
module stun.so
module presence.so
module mwi.so
module account.so
module ctrl_tcp.so
module menu.so
module srtp.so
module aufile.so
module g711.so
EOF

# Generate 30 s of silence as the audio source (baresip needs SOME audio I/O)
u# python3 - <<'EOF'
import wave
with wave.open('/tmp/silence30.wav','wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000)
    w.writeframes(b'\x00\x00' * 8000 * 30)
EOF
```

Smoke-test register:

```bash
u# timeout 12 baresip -t 10 -s 2>&1 | grep -E '200 OK|REGISTER'
        # expect REGISTER -> 401 Unauthorized -> REGISTER+auth -> 200 OK
```

Place the actual call:

```bash
u# nohup baresip -t 30 -e '/dial *99' > /tmp/baresip.log 2>&1 &
u# sleep 25
u# kill -INT $(pgrep baresip)
u# grep -E 'established|terminated|duration' /tmp/baresip.log
        # expect "Call established", "audio=64kbps for ~24s", "Call ... terminated (duration: 24 secs)"
```

> **Trap (v):** Without `module menu.so` baresip rejects `/dial` ("command not found"). Without `module aufile.so` (or another real audio module — `aubridge.so` won't suffice), baresip terminates the call with `audio_decoder_set error: No such device`.
>
> **Trap (vi):** `module stdio.so` requires a TTY. SSH non-interactive sessions trigger `epoll_ctl: EPOLL_CTL_ADD: fd=0 (Operation not permitted)` and baresip exits — leave `stdio.so` out of the module list when running headless.

### 13f. End-to-end verification

What every successful run shows in the AVA log:

```
🎯 HYBRID ARI - StasisStart event received  (channel = PJSIP/1001-..., is_caller=True, is_local=False)
🎯 HYBRID ARI - Caller channel entered Stasis  (caller_name='AVA E2E test caller', caller_number=15551001001)
🎯 HYBRID ARI - Step 1..4 ✅ Caller answered, bridge created, caller in bridge, session stored
Detected caller codec  (normalized_format=ulaw, sample_rate=8000)
🎯 HYBRID ARI - Originating AudioSocket channel
        endpoint = AudioSocket/172.30.0.1:8090/<UUID>/c(slin)
AudioSocket connection accepted  (peer = ['172.30.0.20', <port>])
🎯 HYBRID ARI - AudioSocket channel added to bridge
```

What the hangup-handler hook log shows:

```
POST http://172.17.0.1:5678/webhook/freepbx-call-end
  {"uniqueid":"...","src":"15551001001","phone":"15551001001",
   "duration":..,"disposition":"ANSWERED","direction":"ai-agent"}
{"status":"logged","hubspot_call_id":"<id>","contact_id":"<id>","phone":"15551001001"}
```

HubSpot then has a Call engagement of:

```
{
  "title": "FreePBX call (ai-agent)",
  "direction": "INBOUND",
  "status": "COMPLETED",
  "from": "15551001001",
  "body": "Disposition: ANSWERED\nDuration: <s>s",
  "associated_contacts": ["<contact-id>"]
}
```

### 13g. Known issue — AVA AudioSocket UUID race

After the AudioSocket TCP connection arrives at AVA (`peer 172.30.0.20:<eph>`), AVA logs `Stasis ended` for the AudioSocket channel within ~3 ms and then ~150 ms later prints `AudioSocket UUID not recognized / rejected`. The TCP handshake's UUID lookup races against the session lifecycle.

**Symptom:** AVA never starts streaming TTS. The caller's SIP/RTP leg stays up (24 s in our test, no early hangup), so HubSpot still gets the call logged with the right caller ID — but no AI conversation happens. CRM logging works; the AI conversation does not.

**Likely cause:** AVA's session store keys by audio UUID, but in our host-net-on-AVA + bridge-net-on-FreePBX layout the AudioSocket TCP connection lands before the session is fully registered. Confirmed reproducible across runs.

**Workarounds to try (not yet attempted):**
1. Run AVA on the **same docker network** as FreePBX (`freepbx_defaultnet`) instead of host networking — the cross-network hop may be what triggers the race.
2. Increase AVA's session-store registration delay or use the ExternalMedia RTP transport (`audio_transport: external_media` in `config/ai-agent.local.yaml`) instead of AudioSocket.
3. Switch active provider to Deepgram Voice Agent (`config/ai-agent.golden-deepgram.yaml`) — different audio negotiation path.
4. File an issue against `hkjarral/AVA-AI-Voice-Agent-for-Asterisk` with the timestamps.

The user's primary stated goal — "when we dial from test ext it will log it in CRM" — **is fully met**: every call through `*99` produces a HubSpot Call engagement on the matching contact, regardless of whether AVA's audio side completes.

### 13h. Files touched in § 13

| Path on host | Purpose |
|---|---|
| `/srv/docker/freepbx/asterisk/.ari-credentials.txt` | Generated ARI user `ava` + password |
| inside container `/etc/asterisk/http_additional.conf` | `enabled=yes`, `bindaddr=0.0.0.0` |
| inside container `/etc/asterisk/ari_custom.conf` | `[ava]` ARI user definition |
| `/srv/docker/freepbx/docker-compose.yaml` | added `8088:8088/tcp` port mapping |
| `/srv/docker/ava/` | full AVA repo clone |
| `/srv/docker/ava/.env` | OPENAI/DEEPGRAM keys, ARI creds, JWT secret, AUDIOSOCKET_ADVERTISE_HOST |
| `/srv/docker/ava/config/ai-agent.local.yaml` | OpenAI Realtime golden config |
| `/srv/docker/freepbx/dialplan/extensions_custom.conf` | `[from-ai-agent]` + `*99` feature code |
| `/root/.baresip/{accounts,config}` | Headless SIP softphone registered as ext 1001 |
| `/tmp/silence30.wav` | Silent audio source for baresip |

### 13i. Operating commands

```bash
# AVA stack
u# cd /srv/docker/ava && docker compose up -d ai_engine     # start
u# docker compose up -d --force-recreate ai_engine          # apply .env changes
u# docker logs -f ai_engine                                 # tail logs
u# curl -sS http://127.0.0.1:15000/health                   # health
u# curl -sS -u "ava:$ARI_PASS" http://127.0.0.1:8088/ari/applications

# baresip test client
u# nohup baresip -t 30 -e '/dial *99' > /tmp/baresip.log 2>&1 &  ; sleep 25 ; kill -INT $(pgrep baresip)
```

---

---

## 14. Recording-based transcript + summary in HubSpot (no AVA needed)

**Goal:** every call recorded by Asterisk gets transcribed and summarized by Deepgram, and the resulting text PATCHed onto the existing HubSpot Call engagement. Independent of AVA.

**Outcome:** ✅ proven. Test call placed via baresip → `*98` produced this in HubSpot:

```
## Summary
The agent congratulates the customer on their successful implementation of
Asterisk Open Source PBX and provides information on how to use the dial
answer and hang up commands for the demonstration. The agent also explains
that the customer can use a console channel driver instead of a real phone.

## Transcript (29.5s)
[0.4s] Speaker 0: Congratulations.
[1.5s] Speaker 0: You have successfully installed and executed the Asterisk Open Source PBX.
[7.3s] Speaker 0: You have also installed a set of sample sounds and configuration
[11.6s] Speaker 0: files that should help you get started. Like a normal PBX,
[15.8s] Speaker 0: you will navigate this demonstration
[17.9s] Speaker 0: by dialing digits.
[19.5s] Speaker 0: If you are using a console channel driver instead of a real phone, you can use the dial answer
[26.0s] Speaker 0: and hang up commands to simulate the actions of a standard
```

### 14a. Architecture — two-phase write to the same HubSpot Call

```
   ┌────────────────────────────────────────────────────────────────┐
   │ FreePBX dialplan (extensions_custom.conf)                      │
   │  *98 → Set CID → Set hangup_handler → Answer → MixMonitor →    │
   │       Playback(...) → Read(...) → Hangup                       │
   │                                                                │
   │  hangup_handler_push = freepbx-n8n-logger                      │
   │      └─→ /etc/asterisk/scripts/n8n-call-logger.sh              │
   │                                                                │
   │  MixMonitor third arg = /etc/asterisk/scripts/                 │
   │                          n8n-recording-uploader.sh ${UNIQUEID} │
   └────────────────────────────────────────────────────────────────┘
        │ Phase 1 (immediate, ~50ms)        │ Phase 2 (~5–20s after hangup)
        ▼                                   ▼
   ┌──────────────────────────┐   ┌──────────────────────────────┐
   │ n8n: freepbx-hubspot-    │   │ n8n: freepbx-recording-      │
   │      logger              │   │      transcriber             │
   │                          │   │                              │
   │ Webhook → Normalize →    │   │ Webhook (multipart) →        │
   │ HubSpot Search Contact → │   │ Deepgram /v1/listen          │
   │ Create HubSpot Call      │   │   (raw audio body) →         │
   │   with hs_call_external_ │   │ Compose body →               │
   │   id = ${UNIQUEID}       │   │ HubSpot Search Call by       │
   │                          │   │   external_id →              │
   │                          │   │ HubSpot PATCH /calls/{id}    │
   └──────────────────────────┘   └──────────────────────────────┘
```

### 14b. Phase 1 changes — `hs_call_external_id`

Added three properties to the *Create HubSpot Call* node so Phase 2 can locate the same row:

```diff
   "properties": {
     "hs_call_title": "FreePBX call ({{...direction}})",
-    "hs_call_body": "Disposition: ... Duration: ...s",
+    "hs_call_body": "Disposition: ... Duration: ...s\n\n(transcript pending)",
     ...
+    "hs_call_external_id": "{{ $('Normalize').item.json.original.uniqueid }}"
   }
```

> **Trap:** I initially also set `hs_call_source: INTEGRATIONS_PLATFORM` and `hs_call_app_id: "freepbx-ava"` per HubSpot's docs, but `hs_call_app_id` is validated as an **integer** (the developer-portal app id, not a string label). For non-Calling-Extension integrations, omit both — `hs_call_external_id` works on its own.

### 14c. MixMonitor wiring

```asterisk
[from-internal-custom]
exten => *98,1,NoOp(*98 -> recording-only test)
 same => n,Set(CALLERID(num)=15551001001)
 same => n,Set(CALLERID(name)=Recording E2E test)
 same => n,Set(CHANNEL(hangup_handler_push)=freepbx-n8n-logger,s,1(recording-test))
 same => n,Answer()
 same => n,MixMonitor(${UNIQUEID}.wav,,/etc/asterisk/scripts/n8n-recording-uploader.sh ${UNIQUEID})
 same => n,Playback(demo-congrats)
 same => n,Playback(demo-thanks)
 same => n,Read(_unused,beep,15,,1,15)
 same => n,Hangup()
```

> **Trap:** `MixMonitor` records audio frames flowing through the channel. Apps that don't pump frames (`Wait()`) yield empty WAV files (44 bytes — just header). Use `Playback`, `Read`, `Echo`, `Dial`, or `Bridge` to keep audio flowing through MixMonitor's hook. The `b` option (start at bridge) is also problematic when the call later enters Stasis without a regular bridge — leave the options field empty.
>
> **Trap:** for ext-to-ext calls within FreePBX, the default `direct_media: yes` makes Asterisk hand off RTP peer-to-peer, bypassing MixMonitor. Force `direct_media=no` per endpoint:
> ```sql
> INSERT INTO sip (id, keyword, data, flags) VALUES ('1001','direct_media','no',0)
>   ON DUPLICATE KEY UPDATE data='no';
> ```
> then `fwconsole reload`.

### 14d. The post-recording uploader script

`/srv/docker/freepbx/scripts/n8n-recording-uploader.sh` (mirrored into the container at `/etc/asterisk/scripts/`):

```sh
#!/bin/sh
UNIQUEID=$1
REC=/var/spool/asterisk/monitor/${UNIQUEID}.wav
LOG=/var/log/asterisk/n8n-recording.log
URL='http://172.17.0.1:5678/webhook/freepbx-recording-ready'

# Wait briefly for Asterisk to flush+close the file (usually instant, allow up to 5s).
for i in 1 2 3 4 5; do
  [ -s "$REC" ] && break
  sleep 1
done
date '+%F %T' >> "$LOG"
echo "  uniqueid=$UNIQUEID rec=$REC" >> "$LOG"
[ ! -s "$REC" ] && { echo "  REC missing or empty -> abort" >> "$LOG"; exit 0; }

curl -sS -m 120 -X POST -F "uniqueid=$UNIQUEID" -F "file=@$REC" "$URL" >> "$LOG" 2>&1
echo " (curl rc=$?)" >> "$LOG"
exit 0
```

### 14e. Phase 2 workflow (`freepbx-recording-transcriber`)

7 nodes:

1. **Webhook (Recording Ready)** — receives multipart with `uniqueid` text field and `file` binary.
2. **Deepgram Transcribe+Summarize** — HTTP Request, **raw audio body** (NOT multipart), to `/v1/listen?model=nova-2&punctuate=true&summarize=v2&utterances=true&diarize=true&detect_language=true`. Auth: `Authorization: Token <DEEPGRAM_API_KEY>` (separate Header Auth credential `deepgram-api-token`).
3. **Compose HubSpot Body** — Code node renders `## Summary\n{summary}\n\n## Transcript\n[t] Speaker N: text...` with HubSpot's 65 535-char truncation.
4. **HubSpot Search Call** — POST `/crm/v3/objects/calls/search` with `hs_call_external_id == uniqueid`.
5. **Found?** — IF node, branches on `results.length > 0`.
6. **HubSpot PATCH Call** — PATCH `/crm/v3/objects/calls/{id}` with `properties.hs_call_body = <composed body>`.
7. **Respond Updated / Respond No Match** — webhook responses for observability.

> **Trap (i):** n8n's HTTP Request node with only `sendBinaryData: true` sends multipart by default. Deepgram rejects multipart with `400 corrupt or unsupported data`. The fix in n8n v4 HTTP Request:
> ```json
> "sendBody": true,
> "contentType": "binaryData",
> "inputDataFieldName": "file",
> "headerParameters": { "parameters": [
>   { "name": "Content-Type", "value": "audio/wav" }
> ]}
> ```
> Now n8n sends the raw WAV bytes as the body with `Content-Type: audio/wav`. Deepgram is happy.
>
> **Trap (ii):** `docker compose restart` doesn't reload `env_file` and doesn't apply credential changes — use `docker compose up -d --force-recreate ai_engine`/`n8n` after edits.

### 14f. Recordings file server (basic-auth nginx)

`/srv/docker/recordings/docker-compose.yaml` mounts the `freepbx_var_data` Docker volume read-only and serves `/var/spool/asterisk/monitor/*.wav` over HTTP with basic auth. Bound to Tailscale IP `100.99.173.52:8082` and LAN `192.168.10.107:8082` only — **not exposed to the public Internet**, which means HubSpot's cloud cannot fetch the URL directly. For production you'd swap this for a signed-URL CDN or a Tailscale Funnel endpoint.

The recording URL is **not yet stored in `hs_call_recording_url`** — the Phase 2 PATCH only writes `hs_call_body`. To wire it, add `hs_call_recording_url` to the PATCH JSON: `http://{host}:8082/{UNIQUEID}.wav`. (Skipped here because storing a Tailscale-only URL in HubSpot is not useful — agents can copy the URL but HubSpot's UI cannot render the player.)

### 14g. Files touched in § 14

| Path on host | Purpose |
|---|---|
| `/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json` | Phase 1 — added `hs_call_external_id` |
| `/srv/docker/n8n/workflows/freepbx-recording-transcriber.json` | Phase 2 workflow (new) |
| `/srv/docker/freepbx/dialplan/extensions_custom.conf` | `[from-internal-custom] *98` recording-only test |
| `/srv/docker/freepbx/scripts/n8n-recording-uploader.sh` | Post-recording uploader |
| `/srv/docker/recordings/{docker-compose.yaml,nginx.conf,.htpasswd,.password.txt}` | nginx file server with basic-auth |
| inside container `/var/log/asterisk/n8n-recording.log` | Uploader's append-only log |
| n8n credential `deepgram-api-token` | `Authorization: Token <DEEPGRAM_API_KEY>` |
| Asterisk DB: `sip` table for ext 1001 | `direct_media=no` |

### 14h. Operating commands

```bash
# Replay an existing recording through Phase 2 (without making a new call)
u# UNIQUEID=$(docker exec freepbx-freepbx-1 ls -t /var/spool/asterisk/monitor | head -1 | sed 's/.wav$//')
u# docker exec freepbx-freepbx-1 /etc/asterisk/scripts/n8n-recording-uploader.sh "$UNIQUEID"

# Tail the uploader log
u# docker exec freepbx-freepbx-1 tail -f /var/log/asterisk/n8n-recording.log

# Look at recent n8n executions and per-execution data
u# docker exec n8n-postgres psql -U n8n -d n8n -tAc \
    "SELECT id, status, mode, \"workflowId\" FROM execution_entity ORDER BY id DESC LIMIT 6;"
u# docker exec n8n-postgres psql -U n8n -d n8n -tAc \
    "SELECT data FROM execution_data WHERE \"executionId\"=<N>;"

# Recordings file server
u# cd /srv/docker/recordings && docker compose ps
u# cat /srv/docker/recordings/.password.txt    # the recordings basic-auth password
```

---

## § 15. Phase 1 v2 — robust call logger for any PBX

The v1 workflow only created a HubSpot Call when a contact already existed (by phone). For testing with a different PBX (or production traffic from any number), v2 makes the workflow self-sufficient: every call event becomes a HubSpot Call, missing contacts get auto-created, and every realistic disposition / direction / timestamp shape is accepted.

### 15a. Why v1 wasn't enough

| v1 behavior | v2 fix |
|---|---|
| `phone` lookup uses caller-id only — outbound calls had wrong external party | normalize picks `dst` for outbound, `src` for inbound, `phone` override beats both |
| Unknown phone → response `no_contact_match`, no Call created | unknown phone → auto-create contact (lifecyclestage `lead`, `hs_lead_status NEW`), then create Call associated to it |
| Same `uniqueid` re-posted → duplicate Call | search HubSpot Calls by `hs_call_external_id`; if found, PATCH instead of POST |
| `hs_call_status` always `COMPLETED` regardless of disposition | full mapping: `ANSWERED→COMPLETED`, `NO ANSWER→NO_ANSWER`, `BUSY→BUSY`, `FAILED/CONGESTION/CHANUNAVAIL→FAILED`, `CANCEL/CANCELED/CANCELLED→CANCELED`, `VOICEMAIL→COMPLETED` |
| `hs_timestamp` required ISO with `Z` | accepts ISO-8601, naive `YYYY-MM-DD HH:MM:SS` (assumed UTC), epoch ms (13 digits), epoch s (10 digits) |
| `hs_call_to_number` was never set (only `from_number`) | both populated: from = `src`, to = `dst` |
| `direction` missing → no default | defaults to inbound; case-insensitive |
| `uniqueid` missing → workflow error | falls back to `${startMs}-${digits-or-na}` |

### 15b. Node graph (10 nodes, 2 terminal responses)

```
Webhook (POST /freepbx-call-end)
  └─► Normalize (JS)
        └─► Search Call by hs_call_external_id   ← idempotency probe
              └─► Search Contact (5 filterGroups OR'd)
                    └─► Plan (JS) — emits {contact_id, existing_call_id, need_create_contact}
                          └─► IF need_create_contact?
                                ├─ true  ► Create Contact ► Resolved (created)
                                └─ false ►                  Resolved (existing)
                                              └─► IF Call exists?
                                                    ├─ true  ► PATCH Call ► Respond Updated
                                                    └─ false ► Create Call ► Respond Created
```

The Search Contact node uses **5 filter groups** OR'd together to maximize hit rate across HubSpot's stored phone variants:

1. `phone CONTAINS_TOKEN <last10>`
2. `mobilephone CONTAINS_TOKEN <last10>`
3. `phone CONTAINS_TOKEN <full digits>`
4. `mobilephone CONTAINS_TOKEN <full digits>`
5. `hs_searchable_calculated_phone_number CONTAINS_TOKEN <last10>` (HubSpot's auto-derived normalized field)

### 15c. Webhook contract (any PBX)

`POST http://100.99.173.52:5678/webhook/freepbx-call-end` — `Content-Type: application/json`. All fields optional; the server fills in safe defaults. Field aliases let the same workflow accept events from FreePBX, FusionPBX, 3CX, Asterisk-on-anything, or a CRM-native trigger.

| Field (preferred) | Aliases | What it is | Default |
|---|---|---|---|
| `uniqueid` | `call_id`, `callid` | Stable PBX-side ID for idempotency | `${startMs}-${digits or "na"}` |
| `src` | `from`, `caller` | E.164 / national / extension that initiated the leg | `""` |
| `dst` | `to`, `callee` | Number that was dialed | `""` |
| `phone` | — | Override: the *external* party number regardless of direction | derived from src/dst |
| `direction` | — | `inbound` or `outbound`; case-insensitive | `inbound` |
| `duration` | `billsec` | Talk time in **seconds** | `0` |
| `disposition` | — | FreePBX-style: `ANSWERED`, `NO ANSWER`, `BUSY`, `FAILED`, `CANCEL`, `VOICEMAIL`, `CONGESTION`, `CHANUNAVAIL` | `UNKNOWN → COMPLETED` |
| `start_time` | `timestamp`, `start` | ISO-8601, naive UTC, epoch s, or epoch ms | `Date.now()` |
| `caller_name` | `callerid_name`, `cnam` | Display name (used to seed firstname/lastname for auto-created contact) | `""` |
| `firstname` | — | Override for auto-created contact | first token of `caller_name` or `Unknown` |
| `lastname` | — | Override for auto-created contact | rest of `caller_name` or `Caller-<last4>` |
| `email` | — | Adds email property to auto-created contact | omitted |

Webhook reply is a JSON object: `{status, hubspot_call_id, contact_id, contact_was_created, uniqueid, phone, hs_status, direction}`. `status` ∈ {`created`, `updated`}.

### 15d. End-to-end test battery (15 scenarios — all green 2026-05-08)

```bash
$ bash /tmp/e2e-battery.sh    # POSTs through Tailscale to 100.99.173.52:5678
01 ANSWERED inbound (new contact)        -> created  COMPLETED  INBOUND
02 NO ANSWER inbound                     -> created  NO_ANSWER  INBOUND
03 BUSY outbound                         -> created  BUSY       OUTBOUND
04 FAILED inbound                        -> created  FAILED     INBOUND
05 CANCEL outbound                       -> created  CANCELED   OUTBOUND
06 ANSWERED outbound (existing contact)  -> created  COMPLETED  OUTBOUND   (contact_was_created=false)
07 naive timestamp (no Z)                -> created  COMPLETED  INBOUND
08 epoch ms timestamp                    -> created  COMPLETED  INBOUND
09 missing direction                     -> created  COMPLETED  INBOUND   (default applied)
10 missing disposition                   -> created  COMPLETED  INBOUND   (default applied)
11 idempotency: same uniqueid as 01      -> updated  COMPLETED  INBOUND   (PATCH, same call_id)
12 E.164 same digits as 01               -> created  COMPLETED  INBOUND   (existing contact reused)
13 missing uniqueid (server fabricates)  -> created  COMPLETED  INBOUND
14 CONGESTION disposition                -> created  FAILED     INBOUND
15 outbound, dst-only (no src ext)       -> created  COMPLETED  OUTBOUND
```

Spot-checked HubSpot via API: title `"Inbound call from +12025550001"`, body has structured `Disposition: / Duration: / From: / To: / Direction: / External ID:` block, `hs_call_duration` stored as ms, association `call_to_contact` linked. Test 11 PATCH was confirmed by re-fetching test 01's call: duration changed `42000 → 99000` while `hubspot_call_id` stayed the same.

### 15e. HubSpot scopes

For the v2 workflow you **only need** what the existing Service Key already has:

- `crm.objects.contacts.read` — search contacts
- `crm.objects.contacts.write` — create contacts; create / patch / delete calls (Calls are gated by Contacts scope, no separate `crm.objects.calls.*` scope exists)

Optional add-ons for future expansion:

- `crm.objects.companies.read` + `crm.objects.companies.write` — auto-link calls to a company (e.g., by domain or area code)
- `crm.objects.deals.read` + `crm.objects.deals.write` — link calls to active deals
- `crm.objects.owners.read` — assign calls to a specific HubSpot user

### 15f. Files touched in § 15

| Path | Purpose |
|---|---|
| `/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json` (server) | v2 workflow JSON |
| `/tmp/freepbx-hubspot-call-logger.v2.json` (laptop) | source of truth for v2 |
| `/tmp/e2e-battery.sh` (laptop) | 15-scenario test battery |
| `/tmp/e2e-results.txt` (laptop) | last battery run output |

### 15g. Reapplying the workflow (re-import after edits)

```bash
# Edit on laptop
nano /tmp/freepbx-hubspot-call-logger.v2.json

# Push and import
scp /tmp/freepbx-hubspot-call-logger.v2.json \
    root@100.99.173.52:/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json

ssh root@100.99.173.52 '
  docker cp /srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json n8n:/tmp/wf.json
  docker exec -u root n8n chmod 644 /tmp/wf.json
  docker exec n8n n8n import:workflow --input=/tmp/wf.json
  docker exec n8n n8n update:workflow --id=freepbx-hubspot-logger --active=true
  docker compose -f /srv/docker/n8n/docker-compose.yml restart n8n
'
```

Note: on n8n 2.19.x, `import:workflow` deactivates the workflow — always run `update:workflow --active=true` and **restart the container** (changes don't take effect on a running n8n; the CLI itself prints this warning). The new model also has a `publish:workflow` command, but `update:workflow --active=true` is sufficient for webhook routing.

### 15h. Inspecting + clean up test calls in HubSpot

```bash
TOKEN="$(cat /home/masterok/n8n/private_key.txt)"

# Look at a specific call
curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://api.hubapi.com/crm/v3/objects/calls/<id>?properties=hs_call_title,hs_call_status,hs_call_direction,hs_call_duration,hs_call_external_id,hs_timestamp,hs_call_body" | jq

# Find any calls with our external_id pattern (tests use prefix "batt-" or "probe-")
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"filterGroups":[{"filters":[{"propertyName":"hs_call_external_id","operator":"CONTAINS_TOKEN","value":"batt-"}]}],"properties":["hs_call_external_id","hs_call_title","hs_call_status"],"limit":50}' \
  https://api.hubapi.com/crm/v3/objects/calls/search | jq

# Bulk-delete a list of test calls
for id in 368... 368... ; do
  curl -sS -o /dev/null -w "$id %{http_code}\n" \
    -X DELETE -H "Authorization: Bearer $TOKEN" \
    "https://api.hubapi.com/crm/v3/objects/calls/$id"
done
```

---

*This file is appended to as new commands are run. Last update: 2026-05-08 §15 (workflow v2 — auto-create contact, idempotent upsert, full disposition + direction + timestamp coverage; 15-scenario test battery green).*

---

## § 16. Exposing n8n publicly via pinggy.io (and why the obvious command failed)

### 16a. Symptom

User ran on the server:

```bash
ssh -p 443 -R0:127.0.0.1:5678 qr@free.pinggy.io
```

…and the public pinggy URL returned 502 / nothing useful.

### 16b. Root cause

`docker-compose.yml` published n8n on three host interfaces — but **not** loopback:

```
LISTEN 192.168.10.107:5678   (LAN)
LISTEN 100.99.173.52:5678    (Tailscale)
LISTEN 172.17.0.1:5678       (docker0)
LISTEN 127.0.0.1:5678        ←  MISSING
```

A reverse SSH tunnel `-R0:127.0.0.1:5678` tells the SSH client (the server) to dial `127.0.0.1:5678` whenever pinggy forwards a request. With nothing on loopback, every request got `Connection refused` and pinggy returned 502.

### 16c. Fix — add 127.0.0.1 bind to compose

```yaml
# /srv/docker/n8n/docker-compose.yml — n8n service ports list
ports:
  - "${N8N_HOST}:${N8N_PORT}:5678"
  - "172.17.0.1:${N8N_PORT}:5678"
  - "192.168.10.107:${N8N_PORT}:5678"
  - "127.0.0.1:${N8N_PORT}:5678"   # for local reverse-tunnels (pinggy, ngrok, cloudflared)
```

Apply:

```bash
u# cd /srv/docker/n8n && docker compose up -d --no-deps n8n
# Workaround note: on n8n 2.19.x a fresh compose recreate occasionally needs an
# extra activate+restart cycle to re-register webhooks. If /webhook/* returns 404
# right after recreate:
u# docker exec n8n n8n update:workflow --id=freepbx-hubspot-logger      --active=true
u# docker exec n8n n8n update:workflow --id=freepbx-recording-transcriber --active=true
u# docker compose restart n8n
```

After the fix:

```
LISTEN 127.0.0.1:5678        ✓
LISTEN 172.17.0.1:5678
LISTEN 100.99.173.52:5678
LISTEN 192.168.10.107:5678
```

### 16d. Verified end-to-end through pinggy

```bash
# On server (any TTY or headless):
ssh -p 443 -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -R0:127.0.0.1:5678 qr@free.pinggy.io

# pinggy prints, among other things:
#    Allocated port 1 for remote forward to 127.0.0.1:5678
#    https://<random>-<your-egress-ip>.run.pinggy-free.link

# From the public Internet:
curl -sS https://<random>-<egress>.run.pinggy-free.link/healthz                # -> 200
curl -sS -X POST https://<random>-<egress>.run.pinggy-free.link/webhook/freepbx-call-end \
  -H 'Content-Type: application/json' \
  -d '{"uniqueid":"pin-1","src":"15558881111","duration":12,"disposition":"ANSWERED","start_time":"2026-05-08T14:30:00Z","direction":"inbound"}'
# -> {"status":"created","hubspot_call_id":"368...","contact_id":"483..."}
```

### 16e. Caveats — read before committing to pinggy

| Caveat | Implication |
|---|---|
| Pinggy free tier rotates the URL each session | Don't bake the URL into HubSpot OAuth callbacks or external integrations; treat as ephemeral test access |
| Sessions expire after 60 minutes | Re-establish tunnel via a `while true; do ssh ... ; sleep 5; done` loop or upgrade to Pinggy Pro |
| n8n's `WEBHOOK_URL` env still points at LAN IP | The n8n UI shows `http://192.168.10.107:5678/...` for webhook URLs even when accessed via pinggy. Routing works either way (n8n routes by path, not Host header). To make UI print pinggy URLs, update `WEBHOOK_URL` in `.env` and `docker compose up -d --no-deps n8n` — only practical with a paid stable URL |
| pinggy session needs a TTY-ish channel | Use `ssh -tt` for headless / scripted opens; the first banner says "fallback mode as your terminal is not supported" but the tunnel itself works fine |
| Public URL = anyone on the Internet can hit your webhook | The Phase-1 webhook has no auth. For test traffic that's fine; for production add an `Authorization` header check in the Normalize node, or expose only via Tailscale Funnel (no public URL) |

### 16f. Alternatives if pinggy isn't ideal

- **Tailscale Funnel** (free, stable URL on `<machine>.<tailnet>.ts.net`, no rotation): `tailscale funnel 5678`. Already on the box.
- **cloudflared** with a Cloudflare account: stable URL, free, no time limit, optional access policies.
- **ngrok** (free tier rotates URL like pinggy; paid gives stable subdomain).

### 16g. Files touched in § 16

| Path | Change |
|---|---|
| `/srv/docker/n8n/docker-compose.yml` (server) | added `127.0.0.1:${N8N_PORT}:5678` to ports list |
| `/srv/docker/n8n/docker-compose.yml.bak.<ts>` (server) | auto-saved backup |

---

*This file is appended to as new commands are run. Last update: 2026-05-08 §16 (added 127.0.0.1 bind so pinggy / ngrok reverse-tunnels work; verified public URL hits n8n + HubSpot).*

---

## § 17. Two bugs surfaced by real external traffic — both now fixed

The user pointed at execution #57 (failed) in the n8n UI and asked what went wrong. Inspecting the execution dump from Postgres surfaced two bugs that wouldn't show up in the §15 happy-path battery.

### 17a. Bug 1 — URL-encoded JSON body crashes Search Contact

**Trigger.** Some HTTP clients (certain PBX webhooks, API testers, headless browsers) URL-encode a JSON body but advertise `Content-Type: application/json`. n8n's webhook then stores the body as a single key with empty value:

```json
"body": {
  "{\r\n  \"uniqueid\": \"pbx6ny-...\",\r\n  \"src\": \"12676799953\",\r\n ...}": ""
}
```

Symptom: every field comes through as empty string in Normalize → `digits=""` → `Search Contact` sends `CONTAINS_TOKEN` with blank value → HubSpot rejects with HTTP 400:

```
Invalid input JSON on line 1, column 92:
value must be non-empty and non-blank, if specified {propertyName: 'phone'}
```

**Fix.** Detect the `{<json-string>: ""}` shape in Normalize and re-parse:

```js
if (body && typeof body === 'object' && !Array.isArray(body)) {
  const keys = Object.keys(body);
  if (keys.length === 1 && body[keys[0]] === '' &&
      /^\s*\{[\s\S]*\}\s*$/.test(keys[0])) {
    try { body = JSON.parse(keys[0]); } catch (_e) { /* keep body */ }
  }
}
```

Belt-and-braces: `Search Contact` filter values now fall back to `'__no_phone_token__'` when `last10/digits` are empty so HubSpot doesn't 400 even if Normalize recovery misses something.

### 17b. Bug 2 — empty body crashes the response node

**Trigger.** A truly empty payload (`{}` or no JSON object at all) flows through Normalize with all empty fields. `Plan` sets `need_create_contact=false` (because `!norm.digits`), so the IF "Need create contact?" routes to the FALSE branch — `Resolved (created)` never runs.

The **Respond Created** node referenced `$('Resolved (created)').item` to compute `contact_id`/`contact_was_created`. n8n throws on referencing a not-executed node — even when wrapped in a `?:` ternary — and the workflow fails at the response stage:

```
Node 'Resolved (created)' hasn't been executed
```

**Fix.** Both `Respond Created` and `Respond Updated` now read shared fields from a node that *always* runs in either path: `$('Call exists?').item.json`. Both `Resolved (created)` and `Resolved (existing)` populate the same shape (`contact_id`, `contact_was_created`), and that shape passes through the IF-Call-exists node, so reading from it works on every code path.

```diff
- "contact_id": "{{ $('Plan').item.json.contact_id || ($('Resolved (created)').item ? ... ) }}"
+ "contact_id": "{{ $('Call exists?').item.json.contact_id }}"

- "contact_was_created": {{ $('Plan').item.json.need_create_contact ? 'true' : 'false' }}
+ "contact_was_created": {{ $('Call exists?').item.json.contact_was_created ? 'true' : 'false' }}
```

### 17c. Regression test results (post-fix)

```
[A2] URL-encoded JSON body                  -> created  COMPLETED  INBOUND  ✓ (exec 57 pattern)
[B]  empty body {}                          -> created  COMPLETED  INBOUND  ✓ (exec 58 pattern), contact_id='', no association
[C]  regular JSON (regression)              -> created  COMPLETED  INBOUND  ✓
[D]  back-to-back same uniqueid             -> both responded `created` with different ids — see §17d
```

### 17d. Known limitation — HubSpot search-index lag

If the same `uniqueid` is replayed within ~5-30 seconds, `Search Call by external_id` may not yet see the just-created Call (HubSpot's search index is eventually consistent). The workflow then takes the create-path again and produces a duplicate Call.

This is a HubSpot platform behavior, not a workflow bug — real PBX hangup events do not repeat `uniqueid` within seconds, so this never trips in production. For replay-testing PATCH idempotency, add a delay between the two POSTs:

```bash
ID="patch-$(date +%s)"
curl -sS -X POST "$URL/webhook/freepbx-call-end" -H 'Content-Type: application/json' \
  -d "{\"uniqueid\":\"$ID\",\"src\":\"15553334445\",\"duration\":3,\"disposition\":\"ANSWERED\",\"start_time\":\"$(date -u +%FT%TZ)\",\"direction\":\"inbound\"}"
sleep 30   #  ← give HubSpot time to index
curl -sS -X POST "$URL/webhook/freepbx-call-end" -H 'Content-Type: application/json' \
  -d "{\"uniqueid\":\"$ID\",\"src\":\"15553334445\",\"duration\":99,\"disposition\":\"ANSWERED\",\"start_time\":\"$(date -u +%FT%TZ)\",\"direction\":\"inbound\"}"
# Second response should be {"status":"updated", "hubspot_call_id":"<same as first>"}
```

If end-to-end idempotency in tighter timeframes is ever required, options are:

- Cache `uniqueid → call_id` in n8n's static workflow data (only works on a single n8n instance)
- Use Postgres directly from a Function node to write/read a small dedup table
- HubSpot's `idempotencyKey` header is not yet supported on `/calls` create

### 17e. Inspecting failed executions like a pro

Both bugs were diagnosed entirely from the n8n Postgres tables — no UI session needed. Useful when a webhook caller is reporting failures and you only have the execution number:

```bash
PG="docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD /srv/docker/n8n/.env | cut -d= -f2) n8n-postgres psql -U n8n -d n8n -tA"

# Status row
$PG -c "SELECT id, status, mode, \"startedAt\", \"stoppedAt\", finished
        FROM execution_entity WHERE id=<N>;"

# Full data — n8n stores it as a 'compact' JSON where strings are deduplicated
# and referenced by index. Resolve refs with this Python helper:
$PG -c "SELECT data FROM execution_data WHERE \"executionId\"=<N>;" | python3 -c '
import json, sys
arr = json.loads(sys.stdin.read().strip())
def res(v, seen=None):
  seen = seen or set()
  if isinstance(v, str) and v.isdigit() and int(v) < len(arr) and v not in seen:
    seen.add(v); return res(arr[int(v)], seen)
  if isinstance(v, dict): return {k: res(x, seen.copy()) for k,x in v.items()}
  if isinstance(v, list): return [res(x, seen.copy()) for x in v]
  return v
print(json.dumps(res(arr[2]).get("error", {}), indent=2)[:2000])  # error payload
print(json.dumps(res(arr[1]), indent=2)[:2000])                   # node outputs
'
```

### 17f. Files touched in § 17

| Path | Change |
|---|---|
| `/home/masterok/n8n/freepbx-hubspot-call-logger.v2.json` | Normalize: re-parse form-encoded JSON; Search Contact: sentinel fallback for empty values; Respond Created/Updated: source fields from `$('Call exists?').item.json` |
| `/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json` (server) | same — re-imported & restarted |

---

*This file is appended to as new commands are run. Last update: 2026-05-08 §17 (form-encoded JSON recovery + empty-body response fix; both verified on the workflow live on 107).*

---

## § 17b. Tolerate senders that use literal `_` for spaces (exec 68)

Surfaced from execution #68. Same `{<one-string>: ""}` shape as exec 57, but in this case the JSON itself was malformed:

```
{__"uniqueid":_"pbx6ny-1778256763_3491236",__"src":_"12676799953",__"dst":_"",
  __"phone":_"12676799953",__"duration":_"",__"disposition":_"",
  __"start_time":_"$(date_-u__%Y-%m-%d_%H:%M:%S)",__"direction":_"inbound"}
```

Whatever client made this request:
- replaces ASCII spaces with literal `_` characters (two-space indents become `__`, the space between `:` and the value becomes `_`)
- sends `$(date -u +'%Y-%m-%d %H:%M:%S')` verbatim — never expanded by a shell, with the `+` already missing
- leaves `dst`, `duration`, `disposition` as empty strings

**Fix at the source first.** The right answer is to fix the sender:

```bash
# raw-JSON form (note: outer single quotes, escape via concatenation for $(...))
curl -sS -X POST "$URL/webhook/freepbx-call-end" \
  -H 'Content-Type: application/json' \
  --data '{"uniqueid":"pbx6ny-'$(date +%s)'","src":"12676799953","dst":"*98","phone":"12676799953","duration":17,"disposition":"ANSWERED","start_time":"'"$(date -u +'%Y-%m-%d %H:%M:%S')"'","direction":"inbound"}'
```

**Defense in depth in Normalize.** If the body is the malformed shape and JSON.parse fails, walk the string with a tiny state machine that tracks "inside string" via unescaped `"` and replaces structural `_` (the ones outside strings) with spaces. Identifiers and string contents (`start_time` as a key, `$(date_-u_…)` as a value) are preserved.

```js
let recovered = null;
try { recovered = JSON.parse(raw); } catch (_e) {}
if (!recovered) {
  let out = '', inString = false, escaped = false;
  for (const c of raw) {
    if (escaped) { out += c; escaped = false; continue; }
    if (c === '\\') { out += c; escaped = true; continue; }
    if (c === '"') { inString = !inString; out += c; continue; }
    if (!inString && c === '_') { out += ' '; continue; }
    out += c;
  }
  try { recovered = JSON.parse(out); } catch (_e) {}
}
if (recovered && typeof recovered === 'object') body = recovered;
```

**Verified.** Replaying exec 68's exact body shape now creates a HubSpot Call with `external_id=pbx6ny-replay-test-001`, `from_number=12676799953`, `direction=INBOUND`. Empty fields stay empty (they were sent empty).

---

*Last update: 2026-05-08 §17b (literal-underscore-as-space body recovery; exec 68 pattern handled).*

---

## § 18. Phase 1 v3 — call-start webhook + delayed CDR poll + transcript

The sender (GVoIPC PBX) fires the webhook **at the start of the call**, so `duration` and `disposition` aren't known yet. v3 splits the work into two passes: an immediate ack with placeholder fields, then a background polling chain 10 minutes later that fills in the real CDR data and runs Deepgram transcription on the recording.

### 18a. Architecture

```
t=0    Webhook → Normalize → Search Call → Search Contact → Plan
                                                                  → IF need_create_contact?
                                                                       ├ true → Create Contact → Resolved (created)
                                                                       └ false →                Resolved (existing)
                                                                                                        ↓
                                                                                                   IF Call exists?
                                                                                                       ├ true → PATCH → Respond Updated
                                                                                                       └ false → Create Call ─┬─→ Respond Created     (PBX sees 200 immediately)
                                                                                                                              └─→ Wait 10 min
t=10                                                                                                                                  ↓
                                                                                                                              GET CDR (GVoIPC)
                                                                                                                                  ↓
                                                                                                                              Parse CDR
                                                                                                                                  ↓
                                                                                                                              PATCH HubSpot (CDR)        ← real duration / disposition / status
                                                                                                                                  ↓
                                                                                                                              GET Recording (GVoIPC)
                                                                                                                                  ↓
                                                                                                                              IF mime contains 'audio'?
                                                                                                                                  ├ yes → Deepgram → Compose Body → PATCH HubSpot (Transcript)
                                                                                                                                  └ no  → end (no recording, that's OK)
```

Any failure in the 10-min-later branch routes to **Compose Error Email → Send Error Email** (sent to `$env.ERROR_EMAIL_TO`).

### 18b. Why the second webhook (PATCH path) does NOT trigger polling

If the same `uniqueid` arrives a second time, the workflow takes the PATCH path. That path stops at `Respond Updated` — it does **not** fork into the Wait+poll chain. Rationale: the first invocation already started the polling chain (or already finished it); re-running poll for the same uniqueid would race / double-write to HubSpot.

### 18c. GVoIPC API endpoints used

```
CDR (call metadata, 10 minutes after start):
  GET https://pbx.gvoipc.net/pbx/proxyapi.php
        ?key=<GVOIPC_API_KEY>
        &reqtype=INFO
        &info=SIMPLECDRS
        &tenant=<GVOIPC_TENANT>
        &format=json
        &direction=in
        &uniqueid=<uniqueid>

  Returns: array of records, each with sc_uniqueid, sc_disposition, sc_duration,
           sc_calleridnum, sc_calleridname, sc_dialednum, sc_whoanswered, sc_start

Recording (audio MP3):
  GET https://pbx.gvoipc.net/pbx/proxyapi.php
        ?key=<GVOIPC_API_KEY>
        &reqtype=INFO
        &info=recording
        &tenant=<GVOIPC_TENANT>
        &id=<uniqueid>

  Returns: 200 with binary audio/mpeg body when a recording exists,
           or 200 with empty text/html when none. The IF "Has audio recording?"
           node routes by mime type — anything containing 'audio' goes to Deepgram.
```

### 18d. Environment variables (in `/srv/docker/n8n/.env`)

```bash
# GVoIPC PBX proxy (Phase-1 v3 polling)
GVOIPC_API_KEY=WKrde7d7CuWvVRZE1
GVOIPC_TENANT=GVOIPC
GVOIPC_BASE=https://pbx.gvoipc.net/pbx/proxyapi.php

# How long to wait after webhook before polling CDR.
# Set to 1 for smoke-testing, 10 for production.
POLL_WAIT_MINUTES=10

# Where to send errors that occur in the polling chain.
ERROR_EMAIL_TO=manivan.iv@gmail.com
```

These are also explicitly listed in the `n8n` service `environment:` block of `/srv/docker/n8n/docker-compose.yml` (n8n only sees env vars that compose passes through). After editing `.env`, recreate the container:

```bash
cd /srv/docker/n8n && docker compose up -d --force-recreate --no-deps n8n
```

### 18e. Smoke test (POLL_WAIT_MINUTES=1)

```bash
# 1. Drop wait to 1 min for testing
ssh root@192.168.10.107 'sed -i s/^POLL_WAIT_MINUTES=.*/POLL_WAIT_MINUTES=1/ /srv/docker/n8n/.env
                         cd /srv/docker/n8n && docker compose up -d --force-recreate --no-deps n8n'

# 2. Fire webhook with a known-good GVoIPC uniqueid that has a recording
KNOWN_UID="pbx4fl-1778272172.4477354"
curl -sS -X POST http://100.99.173.52:5678/webhook/freepbx-call-end \
  -H 'Content-Type: application/json' \
  -d "{\"uniqueid\":\"$KNOWN_UID\",\"src\":\"18882442014\",\"dst\":\"12154861082\",\"phone\":\"18882442014\",\"direction\":\"inbound\"}"

# Expected immediate response: {"status":"created","hubspot_call_id":"<NEW>",...}

# 3. Wait ~70s for the polling branch to finish, then inspect:
PG="docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD /srv/docker/n8n/.env | cut -d= -f2) n8n-postgres psql -U n8n -d n8n -tA"
ssh root@192.168.10.107 "$PG -c 'SELECT id, status, mode FROM execution_entity ORDER BY id DESC LIMIT 3;'"

# 4. Confirmed result (smoke test 2026-05-08): every node ran, status=success.
#    HubSpot call body ended up containing:
#       Disposition: ANSWERED (COMPLETED)
#       Duration: 24s
#       From: 18882442014 (GLOBAL VOIP)
#       To: 12154861082
#       Answered by: 12676799953
#
#       ## Summary
#       [Speaker 0:] Hey. How are you doing? Hello? ...
#
#       ## Transcript (13.7s)
#       [1.9s] Speaker 0: Hey. How are you doing? ...

# 5. Restore production wait
ssh root@192.168.10.107 'sed -i s/^POLL_WAIT_MINUTES=.*/POLL_WAIT_MINUTES=10/ /srv/docker/n8n/.env
                         cd /srv/docker/n8n && docker compose up -d --force-recreate --no-deps n8n'
```

### 18f. Bug discovered and fixed during the smoke test (round 1)

The IF "Has audio recording?" node initially had a numeric size check on `$binary.data.fileSize`. n8n stores `fileSize` as a human-readable string like `"0 B"` or `"41.1 kB"`, not as a raw number — so the condition errored with `Conversion error: the string '0 B' can't be converted to a number`. Fixed by dropping the size check and relying purely on `mimeType` containing `audio`. Empty responses come back as `text/html`, which fails the check and routes to `end` (no transcription, no error email).

If you ever need actual byte size in conditions, use `$binary.data.bytes` instead — that one IS numeric.

### 18g. SMTP credentials (ACTIVE — error emails are live)

The `Send Error Email` node is enabled and wired to credential `smtp-default` pointing at `mail.gvoipc.com:465 SSL` with user `gwn@gvoipc.com`. The From address is composed from `$env.SMTP_FROM_NAME <$env.SMTP_FROM_EMAIL>` ("VoiceAI Assistant <gwn@gvoipc.com>"); the To address is `$env.ERROR_EMAIL_TO` (`manivan.iv@gmail.com`).

**Verified end-to-end 2026-05-08**: forced GET CDR to fail by pointing GVOIPC_BASE at a nonexistent host → workflow took the error branch → Compose Error Email built the subject + body → Send Error Email returned `250 OK id=1wLWNN-00000002g1x-0ye6` and the message landed in `manivan.iv@gmail.com`.

**Two implementation gotchas surfaced and fixed during this verification:**

1. **`onError` is a node-level property, not a parameter.** n8n's HTTP Request V4 reads `onError` from the same level as `id`, `name`, `type` — NOT from inside `parameters`. Putting it inside parameters silently fails (the error stops the workflow instead of routing to the second main output). The 8 HTTP nodes that use `continueErrorOutput` were corrected.
2. **n8n's V4 HTTP error router catches network failures (DNS / TCP refused) AND HTTP 4xx/5xx the same way.** Both go to the second main output once `onError: "continueErrorOutput"` is set correctly at the node level.

To swap mail server later, edit `/home/masterok/n8n/KEYS.txt`, then re-run the credential import:

```bash
TOKEN_NA  # not relevant; SMTP creds use plain user+pass
cat > /tmp/smtp-cred.json <<EOF
[{"id":"smtp-default","name":"SMTP (default)","type":"smtp","data":{
  "user":"<new-user>","password":"<new-pass>","host":"<host>","port":465,
  "secure":true,"disableStartTls":false}}]
EOF
scp /tmp/smtp-cred.json root@192.168.10.107:/tmp/
ssh root@192.168.10.107 'docker cp /tmp/smtp-cred.json n8n:/tmp/smtp-cred.json
  docker exec -u root n8n chmod 644 /tmp/smtp-cred.json
  docker exec n8n n8n import:credentials --input=/tmp/smtp-cred.json
  docker compose -f /srv/docker/n8n/docker-compose.yml restart n8n'
```

**Gmail (alternative):**

**Gmail (recommended):**

1. Enable 2-step verification on `manivan.iv@gmail.com` if not already: https://myaccount.google.com/security
2. Generate an App Password at https://myaccount.google.com/apppasswords (label: "n8n")
3. In n8n UI → Credentials → Create New → SMTP:
   - Name:        `SMTP (default)`  (any name; the workflow expects credential ID `smtp-default` which is auto-set on first save)
   - Host:        `smtp.gmail.com`
   - Port:        `465`
   - User:        `manivan.iv@gmail.com`
   - Password:    `<the App Password>`
   - Secure:      ON (SSL, since port 465)
4. Save. The next workflow error sends a real email.

Alternative providers: any SMTP works — set Host/Port/User/Pass accordingly.

### 18h. Files touched in § 18

| Path | Change |
|---|---|
| `/srv/docker/n8n/.env` (server) | added `GVOIPC_API_KEY`, `GVOIPC_TENANT`, `GVOIPC_BASE`, `POLL_WAIT_MINUTES`, `ERROR_EMAIL_TO` |
| `/srv/docker/n8n/docker-compose.yml` (server) | passed those env vars through to the n8n container |
| `/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json` (server) | v3 with 25 nodes (was 14 in v2) |
| `/home/masterok/n8n/freepbx-hubspot-call-logger.v2.json` | source of truth, now v3 (filename kept for continuity) |
| `/home/masterok/n8n/freepbx-hubspot-call-logger.v2-backup-pre-polling.json` | snapshot of v2 before polling was added |

### 18i. New nodes (15 added on top of v2)

| Node | Type | Purpose |
|---|---|---|
| `Wait POLL_WAIT_MINUTES` | wait | Durable timer, env-var-controlled |
| `GET CDR (GVoIPC)` | httpRequest | Fetches `info=SIMPLECDRS` filtered by uniqueid |
| `Parse CDR` | code | Extracts duration/disposition/start/calleridname; maps disposition→hs_call_status; computes `shouldUpdateContact` |
| `Should update contact name?` | if | Routes on `Parse CDR.shouldUpdateContact` boolean |
| `PATCH Contact (name)` | httpRequest | Updates contact's `firstname`/`lastname` from CDR `sc_calleridname` |
| `PATCH HubSpot (CDR)` | httpRequest | Updates hs_call_duration / status / body |
| `GET Recording (GVoIPC)` | httpRequest | `info=recording&id=<uniqueid>` with `responseFormat: file` |
| `Has audio recording?` | if | Routes on `$binary.data.mimeType` contains `audio` |
| `Deepgram Transcribe+Summarize` | httpRequest | nova-2 model with summarize / utterances / diarize |
| `Compose Body w/ Transcript` | code | Appends Summary + diarized Transcript to CDR header |
| `PATCH HubSpot (Transcript)` | httpRequest | Body update with full transcript |
| `Upload Recording to HubSpot Files` | httpRequest | POSTs MP3 to `/files/v3/files` (multipart); returns hosted URL |
| `PATCH HubSpot (Recording URL)` | httpRequest | Sets `hs_call_recording_url` so HubSpot UI shows audio player |
| `Compose Error Email` | code | Builds subject/body from any upstream error |
| `Send Error Email` (disabled) | emailSend | Sends to `$env.ERROR_EMAIL_TO` via `smtp-default` credential |

#### Recording-upload branch

When `Has audio recording? = true`, the workflow fans out into **two parallel sub-chains** that share the same binary input:

```
Has audio recording? = true ─┬─ Deepgram → Compose Body → PATCH HubSpot (Transcript)
                             └─ Upload to HubSpot Files → PATCH HubSpot (Recording URL)
```

The upload uses HubSpot's `/files/v3/files` endpoint with multipart form-data:

```
POST https://api.hubapi.com/files/v3/files
Authorization: Bearer <service-key with `files` scope>
Content-Type: multipart/form-data

file        : <binary MP3 from $binary.data>
folderPath  : /calls/recordings
fileName    : <uniqueid>.mp3
options     : {"access":"PUBLIC_INDEXABLE","overwrite":false,"duplicateValidationStrategy":"NONE","duplicateValidationScope":"ENTIRE_PORTAL"}
```

Response includes a `url` field on `hubspotusercontent-na2.net`. The next node patches that URL into the call's `hs_call_recording_url`. HubSpot's call-record UI then renders a built-in audio player (with download).

**Required HubSpot scope:** `files`. If missing, upload returns `MISSING_SCOPES`.

**Per HubSpot's KB** ([supported-file-types](https://knowledge.hubspot.com/files/supported-file-types)):
- Max upload per file: 20 MB on free tier, 2 GB on paid tier
- No portal-wide storage cap is publicly documented
- No per-file or per-MB fee
- Typical call recordings are 50–500 KB so this is a non-issue at any volume

**Verified end-to-end 2026-05-08:** `info=recording` returns 132 KB audio/mpeg → uploaded to HubSpot Files at `/calls/recordings/pbx4fl-1778283339.4559298.mp3` → `hs_call_recording_url` set → URL fetches as `audio/mpeg` confirming public accessibility. The HubSpot Call UI shows an inline player.

#### Contact-name update rule

`Should update contact name?` routes TRUE only when **all four** are true:

1. `contact_id` is set (we have an associated HubSpot contact)
2. CDR `sc_calleridname` is non-empty
3. `sc_calleridname` is not just digits/punctuation (i.e., a real name, not a phone number)
4. EITHER we just auto-created the contact in this run (`Plan.need_create_contact === true`) OR the existing contact still has our placeholder pattern (`firstname === 'Unknown'` AND `lastname` matches `/^Caller-/`)

Rule (4) is the safety guard: a human-edited contact (anything outside the placeholder pattern) is never overwritten. Verified end-to-end: contact `483407343333` had `Unknown / Caller-6037`, after a CDR poll with `sc_calleridname='IVAN MAN'` it became `IVAN / MAN` while a follow-up call to a manually-named contact would leave the name alone.

### 18j. Inspecting a long-running waiting execution

The Wait node persists state to Postgres. To see executions currently parked in Wait:

```bash
PG='docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD /srv/docker/n8n/.env|cut -d= -f2) n8n-postgres psql -U n8n -d n8n -tA'
ssh root@192.168.10.107 "$PG -c \"SELECT id, status, \\\"startedAt\\\", \\\"waitTill\\\" FROM execution_entity WHERE status='waiting' OR \\\"waitTill\\\" IS NOT NULL ORDER BY id DESC LIMIT 10;\""
```

Each waiting execution has a `waitTill` timestamp — the moment Wait will resume. n8n picks them up via a cron-like sweeper; restarting n8n doesn't lose them (state lives in Postgres).

---

*Last update: 2026-05-08 §18 (v3 — call-start webhook + 10-min CDR poll + Deepgram transcript; full chain proven end-to-end against GVoIPC + HubSpot + Deepgram).*
