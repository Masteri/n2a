# Add a new SIP extension

Provision via FreePBX's `bulkimport` (CSV) — much faster than the UI, idempotent with `--replace`.

```bash
# Pick a unique extension number (e.g., 1002) and a strong secret.
EXT=1002
SECRET=$(openssl rand -hex 12)
NAME="Reception"

ssh root@u "set -e
cat > /tmp/ext.csv <<EOF
extension,name,tech,secret,voicemail,context,findmefollow_enabled
${EXT},${NAME},pjsip,${SECRET},novm,from-internal,no
EOF
docker cp /tmp/ext.csv freepbx-freepbx-1:/tmp/ext.csv
docker exec freepbx-freepbx-1 fwconsole bulkimport --type=extensions --replace /tmp/ext.csv
docker exec freepbx-freepbx-1 fwconsole reload
docker exec freepbx-freepbx-1 asterisk -rx 'pjsip show endpoint ${EXT}'
"

# Disable direct_media so MixMonitor captures audio
ssh root@u "PASS=\$(cat /srv/docker/freepbx/freepbxuser_password.txt)
docker exec freepbx-freepbx-1 mysql -h db -ufreepbxuser -p\"\$PASS\" asterisk -e \"
INSERT INTO sip (id, keyword, data, flags) VALUES ('${EXT}','direct_media','no',0)
  ON DUPLICATE KEY UPDATE data='no';
INSERT INTO sip (id, keyword, data, flags) VALUES ('${EXT}','rtp_symmetric','yes',0)
  ON DUPLICATE KEY UPDATE data='yes';\"
docker exec freepbx-freepbx-1 fwconsole reload"

echo "ext=${EXT} secret=${SECRET}"
```

Hand the secret to whoever's configuring the softphone:

```
SIP server   : 100.99.173.52  (or 192.168.10.107)
Port         : 5060 UDP
User         : <EXT>
Password     : <SECRET>
Codecs       : ulaw, alaw, g722
```

## To remove

```bash
ssh root@u "PASS=\$(cat /srv/docker/freepbx/freepbxuser_password.txt)
docker exec freepbx-freepbx-1 mysql -h db -ufreepbxuser -p\"\$PASS\" asterisk -e \"
DELETE FROM users WHERE extension='${EXT}';
DELETE FROM devices WHERE id='${EXT}';
DELETE FROM sip WHERE id='${EXT}';\"
docker exec freepbx-freepbx-1 fwconsole reload"
```
