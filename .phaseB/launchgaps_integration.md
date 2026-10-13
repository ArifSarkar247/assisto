# Launch gaps — integrator TODO (agent a515a717, self-grade A-)
NEW files (in tree): backend/core/{analytics,reset,legal,nmcheck,photo,unseen,launch_gaps_tests_snippets}.py (9 tests pass); app/lib/screens/{password_reset_screen,password_reset_confirm_screen,legal_screen,photo_enhance_screen,unseen_world_screen}.dart; owner_actions/name_check.md + owner_actions/legal/*.md (DRAFT TO REVIEW BY OWNER).

## MIGRATION (core): PasswordResetToken(user FK, token_hash CharField64 idx, channel default 'email', expires_at, used Bool, created_at); AnalyticsEvent(uid_hash CharField32 idx, name, day Date idx, props JSON, created_at — NO user FK by design). Optional settings.ANALYTICS_HMAC_KEY.
## Endpoints (core/urls+views, thread req_lang): POST /auth/reset/request (neutral_response verbatim; if user exists create token+send_mail build_email); POST /auth/reset/confirm (check_token→validate_password→set); POST /analytics/ingest (analytics.ingest→bulk save); GET /analytics/dashboard (owner-admin); GET /legal + /legal/<key>; GET /name/about; POST /photo/plan (server re-enforces doc/own/faithful rules); GET /unseen.
## api.dart: requestPasswordReset(email), confirmPasswordReset(token,password), legalIndex(), legalPage(key), photoEnhancePlan({kind,ops,ownPhoto}), unseenCompanion().
## fake_api: stubs for all above (see agent report).
## ⚠️ ARB GAP: agent listed KEY NAMES but NOT bn/en values. Keys: reset* (17), legal* (3), photo* (18), unseen* (7). EN values are in the screen call-sites. INTEGRATOR: SendMessage agent a515a717 asking for full {key:[bn,en]} JSON, OR author from screens. These screens won't compile until keys exist in ARB.
## Drawer/login (shared, integrator): sidebar Life += UnseenWorldScreen, PhotoEnhanceScreen; Settings/About += LegalScreen + name-about; login_screen += "Forgot password?" → PasswordResetScreen; deep link assisto://reset/confirm?token= → PasswordResetConfirmScreen.
## Security: reset tokens sha256-hashed, 30min, single-use, compare_digest, no enumeration; analytics HMAC uid_hash no PII no FK consent-gated; photo ID/doc hard-block + own-attest + no-fabricate server-side.

## LAUNCH-GAPS REVIEWER = ADVANCED → fixes + integration notes:
- GAP-1 (P0-adjacent) photo: photo_enhance_screen.dart hardcodes kind:'personal' so photo.py doc hard-block never fires (attestation-only). FIX: UI must pass the user-declared kind (personal/document) so the server block is reachable as defense-in-depth; soften spec/legal copy to "attestation-based ID protection" (true detection needs an ML model = key-gated). Keep own-photo attest + forbidden-op reject.
- GAP-2 (P1) analytics.py HMAC falls back to SECRET_KEY then LITERAL b"assisto-analytics" → if SECRET_KEY unset, uid_hash attacker-reproducible. FIX: require ANALYTICS_HMAC_KEY or SECRET_KEY; FAIL CLOSED (raise) rather than literal.
- GAP-3 wiring (integration): add models + endpoints per this spec (expected).
- GAP-4 (P2 integration): MUST rate-limit /auth/reset/request + /confirm (brute/enum/email-bomb); view always pass req_lang.
