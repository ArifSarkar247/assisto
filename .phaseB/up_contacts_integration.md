# Personal CRM / Phonebook (ADVANCED) — integration notes

Upgrades `CrmContactsScreen` (feature 24, the **personal** relationship manager —
distinct from the Sales CRM under `screens/crm/*`) from a flat name/phone/org/note
list into an advanced personal-contact app benchmarked against the best phonebook
/ CRM apps, satisfying all 10 SPEC v2.1 §21 criteria.

## Files changed / created
| File | What |
| --- | --- |
| `app/lib/screens/crm_contacts_screen.dart` | **Rewritten.** Search + filter chips + sort, favourites, reach-out banner, dedupe/import/export menu, offline-first cache, honest states. |
| `app/lib/widgets/contacts_model.dart` | **NEW.** `Contact` model (round-trips server dict, tolerant of legacy rows), bilingual string table (Bangla as `\u` codepoints — **zero Bangla glyphs in .dart**), pure list ops (search/filter/sort/dedupe/merge/touch-due), vCard, groups/relations/cadence catalogs, `ContactTag`. |
| `app/lib/widgets/contacts_sheets.dart` | **NEW.** Detail sheet (quick actions, copy, stay-in-touch card, link-to-Circle, delete) + rich editor sheet (multi phone/email/address, groups, relation, labels, birthday picker, cadence, favourite). |
| `backend/core/logic/personal_contacts.py` | **NEW.** Pure logic: `normalize_contact`, groups catalog, `search/filter/sort_contacts`, `group_counts`, `find_duplicate_groups` + non-destructive `merge_contacts`, `to_vcard`/`to_vcard_bundle`, cadence + `is_touch_due`/`touch_due_contacts`, `quick_actions` URIs, `link_contact_to_circle`, `import_matches_to_drafts`. Re-exports the messenger hashed-import contract. |
| `backend/core/logic/personal_contacts_tests_snippets.py` | **NEW.** 72 plain-assert tests across 14 cases (`run_all`). Passing. |
| `.phaseB/up_contacts_arb.json` | **NEW.** 68 ARB keys `{key:[bn,en]}`. |

> Per task constraints, NOT edited: `api.dart`, `app_*.arb`, `models.py`, `urls`,
> sidebar, other screens. No flutter/build/migrations run. No Asalify touched.

## What makes it ADVANCED
Groups/labels (family/work/friends/acquaintance/other + free labels) · favourites ·
rich contact (many phones/emails/addresses, birthday, relationship, org, notes) ·
instant search (name/phone/email/org/label, digit-normalized phone search) +
group/favourite filter chips with counts + sort (name/recent/favourite) ·
duplicate detection (shared phone last-9-digits or email, union-find) + one-tap
**non-destructive merge** (unions every phone/email, never loses data) · phone
import (hashed-safe, reuses the messenger contract — raw numbers never leave the
device) · link-to-Circle (promotes relation + family group, server resolves the
user id) · quick actions (call / SMS / WhatsApp-share / email / vCard-share, only
shown when the data exists → no dead buttons) · **stay-in-touch** cadences with a
reach-out digest banner + "log a contact" · recent-interactions sort · vCard 3.0
export (one or all).

## Section-21 (all 10) — how met
1. **Empty** — first-run empty state with body copy + "Add contact" CTA; search
   "nothing matched" and dedupe "no duplicates" states are distinct.
2. **Loading** — `SkeletonList` on cold load; cache shows instantly so warm loads
   never flash a spinner.
3. **Error** — `StateMessage(cloud_off)` + Retry **only** when there is nothing to
   show; otherwise a soft offline banner over the cached list.
4. **Offline** — SharedPreferences cache (`contacts_cache_v2`); reads serve cache,
   writes are optimistic + re-cached and surface "saved offline — will sync later".
5. **Fast** — all search/filter/sort/dedupe are pure client ops over the in-memory
   list; chips update instantly.
6. **Bilingual** — every string via the ARB getter or the local `[bn,en]` table;
   `localeNum` renders Bangla digits via codepoints. Zero Bangla glyphs in .dart.
7. **WCAG** — semantic labels on quick-action buttons, tooltips, `star`/`cloud_off`
   icons paired with text, ellipsis (no clipped text), ≥44px tap targets.
8. **No dead ends** — every empty/error has an action; quick actions appear only
   when actionable; unnamed contacts get a safe display name + initial.
9. **Scenario** — "Khala's birthday is next week, I haven't called in a month":
   she shows in the reach-out banner (monthly cadence overdue) → tap → call → "log
   contact" resets the clock.
10. **Bilingual/consistent chrome** — reuses `StateMessage`, `Gap`, `Radii`,
    `Brand`, the drawer nav (no bottom bar), brand palette.

## Backend wiring the integrator does (endpoints/models are yours)

### 1. Contact model fields (superset; all optional except an identity)
The screen posts via the EXISTING generic `/contacts/` collection
(`api.listItems/createItem/updateItem/deleteItem`). The serializer should accept +
return these keys (legacy `phone`/`org`/`note` scalars are still written for
back-compat and read as fallbacks):

```
id, name,
phones[], emails[], addresses[],          # multi-value
phone, email,                             # legacy scalar mirrors (= first of each)
org, note, birthday ('YYYY-MM-DD' | 'MM-DD'),
relation (circle code), groups[] (family|work|friends|acquaintance|other),
labels[], favourite (bool),
cadence ('' | weekly | fortnightly | monthly | quarterly | yearly),
last_interaction (ISO8601),
linked_user_id (int | null), linked_circle_id (int | null)
```

Run every write through `personal_contacts.normalize_contact(...)` on the server so
caps/dedup/birthday-tolerance/integer-safety are enforced regardless of client.

### 2. "Log a contact" + stay-in-touch
The screen sets `last_interaction = now` and PATCHes. A daily digest (optional,
cron/Celery) can call `touch_due_contacts(contacts)` → `touch_due_label(c)` to push
"time to reach out" notifications. No new field needed beyond `cadence` +
`last_interaction`.

### 3. Phone import = reuse the MESSENGER hashed contract (privacy-critical)
Import is intentionally **not** reimplemented. The client:
1. hashes contacts on-device via `msg_contacts.hash_contacts_clientside(raw, SALT)`
   (see `msg_contacts.hashing_contract()`), uploads ONLY hashes + the permission
   flag;
2. server runs `msg_contacts.match_contacts(hashes, registered_hash_to_user,
   permission_granted=...)` — **stores nothing**, non-users' hashes are dropped;
3. server turns the result into draft contacts with
   `personal_contacts.import_matches_to_drafts(match_result)` and returns them for
   the user to confirm + save.

Suggested endpoint (integrator adds; NOT added here — api.dart/urls not edited):
`POST /contacts/import-match/  {hashes:[...], permission:true}` → `{drafts:[...]}`.
The in-app dialog already states the privacy contract; it is a safe handoff point.

### 4. Link to Circle
The detail sheet's "Link to Circle" sets the `family` group + a sentinel
`linked_circle_id = -1` ("link requested"). The integrator resolves the real Circle
user via `personal_contacts.link_contact_to_circle(contact, user_id=..., circle_id=
..., relation=...)` (e.g. after a hashed-match) and PATCHes the real ids, so family
alerts / SOS reach that person.

### 5. vCard export
Fully client-side (`Contact.toVcard` mirrors `personal_contacts.to_vcard`, vCard
3.0, CRLF). Shared via `share_plus`. A server `GET /contacts/export.vcf` is
optional — `to_vcard_bundle(contacts)` produces the identical bytes if you prefer a
server download.

## Tests
```
cd backend && python3 -c "import core.logic.personal_contacts_tests_snippets as t; t.run_all()"
# personal_contacts: ALL 72 assertions passed across 14 tests.
```
Register `PersonalContactsSnippetTests` in `backend/core/tests.py` via the existing
`_make_snippet_case` helper when wiring (not done here to keep the change surface to
the allowed files).

## Review flags (OWNER)
- Caps/limits in `personal_contacts.py` are marked `OWNER REVIEW` (name/note length,
  max phones/emails/addresses/labels, custom-cadence clamp).
- `linked_circle_id = -1` is a client sentinel for "link requested"; the resolver
  endpoint must replace it (or the serializer should reject negative ids).
