# FAMILY CARE V3 — shared interface (owner order 9 Nov 10:50)

Owner of this file + the data model: agent **fcscreen** (branch `agent/fcscreen`).
Users of it: **fcsos**, **fcelder**, **fcbrain**. Change requests → message fcscreen
(or the integration agent a40c84cc693b0871f). Additive changes only after publish.

## 1. Data model (one migration `01NN_fcscreen`, models in `core/models.py` block `# ---- fcscreen ----`)

| Model | Fields |
|---|---|
| `FcFamily` | `name` (≤60), `created_by` → User, `created_at` |
| `FcMembership` | `family` → FcFamily, `user` → User, `role` admin\|adult\|child\|elder, `state` invited\|active\|declined\|left, `label` (how the family calls them, e.g. "আম্মু", ≤40), `relation` (son\|daughter\|mother\|father\|spouse\|brother\|sister\|grandparent\|other), `alert` JSON `{state:'amber', reason, source, at, until}` (set via `set_member_status`, same on all the user's memberships), `invited_by` → User, `abroad_tz` (IANA tz, "" = at home; Probashi row shows only when someone has it), `joined_at`, `left_at`, `created_at`; unique (family, user) |
| `FcTask` | `family`, `title` (≤120), `kind` medicine\|doctor\|bill\|other, `due_date` (nullable), `created_by`, `taken_by` (nullable) + `taken_at`, `done_by` + `done_at`, `created_at` |

Member *status* (heartbeat, battery, place label, pause) is **not** a table here:
it comes from fcbrain's `family_brain.member_brain_state(viewer, member)` (PaCollectionItem store).
Rules: a person can be in many families (max 5); adults join only by tapping
Accept on their own phone; a child (role `child`) is added active directly by a
guardian with an approved `GuardianLink`; anyone can leave any time; admin
(Django staff) endpoints never expose locations or place labels.

## 2. Python helpers — `core/family_v3.py` (import these; never query the tables directly)

```python
families_of(user) -> list[FcFamily]                 # active memberships, oldest first
ensure_default_family(user) -> FcFamily               # "My family" created lazily on first open
co_member_ids(user, family_id=None) -> list[int]      # active members sharing a family (excl. user)
shares_family(a_user, b_user) -> bool
member_ids(family_id) -> list[int]                    # active members incl. children/elders
membership(user, family_id) -> FcMembership | None    # active only
role_of(user, family_id) -> str | None
leave(user, family_id) -> bool                        # fcbrain's POST /family/brain/leave should call this
someone_abroad(family_id) -> bool
members_of(user) -> list[dict]                        # UNION over all the user's families, excl. user, deduped:
    # {user_id, name, phone, relation, label, role, family_ids:[...]}  (fcsos: _sos_recipients)
family_ids_of(user) -> list[int]                      # elder ladder: setter -> all family -> nearby person
set_member_status(user, state, reason, source, ttl_s=None)  # state 'amber' (only); reason e.g. 'watch',
    # 'carecall_missed', 'journey_overdue'; source = your branch ('fcelder'); ttl None = until cleared
clear_member_status(user, source)                     # e.g. after "I am OK"
```
All helpers never raise on a missing table (return [] / False) so branches merge in any order.

## 3. Pure status rules — `core/logic/family_status.py` (+ Dart mirror `app/lib/family_v3/fc_status.dart`)

`member_status(brain: dict, now: datetime, flags: dict) -> {"state", "reason", "fresh_until"}`
* `brain` = the dict from `member_brain_state` — keys used: `last_seen` (ISO), `battery` (0-100),
  `charging` (bool), `net` ("none"|"wifi"|"cell"|""), `bg_restricted` (bool), `paused_until` (ISO),
  `interval_s` (expected report interval the member phone promises; default 10800 = 3 h, clamp 900..86400).
* `flags` (from other agents, all optional bools): `sos` (fcsos: active SOS by this member),
  `watch_amber` (fcelder silent watch), `carecall_missed` (today), `journey_overdue`.
* states, strongest first: `sos` (red) → `paused` → `stale` (gray, dashed) → `check` (amber) → `ok` (green).
* **GREEN only if** `last_seen` exists, is not >5 min in the future, and `now - last_seen <= interval_s`
  and no amber flag and battery is not ≤15 % while not charging. Anything unknown is never green.
* gray reasons: `never` (Assisto never reported), `battery_off` (last battery ≤5 %), `no_internet`
  (last net = none), `background_killed` (bg_restricted reported, or nothing else explains it),
  `clock` (timestamp in the future). amber reasons: `watch`, `carecall_missed`, `journey_overdue`, `battery_low`.
* `family_line(statuses)` → one line for the top: red SOS > amber "Check on NAME" > gray "No news from NAME" > green "All OK" (green only when ≥1 other member and every one is green).
* Same case table drives both test suites: `backend/core/logic/fc_status_cases.json`.

## 4. HTTP API (all under `/api/`, token auth, `family/v3/...` routes registered before the `family` router)

| Method + path | Body / answer |
|---|---|
| GET `family/v3/families` | `{families:[{id,name,role,member_count,someone_abroad}], invites:[{membership_id,family_id,family_name,invited_by_name,role}]}` (creates "My family" lazily) |
| POST `family/v3/families` | `{name}` → family (caller = admin) |
| POST `family/v3/families/<id>/rename` | `{name}` (admin only) |
| POST `family/v3/families/<id>/invite` | `{circle_member_id, role, label?}` — only an accepted, unblocked My Circle peer; role child needs an approved GuardianLink (then active at once) |
| POST `family/v3/invites/<membership_id>/accept` / `.../decline` | invitee only |
| POST `family/v3/families/<id>/leave` | anyone, any time |
| POST `family/v3/families/<id>/remove/<user_id>` | admin only (not themselves) |
| POST `family/v3/families/<id>/members/<user_id>` | `{label?, relation?, abroad_tz? (self only), role? (admin)}` |
| GET `family/v3/families/<id>/board` | `{family, me:{role}, line:{state,reason,name,member_id}, members:[{user_id,name,label,role,phone,photo,abroad_tz,brain:{…},status:{state,reason,fresh_until},chip}], tasks:[…], today:{carecalls:{done,missed,pending},bills_due,birthdays:[…],bazar_open}, someone_abroad, server_now}` — members sorted alerts first |
| GET `family/v3/members/<user_id>?family=<id>` | member page: `{member, status, timeline:[{at,kind,text}], seen_by:[{user_id,name,family_name}]}` |
| GET/POST `family/v3/families/<id>/tasks` | list / `{title,kind,due_date?}` |
| POST `family/v3/tasks/<id>/take` · `/release` · `/done` · `/delete` | "I will do it" etc.; everyone in the family sees `taken_by_name` |

`flags` for the board come from (each optional, guarded with try/except ImportError so branches merge in any order):
* fcsos: `core.family_sos_v3.active_sos_user_ids(family_id) -> set[int]` (until then: unresolved `FamilyAlert` kind sos)
* fcelder / anyone: call `family_v3.set_member_status(user,'amber',reason,source)` — no import needed on my side.
* fcbrain: `core.family_brain.member_brain_state(viewer, member)` and `member_timeline(viewer, member, day) -> list[{at,kind,text}]` (optional), `core.notif_budget.allow(...)`.

## 5. Flutter hooks — `app/lib/family_v3/fc_slots.dart` (fcscreen creates it; others only ASSIGN)

```dart
class FcSlots {
  // fcsos: open the 5-second SOS sender. Fallback (null) = old family SOS confirm.
  static Future<void> Function(BuildContext context, {int? familyId})? openSosSender;
  // fcbrain: night news card for the Family screen (null / returns null = no card).
  static Widget? Function(BuildContext context, int familyId)? nightNewsCard;
  // fcbrain: offline ask parser (free, on phone). null or returns null -> POST family/brain/ask.
  static FcAskAnswer? Function(String question, FcAskContext ctx)? askParser;
  // fcelder: extra More rows (Elder easy home, set up an elder phone).
  static List<Widget> Function(BuildContext context, int familyId)? moreRows;
}
```
`FcAskContext` = `{familyId, members: [{userId, name, label, role, placeLabel, state}]}`;
`FcAskAnswer` = `{text, memberUserId?, action: 'none'|'open_member'|'call'|'location'}`.
Server ask answer (fcbrain `POST family/brain/ask {q, family_id}`) must use the same keys: `{text, member_user_id, action}`.
Registration: each agent adds ONE line to `app/lib/family_v3/fc_slots_register.dart` → `fcRegisterSlots()` (called by the Family screen's initState). Lines marked `// <branch>`.

## 6. Home-screen widget (fcscreen) — `FamilyWidgetProvider` (native, Kotlin, no WorkManager, no periodic update)
App writes per member `{initial, name, fresh_until_epoch, state}` + one alert line after each board load;
the widget recolors to gray natively when `fresh_until` passes (one inexact non-wakeup alarm), so it never shows a stale green.
