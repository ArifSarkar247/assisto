# Integration — #194 Area community + #187 Doctor appointment/serial tracker

Section-20 features built to the Section-21 "advanced" standard. Two self-contained
utilities: a **local-area neighbourhood notice board** (#194, no-key, local-area
utility — NOT the Messenger community system) and a **doctor-appointment / serial
tracker** (#187, manual tracker with a documented key-gated LIVE-booking partner
seam). Nothing in this change touches api.dart, core/models.py, core/urls.py, the
sidebar source, app_*.arb, migrations, Flutter builds, or Asalify.

---

## New files

| File | Purpose |
|---|---|
| `backend/core/logic/area_community.py` | Pure deterministic area-board logic: area-scoped + category feed, conservative-privacy field whitelist, newest-first ordering. No DB/AI/clock/network. |
| `backend/core/logic/area_community_tests_snippets.py` | 16 plain-assert self-tests. |
| `backend/core/logic/doctor_serial.py` | Pure deterministic appointment logic: upcoming/past bucketing, derived `missed`, reminder-due from a passed-in `now`, honest key-gated booking seam + reminder seam. No DB/AI/clock/network. |
| `backend/core/logic/doctor_serial_tests_snippets.py` | 19 plain-assert self-tests. |
| `app/lib/screens/area_community_screen.dart` | Area board UI: area bar, category filter chips with counts, post cards, compose sheet (no exact-address field), privacy note, honest empty/welcome/filter-empty states. Mirrors `area_community.py` (`_ACore`). ZERO Bangla literals (৳ glyph only, gate-exempt). |
| `app/lib/screens/doctor_serial_screen.dart` | Appointment UI: Upcoming/Past tabs, reminder banner, tracker note, honest key-gated "connect a booking partner" card, appointment cards with status pills + reminder badge, add/edit sheet, status quick-actions. Mirrors `doctor_serial.py` (`_DCore`). ZERO Bangla literals. |

Modified (one logical block only): `backend/core/tests.py` — two `_make_snippet_case`
registrations (`AreaCommunitySnippetTests`, `DoctorSerialSnippetTests`) appended after
`DemandMapSnippetTests`.

---

## ARB keys — `.phaseB/up_areadoctor_arb.json`

**86 keys** per locale (en + bn, matched 1:1). Merge `en` → `app_en.arb`, `bn` →
`app_bn.arb`, add the 4 `placeholders_meta` @-blocks to `app_en.arb` (this project
keeps @-metadata in app_en.arb only), then run l10n codegen.

Reused existing keys (NOT redefined): `loadFailed`, `retry`, `save`, `saved`,
`saveFailed`, `cancel`, `delete`, `edit`.

**Parameterised keys (`_params` / placeholders):**

| Key | Placeholder | Used for |
|---|---|---|
| `areaEmptyAreaTitle` | `area` (Object) | "No notices in {area} yet" |
| `areaNoneInFilterBody` | `category` (Object) | "No \"{category}\" notices in this area right now." |
| `doctorReminderDue` | `count` (Object) | "{count} appointment(s) coming up soon." |
| `doctorSerialNo` | `serial` (Object) | "Serial {serial}" |

Key prefixes: `area*` (38 incl. 6 category labels) and `doctor*` (48 incl. 11
specialty labels, 4 status labels). No collisions with existing keys (verified).

---

## Persistence — generic REST collections (no migration, no api.dart edit)

Integrator adds two names to `GENERIC_COLLECTIONS` in `backend/core/views.py`
(the list that builds `GENERIC_COLLECTION_VIEWSETS` via `type()` over the
`PaCollectionViewSet` base — user-scoped, audit-logged, flatten serializer):

```python
# Section-20 #194 Area board + #187 Doctor appointment tracker
"area/posts",
"doctor/appointments",
```

The Flutter screens use the existing `ApiClient.listItems / createItem /
updateItem / deleteItem` helpers (unchanged). Each row round-trips as
`{id, ...data}` through one flexible per-user JSON collection.

**Row shapes** (what the screen stores; the backend never requires a schema):

- `area/posts` →
  `{id, category, title, body, area, contact?, price?, created}`
  - `category` ∈ {`announcement`, `service`, `lost_found`, `event`, `alert`}
  - `area` = a human area label (e.g. "Dhanmondi, Dhaka"); **never** an exact
    address/GPS. `price` only written for `service` posts. `created` is an ISO
    string the client sets.
- `doctor/appointments` →
  `{id, doctor, specialty, place, date, time, serial, status, notes, created}`
  - `status` ∈ {`booked`, `done`, `cancelled`} (stored). `missed` is **derived**
    (never written) when a booked appointment's time has passed.
  - `date` = `YYYY-MM-DD`, `time` = `HH:MM` (optional), `serial` = free text from
    the user's own chamber slip (never fabricated).

> Note: the generic collection is **per-user**. "Area scope" is a deterministic
> FILTER over the rows the client holds — we do NOT fabricate a cross-user feed.
> If/when a shared area feed is wired later, the same `feed()` filter applies to
> the merged rows; the privacy whitelist (`display_post`) still drops any precise-
> location field a row might carry.

---

## Seams

### #187 LIVE serial booking — DOCUMENTED, KEY-GATED, ABSENT
`doctor_serial.booking_seam(configured=False)` returns the honest state:
```
{feature: "live_serial_booking", required: True, configured: False,
 partner_slug: "health_booking", mock: True,
 request_shape: {doctor, place, date, time, patient, phone},
 never_fabricates: True}
```
No booking partner key exists today, so the screen shows an honest
"Live serial booking (partner needed)" card and the tracker works fully as a
manual log. **A serial/booking is NEVER fabricated** — serials come only from
what the user typed. To activate later: the integrator registers a
`health_booking` entry in `core/integrations.py` (REGISTRY) and routes the
`request_shape` to the partner; `booking_seam(configured=True)` then flips
`mock` off. Nothing in this module calls out.

### #187 Reminder sending — DOCUMENTED seam (computes only)
`doctor_serial.reminder_seam()` →
`{feature: "appointment_reminder", computes_due: True, sends: False,
 window_hours: 24, channels: ("push","sms"), wired: False}`.
`organise(rows, now)` COMPUTES `reminders_due` (booked + within 24h); the UI
shows a "Soon" badge and a count banner. Actually SENDING (push via the existing
`firebase` integration, or SMS via `sms`) is wired by the integrator — nothing
fires from this module or screen.

### #194 Area board — NO key required
Fully local-area utility; no integration. (A future cross-user shared feed would
reuse the same deterministic `feed()` filter; not built.)

---

## Tests

- `area_community`: **16** checks (validation incl. `all`-is-filter-only, privacy
  field-drop, area case/space-insensitive match, titleless-row drop, category
  filter, area-scoped counts before filter, newest-first ordering, determinism,
  bilingual labels).
- `doctor_serial`: **19** checks (validation, upcoming/past bucketing, derived
  `missed` without mutating stored status, cancelled→past, reminder-due window,
  no-reminder for cancelled/done, sort order, undated-active stays upcoming,
  determinism, counts rollup, booking seam honesty both states, never-fabricates-
  serial, reminder seam computes-not-sends, specialty label bilingual + echo).
- **Total: 35**, wired via `core/tests.py` `_make_snippet_case`. Both modules
  import and pass through the Django `core.logic` path
  (`python manage.py test core.tests.AreaCommunitySnippetTests
  core.tests.DoctorSerialSnippetTests` discovers all 35; this sandbox lacks the
  DB-create privilege, so run with a usable test DB in CI). Standalone:
  `python3 core/logic/area_community_tests_snippets.py` and
  `python3 core/logic/doctor_serial_tests_snippets.py`.

---

## Sidebar entries (wiring — integrator)

Add two routes to the drawer nav source (NOT edited here per constraints):

- **Area community** → group **Daily Life** (local-area utility). Icon suggestion
  `Icons.holiday_village_outlined`; route pushes `AreaCommunityScreen()`.
- **Doctor appointments** → group **Family & Safety** (health-adjacent personal
  tracker). Icon suggestion `Icons.medical_services_outlined`; route pushes
  `DoctorSerialScreen()`.

Both screens are self-routing `StatefulWidget`s with their own `AppBar`; add a
drawer tile + a route constant the same way the other Section-20 screens
(probashi/qurbani) are wired.

---

## Constraints honoured

- ZERO Bangla literals in either `.dart` (only the gate-exempt `৳` glyph appears,
  in the area service-price display) — verified by Unicode scan.
- Deterministic pure backend (no DB/AI/clock/network; `now` always passed in).
- Conservative privacy: area-level only; precise-location fields actively dropped.
- Health copy careful: tracker, not medical advice; never fabricates a
  booking/serial; honest key-gated states.
- Original Assisto identity; does not duplicate the Messenger community system.
- No edits to api.dart, core/models.py, core/urls.py, sidebar, app_*.arb,
  migrations; no Flutter build; no Asalify touched.
