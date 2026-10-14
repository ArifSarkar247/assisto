# W5 — "Made in 30 seconds" (instant shop poster) · integration

Feature #172 "Made in 30 seconds": a delightful, fully-deterministic (no AI, no key,
no login) generator. The visitor types a shop/page name, an optional tagline, a few
items with prices, and (optionally) a phone number, picks one of 4 colour themes, and
instantly gets a shareable poster PNG (square + story size). Chosen artifact: a **shop
"open / price-list" poster** — visual, bilingual, screenshot/download-friendly, and a
perfect growth hook for Bangladesh's small-shop / F-commerce audience.

## Concrete artifact
A 1080×1080 (or 1080×1920 "story") poster: shop name headline, tagline, a "Price list /
We are open" section with item rows (name left, price right-aligned, thin dividers),
an "Order / Contact" phone band, and the standard "Assisto · assisto.asalify.com"
footer CTA that drives app installs. Rendered server-side with Pillow (Bangla shaped
via raqm), reusing the exact card primitives from `cards.py`.

## Files created
- `backend/web/logic/made30.py` — pure, offline rendering logic. `parse_items()` turns a
  textarea into a clean `(name, price)` list (accepts `- – : = | \t` separators, price
  optional, caps lengths, trims to MAX_ITEMS=8). `poster_card(...)` returns PNG bytes.
  4 original themes (`fresh`/`sunset`/`ocean`/`royal`), bn/en labels. Reuses
  `font/_vgrad/_decor/_footer/_center_text/_png` from `web/logic/cards.py`.
- `backend/web/templates/web/made30.html` — form page (extends `web/base.html`, uses `T.*`
  labels, bn/en via the shared toggle, csrf, error banner).
- `backend/web/templates/web/made30_result.html` — result page (extends base; shows the
  `/made30/card.png` image; Facebook / WhatsApp / Download share buttons; story-size
  link; `og:image` for rich link previews; app-install CTA; "try again").

## Files edited (precedent-matching only — no API/model/migration/Flutter/Asalify touched)
- `backend/web/urls.py` — added, right after the `festival` routes, exactly mirroring them:
  `path("made30", views.made30)` and `path("made30/card.png", views.made30_card)`.
- `backend/web/views.py` — added `from .logic import made30 as made30logic`; added
  `m30_*` label keys to BOTH the `bn` and `en` `UI` bundles; added the `made30` (GET form /
  POST render) and `made30_card` (PNG) views at the end — same shape as `festival` /
  `festival_card`: `_lang`, `_rate_ok(request, "w5")` + `_rate_limited_page`, `_log("w5", h)`,
  `_ctx(...)`, and a `urlencode`d query string `q` handed to the result template and the
  card endpoint. No AI call (the tool is deterministic by design).
- `backend/web/templates/web/landing.html` — added the tool card (⚡) to both the English
  and Bangla lists, same markup as the sibling tools.
- `backend/web/tests.py` — added `Made30Tests` (logic) + view smoke tests.

## How it's reached
- Form: `GET /made30` (Bangla) or `GET /made30?lang=en` (English) — also linked from the
  landing page `/`.
- Generate: `POST /made30` with `shop`, `tagline`, `items`, `phone`, `theme`.
- Poster image: `GET /made30/card.png?shop=...&tag=...&phone=...&theme=...&i=Name|Price&...`
  (`&story=1` for the 1080×1920 variant). Served `image/png`, no login.

## Tests
`backend/web/tests.py` (run: `python manage.py test web --settings=assisto_backend.settings_test`).
Added 13 new tests — 9 in `Made30Tests` (parse_items variants, PNG output bn/en, all 4
themes, story size, no-items case) and 4 view smoke tests (POST bn, POST en, empty-shop
error, card.png endpoint), plus `/made30?lang=en` folded into `test_all_pages_en`.
Full suite: **49 tests, all passing.**

## Pattern confirmation
Follows the cv/scam/cards/festival web-tool pattern exactly: logic in
`backend/web/logic/<tool>.py`, views + bn/en `UI` labels in `web/views.py`, routes added
the same way in `web/urls.py`, templates extending `web/base.html` with the shared bn/en
toggle, the standard Assisto footer + app-install CTA, IP rate-limiting + `ToolUsage`
logging, and share/OG plumbing identical to `festival_result.html`. Works with **zero
login and zero AI/key**, no fabricated data (every field is user-entered; no price or
item is invented), original Assisto identity, genuinely useful in ~30 seconds.
