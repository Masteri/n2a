# Restart services

```bash
# n8n only — picks up workflow + DB changes
ssh root@u 'cd /srv/docker/n8n && docker compose restart n8n'

# n8n — picks up .env change (force re-read of env_file)
ssh root@u 'cd /srv/docker/n8n && docker compose up -d --force-recreate n8n'

# FreePBX — full restart of Asterisk, dialplan reload, ARI re-init
ssh root@u 'docker exec freepbx-freepbx-1 asterisk -rx "core restart now"'
sleep 12
ssh root@u 'docker exec freepbx-freepbx-1 asterisk -rx "http show status"'

# FreePBX — reload dialplan only (after editing extensions_custom.conf)
ssh root@u 'docker exec freepbx-freepbx-1 asterisk -rx "dialplan reload"'

# FreePBX — re-apply iptables RTP NAT (after iptables flush or host reboot)
ssh root@u 'cd /srv/docker/freepbx && bash run.sh --rtp 10000-20000'

# AVA ai_engine — picks up YAML change
ssh root@u 'docker compose -f /srv/docker/ava/docker-compose.yml restart ai_engine'

# AVA ai_engine — picks up .env change
ssh root@u 'docker compose -f /srv/docker/ava/docker-compose.yml up -d --force-recreate ai_engine'

# AVA admin_ui
ssh root@u 'docker compose -f /srv/docker/ava/docker-compose.yml restart admin_ui'

# Recordings nginx
ssh root@u 'cd /srv/docker/recordings && docker compose restart'

# All — graceful stop everything
ssh root@u '
cd /srv/docker/n8n && docker compose down
cd /srv/docker/ava && docker compose down
cd /srv/docker/recordings && docker compose down
cd /srv/docker/freepbx && docker compose down'
```

## After every reboot of host

```bash
ssh root@u '
# bring up fresh
cd /srv/docker/n8n && docker compose up -d
cd /srv/docker/freepbx && bash run.sh --rtp 10000-20000   # also restores iptables
cd /srv/docker/ava && docker compose up -d ai_engine admin_ui
cd /srv/docker/recordings && docker compose up -d

# fix Asterisk HTTP — fwconsole reload may have reverted
docker exec freepbx-freepbx-1 sed -i "s/^enabled=no/enabled=yes/; s|^bindaddr=127.0.0.1|bindaddr=0.0.0.0|" /etc/asterisk/http_additional.conf
docker exec freepbx-freepbx-1 asterisk -rx "module reload http"
docker exec freepbx-freepbx-1 asterisk -rx "module reload res_ari"

# verify
docker ps --format "table {{.Names}}\t{{.Status}}"
'
```
