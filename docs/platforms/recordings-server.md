# Recordings file server (nginx)

A tiny nginx container that exposes Asterisk's call recordings over HTTP with basic auth. Bound only to LAN + Tailscale — not exposed to the public internet.

## Where things live

| Path | Purpose |
| --- | --- |
| `/srv/docker/recordings/docker-compose.yaml` | Compose definition |
| `/srv/docker/recordings/nginx.conf` | Server config |
| `/srv/docker/recordings/.htpasswd` | Basic-auth user database |
| `/srv/docker/recordings/.password.txt` | Plain copy of the recordings password (operator reference) |
| Volume `freepbx_var_data` (read-only) | mounted at `/srv` inside nginx; recordings live at `/srv/spool/asterisk/monitor/*.wav` |

## Container

| Container | Image | Notes |
| --- | --- | --- |
| `recordings` | `nginx:alpine` | Bound to `100.99.173.52:8082` and `192.168.10.107:8082`. Serves only `*.wav`. |

## Auth

| User | Password |
| --- | --- |
| `recordings` | `cat /srv/docker/recordings/.password.txt` (root only) |

The htpasswd hash is bcrypt; password regenerated via `docker run --rm httpd:alpine htpasswd -nbB recordings <pwd>`.

## Operations

```bash
# Test (without auth → 401, with auth → 200 if file exists, else 404)
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.10.107:8082/<UNIQUEID>.wav
PASS=$(ssh root@u 'cat /srv/docker/recordings/.password.txt')
curl -sS -o /tmp/x.wav -w '%{http_code}\n' \
     -u "recordings:$PASS" \
     http://192.168.10.107:8082/<UNIQUEID>.wav

# Restart
ssh root@u 'cd /srv/docker/recordings && docker compose restart'
```

## What it does NOT do

- Does NOT expose to the public internet (HubSpot's UI cannot fetch from here without you enabling Tailscale Funnel or putting a TLS proxy in front).
- Does NOT serve directory listings (`autoindex off`).
- Does NOT serve anything other than `.wav` files (`location ~* "\.wav$"` only).
- Does NOT delete or rotate old recordings — disk usage grows. Add a cron+find cleanup if needed.

## Adding `hs_call_recording_url` to HubSpot Calls

Currently the Phase 2 PATCH only writes `hs_call_body`. To also include a recording URL, add this to the PATCH body in `freepbx-recording-transcriber.json`:

```json
"hs_call_recording_url": "http://100.99.173.52:8082/{{ $('Compose HubSpot Body').item.json.uniqueid }}.wav"
```

Caveat: HubSpot's UI player needs the URL to be reachable from the user's browser. Tailscale users can hit it; non-Tailscale users see a broken link. For a public production setup, swap this URL for an S3/signed-CDN equivalent.

## See also

- [`../topics/transcription-pipeline.md`](../topics/transcription-pipeline.md)
- `../n8n-freepbx-runbook.md` § 14f
