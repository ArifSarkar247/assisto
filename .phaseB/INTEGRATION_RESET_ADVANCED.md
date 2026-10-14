# Password reset / account recovery — GOOD → ADVANCED (SPEC v2.1 §21)

Upgrades the launch-gap reset flow to ADVANCED. UI-only + reuse of the existing
`backend/core/reset.py` logic; no new endpoints, models, migrations, or
api.dart methods were introduced (deliberately kept inside the allowed edit
surface).

## What changed
- `app/lib/screens/password_reset_screen.dart` (request step) — rewritten.
- `app/lib/screens/password_reset_confirm_screen.dart` (confirm step) — rewritten.
- `app/lib/widgets/reset_strength_meter.dart` — NEW (strength scoring + meter).
- `app/lib/widgets/reset_options.dart` — NEW (channel tiles, rate-limit banner,
  sign-out-all toggle).
- `backend/core/reset.py` — ADDED pure helpers: `score_password`,
  `should_revoke_sessions`, `change_password_check`, strength level constants.
- `backend/core/launch_gaps_tests_snippets.py` — ADDED
  `test_reset_advanced_strength_and_sessions` (passes).

## l10n
Merge `up_reset_arb.json` via `merge_arb.py`. 30 NEW keys (existing `reset*`
keys are reused untouched). ONE key is parameterized and must be added to
`PARAMS` in `merge_arb.py` so it gets `@`-metadata:

```python
PARAMS["resetStrengthSemantics"] = ["label"]
```

All `.dart` is Bangla-free; every human string resolves through
`AppLocalizations`.

## Backend wiring to light up the advanced behaviour (optional)
These are honest no-ops today and the UI degrades gracefully without them:

1. **Sign out all devices.** The confirm screen shows a toggle (secure default
   ON). To honor it, in `ResetConfirmView.post` after a successful reset:
   ```python
   if reset.should_revoke_sessions(request.data):
       from rest_framework.authtoken.models import Token  # or your Token model
       Token.objects.filter(user=tok.user).delete()
   ```
   The app sends `revoke_sessions` only if `api.confirmPasswordReset` is later
   extended; until then `should_revoke_sessions({})` defaults to True, so wiring
   the delete already gives the right behaviour. (No api.dart change was made
   here per the edit constraints.)

2. **Rate-limit honesty.** Already enforced: `throttle_scope="reset"` at
   `6/min`. The UI now reads the resulting **HTTP 429** (`ApiException.status`)
   and shows "too many attempts, wait a minute" instead of a silent failure —
   no retry loop.

3. **SMS channel.** Stays 🔑 key-gated. `reset.sms_reset_available()` returns
   False until an SMS gateway integration is enabled; the UI shows the honest
   "available when an SMS gateway is added" tile (locked, non-tappable).

4. **Security-question channel.** Listed honestly as opt-in / not configured.
   No fake challenge is presented.

## Security properties preserved (unchanged from GOOD)
- Tokens: `secrets.token_urlsafe`, stored as SHA-256 hash only, short TTL
  (30 min), **single-use** (consumed on confirm). `check_token` collapses
  used/expired/invalid into one reason the view reports as a single
  "invalid or expired" message — no attacker signal.
- Anti-enumeration: request step ALWAYS returns the same neutral message.
- Strength FLOOR is authoritative on the backend (`validate_password`); the
  app meter (`score_password`) only mirrors it for an offline hint and never
  blocks typing.

## §21 states covered (both screens)
empty (channel chooser / form) · loading (Sending…/Saving… spinners) · error
(field validation + rate-limit banner) · expired (collapsed used/expired/invalid
card with "request a new link") · success (neutral-sent / password-changed,
with signed-out variant) · bilingual (ARB) · WCAG (strength announced via
`Semantics`, not colour-only; show/hide tooltips; disabled states) · scenario
(deep-link token pre-fill OR paste-a-code path).
```
