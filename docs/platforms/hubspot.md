# HubSpot

HubSpot CRM is the destination for both Phase 1 (call metadata) and Phase 2 (transcript + summary).

## Authentication

| What | Value |
| --- | --- |
| Account | The HubSpot account (any tier) where Service Keys are created |
| Auth type | **Service Key** (`pat-naX-…`) — not OAuth |
| Header | `Authorization: Bearer pat-…` |
| Token storage | `/home/masterok/n8n/private_key.txt` (chmod 600 on laptop) |
| n8n credential | `hubspot-private-app-token` (Header Auth) |

Created inside a regular HubSpot account at **Settings → Integrations → Private Apps → "Use Service Keys instead"**. (Developer-portal "Create app" produces the wrong type — that's an OAuth public app.)

### Required scopes

Only two:

| Scope | Why |
| --- | --- |
| `crm.objects.contacts.read` | Look up the contact by phone |
| `crm.objects.contacts.write` | Create/update Call engagements (HubSpot gates Calls under contacts.write — there is **no separate `crm.objects.calls.*` scope**) |

## Two-phase write to the same Call

```
   Phase 1 (immediate)                          Phase 2 (~5–20s after hangup)

   POST /crm/v3/objects/calls                    POST /crm/v3/objects/calls/search
     properties:                                   filterGroups[0].filters[0]:
       hs_call_title                                 propertyName=hs_call_external_id
       hs_call_direction                             operator=EQ
       hs_call_duration                              value=<UNIQUEID>
       hs_call_from_number
       hs_call_status                              → returns the Call from Phase 1
       hs_timestamp
       hs_call_external_id = <UNIQUEID>          PATCH /crm/v3/objects/calls/{id}
       hs_call_body = "(transcript pending)"       properties:
     associations[0]: contact-by-phone               hs_call_body = summary + transcript
```

`hs_call_external_id` is the bridge — it lets Phase 2 find the same Call without storing the HubSpot id anywhere else.

## Field reference (what we actually write)

| Property | Phase 1 | Phase 2 PATCH |
| --- | --- | --- |
| `hs_call_title` | `"FreePBX call ({direction})"` | unchanged |
| `hs_call_direction` | `INBOUND` / `OUTBOUND` | unchanged |
| `hs_call_duration` | `${CDR(billsec)} * 1000` (ms) | unchanged |
| `hs_call_status` | `COMPLETED` | unchanged |
| `hs_call_from_number` | caller-id | unchanged |
| `hs_timestamp` | call start (ISO 8601) | unchanged |
| `hs_call_external_id` | Asterisk `${UNIQUEID}` (key for Phase 2 lookup) | unchanged |
| `hs_call_body` | `"(transcript pending)"` | `"## Summary\n…\n\n## Transcript (Ns)\n[t] Speaker N: …"` |

> **Don't** set `hs_call_app_id` — HubSpot validates it as the integer ID of a registered Calling Extensions app. We're not one. Setting it as a string causes `INVALID_INTEGER`.
> **Don't** set `hs_call_source: INTEGRATIONS_PLATFORM` either — only meaningful with the above.

## Search semantics for the contact match

```json
{
  "filterGroups": [
    {"filters": [{"propertyName":"phone",       "operator":"CONTAINS_TOKEN", "value":"<digits>"}]},
    {"filters": [{"propertyName":"mobilephone", "operator":"CONTAINS_TOKEN", "value":"<digits>"}]}
  ],
  "properties": ["phone","mobilephone","firstname","lastname","email"],
  "limit": 1
}
```

Multiple `filterGroups` are OR'd. `CONTAINS_TOKEN` matches phone numbers regardless of formatting (`+15551001001`, `(555) 100-1001`, `5551001001` all match the same token list).

**Eventual consistency:** newly-created contacts take ~5–30 s to appear in search results. Phase 1 hits this only if you create a contact and immediately fire a webhook. Real production traffic is unaffected.

## Operations

```bash
# Read a Call back (full props + association)
KEY=$(tr -d '\n\r ' < ~/n8n/private_key.txt)
curl -sS -H "Authorization: Bearer $KEY" \
  "https://api.hubapi.com/crm/v3/objects/calls/<call-id>?properties=hs_call_title,hs_call_direction,hs_call_duration,hs_call_status,hs_call_from_number,hs_call_body,hs_timestamp,hs_call_external_id&associations=contacts" \
  | jq

# Find a Call by external id
curl -sS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -X POST https://api.hubapi.com/crm/v3/objects/calls/search \
  -d '{"filterGroups":[{"filters":[{"propertyName":"hs_call_external_id","operator":"EQ","value":"<uniqueid>"}]}],"properties":["hs_call_body"],"limit":1}' | jq

# Delete a test Call
curl -sS -X DELETE -H "Authorization: Bearer $KEY" \
  "https://api.hubapi.com/crm/v3/objects/calls/<call-id>" -o /dev/null -w '%{http_code}\n'
```

## Known limits

- **`hs_call_body` max 65 535 chars.** Phase 2 truncates with `…(truncated)` if exceeded.
- **No native recording-URL field that fetches with auth.** `hs_call_recording_url` displays as a link but HubSpot's web UI doesn't authenticate to fetch — that's fine for our use because the recordings server is Tailscale-bound only.
- **`Calls` engagement record type ≠ "Call" activity timeline entry.** They appear identically in the contact timeline though.

## See also

- [`../topics/call-logging-pipeline.md`](../topics/call-logging-pipeline.md)
- [`../topics/transcription-pipeline.md`](../topics/transcription-pipeline.md)
- `../n8n-freepbx-runbook.md` § 11, § 14
