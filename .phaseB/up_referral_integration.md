# Referral points -> ADVANCED (#102, SPEC v2.1 §21) — integrator TODO

EDITED: app/lib/screens/referral_screen.dart (now a 3-tab surface: Overview / Friends / History);
backend/core/logic/referral.py (+6 pure functions, superset bundle); referral_tests_snippets.py (18 -> 24 tests, all pass).
NEW widgets: app/lib/widgets/ref_progress_card.dart, ref_share_sheet.dart, ref_leaderboard.dart, ref_achievement_card.dart, ref_audit.dart.
ARB: apply .phaseB/up_referral_arb.json (34 NEW keys) on top of the existing referral_arb.json (22 keys). Zero Bangla in any .dart (codepoint-scanned clean).

## ARB keys (34 new) — parameterized
refProgressJoined{n}, refProgressDaysEarned{days}, refProgressNext{n}, refLeaderboardMember{rank},
refRedeemedRow{days}, refCardCaption{friends,days}. All others are plain getters. Tabs: refTabOverview/Friends/History.

## Backend — NEW pure functions in referral.py (no DB, deterministic, NO invented values)
All derive from the SAME audit ledger + the existing OWNER-REVIEW constants, so they can never disagree with balance()/history():
- my_referrals(ledger,user) / joined_count(ledger,user) — effective (not-clawed) referral grants = people who truly joined.
- progress(ledger,user) -> {friends_joined, points_per_referral, points_per_day, days_earned_total,
  friends_per_day, friends_to_next_day, progress_to_next_day (0..1), earned_points_total}. The "earn X days by inviting Y" model; every number echoed from backend constants.
- invite_leaderboard(ledger,user) -> [{rank, invitee_id, points, month, created_at, joined_label}] — HONEST: one row per invitee who ACTUALLY joined; non-joiners get NO row / NO identity.
- audit(ledger,user) -> {earned_total, spent_total, reversed_total, balance} — reconciles to balance() by construction.
- redeemed_history(ledger,user) -> [{spent, days, created_at, label}] — points->Premium-days redemptions, newest first.
- advanced_summary(ledger,user,lang) -> referral_summary(...) PLUS {progress, leaderboard, audit, redeemed}. A SUPERSET of referral_summary.

## Endpoint wiring (integrator)
1. GET /referral/balance: return `referral.advanced_summary(ledger, user, lang)` INSTEAD OF referral_summary
   (it is a strict superset — the old balance card keeps working). Also add to the payload:
     - `invite_link`  : circle make_invite_token + qr_payload (already planned in m1_referral).
     - `referral_code`: the inviter's short code (embed in link + shown on QR/share/achievement card).
   The Flutter screen degrades gracefully: if `progress/leaderboard/audit/redeemed/referral_code` are absent it
   still renders the basic balance + history (back-compat with the pre-advanced endpoint).
2. invite_leaderboard carries only invitee_id. In the view, JOIN invitee_id -> a display name the user is ALREADY
   allowed to see (a Connected-Circle relationship exists). Send it as `name` on each row; the UI falls back to
   "Member #rank" if absent — it never renders a raw id and never fabricates a name. Do NOT add non-joiners.
3. Share routes are client-side only (share_plus link, QR card w/ placeholder box + selectable link until a QR
   package lands, own-SIM `sms:` composer via url_launcher). No new backend. The achievement card is a
   RepaintBoundary->PNG via the existing WrappedShare helper (no new deps).
4. redeem flow unchanged: POST /referral/redeem {points} -> referral.redeem -> persist row + apply res['days']
   Premium via plans.py. The screen now shows an explicit confirm sheet + a success dialog on ok.

## No change required to
api.dart (existing referralBalance/History/Redeem already carry the richer JSON), core models beyond the m1
ReferralGrant ledger, urls, sidebar, or any app_*.arb (keys delivered via up_referral_arb.json for the merge step).
OWNER-REVIEW constants unchanged (POINTS_PER_REFERRAL=50, WELCOME_BONUS=20, POINTS_PER_PREMIUM_DAY=25,
MIN_REDEEM=25, MONTHLY_CAP=20, MAX_REDEEM_DAYS=400) — still the single source of truth; the client echoes them.
