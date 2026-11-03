# Assisto — standing rules for Claude sessions

## PERMANENT OWNER RULE — WORLD CLASS (4 Nov 2026 01:32; the owner will not repeat this)
Every feature in Assisto must be WORLD CLASS — the best, not just good; it must beat the best app in its
category. OWNER DECISION: at the 8 Nov production launch ALL features stay ON, nothing hidden — goal: every
feature ≥ 9/10 by 7 Nov.
- Quality board: owner_actions/QUALITY_BOARD_BN.md — per feature: best-in-class reference app (internal notes
  only, never in app UI text) + scores /10 for: works end to end on a real phone, speed, design and clarity,
  Bangla quality, reliability and error handling, privacy and safety. Shown in Owner Admin.
- Work order: AI chat rebuild first → features users touch most (My Circle, Safe Journey, home, notifications,
  plans and credits, business ledger and invoice, CCTV) → the rest. No brand-new features until core features reach 9.
- Proof before "done": scripted end-to-end tests of main flows (emulators + Firebase Test Lab), two-phone tests
  for My Circle and Safe Journey, the nightly AI exam. Every owner-found failure becomes a test.
- Daily 21:00 Dhaka: board update in STATUS (how many features ≥ 9). 7 Nov 18:00 Dhaka: list every feature
  still below 9 with what is missing, for the owner to decide.

## PERMANENT OWNER RULE — Assisto AI answer quality (4 Nov 2026 00:47; the owner will not repeat this)
Every Assisto AI answer, at every level (Normal included), must be DETAILED and the BEST possible — not just good:
complete; well structured (short headings or numbered steps); practical actions the user can do today; Bangladesh
context when relevant (local prices, places, laws in general terms, bKash, Nagad, local examples); a short summary
first, then the details; no filler, no vague hedging; correct facts; ends with a clear next step or a useful
follow-up offer. Answers never stop mid-word: if an output limit is reached, end at a full sentence and offer
"Continue" from the cut point (never repeat the answer), and a cut answer is never charged as complete.
Reply in the language of the user's latest message (Bengali script or romanized Bangla → Bangla; English → English).
This rule must also live in the AI system prompts (backend/core/ai_prompt.py).

## Where things are
- Pending work and how to resume: owner_actions/RESUME_PLAN.md (priority order) and .phaseB/QUEUE.md.
- Owner status (Bangla): owner_actions/STATUS_FOR_OWNER.md.
- Never commit secrets; never touch the old Asalify server; CI-only tests/builds; Play production track is never touched.
