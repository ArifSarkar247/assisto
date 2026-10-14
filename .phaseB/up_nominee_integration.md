# Nominee (feature 36) — ADVANCED upgrade · integration notes

Scope of THIS change (already done, in-repo):
- `app/lib/screens/nominee_screen.dart` — rewritten (advanced).
- `app/lib/widgets/nominee_scope_picker.dart` — NEW (multi-category picker).
- `app/lib/widgets/nominee_consent_banner.dart` — NEW (consent + warning).
- `app/lib/widgets/nominee_card.dart` — NEW (priority/scopes/trigger/status card).
- `app/lib/widgets/nominee_release_sheet.dart` — NEW (release state machine UI).
- `backend/core/logic/nominee.py` — NEW (pure logic, no Django) + tests
  `backend/core/logic/nominee_tests_snippets.py` → `run_all()` = **15 asserts**.
- `.phaseB/up_nominee_arb.json` — **63** NEW bilingual keys `{key:[bn,en]}`.

Nothing in `api.dart`, `app_*.arb`, `models.py`, `urls.py`, `serializers.py`,
`sidebar`/`chatnav` was edited. No migrations, no builds, no Asalify/crm.

`flutter analyze` on the five Dart files: the only findings are
`undefined_getter` for the 63 new keys (expected — they live in the ARB until
gen-l10n runs). No other errors/warnings. Zero Bangla literals in any `.dart`
(verified; Bangla digits rendered at runtime from codepoints U+09E6..U+09EF).

---

## (a) l10n — REQUIRED to compile

Merge `up_nominee_arb.json` into `app/lib/l10n/app_en.arb` (use index `[1]`) and
`app_bn.arb` (index `[0]`), then `flutter gen-l10n`. Keys are camelCase and map
1:1 to the `tr.*` getters used by the screen/widgets. One parameterized key:

```
"nomineeRemoveBody": "“{name}” will be removed ..."   // ICU {name} placeholder
```
Its `.arb` entry needs the usual `@nomineeRemoveBody` metadata block declaring
`placeholders: { "name": {"type":"String"} }`.

Existing getters REUSED (already in the generated loc, no action):
`addNominee, addATrustedPersonWho, cancel, checkInternetRetry, delete,
loadFailed, name, noNomineesYet, nominee2, nomineeFamilyAccess, phoneEmail,
retry`.

The legacy getters `accessScope / scopeValue / accessOpen /
accessOpensOnlyWhenYou / emergencyCard / moduleVault / moneyOverview / all`
are no longer referenced by this screen; leave them (other screens may use
`all`). They can be pruned later if unused globally.

---

## (b) models.py — additive fields on `Nominee` (NON-breaking)

The screen writes new keys through the generic item API; the current serializer
silently ignores unknown keys, so the UI runs today in a degraded (single-scope,
owner_grant-only, no grace persistence) mode. To make it fully advanced, EXTEND
`core/models.py` `Nominee` (do not rename existing columns — `scope`,
`inactivity_days`, `activated`, `activated_at`, `contact`, `name` stay):

```python
# multi-category access (the advanced replacement for single `scope`;
# keep `scope` as a back-compat mirror = 'all' or the first category)
scopes = models.JSONField(default=list)          # subset of nominee.SCOPES
relationship = models.CharField(max_length=16, default="family")  # RELATIONSHIPS
priority = models.PositiveIntegerField(default=1)                 # fallback order
trigger = models.CharField(max_length=16, default="owner_grant")  # TRIGGERS

# grace-window release lifecycle
release_state = models.CharField(max_length=10, default="armed")  # armed|pending|open
release_pending = models.BooleanField(default=False)              # UI convenience mirror
release_requested_at = models.DateTimeField(null=True, blank=True)
grace_hours = models.PositiveIntegerField(default=48)
# multi_verify quorum
multi_verify_ids = models.JSONField(default=list)       # user/circle ids
multi_verify_quorum = models.PositiveIntegerField(default=2)
release_confirmations = models.JSONField(default=list)  # ids who confirmed
```

Index `(user, priority)`. Enum values live in `core.logic.nominee`
(`SCOPES, RELATIONSHIPS, TRIGGERS, STATE_*`) — import from there, don't duplicate
strings.

Migration: a new additive migration (NOT run here — environment rule).

---

## (c) serializers.py — expose the new fields

Add the fields above to `NomineeSerializer.Meta.fields`. Keep
`release_state, release_requested_at, activated, activated_at,
release_confirmations` in `read_only_fields` — they must be set ONLY by the
validated transitions in `core.logic.nominee`, never by raw client PATCH, so a
client can't forge an `open` state. The client sends intent
(`release_pending: true/false`) and the view translates it through the logic
layer (below).

---

## (d) views — wire the pure logic (the safety gate lives server-side)

`core.logic.nominee` is the single source of truth for every transition. The
view must never trust a client-sent `release_state`; it calls the logic and
persists the returned dict:

- `POST /nominees` and `PUT/PATCH` → feed owner input to
  `nominee.build_nominee(...)`; it validates (raises `ValueError` → 400 on an
  unusable plan: empty name / empty scopes) and returns the normalized row.
- A new `POST /nominees/<pk>/request-release` →
  `request_release(row, owner_confirmed=?, now=now, wellness_state=?,
  confirmations=?)`. Preconditions per trigger:
  * `owner_grant` → require the request be authenticated as the OWNER and carry
    an explicit second confirmation flag.
  * `inactivity` → the view computes `wellness_state` from the EXISTING
    Safe-Journey wellness engine (`core.logic.safety_journey.wellness_state`,
    item 16) for this user; only `'alert'` is accepted.
  * `multi_verify` → `confirmations` is the set of trusted-person ids that have
    independently confirmed; logic enforces the quorum of NAMED people.
  On success the row is `pending` with `release_requested_at` set. Nothing is
  shared yet.
- `POST /nominees/<pk>/cancel-release` → `cancel_release(row)` (always allowed;
  returns to `armed`, closes any access). This is the owner's always-on kill
  switch; also used to revoke an already-open grant.
- The EXISTING `POST /nominees/<pk>/activate` is now the FINAL open step: before
  flipping `activated`, the view MUST check `nominee.can_open_now(row, now)`
  (grace fully elapsed) and require a final owner confirmation, mirroring
  `open_access(...)`. Reject with 409 if the window has not elapsed — this is
  what stops a client from skipping the grace period.

Audit: keep logging every transition via `log(user, "nominee.<action>", ...)`.

Background: a periodic task should, per user, recompute `wellness_state` and —
only for `inactivity`-trigger nominees whose owner is in `'alert'` — auto-start
the grace window (i.e. call `request_release`). It must notify the owner every
channel and respect `cancel_release`. (No scheduler added here.)

---

## (e) The actual data release — key-gated / mock

When a nominee is `open`, `nominee.visible_scopes(row)` returns the categories
they may see; for anything but `emergency` these are LISTS / pointers /
instructions, never raw secrets:

- `documents` → the vault's document LIST + metadata only. The vault is E2E
  encrypted; its ciphertext is NOT exposed through the nominee flow. A real
  release of vault contents requires the vault's own key-escrow / recovery step
  (out of scope here) — until that ships, treat document release as mock
  (pointers only). Do not add any path that decrypts vault blobs for a nominee
  in this module.
- `accounts` / `insurance` / `wishes` → owner-authored instruction records
  (no passwords/PINs).

This keeps the FLOW and SAFEGUARDS real while the sensitive unlock stays
key-gated and deferred.

---

## Release-safeguard design — why it cannot trigger unsafely (summary)

State machine: `armed → (verified trigger) → pending → (grace elapsed + final
confirm) → open`, with `cancel_release` collapsing any state back to `armed`.

1. A saved plan is `armed`: `visible_scopes` = `[]`. Opens nothing.
2. No trigger fires on its own: `owner_grant` needs an authenticated owner +
   explicit confirm; `inactivity` needs Safe-Journey wellness = `'alert'`
   (full period + response window missed — sensor/activity data alone never
   suffices, and an "I'm OK" cancels); `multi_verify` needs a quorum of DISTINCT
   NAMED people (empty id list ⇒ quorum 0 ⇒ can never fire — tested).
3. There is NO path from `armed`/`pending` to `open` that skips the grace
   window: `open_access` refuses while `grace_remaining_seconds > 0` AND
   requires a final confirm; `activate` must gate on `can_open_now`.
4. Always owner-cancellable: `cancel_release` is unconditional and also revokes
   an open grant.
5. Server-authoritative: `release_state` is read-only to clients; only the
   validated logic transitions set it. Every step is audit-logged.
6. Consent: the UI makes the owner confirm they've informed the nominee; the app
   never silently enrols a third party.

Tests proving 1–6: `nominee_tests_snippets.py::run_all()` (15 asserts).
```

- advanced-vs-before:
  before = single free-text scope, instant owner switch (`activate`) with no
  grace window, no priority, no relationship, no trigger choice, no consent UI.
  after  = multi-category informed-consent picker, priority order, relationship,
  three verified triggers, a real cancellable grace-window release state machine,
  persistent safety/consent banners, full empty/loading/error states, server-
  authoritative transitions, and a pointers-only (no raw secrets) guarantee.
```
