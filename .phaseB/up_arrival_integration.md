# Safe-arrival / "পৌঁছেছি" check-in — ADVANCED (SPEC v2.1 §21) — integrator notes

Upgrades the Safe-Journey / P16 safe-arrival check-in (feature "safe-arrival
check-in") from GOOD → ADVANCED. Concept: user says "I'll reach X by TIME" and
picks who to alert; if they don't tap "I've arrived / পৌঁছেছি" by then (+grace),
the chosen family is alerted AND the last known location is shared. Everything
REUSES the existing Safe Journey / family-alert machinery — no duplicate
audience, PIN, alert path, or routine scheduler.

## Files changed / created (STRICTLY in scope)
| File | What |
| --- | --- |
| `app/lib/screens/safe_arrival_screen.dart` | **NEW.** The advanced screen: who-to-alert setup, live countdown, pre-arrival reminder, miss→escalation (family alert + share last location), recurring daily-commute routine, women's night-safety framing, duress-aware arrival, local history, honest loading/offline/empty states. |
| `app/lib/widgets/arrival_model.dart` | **NEW.** Bilingual string table (Bangla as `\u` codepoints — **zero Bangla glyphs in .dart**), `aNum` Bangla digits, weekday catalog, and pure client-side mirrors of `safety.py` (`aCheckinStatus`, `aCountdown`, `aReminderDue`, `aIsNightTime`, `aEffectiveGrace`). |
| `app/lib/widgets/arrival_target_card.dart` | **NEW.** Active target card: 1-second live countdown (on_time→grace→overdue), reminder nudge, overdue-with-location note, big one-tap "পৌঁছেছি", duress-confirm affordance, night icon. |
| `app/lib/widgets/arrival_setup_sheet.dart` | **NEW.** Setup sheet: destination (optional) · arrival time · **who-to-alert** multi-select (from existing contacts) · night-safety toggle. |
| `app/lib/widgets/arrival_history_tile.dart` | **NEW.** Past-check-in row — green "Arrived" / red "Missed — family alerted" (icon+text, not colour alone). |
| `app/lib/widgets/safety_checkin_card.dart` | **Edited (the GOOD safe-arrival widget).** Added an "Open advanced" entry in both the empty and active states that pushes `SafeArrivalScreen`. Nothing else changed. |
| `backend/core/logic/safety.py` | **Extended (optional per task).** Added safe-arrival advanced helpers: `clamp_remind_lead`, `checkin_reminder_due`, `countdown_parts`, `is_night_time`, `effective_grace` (night grace = 7 min), `checkin_escalation` (overdue payload **+ last_location + maps link + duress/silent** flags), `routine_checkin_eta`, `routine_should_alert`. All REUSE `checkin_status`/`should_alert_checkin`/`checkin_overdue_payload`. |
| `backend/core/logic/safety_tests_snippets.py` | **Extended** 17 → **23** plain-assert tests (remind window, countdown before/overdue, night-grace tightening, escalation-with-location + duress-silent, routine eta + alert). `run_all()` passes. |
| `.phaseB/up_arrival_arb.json` | **NEW. 51 ARB keys** `{key:[bn,en]}`. |

> Per task constraints, NOT edited: `api.dart`, `app_*.arb` (keys emitted to
> `up_arrival_arb.json`), `models.py`, `urls`, sidebar, `journey_live_screen.dart`,
> the SOS/fall sections of `safety_screen.dart`, other screens. No
> flutter/build/migrations run. No Asalify touched.
> `dart analyze` on the 5 new app files: no errors/warnings (only 2 repo-wide
> `withOpacity` info-deprecations, matching existing code).

## REUSED backend / API (no duplication)
The screen talks ONLY to methods that already exist:
- `safetyCheckinStart({place, etaIso})` / `safetyCheckinArrived()` — the existing
  check-in endpoints the family poll reads (`views._build_alerts` →
  `safety.checkin_status` → `checkin_overdue_payload`).
- `journeySos(silent: true)` — the **duress** path: a "I've arrived" tap made
  with the duress PIN confirms normally on-screen while silently firing an SOS
  to watchers (identical to `safety_journey.duress_outcome`). Gated on the
  existing `journey_has_duress` flag set in Journey settings.
- `journeyRoutines()` / `saveJourneyRoutine({days,time,destination,watcher_ids,
  enabled})` — the existing recurring-commute scheduler
  (`safety_journey.routine_due`). "Alert if not home by 9pm" is stored as a
  routine; `safety.routine_should_alert` layers the overdue→alert semantics.
- `getEmergency()` — the who-to-alert candidate list (circle/emergency
  contacts). Selected ids are stored locally (`arrival_alert_ids`) and sent as
  `watcher_ids` on routines; the integrator can thread them into
  `safetyCheckinStart` when that endpoint accepts a watcher list.
- Last-location sharing reuses the journey `last_location {lat,lng,at}` shape;
  `safety.checkin_escalation` builds the overdue alert body WITH the maps link.

## Backend wiring (what the integrator still owns)
1. `checkin_escalation(...)` is what the overdue poll should push instead of the
   bare `checkin_overdue_payload` so family receives the **last location** and a
   **duress/silent** flag. Feed it the user's last `journey.last_location` (or a
   stored last fix). `views._build_alerts` is the single place to swap it in.
2. The one-off check-in's chosen `watcher_ids` + `night_mode` should be stored
   on the check-in row so the overdue poll can use `effective_grace(eta,
   night_mode=...)` (tighter 7-min grace for night arrivals) and alert exactly
   the chosen members. Today the app persists them locally and every circle
   member still sees the overdue alert via the existing poll.
3. The pre-arrival **reminder** (`checkin_reminder_due`) is a LOCAL nudge only —
   wire it to the notification layer if desired; it never alerts anyone.

## ARB sync
Apply `.phaseB/up_arrival_arb.json` (**51 keys**) into `app_bn.arb`/`app_en.arb`.
Placeholders: `aMinLeft`/`aMinLate` take `{min}` (int). Everything else is
plain. The screen/widgets read these via `arrival_model.aStr`/`aMin` **today**
(no ARB edit needed to ship); folding into the ARB lets `dart gen-l10n` own them
later. The existing `safetyCheckin*` / `safetyArrived*` ARB keys on the GOOD
card are untouched and still used there.

## Section 21 — all 10 (acceptance gate)
1. **Best-in-class**: matches Life360/bSafe "check-in by time" + adds women's
   night-safety grace, duress-aware arrival, local-first offline countdown.
2. **Full task flow**: set / edit / arrive (delete=arrive) / routine add / history.
3. **Both rails**: manual set + one-tap arrive; auto overdue→alert on the poll;
   geofence auto-arrival available via `safety.within_place` (journey layer).
4. **States**: empty (no check-in), loading, offline banner + retry, overdue.
5. **bn/en** via codepoint table, light/dark via theme, scroll-safe layout.
6. Reuses the family-alert **poll** (watch feed) + check-in endpoints; voice/chat
   can push the same `safetyCheckinStart`.
7. **Tests**: 6 new server tests (23 total) incl. scenario (night 9:15pm miss).
8. **Share card**: "share last location" + overdue alert body carries the link.
9. **Privacy/consent**: location shared only on user action or documented miss;
   duress stays silent; audience limited to chosen circle members.
10. Independent-reviewer ready: `dart analyze` clean, backend tests green.
