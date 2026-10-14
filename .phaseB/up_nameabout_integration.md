# About the Assisto name / trademark — ADVANCED (SPEC v2.1 §21) — integrator notes

Upgrades the "About the Assisto name" info surface from GOOD -> ADVANCED. It is
an honest, **informational-only** note about the name — never a legal trademark
clearance and never legal advice. It explains the meaning & brand story, which
Nice classes matter (9 & 42 emphasised), the trademark-check STATUS (always
"research pending — no clearance claimed"), a DIY trademark checklist the owner
works through (search the BD DPDT portal + the classes + app stores/domains,
then consult an attorney), the official source links (DPDT portal + WIPO), and
a bilingual FAQ. The not-legal-clearance disclaimer is shown PROMINENTLY and
REPEATEDLY and the surface NEVER claims clearance.

## Advanced vs. before
| | GOOD (before) | ADVANCED (now) |
| --- | --- | --- |
| Disclaimer | one card, mid-page | **high-contrast banner at the TOP + compact reminder repeated LOWER + shown even in the empty state**; status can never read as "cleared" |
| Name / meaning | hero + one meaning line | hero + **"Meaning & brand story"** section (ARB-backed story, server meaning folded in) |
| Status | plain server string | dedicated **"research pending — no clearance claimed"** card (warning colour, never success) shown even if server omits it |
| Classes | flat list | cards with **9 & 42 visually emphasised** ("Primary" badge + outline) + a hint explaining per-class registration |
| Checklist | static list | **interactive DIY checklist** with tick-off + honest "n of m" progress + closing reminder that ticking all boxes is NOT clearance (ticks are local, nothing saved/sent) |
| Sources | none | **official source tiles** — BD DPDT portal + WIPO Global Brand Database — open externally, copy-to-clipboard fallback, framed as "where to look", never "the answer" |
| FAQ | none | **6-question bilingual FAQ** (cleared? / why 9 & 42 / how to search DPDT / need an attorney / outside BD / name taken?) |
| States (§21) | loading / error / empty | loading (skeleton) / **offline (distinct copy)** / error / **empty-with-disclaimer** / scenario-complete body; bilingual; WCAG error-container pairing; Semantics on banner + source links |

## Files changed / created (STRICTLY in scope)
| File | What |
| --- | --- |
| `app/lib/screens/name_about_screen.dart` | **Rewritten.** Phase/state-driven (loading / offline / error / empty-with-disclaimer / body); composes the new widgets; disclaimer at top AND compact reminder at bottom; status always "no clearance claimed". |
| `app/lib/widgets/nameabout_sections.dart` | **NEW.** `NameAboutDisclaimerBanner` (full + compact, Semantics), section title, brand story, status card (warning-only), class card (9/42 emphasis), **source note** (DPDT + WIPO links, external launch + copy fallback), FAQ. Holds the DPDT/WIPO URLs. |
| `app/lib/widgets/nameabout_checklist.dart` | **NEW.** Interactive DIY checklist (local ephemeral ticks), honest progress, closing "ticking ≠ clearance" reminder; uses server-supplied localised steps, falls back to ARB steps. |
| `backend/core/nmcheck.py` | **NOT edited** — the existing payload (`about_the_name`: name/meaning/classes[9,42,35,38]/checklist/status/disclaimer) already feeds the advanced UI faithfully and already refuses to claim clearance. No change needed. |
| `.phaseB/up_nameabout_arb.json` | **NEW.** 34 new ARB keys `{en,bn}` + 1 placeholder meta (`nameAboutStepsProgress`). |

> Per task constraints, NOT edited: `api.dart` (reused `nameAbout()` as-is),
> `app_en.arb` / `app_bn.arb` / `app_localizations.dart` (new keys emitted to
> `up_nameabout_arb.json`; folded at integration), `models`, `urls`, sidebar,
> other screens. No flutter / build / gen-l10n / migrations were run. No
> Asalify touched. `dart analyze` on the 3 app files: the ONLY findings are the
> expected `undefined_getter` references to the new ARB keys — they resolve
> after the ARB merge + gen-l10n below (same convention as every up_* module).

## ARB sync (REQUIRED before build)
Apply `.phaseB/up_nameabout_arb.json` (**34 keys**, prefix `nameAbout*`):
1. Merge the `en` map into `app/lib/l10n/app_en.arb`, the `bn` map into
   `app/lib/l10n/app_bn.arb`.
2. Add the `placeholders_meta` block (`nameAboutStepsProgress` -> `done`,
   `total`) as `@nameAboutStepsProgress` **in app_en.arb only** (this project
   keeps @-metadata in app_en.arb — see existing `@nameAboutClassLabel`).
3. Run `flutter gen-l10n` (or a build). The 35 analyzer errors clear.

Reused existing keys (NOT redefined): `nameAboutTitle`, `nameAboutNameLabel`,
`nameAboutDisclaimerTitle`, `nameAboutDisclaimer`, `nameAboutStatusLabel`,
`nameAboutClassesLabel`, `nameAboutClassLabel`, `nameAboutChecklistLabel`,
`nameAboutChecklistHint`, `nameAboutError*`, `nameAboutEmpty*`, plus shared
`retry`, `copy`, `copied`.

## New dependency surface
`url_launcher` is already a project dependency (used by `ride_deeplink.dart`
etc.) — no pubspec change. External links open via
`launchUrl(..., LaunchMode.externalApplication)` with a copy-to-clipboard
fallback when a browser can't be launched.

## Not-legal-clearance / never-claim-clearance verification
- Disclaimer rendered **3×**: top banner (full), bottom reminder (compact),
  and inside the empty state — plus the server `disclaimer` note when present.
  Every variant reads "informational only — NOT legal trademark clearance /
  not legal advice".
- Status is **always** "research pending — no clearance claimed" (warning
  colour, never success). The hero repeats it. No code path can render a
  "cleared / available / registered" claim.
- Checklist closing line explicitly states ticking every box is NOT clearance
  and only an attorney can advise.
- Sources are **source-noted**: the official BD DPDT portal and WIPO links are
  shown verbatim and opened externally, framed as "where to look", never as a
  result the app produces.
