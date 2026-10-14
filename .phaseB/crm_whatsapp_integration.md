# CRM ⇆ WhatsApp Business Cloud API integration

Date: 2026-10-14 · Scope: Part B item 5 (the "WhatsApp" leg of the owner's
priority trio). Official **WhatsApp Business Cloud API ONLY** — personal
WhatsApp / the WhatsApp Business *app* are refused (ban risk). All live sends
are **MOCKED + key-gated**: nothing opens a socket here; with no Meta key the
server returns a drafted/queued state and NEVER fakes a delivery. Every
send/receive is **auto-logged** as a CRM `Activity` on the lead timeline.

---

## 1. Models needed (migration surface)

**The integrator runs `makemigrations crm` — NO migration was authored here.**
Two new, additive tables (existing models untouched). `makemigrations --dry-run`
confirmed exactly: `0005_whatsappoptin_whatsapptemplate`.

### `WhatsAppTemplate` (owner-defined template copy)
| field | type | notes |
|-------|------|-------|
| `org` | FK→CrmOrg (related_name=`wa_templates`) | tenant scope |
| `name` | CharField(120) | in-app label; `unique_together(org, name)` |
| `meta_name` | CharField(120, blank) | name registered in Meta Business Manager (needed for a PAID template send outside 24h) |
| `language` | CharField(8, default `bn`) | bn / en |
| `body` | TextField | **owner-written copy** — CRM never invents content; `{{1}}`,`{{2}}` placeholders filled at send time |
| `approved` | Bool(default False) | Meta-approved; only an approved template may go outside the 24h window |
| `active` | Bool(default True) | |
| `created_at` | DateTime(auto_now_add) | |

### `WhatsAppOptIn` (per-lead consent + 24h window clock)
| field | type | notes |
|-------|------|-------|
| `lead` | **OneToOne**→Lead (related_name=`wa_optin`) | one row per lead |
| `opted_in` | Bool(default False) | gates ALL sends (1:1 + bulk) |
| `opted_in_at` | DateTime(null) | |
| `last_inbound_at` | DateTime(null) | stamped on every inbound; drives the 24h free-form window |

### Reused (NO new message-log table)
The **`Activity`** model (`kind="whatsapp"`) **already suffices** as the comms
log — every send/receive writes an `Activity` on the lead (subject `WhatsApp →`
/ `WhatsApp ←`, body = message text). Inbound also appends a
`Conversation`/`Message` (direction=`in`) so sentiment + the existing timeline
view pick it up. `Lead.whatsapp`/`Lead.phone` already hold the destination.

---

## 2. Backend endpoints added (method · path · what)

All under both `api/v1/crm/` and `api/crm/`. Trailing-slash router convention
preserved (ViewSet actions get the slash; the two bare APIView-style paths
`join`/`today`/`extract` style use no slash → `whatsapp/bulk`).

| method | path | what |
|--------|------|------|
| GET  | `/crm/leads/{id}/whatsapp_status/` | honest state: `has_key`, `opted_in`, `in_window`, `to`, `window_hours`, `org` |
| POST | `/crm/leads/{id}/whatsapp_optin/` | set consent `{opted_in}` (required before any send) |
| POST | `/crm/leads/{id}/whatsapp_send/` | send `{text}` (free-form, in-window) OR `{template_id, params[]}`; MOCK+key-gated; **auto-logs** an Activity; returns `state` ∈ `queued`/`needs_key` + Graph `send` descriptor |
| POST | `/crm/leads/{id}/whatsapp_receive/` | inbound webhook relay `{text}`; stamps 24h window + implies opt-in; **auto-logs** Activity + Message |
| GET/POST/PATCH/DELETE | `/crm/wa-templates/` (+`/{id}/`) | `WhatsAppTemplateViewSet` — list + create + use owner templates (org-scoped, `?org=&active=1`) |
| POST | `/crm/whatsapp/bulk` | opt-in bulk send to a filtered lead set (`{org, text?/template_id?, params?, lead_ids?/status?/priority?/industry?}`); owner/manager only; respects opt-in + 24h + paid-template; **fans out to INDIVIDUAL 1:1 sends — never a group**; auto-logs each allowed attempt |

### Honest-state contract
- **No Meta key** → `whatsapp_send`/bulk return `state="needs_key"` (drafted,
  `allowed:true`) — never `delivered`. Client shows "connect WhatsApp Business".
- **Opt-out lead** → `409 blocked_optout` (1:1) / counted + skipped (bulk).
- **Outside 24h window, no template** → `409 needs_template`.
- **Unapproved template outside window** → `409 template_not_approved`.
- **Key present + allowed** → `state="queued"` (the integrator's server-side
  worker POSTs `send.body` to `send.endpoint` =
  `graph.facebook.com/v21.0/<PHONE_NUMBER_ID>/messages`). Still not sent live in
  this code — no network here.

---

## 3. Pure-logic + tests

`backend/crm/whatsapp.py` — pure, no network. Reuses `core.logic.business_ai`
as the **single source of truth** for the channel guard
(`guard_channel`/`PersonalWhatsAppBanned`), the 24h window
(`within_service_window`, `SERVICE_WINDOW_HOURS=24`) and the Graph request
descriptor (`assemble_webhook_send`). Adds:
- `render_template(body, params)` — fills owner `{{n}}` placeholders only;
  unfilled placeholders stay visible (honest).
- `plan_send(...)` — one send's state machine (blocked_optout / needs_template /
  needs_key / queued).
- `bulk_fanout_plan(...)` — individual 1:1 fan-out + per-state counts.
- `normalize_wa_number(...)` — digits-only destination.

Tests (`crm/tests.py`, run with NO key / NO network — all green, 33 total):
- `WhatsAppLogicTests` (7): template render, 24h window, opt-out block,
  outside-window→template, needs_key (never fake delivery), personal-WhatsApp
  banned, bulk individual fan-out + opt-in filter.
- `WhatsAppEndpointTests` (3): send→needs_key + auto-logged Activity; opt-out
  refusal; bulk individual fan-out opt-in-only. (These create the two new
  tables transiently via the schema editor so the endpoints verify WITHOUT an
  authored migration — mirrors the generated migration.)

Run: `manage.py test crm --settings=assisto_backend.settings_test`

---

## 4. Flutter

- **New:** `app/lib/screens/crm/crm_whatsapp_sheet.dart` — modal sheet opened
  from the lead quick-action. Shows the key-gated `NeedsKeyBanner`, an opt-in
  switch, the 24h-window note, an owner-template picker (or free-form box inside
  the window), and a send button whose label is honest (`Send` with key /
  `Queue draft` without). A send auto-logs server-side; the sheet returns
  `true` so the lead detail refreshes the timeline.
- **Changed:** `crm_lead_detail_screen.dart` — the WhatsApp quick action now
  opens the sheet (official Cloud API) instead of the old `wa.me` personal
  deep-link.
- **Changed:** `crm_common.dart` (`CrmApi`) — added `whatsappStatus`,
  `whatsappOptIn`, `whatsappSend`, `waTemplates`, `whatsappBulk`. All go through
  the FIXED generic helpers (`getJson`/`postJson`/`listItems`).

### ARB — `.phaseB/crm_whatsapp_arb.json` (17 keys, `{key:[bn,en]}`, camelCase)
Do NOT edit `app_*.arb` — the integrator merges. Zero Bangla in `.dart` (only
the pre-existing `৳` taka sign in `bdt()`, which is allowed).

---

## Hard-rule compliance
- ✅ Official WhatsApp Business Cloud API only; personal WhatsApp guarded +
  commented (`guard_channel` raises `PersonalWhatsAppBanned`).
- ✅ Live send MOCKED + key-gated via `integrations.is_enabled("whatsapp")`;
  `needs_key` state, never a faked delivery.
- ✅ Auto-log mandatory — every send/receive writes an `Activity` (+ inbound a
  `Message`).
- ✅ No invented template content — `body` is owner-written; render only
  substitutes params.
- ✅ Opt-in + 24h window + paid-template rule respected (1:1 and bulk).
- ✅ Multi-tenant — all scoped via `_OrgScopedViewSet` / `_member_org_ids` /
  `_require_member`; bulk is owner/manager-only.
