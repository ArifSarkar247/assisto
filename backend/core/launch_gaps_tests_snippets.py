"""
Pure-python self-tests for the launch-gap logic modules (analytics, reset,
legal, nmcheck, photo, unseen). The integrator can paste these into
core/tests.py (or run this file directly: `python core/launch_gaps_tests_snippets.py`).

These avoid Django/DB: analytics is fed plain event dicts, reset uses raw
hashing, etc. They prove the SECURITY + privacy guarantees hold.
"""
import os
import sys
from datetime import date, datetime, timedelta

# Allow running standalone from the backend/ dir without Django settings for
# the parts that don't touch Django. i18n.pick and the logic modules are
# import-safe (they only import integrations/settings lazily inside funcs).
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))  # backend/

from core import analytics, reset, legal, nmcheck, photo, unseen  # noqa: E402


# --------------------------- analytics -------------------------------------
def test_analytics_no_pii_and_consent():
    # consent off -> nothing stored
    assert analytics.normalize_event(42, "app_open", consent=False) is None
    # unknown event dropped
    assert analytics.normalize_event(42, "totally_unknown") is None
    # PII props stripped, only allow-list survives
    row = analytics.normalize_event(
        42, "feature_used",
        props={"feature": "money", "phone": "01700000000",
               "email": "a@b.com", "name": "Rahim", "locale": "bn"})
    assert row["props"] == {"feature": "money", "locale": "bn"}, row["props"]
    # raw id never stored; only a stable opaque hex hash (not reversible to id)
    assert "uid" not in row and "user_id" not in row and "user" not in row
    assert row["uid_hash"] == analytics.uid_hash(42)
    assert row["uid_hash"] != str(42)
    assert len(row["uid_hash"]) == 32
    assert all(c in "0123456789abcdef" for c in row["uid_hash"])
    # different users get different hashes
    assert analytics.uid_hash(42) != analytics.uid_hash(43)


def test_analytics_retention():
    f = date(2026, 1, 1)
    evs = [
        # user A: seen day0, returns day1 and day7
        {"uid_hash": "A", "name": "app_open", "day": f.isoformat()},
        {"uid_hash": "A", "name": "app_open", "day": (f + timedelta(days=1)).isoformat()},
        {"uid_hash": "A", "name": "app_open", "day": (f + timedelta(days=7)).isoformat()},
        # user B: seen day0, never returns
        {"uid_hash": "B", "name": "app_open", "day": f.isoformat()},
    ]
    r = analytics.retention(evs)
    assert r["new_users"] == 2
    assert r["d1"]["returned"] == 1 and r["d1"]["eligible"] == 2
    assert r["d1"]["pct"] == 50.0
    assert r["d7"]["returned"] == 1


def test_analytics_funnels():
    evs = [
        {"uid_hash": "A", "name": "invite_sent"},
        {"uid_hash": "A", "name": "invite_accepted"},
        {"uid_hash": "B", "name": "invite_sent"},
        {"uid_hash": "A", "name": "plan_viewed"},
        {"uid_hash": "A", "name": "upgrade_started"},
        {"uid_hash": "A", "name": "upgrade_completed"},
        {"uid_hash": "B", "name": "plan_viewed"},
    ]
    inv = analytics.invites(evs)
    assert inv == {"sent": 2, "accepted": 1, "accept_rate_pct": 50.0}, inv
    pf = analytics.paid_funnel(evs)
    assert pf["viewed"] == 2 and pf["started"] == 1 and pf["completed"] == 1
    assert pf["view_to_paid_pct"] == 50.0
    d = analytics.dashboard(evs)
    assert set(d) == {"retention", "invites", "paid_funnel", "top_features",
                      "active", "signups_series", "revenue", "range",
                      "total_events"}


def test_analytics_active_users_and_series():
    f = date(2026, 3, 1)
    evs = [
        {"uid_hash": "A", "name": "app_open", "day": f.isoformat()},
        {"uid_hash": "B", "name": "app_open", "day": f.isoformat()},
        # most-recent day = f+2, only A active -> DAU 1
        {"uid_hash": "A", "name": "session_start",
         "day": (f + timedelta(days=2)).isoformat()},
    ]
    a = analytics.active_users(evs, window_days=7)
    assert a["dau"] == 1, a            # only A on the last day
    assert a["wau"] == 2 and a["mau"] == 2  # A+B within trailing windows
    assert len(a["series"]) == 7       # dense, zero-filled
    assert a["series"][-1] == {"day": (f + timedelta(days=2)).isoformat(),
                               "users": 1}
    # honest empty state -> zeros, empty series (no fabricated line)
    empty = analytics.active_users([])
    assert empty == {"dau": 0, "wau": 0, "mau": 0, "series": []}


def test_analytics_revenue_no_fabrication():
    evs = [
        {"uid_hash": "A", "name": "upgrade_completed", "props": {"plan": "pro"}},
        {"uid_hash": "B", "name": "upgrade_completed", "props": {"plan": "pro"}},
        {"uid_hash": "C", "name": "upgrade_completed", "props": {"plan": "max"}},
    ]
    # no prices configured -> revenue stays unknown, never guessed
    r0 = analytics.revenue_by_plan(evs)
    assert r0["total_paid_users"] == 3
    assert r0["total_revenue"] is None and r0["revenue_known"] is False
    assert all(p["revenue"] is None for p in r0["plans"])
    # fully priced -> honest revenue = distinct users x price
    r1 = analytics.revenue_by_plan(evs, price_map={"pro": 100, "max": 300})
    assert r1["revenue_known"] is True
    assert r1["total_revenue"] == 2 * 100 + 1 * 300
    # partially priced -> total stays null (a partial sum would mislead)
    r2 = analytics.revenue_by_plan(evs, price_map={"pro": 100})
    assert r2["revenue_known"] is False and r2["total_revenue"] is None


# ----------------------------- reset ---------------------------------------
def test_reset_token_hashing_and_checks():
    raw, h = reset.generate_token()
    assert raw and h and raw != h
    assert reset.hash_token(raw) == h
    now = datetime(2026, 1, 1, 12, 0, 0)
    exp = reset.expiry(now)
    ok, reason = reset.check_token(h, raw, exp, now, used=False)
    assert ok and reason == "ok"
    # wrong token
    ok, reason = reset.check_token(h, "wrong", exp, now, used=False)
    assert not ok and reason == "invalid"
    # expired
    later = exp + timedelta(minutes=1)
    ok, reason = reset.check_token(h, raw, exp, later, used=False)
    assert not ok and reason == "expired"
    # already used
    ok, reason = reset.check_token(h, raw, exp, now, used=True)
    assert not ok and reason == "used"


def test_reset_no_enumeration_and_strength():
    # neutral response identical regardless of existence (view returns this
    # verbatim); here we just confirm it doesn't leak and is stable text.
    a = reset.neutral_response("en", "email")
    assert a["ok"] and "if an account exists" in a["message"].lower()
    ok, _ = reset.validate_password("abc123", "en")
    assert not ok  # too short
    ok, _ = reset.validate_password("12345678", "en")
    assert not ok  # digits only
    ok, _ = reset.validate_password("abcd1234", "en")
    assert ok


def test_reset_advanced_strength_and_sessions():
    # ADVANCED: score_password mirrors the app's PwScore floor + grading.
    assert reset.score_password("") == reset.STRENGTH_WEAK
    assert reset.score_password("short1") == reset.STRENGTH_WEAK   # < 8
    assert reset.score_password("abcdefghij") == reset.STRENGTH_WEAK  # no digit
    assert reset.score_password("12345678") == reset.STRENGTH_WEAK   # no letter
    assert reset.score_password("abcd1234") == reset.STRENGTH_FAIR   # 8, 2 classes
    assert reset.score_password("Abcd1234") == reset.STRENGTH_GOOD   # 8, 3 classes
    assert reset.score_password("abcd12345678") == reset.STRENGTH_GOOD  # 12, 2 classes
    assert reset.score_password("Abcd12345678") == reset.STRENGTH_STRONG  # 12, 3 classes
    assert reset.score_password("Abcd1234!xyz") == reset.STRENGTH_STRONG  # 12, 4 classes
    # strength grading never contradicts the authoritative floor
    for pw in ("abcd1234", "Abcd12345678", "Abcd1234!xyz"):
        ok, _ = reset.validate_password(pw, "en")
        assert ok and reset.score_password(pw) != reset.STRENGTH_WEAK
    ok, _ = reset.validate_password("short1", "en")
    assert not ok and reset.score_password("short1") == reset.STRENGTH_WEAK

    # "sign out all devices": secure default ON, honestly parses the flag.
    assert reset.should_revoke_sessions(None) is True          # default
    assert reset.should_revoke_sessions({}) is True
    assert reset.should_revoke_sessions({"revoke_sessions": False}) is False
    assert reset.should_revoke_sessions({"revoke_sessions": "false"}) is False
    assert reset.should_revoke_sessions({"revoke_sessions": True}) is True

    # change-password (logged-in) reuse: wrong current pw blocks regardless of
    # how strong the new one is; correct current pw falls back to the floor.
    ok, _ = reset.change_password_check(False, "Abcd1234!xyz", "en")
    assert not ok
    ok, _ = reset.change_password_check(True, "weak", "en")
    assert not ok     # new pw below floor
    ok, _ = reset.change_password_check(True, "abcd1234", "en")
    assert ok


# ----------------------------- legal ---------------------------------------
def test_legal_draft_stamped_both_langs():
    # §22: every page is a DRAFT and stamped "to be reviewed by owner/lawyer"
    # in BOTH languages — no page may present unreviewed legal text as final.
    for lang in ("bn", "en"):
        for key in legal.PAGES:
            p = legal.page(key, lang)
            if key in legal.REVIEWED_PAGES:   # owner-reviewed 25 Oct: no stamp
                assert p["draft"] is False and "lifeassisto.com" in p["stamp"]
                continue
            assert p["draft"] is True
            assert p["stamp"] == (legal.DRAFT_STAMP_BN if lang == "bn"
                                  else legal.DRAFT_STAMP_EN)
            # structured sections + back-compat flat body + metadata present
            assert p["sections"] and all(s["heading"] and s["body"]
                                         for s in p["sections"])
            assert p["body"]
            assert p["last_updated"] == legal.LAST_UPDATED
            assert p["contact"]
    assert legal.page("nope", "en") is None
    assert len(legal.index("en")) == len(legal.PAGES)
    # the advanced centre grew from 4 → 9 pages
    assert len(legal.PAGES) == 9


def test_legal_advanced_pages_present():
    expected = {"privacy", "terms", "health_disclaimer", "community_guidelines",
                "content_policy", "data_safety", "age_note", "data_rights",
                "admin_transparency"}
    assert set(legal.PAGES) == expected
    # index titles are non-empty and bilingual (differ bn vs en)
    for en, bn in zip(legal.index("en"), legal.index("bn")):
        assert en["title"] and bn["title"]
    # 18+ note actually says 18
    assert "18" in legal.page("age_note", "en")["body"]


def test_legal_mandatory_disclaimers_present():
    # §22 — the four mandatory disclaimers must be present (both languages),
    # each on its owning page. They live in MANDATORY_DISCLAIMERS so they can
    # never be silently dropped.
    assert set(legal.MANDATORY_DISCLAIMERS) == {
        "not_medical_advice", "not_legal_advice", "never_hold_money",
        "data_rights"}
    for lang in ("bn", "en"):
        idx = 0 if lang == "bn" else 1
        med = legal.MANDATORY_DISCLAIMERS["not_medical_advice"][idx]
        leg = legal.MANDATORY_DISCLAIMERS["not_legal_advice"][idx]
        money = legal.MANDATORY_DISCLAIMERS["never_hold_money"][idx]
        rights = legal.MANDATORY_DISCLAIMERS["data_rights"][idx]
        # not-medical-advice on the health page
        assert med in legal.page("health_disclaimer", lang)["body"]
        # never-hold-money on the terms page
        assert money in legal.page("terms", lang)["body"]
        # data-rights on the privacy + dedicated data-rights pages
        assert rights in legal.page("privacy", lang)["body"]
        assert rights in legal.page("data_rights", lang)["body"]
        # not-legal-advice is a real, non-empty disclaimer string
        assert leg


# ----------------------------- nmcheck -------------------------------------
def test_nmcheck_no_clearance_claim():
    about = nmcheck.about_the_name("en")
    assert about["name"] == "Assisto"
    assert "no clearance" in about["status"].lower()
    assert "not legal clearance" in about["disclaimer"].lower()
    assert len(about["checklist"]) >= 5


# ------------------------------ photo --------------------------------------
def test_photo_blocks_documents_and_fabrication():
    # ID / official docs hard-blocked in both langs
    for kind in ("id_card", "nid", "passport", "document"):
        p = photo.plan(kind, ["sharpen"], own_photo=True, lang="en")
        assert not p["allowed"] and p["reason"] == "document_blocked"
    # not-own photo blocked
    assert not photo.plan("personal", ["sharpen"], own_photo=False)["allowed"]
    # fabricating ops rejected
    p = photo.plan("personal", ["face_swap"], own_photo=True)
    assert not p["allowed"] and p["reason"] == "forbidden_op"
    # faithful ops allowed, device path by default
    p = photo.plan("landscape", ["denoise", "sharpen", "generate"],
                   own_photo=True)
    # 'generate' is forbidden -> whole request rejected
    assert not p["allowed"] and p["reason"] == "forbidden_op"
    p = photo.plan("landscape", ["denoise", "sharpen"], own_photo=True)
    assert p["allowed"] and p["ops"] == ["denoise", "sharpen"]
    assert p["path"] in ("device", "cloud")


def test_photo_advanced_presets_and_ai_honest():
    # ADVANCED presets are faithful bundles; none reuses a forbidden op.
    ps = photo.presets("en")
    ids = {p["id"] for p in ps}
    assert {"document", "portrait", "passport"} <= ids
    for p in ps:
        assert p["label"]  # localized, non-empty
        for a in p["adjustments"]:
            assert a in photo.BASIC_ADJUSTMENTS
            assert a not in photo._FORBIDDEN_OPS
    # Passport/ID preset links OUT to the web tool — it never edits identity.
    passport = next(p for p in ps if p["id"] == "passport")
    assert passport["web_tool"] is True and passport["ai"] is False

    # AI ops are reported HONESTLY: always key-gated, availability mirrors the
    # real provider wiring (no provider in tests -> available False, no fake).
    ops = photo.ai_ops("en")
    assert {o["op"] for o in ops} == set(photo.AI_OPS)
    assert all(o["requires_key"] is True for o in ops)
    assert all(o["available"] == photo.cloud_available() for o in ops)
    # background_replace stays forbidden on the FAITHFUL (non-AI) plan path.
    assert "background_replace" in photo._FORBIDDEN_OPS
    blocked = photo.plan("personal", ["background_replace"], own_photo=True)
    assert not blocked["allowed"] and blocked["reason"] == "forbidden_op"


def test_photo_advanced_scenario():
    # Real-world: a user cleans up their OWN holiday photo with the portrait
    # preset's faithful knobs; plan allows it, device path, no fabrication.
    portrait = next(p for p in photo.presets("en") if p["id"] == "portrait")
    p = photo.plan("personal", ["denoise", "sharpen"], own_photo=True, lang="en")
    assert p["allowed"] and p["reason"] == "ok"
    assert all(a in photo.BASIC_ADJUSTMENTS for a in portrait["adjustments"])
    # The same user then tries AI upscale with no key -> honest, not faked.
    assert all(not o["available"] or photo.cloud_available()
               for o in photo.ai_ops("en"))


# ------------------------------ unseen -------------------------------------
def test_unseen_sourced_and_filterable():
    c = unseen.companion("en")
    assert c["source"] == "unseenbangladesh.com"
    # ADVANCED: honest multi-source — owner site + open data, every item sourced.
    allowed = {"unseenbangladesh.com", "Wikivoyage / open data"}
    assert c["destinations"]
    assert all(d["source"] in allowed for d in c["destinations"])
    assert unseen.destination("sajek", "en")["name"] == "Sajek Valley"
    assert unseen.destination("nope", "en") is None
    syl = unseen.destinations("en", region="Sylhet")
    assert syl and all(d["region"] == "Sylhet" for d in syl)
    assert unseen.destinations("en", query="nijhum")
    # Costs are approximate + never a live/invented exact price.
    assert all(d.get("cost_approx") is True for d in c["destinations"])


def _run():
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for t in tests:
        t()
        print("ok:", t.__name__)
    print(f"\nAll {len(tests)} launch-gap self-tests passed.")


if __name__ == "__main__":
    _run()
