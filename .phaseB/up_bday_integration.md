# Birthdays / Memorable days — ADVANCED (SPEC v2.1 §21) — integrator notes

Upgrades `BirthdaysScreen` (feature #23) from GOOD → ADVANCED. Benchmarked vs the
phone's built-in birthday reminders: adds relation/notes, yearly recurrence,
CONFIGURABLE pre-reminders, a "this week" highlight, age/years, wish + greeting-
card DRAFTS, a KEY-GATED AI-mock wish, ONE-TAP SEND (WhatsApp-share/SMS/call),
link-to-Circle + import-from-contacts, and honest empty/loading/error/offline
states. NEVER auto-sends — every wish is a draft the user sends.

## Files changed / created (STRICTLY in scope)
| File | What |
| --- | --- |
| `app/lib/screens/birthdays_screen.dart` | **Rewritten.** Offline-first cache, this-week + upcoming sections, add/edit via new sheet, wish via new sheet with key-gated AI-mock hookup, import-from-contacts entry, offline banner + honest states. |
| `app/lib/widgets/bday_model.dart` | **NEW.** Bilingual string table (Bangla as `\u` codepoints — **zero Bangla glyphs in .dart**), `bNum` Bangla digits, pre-reminder + relation catalogs, kind icons, one-tap-send URI builders (`bWhatsAppUri`/`bSmsUri`/`bCallUri`), offline next-occurrence/days-until math mirroring `birthdays.py`. |
| `app/lib/widgets/bday_upcoming_card.dart` | **NEW.** Rich card: name + relation pill, when (Bangla digits), turning-age, "this week" highlight (tint + border + badge, not colour alone), "linked in Circle" badge; wish/edit/delete actions; `Semantics` label. |
| `app/lib/widgets/bday_add_sheet.dart` | **NEW.** Add/edit sheet: name · kind chips · date · relation (quick-pick + free text) · notes · yearly toggle · multi-select pre-reminders (1wk/3d/1d/on-the-day) · phone (for one-tap wish) · import-from-contacts button. Emits `lead_days` as an int LIST. |
| `app/lib/widgets/bday_wish_sheet.dart` | **NEW.** Wish drafts (short/warm/formal) + greeting-card draft + AI wish (MOCK + KEY-GATED, honest "AI preview (mock, no key)" marker); each draft: WhatsApp/SMS/Call (when phone) + Copy + Share. |
| `backend/core/logic/birthdays.py` | **Extended** (optional per task). Added: `relation`/`notes`/`yearly` threading, `this_week`/`kind_label` in `upcoming()`, `this_week()`, relation-aware formal draft, `default_ai_wish_provider` + `ai_wish()` (mock + key-gated, honest `is_mock`/`ai_required`), `send_actions()` URI builders, `link_occasion_to_contact()`, `import_occasions_from_contacts()`. |
| `backend/core/logic/birthdays_tests_snippets.py` | **Extended** 16 → **26** plain-assert tests (this-week/label, non-yearly one-off, relation-in-formal, AI-mock honest + real-provider, send-actions, link/import, scenario). `run_all()` passes. |
| `.phaseB/up_bday_arb.json` | **NEW.** 49 ARB keys `{key:[bn,en]}`. |

> Per task constraints, NOT edited: `api.dart`, `app_*.arb` (keys emitted to
> `up_bday_arb.json`), `models.py`, `urls`, sidebar, `health_api.dart`, other
> screens. No flutter/build/migrations run. No Asalify touched.
> `dart analyze` on the 5 app files: **No issues found.**

## ARB sync
Apply `.phaseB/up_bday_arb.json` (**49 keys**) into `app_bn.arb`/`app_en.arb`.
Placeholders: `{age}`,`{years}` = int (keys `bAgeLabel`,`bYearsLabel`). Everything
else is plain. The screen/widgets read these via `bday_model.bStr` TODAY (no ARB
edit needed to ship); folding into the ARB lets `dart gen-l10n` own them later.
Existing `health_arb.json` birthday keys (birthdaysTitle, birthdayToday/Tomorrow/
InDays, birthdayTurningAge, birthdayWishAction, birthdayShare, retry/save/copy/
copied/delete) are reused as-is.

## Backend wiring (model + endpoints)
Birthday model (from health_integration): user FK, name, date (sentinel year
<=1900 for unknown year), kind, lead_days. **ADVANCED adds columns**: `relation`
(char, blank), `notes` (text, blank), `yearly` (bool default True), `phone`
(char, blank, for one-tap send), `linked_contact_id`/`linked_user_id` (nullable
FK/int). `lead_days` SHOULD be a JSON list of ints (the UI sends e.g. `[7,1,0]`);
`birthdays.reminder_dates()` already accepts an int OR a list.

Endpoints (bind `birthdays.*`, `req_lang`):
- `GET /birthdays` → `{upcoming: birthdays.upcoming(rows, within_days=30, lang),
  kinds: birthdays.kinds(lang)}`. Each upcoming row now carries `days_until`,
  `next_date`, `turning_age`, `kind_label`, `this_week`, plus the stored
  `relation/notes/phone/linked_*`.
- `POST /birthdays` {name,date,kind,yearly,lead_days[],relation?,notes?,phone?} →
  created row. (Edit ships as delete+create from the app; integrator MAY add a
  real `PATCH /birthdays/{id}` and the sheet already emits `id`.)
- `POST /birthdays/{id}/delete` → `{ok:true}`.
- `POST /birthdays/drafts` {name,kind,age?,relation?} →
  `{drafts: birthdays.wish_drafts(...), card: birthdays.greeting_card(...)}`.
  **AI path**: when the body has `ai:true` (+ optional `style`), ALSO return
  `ai: birthdays.ai_wish(name, kind, age, lang, relation, style,
  ai_key_available=<settings has key>, provider=<real LLM or None>)`. With NO
  key this is the deterministic mock with `is_mock:true` — the app shows the
  honest "AI preview (mock, no key)" marker. Drop in a real provider later;
  nothing else changes.

## One-tap send / contacts / Circle
- Send actions are URI launches (`url_launcher`) — WhatsApp `wa.me?text=`, `sms:`,
  `tel:` — plus `share_plus`. NEVER a gateway, `auto_sent:false` everywhere.
  `birthdays.send_actions()` builds the same URIs server-side if you prefer.
- `import_occasions_from_contacts(contacts)` turns device contacts that carry a
  `birthday` into draft occasions (default pre-reminders `[7,1,0]`, pre-linked).
  Reuse the existing on-device hashed importer (msg_contacts) to source them —
  raw numbers never leave the device. The screen's import sheet shows an honest
  empty state until that device source is wired (no dead end).
- `link_occasion_to_contact(occ, contact_id=, phone=, relation=)` returns the
  patch to connect an occasion to a Circle/phonebook contact so one-tap-send
  knows the number; the card shows a "Linked in Circle" badge.

## Section-21 coverage (all 10)
1. **Benchmarked** vs phone reminders — equal/better: pre-reminders, relation,
   yearly, age, drafts, one-tap send, this-week, contacts/Circle link.
2. **Full flow**: create / **edit** / delete / list sorted by next occurrence;
   filter into this-week vs upcoming; import.
3. **Both rails**: manual add + import-from-contacts (auto); AI wish carries an
   explicit "AI preview (mock)" marker on AI-captured text.
4. **Empty / loading / error / OFFLINE** all designed (offline-first cache +
   banner; failed refresh keeps cache; add blocked offline with a message).
5. **bn/en** strict (zero Bangla glyphs in .dart; dates/ages use Bangla digits
   via codepoints), light/dark via theme, small/large via Wrap + ellipsis.
6. Wired into **reminders** (lead-day `reminder_dates`/`should_remind_today` +
   `reminder_payload` for the foreground poll / watch feed) and **chat** nav
   route `birthdays` (existing fake_api watch item); voice-runnable via route.
7. **Server tests** 26 pass incl. a real-world **scenario** (week-before Mom's
   birthday: pre-reminder fires, age=56, personalised AI wish, WhatsApp send).
8. **Share/result cards**: greeting-card draft + per-draft Share action; reuse
   the web festival-card concept (`backend/web/logic/cards.py`) for an image
   card later (text drafts ship now).
9. **Privacy/consent**: never auto-send (every action opens the native app for
   the user to press send); contact import is on-device/hashed; audit the
   create/delete/link in the model's save hook.
10. Pending **independent reviewer**.
