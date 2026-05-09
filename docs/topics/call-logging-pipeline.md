# Phase 1 — Call logging pipeline

Fires within ~50 ms of any call hangup. Creates a HubSpot Call engagement on the matching contact.

## Trigger

The hangup-handler is attached via `predial-hook` macros (FreePBX 17 names):

```asterisk
[macro-dialout-one-predial-hook]
exten => s,1,Set(CHANNEL(hangup_handler_push)=freepbx-n8n-logger,s,1(outbound))

[macro-dial-ringall-predial-hook]
exten => s,1,Set(CHANNEL(hangup_handler_push)=freepbx-n8n-logger,s,1(inbound))

[macro-dial-hunt-predial-hook]
exten => s,1,Set(CHANNEL(hangup_handler_push)=freepbx-n8n-logger,s,1(inbound))
```

Each pre-dial hook attaches the handler to the channel right before `Dial()`. On any hangup, the handler runs.

## Handler subroutine

```asterisk
[freepbx-n8n-logger]
exten => s,1,System(/etc/asterisk/scripts/n8n-call-logger.sh
                    "${UNIQUEID}" "${CDR(src)}" "${CDR(dst)}" "${CALLERID(num)}"
                    "${CDR(billsec)}" "${CDR(disposition)}" "${CDR(start)}" "${ARG1}")
 same => n,Return()
```

`${ARG1}` is the direction string (`inbound`, `outbound`, `ai-agent`, etc.) passed when the handler was attached.

## Bash helper script

`/etc/asterisk/scripts/n8n-call-logger.sh` — POSTs JSON to n8n:

```bash
curl -sS -m 5 -X POST -H 'Content-Type: application/json' \
  -d '{"uniqueid":"...","src":"...","dst":"...","phone":"...",
       "duration":N,"disposition":"...","start_time":"...","direction":"..."}' \
  http://172.17.0.1:5678/webhook/freepbx-call-end
```

Logs everything to `/var/log/asterisk/n8n-hook.log` for forensics.

## n8n workflow `freepbx-hubspot-logger`

```
Webhook POST /webhook/freepbx-call-end
   │
   ▼
Code "Normalize"
   strip phone to digits, parse direction/duration, ISO-format the timestamp
   │
   ▼
HTTP "HubSpot Search Contact"
   POST /crm/v3/objects/contacts/search
     filterGroups: phone CONTAINS_TOKEN <digits> OR mobilephone CONTAINS_TOKEN <digits>
   │
   ▼
IF "Contact found?"
   ├── yes → HTTP "Create HubSpot Call"
   │           POST /crm/v3/objects/calls
   │             properties: hs_call_*, hs_call_external_id=${UNIQUEID}
   │             associations: contact-by-id
   │         → "Respond Logged" {status, hubspot_call_id, contact_id, phone}
   │
   └── no → "Respond No Match" {status:no_contact_match, phone}
```

## What FreePBX sends, end to end

```bash
# Asterisk dialplan auto-fires:
curl -sS -X POST http://172.17.0.1:5678/webhook/freepbx-call-end \
  -H 'Content-Type: application/json' \
  -d '{
    "uniqueid":"1778240126.17",
    "src":"15551001001",
    "dst":"*98",
    "phone":"15551001001",
    "duration":29,
    "disposition":"ANSWERED",
    "start_time":"2026-05-08 11:35:26",
    "direction":"recording-test"
  }'
```

n8n responds with one of:

```json
{"status":"logged","hubspot_call_id":"368...","contact_id":"482...","phone":"15551001001"}
{"status":"no_contact_match","phone":"15551001001","hint":"..."}
```

## Where `hs_call_external_id` matters

It's the join key between Phase 1 and Phase 2. Phase 2 searches HubSpot by it to find the same Call and PATCH the body with transcript + summary:

```json
{"filterGroups":[{"filters":[{"propertyName":"hs_call_external_id","operator":"EQ","value":"<uniqueid>"}]}]}
```

## Files of interest

| Path | Owner | What |
| --- | --- | --- |
| `/srv/docker/freepbx/dialplan/extensions_custom.conf` | host | dialplan source (mirrors `/etc/asterisk/extensions_custom.conf`) |
| `/srv/docker/freepbx/scripts/n8n-call-logger.sh` | host | helper script source |
| inside container: `/var/log/asterisk/n8n-hook.log` | asterisk:asterisk | append-only execution log |
| `/srv/docker/n8n/workflows/freepbx-hubspot-call-logger.json` | host | n8n workflow source |

## See also

- [`../platforms/freepbx-asterisk.md`](../platforms/freepbx-asterisk.md)
- [`../platforms/n8n.md`](../platforms/n8n.md)
- [`../platforms/hubspot.md`](../platforms/hubspot.md)
- `../n8n-freepbx-runbook.md` § 7, § 11a, § 14b
