"""
scam_tests_snippets.py — plain-assert tests for core.logic.scam.

NOT a Django TestCase. The integrator folds these into core/tests.py. Each
function takes no args and raises AssertionError on failure. Smoke locally:

    python3 -c "import core.logic.scam_tests_snippets as t; t.run_all()"

Imports only the logic module (no DB), so safe to run anywhere.
"""
from core.logic import scam as S


def test_pin_otp_detected():
    r = S.check_message("আপনার bKash OTP 123456 এখনই দিন, নইলে অ্যাকাউন্ট বন্ধ", "bn")
    keys = {p["key"] for p in r["patterns"]}
    assert "pin_otp_request" in keys, r
    assert r["verdict"] == "scam", r
    assert r["score"] >= 55, r


def test_prize_lottery_en():
    r = S.check_message("Congratulations! You are the winner of a lottery prize. "
                        "Pay a small fee to claim.", "en")
    keys = {p["key"] for p in r["patterns"]}
    assert "prize_lottery" in keys, r
    assert r["verdict"] in ("scam", "suspicious"), r
    # English labels when lang=en
    assert any(p["name"].isascii() for p in r["patterns"]), r


def test_mfs_reversal_trick():
    r = S.check_message("ভুল করে আপনার নম্বরে ৫০০ টাকা পাঠিয়েছি, দয়া করে Send Money করে ফেরত দিন", "bn")
    keys = {p["key"] for p in r["patterns"]}
    assert "mfs_reversal_trick" in keys, r
    assert r["verdict"] == "scam", r


def test_spaced_otp_still_matches():
    # scammers space out letters to dodge filters: "o t p"
    r = S.check_message("please share your o t p now", "en")
    keys = {p["key"] for p in r["patterns"]}
    assert "pin_otp_request" in keys, r


def test_bangla_digits_folded():
    # Bangla digits should normalise so the long-number MFS signal fires
    r = S.check_message("নগদ থেকে বলছি, আপনার নম্বর ০১৭১২৩৪৫৬৭৮ যাচাই করুন", "bn")
    assert any(p["key"] in ("mfs_number_mentioned", "impersonation_authority")
               for p in r["patterns"]), r


def test_shortener_link_high_weight():
    r = S.check_message("Claim now http://bit.ly/win123", "en")
    keys = {p["key"] for p in r["patterns"]}
    assert "suspicious_link" in keys, r
    # shortener/http => full weight, not the mild 8
    plain = S.check_message("See our site example.online for details", "en")
    assert r["score"] > plain["score"], (r, plain)


def test_clean_message_safe():
    r = S.check_message("আব্বা, আমি বিকেলে বাসায় আসছি, রাতের খাবার একসাথে খাব।", "bn")
    assert r["verdict"] == "safe", r
    assert r["patterns"] == [], r


def test_empty_message():
    r = S.check_message("", "en")
    assert r["verdict"] == "safe", r
    assert r["score"] == 0, r


def test_fake_job():
    r = S.check_message("ঘরে বসে দিনে ৫০০০ টাকা আয় করুন, শুধু রেজিস্ট্রেশন ফি দিন", "bn")
    keys = {p["key"] for p in r["patterns"]}
    assert "fake_job" in keys, r


def test_impersonation_family():
    r = S.check_message("It's me, your son, this is my new number. I had an accident, "
                        "send money urgently", "en")
    keys = {p["key"] for p in r["patterns"]}
    assert "impersonation_family" in keys, r


def test_library_bilingual():
    bn = S.library("bn")
    en = S.library("en")
    assert len(bn) == len(en) == len(S.PATTERNS), (len(bn), len(en))
    # every entry has non-empty why/do in both languages
    for e in bn + en:
        assert e["why"] and e["do"] and e["name"], e


def test_family_alert_cites_pattern():
    r = S.check_message("Your bank account will be blocked, share OTP now", "en")
    payload = S.family_alert_payload("Rahim", r, "en")
    assert payload["kind"] == "scam_report", payload
    assert "Rahim" in payload["body"], payload


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"scam: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
