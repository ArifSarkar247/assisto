# PA Secretary — CELEBRITY/STAR tier (SPEC v2.1 §14 #121–#125) — integration note

Extends PA Secretary Mode with five STAR-tier features, built to ADVANCED
(Section-21 states, bn/en, premium polish, honest states, no clipped text at
360dp, welcome state). All DETERMINISTIC/MOCK (work fully with no key), honest
key-gated seams, holds no money, conservative privacy. Original Assisto identity
— NOT a Meta copy.

- #121 Deals & offers — brand-deal pipeline
- #122 PR & press — press/media tracker
- #123 Social inbox — unified DM/mention triage (honest IG/FB-Page live-fetch seam)
- #124 Shooting/concert logistics — call-sheet builder
- #125 Lifestyle — personal lifestyle manager

Report summary: 10 new files (5 Flutter screens + 5 backend logic, each with a
tests_snippets sibling = 15 .py). 184 new ARB keys. 43 backend tests (9/8/8/9/9).
ZERO Bangla literals in all 5 .dart files (only the exempt ৳ taka sign appears).

---

## 1. New files

### Flutter screens (app/lib/screens/pa/)
- `star_deals_screen.dart`      — #121 brand-deal pipeline board
- `pr_press_screen.dart`        — #122 coverage / interviews / talking-points (3 tabs)
- `social_inbox_screen.dart`    — #123 manual DM/mention triage board
- `shoot_logistics_screen.dart` — #124 call-sheet (schedule / checklist / contacts)
- `lifestyle_screen.dart`       — #125 appointments / preferences / routines (3 tabs)

### Backend pure logic (backend/core/logic/)
- `pa_deals.py`        + `pa_deals_tests_snippets.py`        (9 tests)
- `pa_pr.py`           + `pa_pr_tests_snippets.py`           (8 tests)
- `pa_socialinbox.py`  + `pa_socialinbox_tests_snippets.py`  (8 tests)
- `pa_shoot.py`        + `pa_shoot_tests_snippets.py`        (9 tests)
- `pa_lifestyle.py`    + `pa_lifestyle_tests_snippets.py`    (9 tests)

All logic is pure stdlib: no Django, no DB, no network, no clock (every
time-dependent fn takes `now`/dates as an argument), no AI, no payment. Each
mirrors the on-device Dart so previews match offline and tests pin them.

### Files edited (only two, both allowed)
- `backend/core/views.py` — added 5 names to `GENERIC_COLLECTIONS` (see §3).
- `backend/core/tests.py` — ONE added line wiring the 5 snippet cases (see §6).

NOT touched: api.dart, core/models.py, core/urls.py, sidebar, app_*.arb,
migrations, pa_hub_screen.dart, Asalify.

---

## 2. ARB keys

Emitted to `.phaseB/up_pastar_arb.json` (format `keyName -> [bn, en]`; `_params`
block lists placeholder types for the merge script's PARAMS map; `_note` has the
provenance). 184 new keys. Bangla is real & natural; ৳ kept as-is (exempt).

Reused shared keys (already in ARB, NOT redefined): `cancel, delete,
deleteFailed, edit, loadFailed, ok, retry, save, saveFailed, saved`.

The five **title keys double as the PA-hub tile labels**:
`starDealsTitle`, `prPressTitle`, `socialInboxTitle`, `shootTitle`, `lifestyleTitle`.

Parameterized keys (add to the merge script's PARAMS map — all `String` args):
```
starDealsOverdue{count}  starDealsDeadline{date}  starDealsDeadlineOverdue{date}
starDealsAdvance{next}   starDealsDeleteBody{brand}
prPressSentPositive{count}  prPressSentNeutral{count}  prPressSentNegative{count}
prPressNetPositive{net}  prPressNetNegative{net}
prPressUpcoming{count}   prPressPast{count}
socialInboxStatOpen{count}  socialInboxStatUrgent{count}
shootCallTimeValue{time}
shootChecklistProgress{checked,total,pct}
lifestyleUpcoming{count}  lifestylePast{count}
```

---

## 3. Persistence — generic REST collections (no migration)

Each screen uses the generic PaCollectionItem store via the untouched api.dart
helpers `listItems / createItem / updateItem / deleteItem`. The integrator added
these 5 names to `GENERIC_COLLECTIONS` in `backend/core/views.py` (already done
in this change; the base `PaCollectionViewSet` user-scopes + audit-logs them —
no migration, no new model):

```python
"star/deals", "star/press", "star/socialinbox",
"star/callsheets", "star/lifestyle",
```

Row shapes (flexible JSON on PaCollectionItem; `id` + `kind` where multi-type):

- **star/deals** (one row per deal):
  `{brand:str, value:num(৳, tracked only), stage:'negotiating'|'signed'|'delivered'|'paid',
    deliverables:str("one per line"/comma) | list, deadline:ISO-date, note:str}`

- **star/press** (tagged rows):
  `{kind:'coverage', outlet, type:'print'|'online'|'tv'|'radio'|'social', date:ISO, sentiment:'positive'|'neutral'|'negative', link, note}`
  `{kind:'interview', outlet, topic, at:ISO-datetime, place, note}`
  `{kind:'talkingpoint', topic, note}`

- **star/socialinbox** (one row per triaged item):
  `{platform:'instagram'|'facebook'|'messenger'|'twitter'|'youtube'|'other',
    from_handle, message, priority:'urgent'|'normal'|'low',
    status:'new'|'replied'|'archived', at:ISO-datetime}`

- **star/callsheets** (tagged rows; children carry `sheet_id`). The row-routing
  field is always the top-level `kind`; the block/check TYPE uses a distinct
  field (`block_kind` / `check_kind`) so it never collides with the row `kind`:
  `{kind:'sheet', title, date:ISO, call_time:'HH:MM', location, note}`
  `{kind:'block', sheet_id, label, block_kind:'scene'|'soundcheck'|'set'|'break'|'travel'|'other', start:'HH:MM', end:'HH:MM'}`
  `{kind:'contact', sheet_id, name, role, phone}`
  `{kind:'check', sheet_id, check_kind:'wardrobe'|'equipment'|'prep', label, checked:bool}`

- **star/lifestyle** (tagged rows):
  `{kind:'appt', category:'salon'|'gym'|'wellness'|'stylist'|'spa'|'other', title, place, at:ISO-datetime, note}`
  `{kind:'pref', topic, text}`
  `{kind:'routine', slot:'morning'|'afternoon'|'evening'|'night', label, time:'HH:MM'}`

---

## 4. Honest key-gated seams

- **#123 live DM/mention fetch** — `pa_socialinbox.inbox_fetch_seam()` returns
  `{action:'fetch', messages:[], required:True, keys:['instagram','messenger'],
   mock:True, marker:'social_inbox_seam'}`. It NEVER fetches or fabricates a DM
  or sender. The two Integrations REGISTRY keys that unlock a real fetch are
  **`instagram`** (IG Business/Creator) + **`messenger`** (Facebook Page) via the
  Meta Graph API (both already in `core/integrations.py`). The screen shows an
  honest "connect your Page / Instagram" card (`socialInboxConnect*`) and an
  explicit "we never fabricate a DM" line (`socialInboxNeverFabricate`). To wire
  live fetch later: gate on `integrations.is_enabled('instagram')` /
  `is_enabled('messenger')`, call the Graph API, and map results into the
  `star/socialinbox` row shape as PRE-FILLED but still manually-triaged items.

- **#125 reminders** — `pa_lifestyle.reminder_seam(appt)` returns
  `{action:'remind', appt_id, scheduled:[], required:True, mock:True,
   marker:'lifestyle_reminder_seam'}`. Opt-in, never sends, never leaves device.
  Wire to a push/SMS provider (e.g. `firebase` / `sms`) only on explicit opt-in.

- **#124 no AI/booking seam** — call-sheet is fully hand-built (deterministic);
  no external seam. **#121/#122** are fully deterministic (no AI, no money, no
  fetch). `pa_deals.pipeline()` returns `holds_money:False`; the UI repeats this
  (`starDealsNoHold`) and labels the weighted total "expected (weighted) — not
  cash" (`starDealsExpectedNote`).

Markers (localise in UI as needed): `social_inbox_seam`,
`lifestyle_reminder_seam`. #123 copy keys: `socialInboxConnectTitle/Body/Keys`,
`socialInboxNeverFabricate`. Privacy copy: `lifestylePrivacyNote`.

---

## 5. PA-hub tiles — ready-to-paste (do NOT let me edit pa_hub_screen.dart)

Add these imports at the top of `app/lib/screens/pa/pa_hub_screen.dart`:

```dart
import 'star_deals_screen.dart';
import 'pr_press_screen.dart';
import 'social_inbox_screen.dart';
import 'shoot_logistics_screen.dart';
import 'lifestyle_screen.dart';
```

Add these five `_PaTool` tiles to the `tools` list (titles reuse the screens'
own title getters, so the hub carries zero new strings):

```dart
      // §14 #121–#125 CELEBRITY/STAR tier — deterministic/mock, honest seams.
      _PaTool(Icons.handshake_outlined, t.starDealsTitle,
          (_) => const StarDealsScreen()),
      _PaTool(Icons.newspaper_outlined, t.prPressTitle,
          (_) => const PrPressScreen()),
      _PaTool(Icons.forum_outlined, t.socialInboxTitle,
          (_) => const SocialInboxScreen()),
      _PaTool(Icons.video_camera_front_outlined, t.shootTitle,
          (_) => const ShootLogisticsScreen()),
      _PaTool(Icons.spa_outlined, t.lifestyleTitle,
          (_) => const LifestyleScreen()),
```

Title ARB keys used by the tiles: `starDealsTitle`, `prPressTitle`,
`socialInboxTitle`, `shootTitle`, `lifestyleTitle` (all in up_pastar_arb.json).

---

## 6. Tests — ONE added line in core/tests.py

Added after the existing PA travel/expense/research registration (~line 992):

```python
PaDealsSnippetTests = _make_snippet_case("core.logic.pa_deals_tests_snippets", "PaDealsSnippetTests"); PaPrSnippetTests = _make_snippet_case("core.logic.pa_pr_tests_snippets", "PaPrSnippetTests"); PaSocialInboxSnippetTests = _make_snippet_case("core.logic.pa_socialinbox_tests_snippets", "PaSocialInboxSnippetTests"); PaShootSnippetTests = _make_snippet_case("core.logic.pa_shoot_tests_snippets", "PaShootSnippetTests"); PaLifestyleSnippetTests = _make_snippet_case("core.logic.pa_lifestyle_tests_snippets", "PaLifestyleSnippetTests")
```

`manage.py test` discovers 43 methods (9/8/8/9/9); all pass when run directly
(the sandbox can't create a test DB, but these are pure methods — verified via
`django.setup()` + direct invocation, and standalone `run_all()`).

---

## 7. Merge / build (handled by integrator, not here)

1. Merge `up_pastar_arb.json` into `app_bn.arb` / `app_en.arb` with the existing
   merge script; register the 18 parameterized keys in its PARAMS map (all args
   are `String` except none — see §2).
2. Paste the PA-hub tiles + imports from §5 into `pa_hub_screen.dart`.
3. `flutter gen-l10n` then a cloud APK build. No migration needed (generic
   collections reuse PaCollectionItem).
