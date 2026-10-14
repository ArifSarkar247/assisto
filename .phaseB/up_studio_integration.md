# Agent Studio — BASIC → ADVANCED (SPEC v2.1 §21): integration notes

Scope was kept to the allowed edit set: the Agent Studio screen, new
`studio_*` widgets, and the optional pure backend engine + its tests. No
`api.dart`, no `app_*.arb`, no models/urls/serializers/sidebar were touched.
This file lists what the backend/API would gain to persist and actually *fire*
these automations server-side, and spells out exactly which parts are AI /
key-gated.

## What changed (advanced vs. the old basic screen)

The old `AgentStudioScreen` was a single-shot **document generator** (letter /
CV / caption / Excel / email) that called the existing `POST /studio` endpoint
and showed a needs-key card. That endpoint and its view are **unchanged**.

The screen is now a **no-code automation builder** — the user assembles their
own mini-agents as readable **WHEN … IF … THEN** rules:

- **Triggers (WHEN):** time/schedule (HH:MM, weekdays and/or day-of-month),
  event, keyword, incoming-message. Multiple triggers = OR (any arms it).
- **Conditions (IF):** field / op / value, combined with ALL (AND) or ANY (OR).
  Optional — none ⇒ always runs. Ops: `== != > >= < <= contains`.
- **Actions (THEN):** remind, message, log, summarize, call-a-tool. Run in order.
- **Templates gallery:** bill reminder, daily summary, follow-up, birthday wish.
- **Test / Run now, enable/disable, run history** (last 50 runs per automation).
- A live readable WHEN/IF/THEN preview card in both the builder and the detail.

## Files changed / created

- **Edited** `app/lib/screens/agent_studio_screen.dart` — full rewrite: two tabs
  (My automations / Templates), §21 states (loading skeleton / error+retry /
  empty-with-CTA), FAB create, pull-to-refresh, per-automation detail sheet with
  run-now + run history + enable toggle + delete.
- **New** `app/lib/widgets/studio_engine.dart` — on-device Dart mirror of the
  Python rule engine (models, `isDue`/`evaluate`/`conditionsPass`/`validate`,
  the 5-minute schedule grace window + `last_fired` dedupe), local persistence
  (`StudioStore`, SharedPreferences, key `agent_studio_automations_v1`) and the
  template seeds.
- **New** `app/lib/widgets/studio_cards.dart` — presentation atoms (WHEN/IF/THEN
  reader card, automation tile, template card, run-history tile, honest AI
  banner) + the token→label bilingual localisation.
- **New** `app/lib/widgets/studio_builder_sheet.dart` — the guided builder
  (trigger/condition/action editors, weekday/time pickers, match AND/OR toggle,
  validation, live preview).
- **New** `backend/core/logic/agent_studio.py` — pure deterministic engine
  (no Django/DB/net/AI/clock; `now` is always passed in).
- **New** `backend/core/logic/agent_studio_tests_snippets.py` — 22 plain-assert
  tests, `run_all()` green; wired into `core/tests.py` as
  `AgentStudioSnippetTests`. Full suite: **455 tests OK**.
- **New** `.phaseB/up_studio_arb.json` — **84 keys**, `{key:[bn,en]}`.

## The deterministic engine (source of truth)

`backend/core/logic/agent_studio.py` is the canonical rule engine; the Dart
mirror matches it semantics-for-semantics so Test/Run-now and the due decision
behave identically offline. Main entry:

```python
evaluate(automations, now, ctx=None, grace_minutes=5)
  -> [{"id", "name", "actions": [descriptor...], "needs_ai": bool}, ...]
```

`now` is an explicit local `datetime`; `ctx` carries event/keyword/incoming
context (`{"event", "text", "incoming_from", <condition fields>}`). Schedule
triggers fire inside `[at, at+grace)` and de-dupe against `last_fired`, so a poll
a few minutes late fires **exactly once**. `mark_fired(auto, now)` stamps the
timestamp (pure — returns a copy). `validate(auto)` returns problem keys;
`describe(auto)` returns the structured WHEN/IF/THEN tokens the UI renders.

## Automation shape (the wire/stored object)

```json
{
  "id": "a1", "name": "Electricity bill", "enabled": true,
  "triggers": [{"type":"schedule","at":"09:00","day_of_month":5}],
  "conditions": [{"field":"amount","op":">=","value":500}],
  "match": "all",
  "actions": [{"type":"remind","text":"Pay the bill"}],
  "last_fired": "2026-10-05T09:00:00",
  "history": [{"at":"...","manual":true,"actions":["remind"],"ai_mock":false}]
}
```

## Backend work to light this up end-to-end (NOT done here)

Today automations live only on-device (SharedPreferences). To run them when the
app is closed and share across devices, the backend would add:

| Item | Shape |
|---|---|
| **Model** `core.models.Automation` | `user FK`, `name`, `enabled bool`, `spec JSONField` (triggers/conditions/match/actions), `last_fired DateTimeField(null)`, `created/updated`. One `JSONField` keeps the closed-set spec flexible with no migrations later — same pattern as `Document.details`. |
| **Model** `core.models.AutomationRun` | `automation FK`, `at`, `manual bool`, `action_types JSON`, `ai_mock bool`. |
| **Endpoints** (new, under `/api/v1/`) | `GET/POST /studio/automations`, `GET/PATCH/DELETE /studio/automations/{id}`, `POST /studio/automations/{id}/run` (Test/Run-now → returns the `evaluate` plan + records a run). |
| **Scheduler** | a periodic task (cron/Celery beat) calls `agent_studio.evaluate(user_autos, now)` per user, performs the returned actions (reminders already exist via the reminders engine; message/log/tool map to existing services) and `mark_fired`s the ones it fired. |
| **`api.dart`** (out of scope) | add `automations()/createAutomation()/updateAutomation()/deleteAutomation()/runAutomation()`; the screen falls back to local storage until these exist, so it works offline today. |

## Which parts are AI / key-gated (honest)

- The rule engine is **100% deterministic and key-free** — triggers, conditions,
  due decision, run history: no model is ever called.
- The **only** AI-flavoured action is **`summarize`**. The engine never runs it;
  it only flags the action `ai_required: True` (`AI_ACTIONS == ("summarize",)`).
- In the app, any automation containing a summarize action shows the honest
  **AiMockBanner** ("The summarize step shows a mocked preview for now. Add an AI
  key in Integrations for real AI output."), carries an **AI / AI mock** tag on
  the tile and in run history, and Run-now reports
  `studioRanWithAiMock` ("Ran — the AI part is a mock; add a key for real
  output."). Nothing is presented as real AI output without a key.
- When a key is added (Integrations) the scheduler/executor can route the
  `summarize` descriptor to the existing `ai.generate(...)` path (the same one
  `AgentStudioView`/`/studio` already uses) — no engine change needed.

## Section-21 checklist (all 10)

1. **Empty** — crafted empty state (icon, title, body, "Browse templates" CTA).
2. **Loading** — `SkeletonList` while reading local store.
3. **Error** — load failure → `StateMessage` + Retry.
4. **Offline** — fully local (SharedPreferences); create/edit/run/history all
   work with no network. Pull-to-refresh re-reads the store.
5. **Bilingual** — every string is an l10n key; **zero Bangla literals** in any
   `.dart` (verified); 84 bn/en pairs in `up_studio_arb.json`.
6. **WCAG** — theme tokens only (scheme + `Brand`); tags use ≥AA tinted chips;
   no dark-on-dark; the enabled/disabled tile icon keeps contrast in both modes.
7. **Scenario** — bill-reminder / daily-summary / follow-up / birthday templates
   map one-to-one to the engine's hand-verified test scenarios.
8. **Readable** — the WHEN…IF…THEN card renders the rule in plain language.
9. **Honest AI** — see the key-gated section above.
10. **Deterministic + tested** — `agent_studio.py` + 22 passing snippet tests,
    folded into the Django suite (455 OK).
```
