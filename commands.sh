#!/usr/bin/env bash
# =============================================================================
# n8n + FreePBX + HubSpot — flat command log
# =============================================================================
# Every meaningful command issued during the build, in execution order, with
# section markers matching n8n-freepbx-runbook.md.
#
# DO NOT run this top-to-bottom blindly. It is a re-runbook reference. Run a
# section at a time, after reading the corresponding section of the runbook.
#
# Conventions:
#   $LOCAL  = run on this laptop
#   $REMOTE = run on host `u` (Tailscale 100.99.173.52, LAN 192.168.10.107)
#             Reach via:  ssh root@100.99.173.52 '...'
#   $FPBX   = run inside the freepbx-freepbx-1 container
#   $N8N    = run inside the n8n container
#   $DB     = run inside the n8n-postgres container (or mariadb for freepbx)
# =============================================================================

set -euo pipefail

# ---------- 1. SSH key bootstrap (run from the laptop, real terminal) ----------
ls -la ~/.ssh
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@100.99.173.52     # MUST be a real terminal; Claude !-prompt has no TTY
ssh -o BatchMode=yes root@100.99.173.52 'hostname; ip -4 addr | grep inet'

# ---------- 2. Recon on u ----------
ssh root@100.99.173.52 'cat /etc/os-release | head -5'
ssh root@100.99.173.52 'docker --version; docker compose version'
ssh root@100.99.173.52 'docker ps --format "table {{.Names}}\t{{.Image}}"'
ssh root@100.99.173.52 'ss -tlnp | grep -v 127.0.0.'
ssh root@100.99.173.52 'ss -ulnp'
ssh root@100.99.173.52 'df -h /'
ssh root@100.99.173.52 'free -h'
ssh root@100.99.173.52 'ip -4 addr show | grep "inet "'
# Confirm port 8080 owner (open-webui snap), so we don't collide
ssh root@100.99.173.52 'ss -tlnp | grep ":8080 "'

# ---------- 3. Directory layout ----------
ssh root@100.99.173.52 'mkdir -p /srv/docker/n8n /srv/docker/freepbx && chmod 750 /srv/docker'

# ---------- 4. n8n stack ----------
# 4a. secrets + .env + docker-compose.yml
ssh root@100.99.173.52 'set -e
cd /srv/docker/n8n
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
N8N_BASIC_AUTH_PASSWORD=$(openssl rand -hex 12)
cat > .env <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
N8N_HOST=100.99.173.52
N8N_PORT=5678
GENERIC_TIMEZONE=UTC
EOF
chmod 600 .env'
# Then write docker-compose.yml — see runbook § 4 for full content; binds n8n to:
#   - 100.99.173.52:5678  (Tailscale)
#   - 172.17.0.1:5678     (docker0, for FreePBX container reach)
#   - 192.168.10.107:5678 (LAN)            <-- added in § 9
# and sets N8N_SECURE_COOKIE: "false"      <-- added in § 10

# 4b. bring up
ssh root@100.99.173.52 'cd /srv/docker/n8n && docker compose config --quiet && docker compose pull && docker compose up -d && docker compose ps'
curl -sI http://100.99.173.52:5678/healthz   # expect HTTP/1.1 200

# ---------- 5. FreePBX stack ----------
# 5a. clone upstream + relocate subnet (172.18 collides with docker_gwbridge on this host)
ssh root@100.99.173.52 'set -e
cd /srv/docker
git clone --depth 1 https://github.com/escomputers/freepbx-docker.git freepbx
cd freepbx
sed -i "s|172.18.0.0/16|172.30.0.0/16|;
        s|172.18.0.1|172.30.0.1|;
        s|172.18.0.10|172.30.0.10|;
        s|172.18.0.20|172.30.0.20|" docker-compose.yaml
sed -i "s|freepbxip=\"172.18.0.20\"|freepbxip=\"172.30.0.20\"|" run.sh
docker compose config --quiet'

# 5b. secrets (Docker secrets files; the upstream compose mounts these)
ssh root@100.99.173.52 'set -e
cd /srv/docker/freepbx
MYSQL_ROOT_PASS=$(openssl rand -hex 16)
FREEPBX_DB_PASS=$(openssl rand -hex 16)
printf "%s" "$MYSQL_ROOT_PASS" > mysql_root_password.txt
printf "%s" "$FREEPBX_DB_PASS" > freepbxuser_password.txt
printf "%s" "smtp.example.com:587 noreply@example.com:none" > sasl_passwd.txt   # placeholder
chmod 600 mysql_root_password.txt freepbxuser_password.txt sasl_passwd.txt
cat > .credentials.txt <<EOF
mysql_root_password: $MYSQL_ROOT_PASS
freepbxuser_password: $FREEPBX_DB_PASS
EOF
chmod 600 .credentials.txt'

# 5c. pull, run, install FreePBX schema
ssh root@100.99.173.52 'cd /srv/docker/freepbx && docker compose pull'
ssh root@100.99.173.52 'cd /srv/docker/freepbx && bash run.sh --rtp 10000-20000'   # iptables RTP NAT + compose up
ssh root@100.99.173.52 'cd /srv/docker/freepbx && docker compose ps'
ssh root@100.99.173.52 'cd /srv/docker/freepbx && docker compose exec -T -w /usr/local/src/freepbx freepbx php install -n --dbuser=freepbxuser --dbpass="$(cat freepbxuser_password.txt)" --dbhost=db'
curl -sI http://100.99.173.52/admin/   # expect HTTP/1.1 302 -> config.php (first-run wizard)

# ---------- 6. n8n workflow JSON import ----------
# Workflow JSON content is in /srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json
ssh root@100.99.173.52 'mkdir -p /srv/docker/n8n/workflows'
# scp the JSON, then:
ssh root@100.99.173.52 'docker cp /srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json n8n:/tmp/wf.json
                       docker exec -u root n8n chmod 644 /tmp/wf.json
                       docker exec n8n n8n import:workflow --input=/tmp/wf.json
                       docker exec n8n n8n list:workflow'

# ---------- 7. FreePBX dialplan + helper script ----------
ssh root@100.99.173.52 'mkdir -p /srv/docker/freepbx/dialplan /srv/docker/freepbx/scripts'
# scp /tmp/extensions_custom.conf  -> /srv/docker/freepbx/dialplan/extensions_custom.conf  (see runbook § 7)
# scp /tmp/n8n-call-logger.sh      -> /srv/docker/freepbx/scripts/n8n-call-logger.sh        (see runbook § 7)
ssh root@100.99.173.52 'set -e
docker cp /srv/docker/freepbx/dialplan/extensions_custom.conf freepbx-freepbx-1:/etc/asterisk/extensions_custom.conf
docker exec freepbx-freepbx-1 mkdir -p /etc/asterisk/scripts
docker cp /srv/docker/freepbx/scripts/n8n-call-logger.sh freepbx-freepbx-1:/etc/asterisk/scripts/n8n-call-logger.sh
docker exec freepbx-freepbx-1 chmod +x /etc/asterisk/scripts/n8n-call-logger.sh
docker exec freepbx-freepbx-1 chown -R asterisk:asterisk /etc/asterisk/extensions_custom.conf /etc/asterisk/scripts
docker exec freepbx-freepbx-1 sh -c "touch /var/log/asterisk/n8n-hook.log && chown asterisk:asterisk /var/log/asterisk/n8n-hook.log"
docker exec freepbx-freepbx-1 asterisk -rx "dialplan reload"'

# Smoke-test the script directly (does NOT prove dialplan firing — only that the script + n8n route work)
ssh root@100.99.173.52 'docker exec freepbx-freepbx-1 /etc/asterisk/scripts/n8n-call-logger.sh "TEST-1" "1001" "5559876543" "5559876543" "42" "ANSWERED" "2026-05-08 02:00:00" "inbound"
docker exec freepbx-freepbx-1 tail /var/log/asterisk/n8n-hook.log'
# Expected: 404 from n8n until the workflow is activated (§ 11a-1).

# ---------- 8. End-to-end verification (10 checks) ----------
ssh root@100.99.173.52 '
fail=0
ok() { printf "  OK   %s\n" "$*"; }; bad() { printf "  FAIL %s\n" "$*"; fail=1; }
for c in n8n n8n-postgres freepbx-freepbx-1 freepbx-db-1; do
  s=$(docker inspect -f "{{.State.Status}}" "$c" 2>/dev/null || echo missing)
  [ "$s" = "running" ] && ok "$c $s" || bad "$c $s"
done
code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://100.99.173.52:5678/healthz);              [ "$code" = 200 ] && ok n8n200 || bad "n8n $code"
code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://100.99.173.52/admin/);                    [ "$code" = 302 ] && ok fpbx302 || bad "fpbx $code"
docker exec n8n n8n list:workflow 2>&1 | grep -q "FreePBX" && ok wf || bad wf
docker exec freepbx-freepbx-1 asterisk -rx "dialplan show freepbx-n8n-logger" 2>&1 | grep -q "1 extension" && ok ctx || bad ctx
docker exec freepbx-freepbx-1 test -x /etc/asterisk/scripts/n8n-call-logger.sh && ok sh || bad sh
iptables -t nat -S PREROUTING 2>/dev/null | grep -q "10000:20000" && ok rtp_dnat || bad rtp_dnat
iptables -S DOCKER-USER       2>/dev/null | grep -q "10000:20000" && ok rtp_user || bad rtp_user
code=$(docker exec freepbx-freepbx-1 curl -s -o /dev/null -w "%{http_code}" -m 3 http://172.17.0.1:5678/healthz); [ "$code" = 200 ] && ok docker0 || bad docker0
code=$(curl -s -o /dev/null -w "%{http_code}" -m 3 -X POST http://100.99.173.52:5678/webhook/freepbx-call-end -H "Content-Type: application/json" -d "{\"phone\":\"x\"}"); [ "$code" = 404 ] && ok webhook404 || bad "webhook $code"
[ $fail -eq 0 ] && echo OK || echo FAIL
'

# ---------- 9. LAN binding fix ----------
ssh root@100.99.173.52 'cd /srv/docker/n8n
sed -i "/172.17.0.1:\${N8N_PORT}:5678/a\      - \"192.168.10.107:\${N8N_PORT}:5678\"" docker-compose.yml
docker compose config --quiet
docker compose up -d --no-deps n8n
ss -tlnp | grep ":5678"'
curl -sI http://192.168.10.107:5678/healthz   # expect HTTP/1.1 200

# ---------- 10. Disable secure-cookie enforcement (testing-only, not for HTTPS) ----------
ssh root@100.99.173.52 'cd /srv/docker/n8n
sed -i "/N8N_HIRING_BANNER_ENABLED:/a\      N8N_SECURE_COOKIE: \"false\"" docker-compose.yml
docker compose up -d --no-deps n8n
docker exec n8n printenv N8N_SECURE_COOKIE   # expect: false'
curl -sI http://192.168.10.107:5678/healthz

# ---------- 11. HubSpot Service Key + n8n credential + workflow activation ----------
# 11a-0. token already in /home/masterok/n8n/private_key.txt (chmod 600)

# 11a-1. transfer key without exposing it
cat /home/masterok/n8n/private_key.txt | ssh root@100.99.173.52 'cat > /tmp/hubspot_key && chmod 600 /tmp/hubspot_key'

# 11a-2. build credential JSON, import into n8n, capture credential id
ssh root@100.99.173.52 'set -e
python3 - <<EOF
import json
with open("/tmp/hubspot_key") as f: token = f.read().strip()
cred = [{"id":"hubspot-private-app-token","name":"HubSpot Private App Token","type":"httpHeaderAuth","data":{"name":"Authorization","value":f"Bearer {token}"}}]
open("/tmp/cred.json","w").write(json.dumps(cred))
EOF
docker cp /tmp/cred.json n8n:/tmp/cred.json
docker exec -u root n8n chmod 644 /tmp/cred.json
docker exec n8n n8n import:credentials --input=/tmp/cred.json
docker exec -u root n8n rm -f /tmp/cred.json
rm -f /tmp/cred.json /tmp/hubspot_key
docker exec n8n-postgres psql -U n8n -d n8n -tAc "SELECT id, name, type FROM credentials_entity WHERE name='\''HubSpot Private App Token'\'';"'

# 11a-3. workflow JSON now has credentials block on the two HTTP Request nodes pointing at id=hubspot-private-app-token
#         (see runbook § 11a-2). Re-import + activate + restart n8n:
ssh root@100.99.173.52 'set -e
docker cp /srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json n8n:/tmp/wf.json
docker exec -u root n8n chmod 644 /tmp/wf.json
docker exec n8n n8n import:workflow --input=/tmp/wf.json
docker exec n8n n8n update:workflow --id=freepbx-hubspot-logger --active=true
docker compose -f /srv/docker/n8n/docker-compose.yml restart n8n
sleep 6
docker exec n8n-postgres psql -U n8n -d n8n -tAc "SELECT id, name, active FROM workflow_entity;"   # expect active = t'

# 11a-4. End-to-end proof (creates + deletes a HubSpot test contact)
KEY=$(tr -d '\n\r ' < /home/masterok/n8n/private_key.txt)
TEST_PHONE="+15550008888"
RESP=$(curl -sS -m 10 -X POST "https://api.hubapi.com/crm/v3/objects/contacts" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"properties\":{\"phone\":\"$TEST_PHONE\",\"firstname\":\"E2E\",\"lastname\":\"DELETE-ME\"}}")
CONTACT_ID=$(echo "$RESP" | jq -r '.id')
# poll until search index catches up
for i in $(seq 1 15); do
  HITS=$(curl -sS -m 5 -X POST "https://api.hubapi.com/crm/v3/objects/contacts/search" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"filterGroups\":[{\"filters\":[{\"propertyName\":\"phone\",\"operator\":\"CONTAINS_TOKEN\",\"value\":\"15550008888\"}]}],\"properties\":[\"phone\"],\"limit\":1}" \
    | jq -r '.total // 0')
  [ "$HITS" -ge 1 ] && break; sleep 3
done
WEBHOOK_RESP=$(curl -sS -m 30 -X POST "http://192.168.10.107:5678/webhook/freepbx-call-end" \
  -H 'Content-Type: application/json' \
  -d "{\"uniqueid\":\"e2e-$(date +%s)\",\"phone\":\"$TEST_PHONE\",\"src\":\"15550008888\",\"dst\":\"1001\",\"duration\":67,\"disposition\":\"ANSWERED\",\"start_time\":\"$(date -u +%FT%TZ)\",\"direction\":\"inbound\"}")
echo "$WEBHOOK_RESP" | jq .
CALL_ID=$(echo "$WEBHOOK_RESP" | jq -r '.hubspot_call_id')
curl -sS -m 10 -H "Authorization: Bearer $KEY" \
  "https://api.hubapi.com/crm/v3/objects/calls/$CALL_ID?properties=hs_call_title,hs_call_direction,hs_call_duration,hs_call_status,hs_call_from_number,hs_call_body,hs_timestamp&associations=contacts" | jq
# cleanup
curl -sS -o /dev/null -w '%{http_code}\n' -m 10 -X DELETE -H "Authorization: Bearer $KEY" "https://api.hubapi.com/crm/v3/objects/calls/$CALL_ID"
curl -sS -o /dev/null -w '%{http_code}\n' -m 10 -X DELETE -H "Authorization: Bearer $KEY" "https://api.hubapi.com/crm/v3/objects/contacts/$CONTACT_ID"
unset KEY

# ---------- 12. Provision extension 1001 + real-call test ----------
# 12a. install bulkhandler module, bulk-import extension
ssh root@100.99.173.52 'docker exec freepbx-freepbx-1 fwconsole ma downloadinstall bulkhandler'
ssh root@100.99.173.52 'cat > /tmp/ext1001.csv <<EOF
extension,name,tech,secret,voicemail,context,findmefollow_enabled
1001,Test Ext 1001,pjsip,<EXT_1001_SECRET>,novm,from-internal,no
EOF
docker cp /tmp/ext1001.csv freepbx-freepbx-1:/tmp/ext1001.csv
docker exec freepbx-freepbx-1 fwconsole bulkimport --type=extensions --replace /tmp/ext1001.csv
docker exec freepbx-freepbx-1 fwconsole reload
docker exec freepbx-freepbx-1 asterisk -rx "pjsip show endpoint 1001"'

# 12b. enable live_dangerously so System() works inside dialplan reached via originate
ssh root@100.99.173.52 'docker exec freepbx-freepbx-1 sed -i "s/^;live_dangerously = no/live_dangerously = yes/" /etc/asterisk/asterisk.conf
docker exec freepbx-freepbx-1 grep "^live_dangerously" /etc/asterisk/asterisk.conf
docker exec freepbx-freepbx-1 asterisk -rx "core restart now"'
sleep 10

# 12c. extensions_custom.conf — at this point contains:
#   [freepbx-n8n-logger]            (hangup-handler subroutine)
#   [macro-dialout-one-predial-hook]  (FreePBX 17 hook for any dial)
#   [macro-dial-ringall-predial-hook] (FreePBX 17 hook for ringall)
#   [macro-dial-hunt-predial-hook]    (FreePBX 17 hook for hunt)
#   [n8n-test-caller]                 (synthetic originator that attaches handler directly)
# scp /tmp/extensions_custom.conf  -> /srv/docker/freepbx/dialplan/extensions_custom.conf
ssh root@100.99.173.52 'docker cp /srv/docker/freepbx/dialplan/extensions_custom.conf freepbx-freepbx-1:/etc/asterisk/extensions_custom.conf
docker exec freepbx-freepbx-1 chown asterisk:asterisk /etc/asterisk/extensions_custom.conf
docker exec freepbx-freepbx-1 asterisk -rx "dialplan reload"'

# 12d. THE real-call test
KEY=$(tr -d '\n\r ' < /home/masterok/n8n/private_key.txt)
TEST_PHONE="+15550007777"
RESP=$(curl -sS -m 10 -X POST "https://api.hubapi.com/crm/v3/objects/contacts" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"properties\":{\"phone\":\"$TEST_PHONE\",\"firstname\":\"RealCall\",\"lastname\":\"DELETE-ME\"}}")
CONTACT_ID=$(echo "$RESP" | jq -r '.id')
# wait for search index
for i in $(seq 1 15); do
  HITS=$(curl -sS -m 5 -X POST "https://api.hubapi.com/crm/v3/objects/contacts/search" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"filterGroups\":[{\"filters\":[{\"propertyName\":\"phone\",\"operator\":\"CONTAINS_TOKEN\",\"value\":\"15550007777\"}]}],\"properties\":[\"phone\"],\"limit\":1}" \
    | jq -r '.total // 0')
  [ "$HITS" -ge 1 ] && break; sleep 3
done
# fire the real Asterisk originate
ssh root@100.99.173.52 'docker exec freepbx-freepbx-1 sh -c ":> /var/log/asterisk/n8n-hook.log"
docker exec freepbx-freepbx-1 asterisk -rx "channel originate Local/start@n8n-test-caller application Wait 30"
sleep 15
docker exec freepbx-freepbx-1 cat /var/log/asterisk/n8n-hook.log'
# verify the call landed in HubSpot
sleep 3
CALLS=$(curl -sS -m 10 -H "Authorization: Bearer $KEY" "https://api.hubapi.com/crm/v3/objects/contacts/$CONTACT_ID/associations/calls")
echo "$CALLS" | jq
LATEST=$(echo "$CALLS" | jq -r '.results[0].id // empty')   # NOTE: .id on the association object (not .toObjectId)
[ -n "$LATEST" ] && curl -sS -m 10 -H "Authorization: Bearer $KEY" \
  "https://api.hubapi.com/crm/v3/objects/calls/$LATEST?properties=hs_call_title,hs_call_direction,hs_call_duration,hs_call_status,hs_call_from_number,hs_call_body,hs_timestamp&associations=contacts" | jq
# cleanup
[ -n "$LATEST" ] && curl -sS -o /dev/null -w 'delete call %{http_code}\n' -m 10 -X DELETE -H "Authorization: Bearer $KEY" "https://api.hubapi.com/crm/v3/objects/calls/$LATEST"
curl -sS -o /dev/null -w 'delete contact %{http_code}\n' -m 10 -X DELETE -H "Authorization: Bearer $KEY" "https://api.hubapi.com/crm/v3/objects/contacts/$CONTACT_ID"
unset KEY

# ---------- Operational quickref ----------
ssh root@100.99.173.52 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
ssh root@100.99.173.52 'docker logs --tail 50 -f n8n'                              # n8n logs
ssh root@100.99.173.52 'docker logs --tail 50 -f freepbx-freepbx-1'                # freepbx
ssh root@100.99.173.52 'docker exec freepbx-freepbx-1 tail -f /var/log/asterisk/full'
ssh root@100.99.173.52 'docker exec freepbx-freepbx-1 tail -f /var/log/asterisk/n8n-hook.log'
# Restart n8n only:           cd /srv/docker/n8n && docker compose up -d --no-deps n8n
# Restart FreePBX (re-NAT'd): cd /srv/docker/freepbx && bash run.sh --rtp 10000-20000
# Stop both:                  cd /srv/docker/n8n && docker compose down
#                             cd /srv/docker/freepbx && docker compose down
# Volumes (don't delete):     docker volume ls | grep -E 'n8n_|freepbx_'

# ---------- § 15: Phase-1 v2 deploy + test (any-PBX webhook) ----------
# (1) push v2 workflow JSON from laptop to server
scp /tmp/freepbx-hubspot-call-logger.v2.json \
    root@100.99.173.52:/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json

# (2) reimport, reactivate, restart
ssh root@100.99.173.52 '
  docker cp /srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json n8n:/tmp/wf.json
  docker exec -u root n8n chmod 644 /tmp/wf.json
  docker exec n8n n8n import:workflow --input=/tmp/wf.json
  docker exec n8n n8n update:workflow --id=freepbx-hubspot-logger --active=true
  docker compose -f /srv/docker/n8n/docker-compose.yml restart n8n
'

# (3) generic single-call probe (works from anywhere — laptop or any test PBX)
curl -sS -X POST http://100.99.173.52:5678/webhook/freepbx-call-end \
  -H 'Content-Type: application/json' \
  -d "{\"uniqueid\":\"probe-$(date +%s)\",\"src\":\"15551110001\",\"dst\":\"1001\",\"phone\":\"15551110001\",\"duration\":7,\"disposition\":\"ANSWERED\",\"start_time\":\"$(date -u +%FT%TZ)\",\"direction\":\"inbound\"}"

# (4) full 15-scenario battery — see /tmp/e2e-battery.sh on the laptop. Run:
bash /tmp/e2e-battery.sh

# (5) HubSpot search for workflow-created calls (any with hs_call_external_id starting with batt- or probe-)
TOKEN="$(cat /home/masterok/n8n/private_key.txt)"
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"filterGroups":[{"filters":[{"propertyName":"hs_call_external_id","operator":"CONTAINS_TOKEN","value":"batt-"}]}],"properties":["hs_call_external_id","hs_call_title","hs_call_status"],"limit":50}' \
  https://api.hubapi.com/crm/v3/objects/calls/search | jq

# (6) bulk delete test calls
for id in 368xxxxx 368xxxxx ; do
  curl -sS -o /dev/null -w "$id %{http_code}\n" -X DELETE \
    -H "Authorization: Bearer $TOKEN" \
    "https://api.hubapi.com/crm/v3/objects/calls/$id"
done
unset TOKEN
