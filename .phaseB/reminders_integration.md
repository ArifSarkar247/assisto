# Reminders & Memory NL-engine — integrator TODO (agent ada293c7) — PENDING REVIEW
Owned in tree: backend/core/logic/nlp_datetime.py, reminders_engine.py (+tests 65 asserts pass); app/lib/screens/reminders_screen.dart(rebuilt), reminders_quick_add.dart(NEW), memory_screen.dart(rebuilt), notes_todos_screen.dart; app/lib/widgets/reminders_nlp.dart(NEW Dart mirror parser, offline).
ARB: apply .phaseB/reminders_arb.json (38 keys). Placeholder @-meta(Object): remRecurMonthlyOn{day}, notesOpenCount{count}.
api.dart add: parseReminder(text)->POST /reminders/parse; searchMemoryApi(q)->GET /memory/search?q= . (UI works offline via Dart mirrors; these are server-of-truth hooks.)
MIGRATION (core): Reminder += recurrence_rule(JSON default dict), date_only(Bool default False), link(JSON default dict). ReminderSerializer.fields += recurrence_rule,date_only,link. No new models.
Endpoints: POST /reminders/parse {text}->nlp_datetime.parse(); GET /memory/search?q=->reminders_engine.search_memory over user's MemoryItems; (optional GET /reminders/upcoming via next_occurrence/expand).
fake_api: extend case 'reminders' with recurrence_rule/date_only/link sample rows (both langs); add a couple memory items w/ category.
Self-grade: parser/engine/retrieval/UI all advanced; linked-entity id-autoresolve deferred. PENDING reviewer.

## REMINDERS REVIEWER = GOOD → fixes (agent running):
- P1 reminders_screen.dart:166 nextFireOf uses after:now-1day → recurring whose time passed today files as Overdue all day. FIX: after:now for next-upcoming; compute overdue separately (mirror is_overdue).
- P1 reminders_nlp.dart nextOccurrence ignores interval for monthly/yearly (daily/weekly ok) → match Python (monthsFromAnchor%interval, (y-anchor.year)%interval).
- P1 reminders_nlp.dart snooze "পরশু" wrongly → tonight; map পরশু→+2 days (align Python; Python has no পরশু branch — add).
- P2 nlp_datetime _clean_title: strip dangling connectors (at/on/by/to/এ/তে) after date removal.
- P2 reminders_nlp.dart _monthDate missing: "এই/চলতি মাসের N তারিখ" + month-name parsing ("25 December","ডিসেম্বর ৫") — add to match Python.
- P2 memory_screen.dart _memoryStop English-only → add Bangla framing stopwords (\u-escaped) to match Python _MEMORY_STOP.
- P2 expose interval + weekday/day-of-month in recurrence picker (reminders_quick_add.dart) for "every N weeks".
- P3 #10 (HIGH leverage): add shared golden-fixture JSON (inputs→expected datetime/rule/title) run by BOTH reminders_tests_snippets.py AND a Dart test to stop Python↔Dart drift.

## FIX AGENT — ALL DONE (code-only; python snippets 142 asserts / 23 tests PASS)
- P1 reminders_screen.dart: nextFireOf now uses `after: now` (next UPCOMING fire). New `isOverdue(d,now)` + `overdueFireOf(d,now)` helpers; grouping files Overdue via isOverdue. Recurring overdue rule = pointer(due_at) is past AND a whole further occurrence already elapsed (`nextOccurrence(anchor,rule,after:anchor) <= now`) → daily 08:00 seen 10:00 = Today (next tomorrow 08:00), NOT overdue; a skipped day or missed one-off = Overdue. Overdue card shows the missed instant (red); overdue sort by overdueFireOf.
- P1 reminders_nlp.dart nextOccurrence: interval skip added for monthly (monthsFromAnchor%interval) & yearly ((y-anchor.year)%interval) — now matches Python.
- P1 reminders_nlp.dart snooze + reminders_engine.snooze: পরশু/"day after tomorrow" → +2 days at daypart (default 9), checked BEFORE tomorrow/tonight. Python snooze() got the same new branch.
- P2 nlp_datetime._clean_title + Dart _cleanTitle: strip dangling leading/trailing connectors (en at|on|by|to|in ; bn tarikhe|tarikh|te|e) in a loop after date removal. "pay bill on 25/12"→"pay bill", "call mom at 5pm"→"call mom", "২৫ তারিখে বিল দাও"→"বিল দাও".
- P2 reminders_nlp.dart _monthDate: added this-month ("এই/চলতি মাসের N তারিখ") + month-name ("25 December", "ডিসেম্বর ৫", "may 5") branches with same ordering/year-rollover as Python. Added escaped _months map + _biThisMonth const (no literal Bangla).
- P2 memory_screen.dart _memoryStop: added Bangla framing stopwords (\u-escaped) to match Python _MEMORY_STOP exactly; dropped stray 'for' for parity.
- P2 reminders_quick_add.dart: recurrence picker now exposes interval ("Repeat every N <unit>", 1–12), weekday dropdown (weekly), day-of-month dropdown (monthly) → written into recurrence_rule via rebuildRule().
- P3: backend/core/logic/reminders_golden.json created (22 bn/en/Banglish cases, now=2026-10-13T10:00). reminders_tests_snippets.py test_golden() loads + asserts datetime/recurrence_rule/clean_title.

### NEW ARB KEYS (add to real ARBs at integration — 7 keys, bn+en in reminders_arb.json)
remEveryLabel, remOnWeekday, remOnDayOfMonth, remUnitDays, remUnitWeeks, remUnitMonths, remUnitYears.
(reminders_arb.json now lists 45 keys total.)

### PENDING DART TEST (integrator must add)
Add a Dart test (e.g. app/test/reminders_golden_test.dart) that loads the SAME backend/core/logic/reminders_golden.json, runs parseReminder(input, now: DateTime.parse(now)) and asserts dateTime.toIso8601String()==expected.datetime, recurrence==expected.recurrence_rule, cleanTitle==expected.clean_title. This is what actually locks Python↔Dart parity — the Python test alone cannot. (Copy the json into app assets or read via a relative path in the test.)
No git / flutter / migrations run by this agent.

## REMINDERS FIX DONE → ADVANCED (agent aed8ddd). 142 asserts pass + golden fixtures.
- ARB now 45 keys (added remEveryLabel/remOnWeekday/remOnDayOfMonth/remUnitDays/Weeks/Months/Years). Placeholder @-meta unchanged.
- NEW backend/core/logic/reminders_golden.json (22 cases) asserted by reminders_tests_snippets.
- INTEGRATOR pending: add app/test/reminders_golden_test.dart loading the SAME reminders_golden.json to assert reminders_nlp.dart parity (locks Python↔Dart drift).
