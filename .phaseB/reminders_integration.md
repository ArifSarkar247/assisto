# Reminders & Memory NL-engine — integrator TODO (agent ada293c7) — PENDING REVIEW
Owned in tree: backend/core/logic/nlp_datetime.py, reminders_engine.py (+tests 65 asserts pass); app/lib/screens/reminders_screen.dart(rebuilt), reminders_quick_add.dart(NEW), memory_screen.dart(rebuilt), notes_todos_screen.dart; app/lib/widgets/reminders_nlp.dart(NEW Dart mirror parser, offline).
ARB: apply .phaseB/reminders_arb.json (38 keys). Placeholder @-meta(Object): remRecurMonthlyOn{day}, notesOpenCount{count}.
api.dart add: parseReminder(text)->POST /reminders/parse; searchMemoryApi(q)->GET /memory/search?q= . (UI works offline via Dart mirrors; these are server-of-truth hooks.)
MIGRATION (core): Reminder += recurrence_rule(JSON default dict), date_only(Bool default False), link(JSON default dict). ReminderSerializer.fields += recurrence_rule,date_only,link. No new models.
Endpoints: POST /reminders/parse {text}->nlp_datetime.parse(); GET /memory/search?q=->reminders_engine.search_memory over user's MemoryItems; (optional GET /reminders/upcoming via next_occurrence/expand).
fake_api: extend case 'reminders' with recurrence_rule/date_only/link sample rows (both langs); add a couple memory items w/ category.
Self-grade: parser/engine/retrieval/UI all advanced; linked-entity id-autoresolve deferred. PENDING reviewer.
