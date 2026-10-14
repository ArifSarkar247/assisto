# Social-media post & caption composer (#135, SPEC v2.1 §21): integration notes

ADD-ONLY feature on top of the already-advanced Agent Studio. Scope stayed
inside the allowed edit set: one **new** screen opened from Agent Studio, new
`social_*` widgets, and a **new** pure backend engine + its tests. No
`app_*.arb`, no `api.dart`, no models / urls / serializers / sidebar were
touched. The Agent Studio automation builder is **unchanged**; this is a
separate "mini-tool".

## What it does

Pick a **platform** (Facebook / Instagram / LinkedIn / WhatsApp-status), a
**topic/goal**, a **tone**, a **length** and a **language** (bn / Banglish / en)
→ it **drafts** a post body + a one-line caption + hashtags + suggested emoji.
The user edits the draft freely, taps hashtag/emoji chips to insert them, sees a
live **per-platform character counter** (turns amber near the cap, red + blocks
Share when over), then **copies** or **shares** the text to the platform's own
app and posts it **themselves**. Drafts can be **saved** and reopened (local
history, newest-first, capped at 50).

## Files changed / created

- **New** `app/lib/screens/social_compose_screen.dart` — two tabs (Compose /
  Saved), §21 states (loading skeleton / error+retry / empty-with-CTA on the
  Saved tab), choosers, draft, edit, char-count, copy/share, save.
- **New** `app/lib/widgets/social_engine.dart` — on-device Dart mirror of
  `backend/core/logic/social.py`: the deterministic generator (`buildDraft`,
  `hashtagsFor`, `emojiFor`, `charCount`, `captionFor`, `composeForShare`,
  `validateSocial`), the per-platform limit table (`kPlatforms`), and local
  persistence (`SocialStore`, SharedPreferences key `social_drafts_v1`).
- **New** `app/lib/widgets/social_cards.dart` — presentation atoms: the honest
  **AiDraftMarker** ("AI-generated — review before posting" + "Assisto never
  posts for you"), generic single-select `ChoiceChipsRow`, `CharCounter`,
  `HashtagChips`, `EmojiChips`, `SavedDraftTile`, and the token→label switches.
- **Edited** `app/lib/screens/agent_studio_screen.dart` — **one** bounded entry
  point only: a single `AppBar` `IconButton` (campaign icon, tooltip
  `socialTitle`) that pushes `SocialComposeScreen`. Nothing else changed.
- **New** `backend/core/logic/social.py` — pure deterministic engine (no
  Django/DB/net/AI/clock/key).
- **New** `backend/core/logic/social_tests_snippets.py` — 15 plain-assert tests,
  `run_all()` green; wired into `core/tests.py` as `SocialComposeSnippetTests`
  via the existing `_make_snippet_case` factory.
- **New** `.phaseB/up_social_arb.json` — **43 keys**, `{key:[bn,en]}`.

## Per-platform limits (source of truth = `social.py::PLATFORMS`)

| Platform | Hard limit | Soft target | Hashtags | Emoji |
|---|---|---|---|---|
| Facebook | 63206 | 480 | 3 | yes |
| Instagram | 2200 | 300 | 8 | yes |
| LinkedIn | 3000 | 700 | 5 | **no** (chips hidden) |
| WhatsApp status | 700 | 180 | 2 | yes |

The Dart `kPlatforms` table mirrors this exactly, so the live counter and the
draft sizing agree with the Python tests. Length (`short/medium/long`) scales
the soft target ×0.45 / ×1.0 / ×1.6, always clamped to the hard limit.

## Honest AI — MOCK now, real provider key-gated

- The "AI drafts it for you" output is produced **entirely by the deterministic
  template generator** (`social.py` / `social_engine.dart`). Identical inputs →
  identical draft. It **never calls a model and never needs a key**. `draft()`
  returns `ai_required=False, mock=True`; the Dart `SocialDraft` exposes the same
  `aiRequired=false / mock=true`.
- The screen shows an **always-visible** `AiDraftMarker`: "AI-generated — review
  before posting." Nothing is presented as real AI output.
- When an AI key is present (Integrations), the executor MAY route the same
  request (`platform/topic/tone/length/lang`) to the existing
  `core.ai.generate(...)` path for a richer, language-correct draft (bn /
  Banglish / en). The request shape here is the contract; **no engine change
  needed** and this module still calls nothing.

## NEVER auto-posts

Assisto only produces **text** + a **share intent**. `share_target(platform)`
returns a deep-link scheme hint + `prefer_share_sheet: True` (most networks
can't reliably prefill a post body, so the honest flow is: copy text → open the
share sheet / app → the user pastes/edits and posts). The screen's Share button
copies to the clipboard then opens the OS share sheet (`share_plus`); the user
chooses the app and posts it. There is **no posting code path** anywhere.

## Backend work to light this up end-to-end (NOT done here)

Today drafts live only on-device (SharedPreferences). To sync drafts and offer
the real-AI draft server-side the backend would add:

| Item | Shape |
|---|---|
| **Model** `core.models.SocialDraft` | `user FK`, `platform`, `topic`, `tone`, `caption`, `body text`, `hashtags JSON`, `created/updated`. |
| **Endpoints** `/api/v1/social/...` | `GET/POST /social/drafts`, `DELETE /social/drafts/{id}`, `POST /social/compose` (runs `social.draft(...)`; with a key, routes to `ai.generate`). |
| **`api.dart`** (out of scope) | `socialDraft()/saveSocialDraft()/socialDrafts()`; the screen falls back to local storage until these exist, so it works offline today. |

## Section-21 checklist (all 10)

1. **Empty** — Saved tab has a crafted empty state (icon, title, body, "Compose" CTA).
2. **Loading** — `SkeletonList` while reading the local draft store.
3. **Error** — load failure → `StateMessage` + Retry.
4. **Offline** — fully local (SharedPreferences + deterministic generator);
   draft / edit / copy / save all work with no network. Pull-to-refresh re-reads.
5. **Bilingual** — every UI string is an l10n key; **zero Bangla literals** in any
   `.dart` (verified — only emoji + em-dashes are non-ASCII); 43 bn/en pairs.
6. **WCAG** — theme tokens only (scheme + `Brand`); counter uses amber (near) /
   `Brand.danger` (over) with an icon; chips use scheme container colours.
7. **Scenario** — four platforms + five tones + three lengths map one-to-one to
   the generator's hand-verified test scenarios.
8. **Readable** — plain post + caption + tappable hashtag/emoji chips; live counter.
9. **Honest AI** — always-on "AI-generated — review before posting" + "never
   posts for you" marker; mock + key-gated (see above).
10. **Deterministic + tested** — `social.py` + 15 passing snippet tests, folded
    into the Django suite as `SocialComposeSnippetTests`.
