"""
saved_items.py — pure, deterministic SAVED / BOOKMARKS logic (#18, §21).
A universal "save this" surface: the user bookmarks any item — a chat answer, a
tip, a document reference, or a link — with a title, an optional note, an
optional tag, and a source type. They can then browse, SEARCH, filter by TAG,
and delete. This module holds the PURE filtering / search / sorting / tag and
validation helpers; the rows live in the generic REST collection 'saved/items'.

WHY PURE: all list operations (search over title+note+tag, tag filter, sort,
tag-cloud counts, normalisation of a new save) are deterministic and
unit-testable here, so the .dart screen mirrors this logic VERBATIM and the DB
stays the integrator's flexible per-user JSON collection (PaCollectionItem
precedent) — no new model, no migration.

CROSS-APP "SAVE THIS" SEAM (documented, not wired here):
  Any other screen can offer a "Save" action by building a row with
  `make_item(...)` (validates + normalises) and POSTing it to 'saved/items'
  via the existing ApiClient.createItem — e.g. the chat screen passes
  kind='answer' + the answer text as the note; the document screen passes
  kind='doc' + a ref; a link preview passes kind='link' + the url. No special
  endpoint: it's the same generic collection every save flows through. The
  seam is just the row shape below + createItem('saved/items', row).

KINDS (source type of the saved thing):
  'note'   — a free-text snippet / tip the user typed or kept
  'answer' — a saved AI/chat answer
  'doc'    — a reference to a Vault document (ref holds the doc id/name)
  'link'   — a URL (ref holds the url)

HARD RULES:
  * NO DB, NO AI, NO I/O, NO MONEY-HOLDING. Pure dicts/lists in and out.
  * TIME IS PASSED IN where needed (sort uses the row's own created field; no
    hidden clock).
  * Bilingual {"bn","en"} copy via `pick`; the .dart mirror keeps ZERO Bangla
    literals (all strings are localization getters).
  * HONEST states: empty (nothing saved) is distinct from search-no-results.
    Filtering/search never fabricate matches.

Row shape the view layer stores, collection 'saved/items':
  item : {id, title, note, tag, kind, ref, created}
    title   short label (required, trimmed, <=120 chars)
    note    optional longer text / the saved content
    tag     optional single tag (lower-cased, no leading '#', <=40 chars)
    kind    'note' | 'answer' | 'doc' | 'link'  (defaults 'note')
    ref     optional reference payload (url for link, doc id/name for doc)
    created 'YYYY-MM-DD' (or ISO) — used only for sort; set by the view layer

Run self-tests (no DB):
    python3 -c "import core.logic.saved_items_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


KINDS = ["note", "answer", "doc", "link"]
DEFAULT_KIND = "note"

MAX_TITLE = 120
MAX_TAG = 40
MAX_NOTE = 4000


def _s(v):
    return "" if v is None else str(v)


def normalise_tag(tag):
    """Lower-case, strip a leading '#', collapse inner spaces to single, trim,
    and cap length. Empty/None -> '' (meaning untagged)."""
    t = _s(tag).strip()
    if not t:
        return ""
    if t.startswith("#"):
        t = t[1:]
    t = " ".join(t.split()).lower()
    return t[:MAX_TAG]


def normalise_kind(kind):
    k = _s(kind).strip().lower()
    return k if k in KINDS else DEFAULT_KIND


def validate(title, kind=DEFAULT_KIND, ref=""):
    """Return a list of problem codes ([] == ok). Honest, minimal:
      - 'title_required' when the title is blank after trimming
      - 'bad_kind' when kind is not a known kind
      - 'ref_required_for_link' when kind=='link' but no ref/url given
    We do NOT validate that a url is reachable (no I/O) — only that it's
    present; the view layer can add a soft format hint."""
    problems = []
    if not _s(title).strip():
        problems.append("title_required")
    if _s(kind).strip().lower() not in KINDS:
        problems.append("bad_kind")
    if _s(kind).strip().lower() == "link" and not _s(ref).strip():
        problems.append("ref_required_for_link")
    return problems


def make_item(title, note="", tag="", kind=DEFAULT_KIND, ref="", created=""):
    """Normalise inputs into a storable row (WITHOUT id — collection assigns).

    This is the cross-app "save this" entry point: any screen builds a row here
    and POSTs it to 'saved/items'. Raises ValueError with the problem codes if
    the row is invalid, so a bad save never silently stores junk."""
    problems = validate(title, kind, ref)
    if problems:
        raise ValueError(",".join(problems))
    return {
        "title": _s(title).strip()[:MAX_TITLE],
        "note": _s(note).strip()[:MAX_NOTE],
        "tag": normalise_tag(tag),
        "kind": normalise_kind(kind),
        "ref": _s(ref).strip(),
        "created": _s(created).strip(),
    }


def _hay(item):
    """Lower-cased searchable text for an item: title + note + tag + ref."""
    return " ".join([
        _s(item.get("title")),
        _s(item.get("note")),
        _s(item.get("tag")),
        _s(item.get("ref")),
    ]).lower()


def search(items, query):
    """Case-insensitive AND-of-terms search over title+note+tag+ref.

    A blank query returns all items unchanged (not "no results"). Every
    whitespace-separated term must appear somewhere in the haystack, so
    'eid sale' matches an item containing both words in any field/order.
    Deterministic: preserves input order, never fabricates matches."""
    q = _s(query).strip().lower()
    if not q:
        return list(items or [])
    terms = q.split()
    out = []
    for it in items or []:
        hay = _hay(it)
        if all(term in hay for term in terms):
            out.append(it)
    return out


def filter_by_tag(items, tag):
    """Items whose normalised tag equals the normalised `tag`.

    A blank/None tag returns all items (the 'All' filter). Untagged items match
    only when the requested tag is blank, never under a real tag."""
    want = normalise_tag(tag)
    if not want:
        return list(items or [])
    return [it for it in (items or []) if normalise_tag(it.get("tag")) == want]


def filter_by_kind(items, kind):
    """Items of a given kind; blank/None kind returns all."""
    k = _s(kind).strip().lower()
    if not k or k not in KINDS:
        return list(items or [])
    return [it for it in (items or []) if normalise_kind(it.get("kind")) == k]


def tag_counts(items):
    """Sorted (tag, count) for every non-empty tag, most-used first then A→Z.

    Powers the tag-filter chips. Untagged items are excluded (they live under
    the implicit 'All'); the caller shows an 'All (n)' chip from len(items)."""
    counts = {}
    for it in items or []:
        t = normalise_tag(it.get("tag"))
        if t:
            counts[t] = counts.get(t, 0) + 1
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))


def sort_recent(items):
    """Newest first by `created` (string compare on ISO dates), ties keep
    input order via a stable sort; blank created sorts last (oldest)."""
    def _key(it):
        c = _s(it.get("created")).strip()
        # blank -> sorts as very old so it falls to the bottom when desc
        return c if c else ""
    return sorted(items or [], key=_key, reverse=True)


def apply(items, query="", tag="", kind=""):
    """Full pipeline: tag filter -> kind filter -> search -> sort recent.

    Returns {'items': [...], 'empty': bool, 'no_results': bool} so the view
    layer can show the RIGHT honest state:
      - empty      : the user has saved nothing at all (len(items)==0)
      - no_results : there ARE saved items but the current filter/search
                     matched none — a distinct, honest state.
    """
    base = list(items or [])
    filtered = filter_by_tag(base, tag)
    filtered = filter_by_kind(filtered, kind)
    filtered = search(filtered, query)
    filtered = sort_recent(filtered)
    has_filter = bool(_s(query).strip() or normalise_tag(tag)
                      or (_s(kind).strip().lower() in KINDS))
    return {
        "items": filtered,
        "empty": len(base) == 0,
        "no_results": len(base) > 0 and len(filtered) == 0 and has_filter,
    }
