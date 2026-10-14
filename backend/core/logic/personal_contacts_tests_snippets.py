"""
personal_contacts_tests_snippets.py — pure self-tests for personal_contacts.
No Django, no DB, no network.  Run:
    python3 -c "import core.logic.personal_contacts_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from core.logic.personal_contacts import (
    GROUP_FAMILY,
    GROUP_FRIENDS,
    cadence_days,
    filter_contacts,
    find_duplicate_groups,
    group_catalog,
    group_counts,
    import_matches_to_drafts,
    is_touch_due,
    link_contact_to_circle,
    merge_contacts,
    normalize_contact,
    quick_actions,
    search_contacts,
    sort_contacts,
    to_vcard,
    to_vcard_bundle,
    touch_due_contacts,
)

_count = 0


def ok(cond, msg):
    global _count
    _count += 1
    if not cond:
        raise AssertionError(msg)


NOW = datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc)


# ---------------------------------------------------------------------------

def test_normalize_legacy_and_rich():
    # legacy single fields fold into the rich multi-value shape
    c = normalize_contact({"name": "Karim", "phone": "01712345678",
                           "org": "Acme", "note": "met at fair"}, lang="en")
    ok(c["phones"] == ["01712345678"], "legacy phone folds into phones[]")
    ok(c["org"] == "Acme" and c["note"] == "met at fair", "legacy org/note kept")
    ok(c["display_name"] == "Karim", "display name is the name")
    ok(c["initial"] == "K", "initial computed")
    # rich shape with multi values + dedup + caps
    c2 = normalize_contact({
        "name": "A", "phones": ["1", "1", "2"], "emails": ["X@Y.com", "x@y.com"],
        "addresses": ["Dhaka"], "favorite": True, "relation": "brother",
    }, lang="en")
    ok(c2["phones"] == ["1", "2"], "phones de-duped")
    ok(c2["emails"] == ["x@y.com"], "emails lowercased + de-duped")
    ok(c2["favourite"] is True, "favorite alias → favourite")
    ok(GROUP_FAMILY in c2["groups"], "family relation surfaces family group")


def test_unnamed_never_blank():
    c = normalize_contact({"phones": ["999"]}, lang="en")
    ok(c["display_name"] == "999", "unnamed falls back to phone")
    c2 = normalize_contact({}, lang="en")
    ok(c2["display_name"] == "Unnamed contact", "fully empty → unnamed label (en)")
    ok(c2["initial"] == "U", "initial of fallback")


def test_birthday_tolerant():
    ok(normalize_contact({"birthday": "1990-05-09"})["birthday"] == "1990-05-09",
       "iso birthday kept")
    ok(normalize_contact({"birthday": "05/09"})["birthday"] == "05-09",
       "year-less birthday")
    ok(normalize_contact({"birthday": "garbage"})["birthday"] == "",
       "garbage birthday → empty, no raise")


def test_search():
    data = [normalize_contact(x) for x in [
        {"name": "Karim", "phones": ["01712345678"], "org": "Acme"},
        {"name": "Rahim", "emails": ["rahim@mail.com"]},
        {"name": "Jdoe", "labels": ["gym"]},
    ]]
    ok(len(search_contacts(data, "kar")) == 1, "name search")
    ok(len(search_contacts(data, "acme")) == 1, "org search")
    ok(len(search_contacts(data, "rahim@")) == 1, "email search")
    ok(len(search_contacts(data, "gym")) == 1, "label search")
    ok(len(search_contacts(data, "017 1234")) == 1, "spaced phone search matches")
    ok(len(search_contacts(data, "")) == 3, "empty query → all")


def test_filter_and_counts():
    data = [normalize_contact(x) for x in [
        {"name": "A", "relation": "mother", "favorite": True},
        {"name": "B", "groups": ["work"]},
        {"name": "C", "groups": ["friends"], "birthday": "01-01"},
    ]]
    ok(len(filter_contacts(data, group="family")) == 1, "family filter")
    ok(len(filter_contacts(data, favourites_only=True)) == 1, "favourites filter")
    ok(len(filter_contacts(data, has_birthday=True)) == 1, "has-birthday filter")
    counts = group_counts(data)
    ok(counts["_all"] == 3, "all count")
    ok(counts["_favourites"] == 1, "favourite count")
    ok(counts[GROUP_FAMILY] == 1 and counts["work"] == 1, "group counts")


def test_sort():
    data = [normalize_contact(x) for x in [
        {"name": "Zed"},
        {"name": "Amy", "favorite": True},
        {"name": "Bob", "last_interaction": "2026-10-10"},
    ]]
    by_name = [c["name"] for c in sort_contacts(data, by="name")]
    ok(by_name == ["Amy", "Bob", "Zed"], "name sort A→Z")
    by_fav = [c["name"] for c in sort_contacts(data, by="favourite")]
    ok(by_fav[0] == "Amy", "favourite sorts first")
    by_recent = [c["name"] for c in sort_contacts(data, by="recent")]
    ok(by_recent[0] == "Bob", "recent sorts dated first")


def test_dedupe_and_merge():
    a = normalize_contact({"name": "Karim", "phones": ["+8801712345678"],
                           "org": "Acme", "favorite": True})
    b = normalize_contact({"name": "Karim Uddin", "phones": ["01712345678"],
                           "emails": ["k@mail.com"], "note": "second copy"})
    c = normalize_contact({"name": "Totally Other", "phones": ["01999999999"]})
    groups = find_duplicate_groups([a, b, c])
    ok(len(groups) == 1 and len(groups[0]) == 2,
       "phone-by-last-9-digits detects the dup pair, not the unrelated one")
    m = merge_contacts(a, b)
    ok(set(m["phones"]) >= {"+8801712345678", "01712345678"},
       "merge unions phones (never loses one)")
    ok(m["emails"] == ["k@mail.com"], "merge pulls in the email")
    ok(m["favourite"] is True, "merge OR's favourite")
    ok("second copy" in m["note"], "merge keeps both notes")
    ok(m["id"] == a["id"], "merge keeps primary id")


def test_vcard():
    v = to_vcard(normalize_contact({
        "name": "Karim; Jr", "phones": ["0171"], "emails": ["k@mail.com"],
        "org": "Acme, Inc", "birthday": "1990-05-09", "note": "line1\nline2",
        "groups": ["family"], "relation": "brother",
    }), lang="en")
    ok(v.startswith("BEGIN:VCARD\r\nVERSION:3.0"), "vcard header + CRLF")
    ok("FN:Karim\\; Jr" in v, "name special chars escaped")
    ok("TEL;TYPE=CELL:0171" in v, "phone line")
    ok("EMAIL;TYPE=INTERNET:k@mail.com" in v, "email line")
    ok("BDAY:1990-05-09" in v, "bday line")
    ok("CATEGORIES:Family" in v, "categories from group label")
    ok("NOTE:line1\\nline2" in v, "note newline escaped")
    ok(v.rstrip().endswith("END:VCARD"), "vcard footer")
    bundle = to_vcard_bundle([normalize_contact({"name": "A"}),
                              normalize_contact({"name": "B"})])
    ok(bundle.count("BEGIN:VCARD") == 2, "bundle has 2 cards")


def test_cadence_and_touch():
    ok(cadence_days("monthly") == 30, "preset cadence")
    ok(cadence_days("d45") == 45, "custom cadence")
    ok(cadence_days("") == 0, "no cadence")
    ok(cadence_days("d99999") == 3650, "custom cadence clamped")
    # monthly cadence, last talked 40 days ago ⇒ due
    old = (NOW - timedelta(days=40)).isoformat()
    c = normalize_contact({"name": "A", "cadence": "monthly",
                           "last_interaction": old})
    ok(is_touch_due(c, now=NOW) is True, "overdue monthly is due")
    # last talked 5 days ago ⇒ not due
    recent = (NOW - timedelta(days=5)).isoformat()
    c2 = normalize_contact({"name": "B", "cadence": "monthly",
                            "last_interaction": recent})
    ok(is_touch_due(c2, now=NOW) is False, "recent monthly not due")
    # cadence set but never touched ⇒ due
    c3 = normalize_contact({"name": "C", "cadence": "weekly"})
    ok(is_touch_due(c3, now=NOW) is True, "never-touched with cadence is due")
    # no cadence ⇒ never due (opt-in)
    c4 = normalize_contact({"name": "D", "last_interaction": old})
    ok(is_touch_due(c4, now=NOW) is False, "no cadence never due")
    due = touch_due_contacts([c, c2, c3, c4], now=NOW)
    ok(c3 in due and c in due and c2 not in due and c4 not in due,
       "touch_due_contacts picks the right set")
    ok(due[0] is c3, "never-touched ranks most urgent")


def test_quick_actions_no_dead_buttons():
    with_phone = quick_actions(normalize_contact(
        {"name": "A", "phones": ["+8801712345678"]}), lang="en")
    kinds = {a["kind"] for a in with_phone}
    ok({"call", "sms", "whatsapp"} <= kinds, "phone yields call/sms/whatsapp")
    ok(all(a.get("auto_sent", False) is False for a in with_phone
           if a["kind"] == "whatsapp"), "whatsapp never auto-sent")
    no_phone = quick_actions(normalize_contact({"name": "B"}), lang="en")
    ok(all(a["kind"] not in ("call", "sms", "whatsapp") for a in no_phone),
       "no phone ⇒ no call/sms/whatsapp (no dead button)")
    with_email = quick_actions(normalize_contact(
        {"name": "C", "emails": ["c@mail.com"]}), lang="en")
    ok(any(a["kind"] == "email" for a in with_email), "email action present")


def test_link_to_circle():
    c = normalize_contact({"name": "Mom", "phones": ["0171"]})
    patch = link_contact_to_circle(c, user_id="42", circle_id="7",
                                   relation="mother", lang="en")
    ok(patch["linked_user_id"] == 42, "user id int-coerced")
    ok(patch["linked_circle_id"] == 7, "circle id int-coerced")
    ok(patch["relation"] == "mother", "relation set")
    ok(GROUP_FAMILY in patch["groups"], "family group added on link")


def test_import_drafts_privacy():
    # matcher output: one matched registered user, nothing else leaked
    match_result = {"ok": True, "matches": [
        {"contact_hash": "abc", "user": {"id": 9, "name": "Nabila",
                                         "phone": "+8801711111111"}},
    ], "stored": False}
    drafts = import_matches_to_drafts(match_result, lang="en")
    ok(len(drafts) == 1, "one draft per matched user")
    ok(drafts[0]["linked_user_id"] == 9, "draft pre-linked to user")
    ok(GROUP_FRIENDS in drafts[0]["groups"], "import default group")
    # permission refused ⇒ no drafts
    ok(import_matches_to_drafts({"ok": False}) == [], "refused match → no drafts")


def test_catalogs_bilingual():
    en = {g["code"]: g["label"] for g in group_catalog("en")}
    bn = {g["code"]: g["label"] for g in group_catalog("bn")}
    ok(en[GROUP_FAMILY] == "Family", "en family label")
    ok(bn[GROUP_FAMILY] != en[GROUP_FAMILY], "bn label differs from en")


def test_integer_safety():
    # ids as strings, floats, junk never raise and coerce sanely
    c = normalize_contact({"id": "15", "name": "X", "linked_user_id": "abc"})
    ok(c["id"] == 15 and c["linked_user_id"] is None, "id int-safe, junk → None")
    counts = group_counts([])  # empty never raises
    ok(counts["_all"] == 0, "empty counts safe")
    ok(sort_contacts(None) == [], "None list sorts to empty")
    ok(search_contacts(None, "x") == [], "None list search safe")


# ---------------------------------------------------------------------------

def run_all():
    global _count
    _count = 0
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
    print(f"personal_contacts: ALL {_count} assertions passed across "
          f"{len(tests)} tests.")
    return _count


if __name__ == "__main__":
    run_all()
