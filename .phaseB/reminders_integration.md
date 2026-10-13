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
