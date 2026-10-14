# Messenger Moderation + Owner-Admin — Integration (Step 3)

Pure logic lives in `backend/core/logic/msg_moderation.py` (+ tests
`msg_moderation_tests_snippets.py`, 34 passing, no DB). This doc tells the
integrator how to wire it. **No models/views/urls/app/Asalify were edited** —
all below is a spec for the integrator.

> SCOPE NOTE: The original Connected Circle spec (line 22) deferred
> public channels/communities "owner decision later". This moderation engine
> is the prerequisite for that decision; it governs PUBLIC surfaces only. The
> circle-only E2E chat stays untouched — server stores ciphertext only and
> **admin NEVER reads message contents or contact lists** (guard below).

## Models (integrator to add; names suggested)

### `ModerationReport`
| field | type | note |
|---|---|---|
| id | PK | |
| reporter | FK(User) | nullable-check → invalid if null |
| target_kind | char | channel/post/community/group/person |
| target_id | int/char | id within that kind |
| categories | JSON(list) | normalized reason codes |
| note | text | optional |
| created_at | datetime | |
| valid | bool | from `build_report` |

### `ModerationItem` (review-queue)
| field | type | note |
|---|---|---|
| id | PK | |
| target_kind, target_id | | the moderated object |
| categories | JSON | merged across reports |
| severe | bool | |
| content_status | char | visible/hidden/removed/restored |
| queue_state | char | queued/under_appeal/resolved |
| legal_retention | bool | **retain for legal reporting — see OWNER-REVIEW** |
| report_count | int | |
| decision | char | last admin action |
| opened_at / resolved_at | datetime | |

### `ModerationAudit` (append-only; never edited/deleted)
`actor_id, action, target_kind, target_id, reason, at, + extra JSON`
(`new_status`, `reset_sessions`, `queue_item`, `legal_retention`). One row per
admin/appeal action. **Retained** for legally-required reporting of illegal
content.

### `User` additions (admin-facing public fields only)
`status` (active/suspended/banned), `report_count`, `app_version`,
`last_active`, `signup_date`, `plan`, `photo_url`. Message contents & contacts
stay in their existing private tables — **never surfaced to admin**.

## Endpoints (integrator to add)

| method | path | logic fn | enforcement |
|---|---|---|---|
| POST | `/api/moderation/report` | `build_report` → `evaluate_report` | severe→hide, mass→hide, else queue; apply `new_status` to target |
| GET | `/api/admin/moderation/queue` | list `ModerationItem` where queue_state≠resolved | admin-only, audit the view |
| POST | `/api/admin/moderation/<item>/action` | `apply_admin_action` | remove/restore/warn/suspend/ban; reason REQUIRED; writes audit |
| POST | `/api/moderation/<item>/appeal` | `can_appeal` → `open_appeal` | affected user only; re-opens |
| POST | `/api/admin/moderation/<item>/reopen` | `reopen_for_review` | appealed → queued |
| GET | `/api/admin/users` | `list_users_for_admin` | **public projection only**; audit the view |
| POST | `/api/admin/users/<id>/action` | `admin_user_action` | suspend/unsuspend/reset-sessions/ban; reason REQUIRED; audit |

Wiring rule: the view resolves raw rows → passes dicts to logic → persists the
returned `new_status` / item / audit. The client can never bypass the decision.

## Flow summary
- **Severe** (CSAE / violent threat / terrorism / scam-fraud): 1 valid report →
  `content_status=HIDDEN` immediately, item queued.
- **Non-severe**: single report → queue only (stays visible). ≥ threshold
  DISTINCT reporters within window → temp AUTO-HIDE + queue (false-report-proof:
  same reporter counts once; stale reports outside window don't count).
- **Admin** resolves: remove(→removed) / restore(→restored) / warn(no change) /
  suspend(→hidden) / ban(→removed). Every action audited.
- **Appeal** within window → `under_appeal` → reopen → `queued` for re-review.

## Owner admin-panel (build later — OWNER-REVIEW on policy)
- Queue screen (filter severe/legal), item detail (reason, count, categories),
  action buttons (remove/restore/warn/suspend/ban) with mandatory reason box.
- Users screen: search by name/phone, filter by status; row shows only public
  projection; suspend/unsuspend/reset-sessions buttons.
- Audit log viewer (read-only).
- bn/en × light/dark gallery required before ship (design standard).

## === TO REVIEW BY OWNER / LAWYER (content policy pages) ===
These are **modeled** here but the legal content is NOT written — owner/lawyer
must supply/approve before any public launch:
1. **Content policy / community guidelines** page (what's banned, how reported).
2. **18+ / adult-content** page & age-gating rules (`R_NUDITY` handling).
3. **Legal reporting of illegal content**: for `LEGAL_RETENTION_CATEGORIES`
   (CSAE, terrorism, violent threats) — WHAT to report, TO WHOM (e.g. mandated
   authorities), HOW LONG to retain. `legal_retention=True` flags the records;
   the actual duty/process is a legal question, **owner/lawyer to confirm**.
4. Appeal window length, mass-report threshold/window, warning escalation —
   owner to finalize (defaults: threshold 5, window 60m, appeal 30d).
5. Whether public channels/communities launch at all (spec line 22 deferral).
