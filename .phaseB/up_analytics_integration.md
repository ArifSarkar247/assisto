# Owner Analytics — ADVANCED upgrade (SPEC v2.1 §21, launch gap P15)

GOOD -> ADVANCED. Privacy-friendly product analytics, computed **on OUR OWN
backend only** — no third-party trackers / SDKs, no PII, owner-only (403 for
non-owners). Every number on screen comes straight from the backend payload;
nothing is fabricated.

## Files touched (within the allowed scope)

- `app/lib/screens/owner_analytics_screen.dart` — rewritten to ADVANCED.
- `app/lib/widgets/analytics_charts.dart` — **new** dependency-free chart
  primitives (Sparkline / FunnelBars / PlanBreakdownBar / RangeChips). No
  external chart library; drawn with `CustomPainter` + plain widgets.
- `backend/core/analytics.py` — added `active_users()` (DAU/WAU/MAU + dense
  daily series), `daily_series()` (signup trend), `revenue_by_plan()` (honest,
  null revenue unless priced), `_day_span()`; `dashboard()` now returns the
  superset payload. **Signature stays `dashboard(rows)`-compatible**, so the
  unchanged `AnalyticsDashboardView` (`Response(analytics.dashboard(rows))`)
  passes the new keys through automatically — no view/urls/models/migrations
  edit required.
- `backend/core/launch_gaps_tests_snippets.py` — added
  `test_analytics_active_users_and_series` and
  `test_analytics_revenue_no_fabrication`; updated the dashboard key-set
  assertion. All analytics tests pass (run directly, no Django/DB needed).

## ARB — merge required (not auto-wired)

NEW keys only in `up_analytics_arb.json` (format `key -> [bn, en]`). Merge into
`app/lib/l10n/app_bn.arb` + `app/lib/l10n/app_en.arb` with the existing
`merge_arb.py` (adds missing keys; leaves the existing `analytics*` keys from
`p15_analytics_arb.json` untouched), then regenerate `app_localizations.dart`.
The screen references these getters; it compiles after the merge + gen, exactly
like the other `up_*` features. **26 new keys.** (One removed card label,
`analyticsRetentionD1Base`, reuses the existing D1 wording style.)

## Backend payload (new keys on GET /analytics/dashboard)

```
"active":  {"dau": int, "wau": int, "mau": int,
            "series": [{"day": "YYYY-MM-DD", "users": int}, ...]}   # dense, zero-filled
"signups_series": [{"day": "YYYY-MM-DD", "count": int}, ...]        # dense, zero-filled
"revenue": {"plans": [{"plan": str, "paid_users": int,
                       "price": int|null, "revenue": int|null}, ...],
            "total_paid_users": int,
            "total_revenue": int|null,       # null unless EVERY plan is priced
            "revenue_known": bool}
"range":   {"start": "YYYY-MM-DD"|null, "end": "YYYY-MM-DD"|null}
```

Existing keys (`retention`, `invites`, `paid_funnel`, `top_features`,
`total_events`) are unchanged.

### Optional: enabling real revenue

`dashboard(events, price_map={...})` accepts an owner-configured
`{plan: monthly_price}` map. The current view calls `dashboard(rows)` with no
map, so revenue renders as an honest **"Revenue unavailable (no prices set)"**
estimate badge. To light up revenue figures later, the integrator passes a
`price_map` from settings in the view (a one-line change, outside this task's
edit scope). Until then, no figure is invented.

## ADVANCED vs. GOOD (what's new)

| Area | GOOD (before) | ADVANCED (now) |
|---|---|---|
| Active users | — | DAU / WAU / MAU cards + sparkline trend |
| New users | single count | count + daily sign-up sparkline |
| Retention | D1/D7/D30 + new users | same + D1 cohort base size |
| Funnel | flat metric cards | proportional **bar** funnel + view→paid % |
| Revenue/plans | — | paid users by plan, segmented bar, honest revenue |
| Trends/charts | none | sparklines + bars (no external lib) |
| Date range | none | All / 7d / 30d / 90d chips (scopes trend charts) |
| Export | none | CSV via share sheet (Clipboard fallback) |
| Honesty states | empty/loading/error/owner-only | + per-chart "no trend", "no paid users", revenue "estimate unavailable" |

## Section-21 coverage (all 10)

1. **Loading** — `SkeletonList`. 2. **Empty** — "No data yet" when
   total_events + new_users are 0. 3. **Error** — `cloud_off` + retry.
4. **Owner-only** — 403 -> lock state (not a generic error).
5. **Bilingual** — all copy via ARB; zero Bangla literals in `.dart` (Bangla
   numerals built from code points U+09E6..U+09EF).
6. **WCAG** — white-on-gradient header, `onSurfaceVariant` hints, semantics
   labels on every chart (`Sparkline`/`FunnelBars`), tooltip on export.
7. **No clipped text** — `FittedBox` metric values, `ellipsis` labels.
8. **Scenario** — pull-to-refresh; range chips re-slice without refetch.
9. **Honest numbers** — only backend values; per-chart no-data placeholders;
   revenue null unless priced (never a guess).
10. **Privacy** — OUR backend only, no third-party trackers/SDKs, PII-free
    aggregates (distinct `uid_hash` counts), owner-only.

## Confirmations

- **Our-backend-only / no third-party / no PII:** yes. Charts are local
  `CustomPainter`; data is aggregate counts of opaque `uid_hash`; CSV export is
  built in-app from on-screen numbers and shared via the OS sheet / clipboard —
  no network, no file written, no analytics SDK.
- **Owner-only:** yes. `AnalyticsDashboardView` returns 403 for non-staff; the
  screen shows a dedicated owner-only state.
- **Numbers from backend only:** yes. No client-side synthesis; unknown
  revenue and empty trends render honest estimate / no-data states.
