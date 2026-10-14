# Legal / policy centre (launch gap C) — GOOD → ADVANCED · integration notes

SPEC v2.1 §21 (10-point quality bar) + §22 (mandatory disclaimers). Scope of
THIS change (already done, in-repo):

- `app/lib/screens/legal_screen.dart` — rewritten (advanced: searchable policy
  index, per-page search for long pages, structured expandable sections, DRAFT
  banner, last-updated + contact footer, copy-page, full state set).
- `app/lib/widgets/legal_widgets.dart` — NEW (reusable chrome: `LegalPageData`
  / `LegalSection` models with search + old-backend back-compat;
  `LegalDraftBanner`, `LegalSearchField`, `LegalSectionList`, `LegalPageFooter`,
  and the designed `LegalLoading` / `LegalErrorState` / `LegalEmptySearch`
  states).
- `backend/core/legal.py` — EXTENDED (4 → 9 pages; each page now returns ordered
  `sections` + a back-compat flat `body` + `contact`; centralised §22
  `MANDATORY_DISCLAIMERS`).
- `backend/core/launch_gaps_tests_snippets.py` — +2 legal tests (now 3) and the
  existing one hardened.
- `.phaseB/up_legal_arb.json` — **5** NEW bilingual chrome keys `{key:[bn,en]}`.

Nothing else was edited: no `api.dart`, no `app_*.arb`, no `models.py`,
`urls.py`, `serializers.py`, `views_module5.py`, no sidebar/chatnav. No
migrations, no flutter build, no Asalify.

## Advanced vs. before
Before (GOOD): 4 pages (privacy, terms, health, data-safety), each a single
flat Bangla/English blob; a plain list + flat text viewer; loading + offline
states only.
After (ADVANCED): 9 pages — **Privacy, Terms, Health Disclaimer, Community
Guidelines, Content Policy, Play Data-safety summary, 18+ note, Data rights
(export/delete), What admins can see** — each rendered as clear, titled,
expandable sections; searchable index (matches titles + any opened page's
section text) and per-page search; §22 DRAFT banner on every page; last-updated
date + "questions/contact" line; copy-page; full §21 state set (loading /
offline+retry / empty-search). Bilingual end-to-end (backend serves bn|en via
Accept-Language; chrome via ARB). 45 sections total across the 9 pages.

## Contract (api.dart UNCHANGED — superset only)
`/legal` still returns `{pages:[{key,title,stamp}]}` (now 9 entries).
`/legal/<key>` still returns `{key,title,draft,stamp,last_updated,body}` and
now ALSO `sections:[{heading,body}]` and `contact`. `LegalPageData.fromJson`
tolerates an old backend (no `sections`) by synthesising one section from
`body`, so the viewer degrades gracefully.

## §22 mandatory disclaimers — present & test-locked
Centralised in `legal.MANDATORY_DISCLAIMERS` (bn+en), surfaced on their owning
pages and asserted by tests:
- **not-medical-advice** → Health Disclaimer ("Important" section).
- **not-legal-advice** → defined + available (Terms points to it; it is the
  spine of the whole centre being DRAFT/not-final).
- **never-hold-money** → Terms ("About money" section).
- **data-rights (view/export/delete)** → Privacy ("Your rights") + the
  dedicated Data-rights page.

## §22 DRAFT stamp — every page, both languages
`DRAFT_STAMP_BN = "খসড়া — মালিক/আইনজীবী কর্তৃক পর্যালোচনা প্রয়োজন"`,
`DRAFT_STAMP_EN = "DRAFT — to be reviewed by owner/lawyer"`. Returned by
`index()` and `page()` for every key; rendered by `LegalDraftBanner` on every
page and shown as each index tile's subtitle. No page can present unreviewed
legal text as final.

## l10n — REQUIRED to compile
`flutter analyze` on the 2 Dart files reports exactly **5** `undefined_getter`
findings — all for the new `legal*` ARB keys (expected; they live in the ARB
until gen-l10n runs). No other errors/warnings.

To wire:
1. Merge `up_legal_arb.json` into `app/lib/l10n/app_bn.arb` (index `[0]`) and
   `app/lib/l10n/app_en.arb` (index `[1]`). (Plain string keys, no ICU
   placeholders.) Reused keys `legalTitle / legalOffline / legalLastUpdated /
   retry / copied / search / close / contact` are already present — do not
   re-add.
2. Run `flutter gen-l10n` → regenerates the getters → 0 analyzer errors.

Zero Bangla string literals in any `.dart` (verified:
`grep -P '[\x{0980}-\x{09FF}]'` on both files is empty). All rendered Bangla
(page titles, section headings/bodies, stamp, contact) is backend DATA.

## Backend tests
`python3 -c "import core.launch_gaps_tests_snippets as t;
t.test_legal_draft_stamped_both_langs(); t.test_legal_advanced_pages_present();
t.test_legal_mandatory_disclaimers_present(); print('legal: 3 tests passed')"`
→ passes (3). (The analytics tests in that file need Django `SECRET_KEY`; that
is a pre-existing env requirement, unrelated to legal.)

## Section-21 (all 10) coverage
1. Side-by-side (vs a scattered web-only policy link): a single in-app centre,
   searchable, bilingual, offline-tolerant, with transparency + data-rights.
2. Full flow: open centre → search index → open page → search within page →
   expand/collapse sections → copy page → back (page cached for index search).
3. Input rails: typed search (index + per-page), tap-to-expand sections,
   copy-page button, clear-search. No AI here (static reviewed-draft copy) — no
   AI marker needed.
4. States: loading (spinner + label), offline/error (icon + retry), empty
   index-search, empty page-search, graceful old-backend fallback.
5. bn/en both (backend data + ARB chrome), light/dark (ColorScheme-driven, no
   hardcoded surface colours; DRAFT banner uses errorContainer for WCAG-AA
   contrast in both), small/large (ListView + ExpansionTile + SelectableText,
   no clipping, text wraps/scrolls).
6. Hooks: reusable `LegalPageData` / section widgets + copy feed other surfaces;
   the centre is reachable from Settings/sidebar via the existing route.
7. Tests: backend 3 asserts (draft+stamp both langs, 9 advanced pages present
   incl. "18" on the age note, all four mandatory disclaimers on their pages).
8. Share: per-page copy-to-clipboard with a confirmation snackbar.
9. Privacy: read-only pages, `AllowAny` endpoints, no PII, no logging; the
   admin-transparency page itself discloses what operators can/cannot see.
10. Reviewer: every page stamped DRAFT — pending owner/lawyer review (the whole
    point of §22); plus the usual owner screenshot-review pass.
