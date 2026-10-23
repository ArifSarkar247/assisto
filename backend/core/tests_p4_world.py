"""p4-world: Unseen World — feed parsing (recorded response shapes), snippet
limits, caching, Today cards hidden without data/keys, web answers (two search
adapters, numbered citations, credits + Profit Guard, cache, caps, honest
failures), hubs content, MCQ scoring, job alerts cap, chat-vision purposes."""
import json
from datetime import datetime, timedelta, timezone as dt_timezone
from pathlib import Path
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import billing
from core import world_service as SVC
from core.logic import chat_vision as CV
from core.logic import pricing as P
from core.logic import world_content as WC
from core.logic import world_feeds as WF
from core.logic import world_mcq as MCQ
from core.logic import world_search as WS
from core.models import User, WorldAnswer, WorldFeed, WorldMcqAttempt, WorldPrefs

DATA = Path(__file__).resolve().parent / "test_data_p4"


def _raw(name):
    return (DATA / name).read_bytes()


NOW = datetime(2026, 10, 23, 18, 0, tzinfo=dt_timezone.utc)

# Response SHAPES as documented by each provider; values are synthetic.
BRAVE_DOC = {"type": "search", "web": {"type": "search", "results": [
    {"title": "Passport fees <strong>2026</strong>", "url": "https://www.epassport.gov.bd/fees",
     "description": "Official fee table for the e-passport."},
    {"title": "e-Passport FAQ", "url": "https://www.epassport.gov.bd/faq", "description": "Questions."},
    {"title": "dup", "url": "https://www.epassport.gov.bd/fees", "description": "dup"},
    {"title": "bad", "url": "javascript:alert(1)", "description": "x"},
]}}
TAVILY_DOC = {"query": "q", "results": [
    {"title": "BMET clearance", "url": "https://www.bmet.gov.bd/clearance", "content": "How to get the smart card.", "score": 0.9},
    {"title": "Probashi", "url": "https://probashi.gov.bd", "content": "Ministry site.", "score": 0.5},
]}


# =========================================================================== pure: feeds
class FeedParseTests(SimpleTestCase):
    def test_bbc_style_headline_snippet_link(self):
        items = WF.parse_rss(_raw("rss_bbc_style.xml"), "BBC Bangla")
        self.assertEqual(len(items), 3)                 # duplicate link dropped
        self.assertEqual(items[0]["title"], "পরীক্ষার শিরোনাম এক")
        self.assertTrue(items[0]["link"].startswith("https://www.bbc.com/bengali/"))
        self.assertEqual(items[0]["source"], "BBC Bangla")
        for it in items:
            self.assertLessEqual(len(it["snippet"]), WF.SNIPPET_MAX)
            self.assertNotIn("<", it["snippet"])
        self.assertTrue(items[1]["snippet"].endswith("…"))
        self.assertTrue(items[0]["published"].startswith("2026-10-23"))

    def test_full_article_never_used(self):
        items = WF.parse_rss(_raw("rss_prothomalo_style.xml"), "Prothom Alo")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["snippet"], "")       # empty feed summary stays empty
        self.assertNotIn("FULL ARTICLE", json.dumps(items, ensure_ascii=False))

    def test_html_entities_and_two_digit_year(self):
        items = WF.parse_rss(_raw("rss_entities_style.xml"))
        self.assertEqual(items[0]["title"], "Budget talks resume – officials say")
        self.assertIn("Ministers’", items[0]["snippet"])
        self.assertTrue(items[0]["published"].startswith("2026-10-23"))

    def test_html_page_and_garbage_rejected(self):
        with self.assertRaises(WF.FeedError):
            WF.parse_rss(b"<!DOCTYPE html><html><body>Just a moment...</body></html>")
        with self.assertRaises(WF.FeedError):
            WF.parse_rss(b"")
        with self.assertRaises(WF.FeedError):
            WF.parse_rss(b"<rss><channel><item>")

    def test_stale_items_hidden(self):
        items = WF.parse_rss(_raw("rss_bbc_style.xml"))
        fresh = WF.fresh_items(items, NOW)
        self.assertEqual([i["title"] for i in fresh][:2], ["পরীক্ষার শিরোনাম এক", "Second test headline"])
        self.assertNotIn("Old story", [i["title"] for i in fresh])

    def test_snippet_clamp_hard_limit(self):
        s = WF.clamp_snippet("word " * 200)
        self.assertLessEqual(len(s), 200)
        self.assertEqual(WF.clamp_snippet("<p>short &amp; sweet</p>"), "short & sweet")

    def test_met_weather(self):
        p = WF.parse_met(json.loads(_raw("met_dhaka.json")))
        self.assertIsInstance(p["temp"], float)
        w = WF.weather_public(p, "bn")
        self.assertIn("MET Norway", w["source"])
        self.assertTrue(w["label"])
        with self.assertRaises(WF.FeedError):
            WF.parse_met({"properties": {}})

    def test_currency(self):
        fx = WF.parse_fx(json.loads(_raw("er_usd.json")))
        self.assertAlmostEqual(fx["rates"]["USD"], 123.71, places=1)
        self.assertAlmostEqual(fx["rates"]["SAR"], round(123.709857 / 3.75, 2), places=2)
        self.assertNotIn("JPY", fx["rates"])
        pub = WF.fx_public(fx, "en")
        self.assertEqual(pub["source_url"], "https://www.exchangerate-api.com")
        with self.assertRaises(WF.FeedError):
            WF.parse_fx({"result": "error"})

    def test_admin_card_hidden_until_entered(self):
        self.assertIsNone(WF.admin_card("gold", [{"key": "gold_22k", "value": None}], "bn"))
        c = WF.admin_card("gold", [{"key": "gold_22k", "value": 150000, "effective_date": "2026-10-20"},
                                   {"key": "fuel_octane", "value": 130}], "en")
        self.assertEqual(len(c["rows"]), 1)
        self.assertTrue(c["entered_by_assisto"])
        self.assertIn("bajus", c["source_url"])

    def test_cards_merge(self):
        m = WF.merge_cards({"news_world": False, "bogus": True, "gold": "x"})
        self.assertFalse(m["news_world"])
        self.assertTrue(m["gold"])
        self.assertNotIn("bogus", m)

    def test_sports_parsers(self):
        foot = WF.parse_football({"errors": [], "response": [
            {"fixture": {"status": {"elapsed": 67, "short": "2H"}}, "league": {"name": "League"},
             "teams": {"home": {"name": "A"}, "away": {"name": "B"}}, "goals": {"home": 1, "away": None}}]})
        self.assertEqual(foot[0]["score"], "1-0")
        with self.assertRaises(WF.FeedError):
            WF.parse_football({"errors": {"token": "bad key"}, "response": []})
        cr = WF.parse_cricket({"status": "success", "data": [
            {"name": "X vs Y", "status": "Live", "matchStarted": True, "matchEnded": False,
             "score": [{"inning": "X", "r": 120, "w": 3, "o": 18.2}]}]})
        self.assertTrue(cr[0]["live"])
        self.assertIn("120/3", cr[0]["score"])


# =========================================================================== pure: search
class SearchLogicTests(SimpleTestCase):
    def test_provider_choice(self):
        self.assertEqual(WS.provider_of({}), "")
        self.assertEqual(WS.provider_of({"provider": "brave"}), "")         # no key
        self.assertEqual(WS.provider_of({"provider": "tavily", "tavily_api_key": "t"}), "tavily")
        self.assertEqual(WS.provider_of({"brave_api_key": "b"}), "brave")
        self.assertEqual(WS.cost_per_search({}, "brave"), 0.005)
        self.assertEqual(WS.cost_per_search({"cost_per_search_usd": "0.004"}, "brave"), 0.004)

    def test_requests(self):
        m, url, h, body = WS.build_request("brave", {"brave_api_key": "b"}, "পাসপোর্ট ফি", "bn")
        self.assertEqual(m, "GET")
        self.assertIn("api.search.brave.com", url)
        self.assertEqual(h["X-Subscription-Token"], "b")
        self.assertIsNone(body)
        m, url, h, body = WS.build_request("tavily", {"tavily_api_key": "t"}, "q" * 999, "en")
        self.assertEqual(m, "POST")
        self.assertEqual(h["Authorization"], "Bearer t")
        self.assertEqual(len(json.loads(body)["query"]), WS.QUESTION_MAX)

    def test_parsers(self):
        b = WS.parse_brave(BRAVE_DOC)
        self.assertEqual(len(b), 2)                    # dup + javascript: dropped
        self.assertEqual(b[0]["title"], "Passport fees 2026")
        self.assertEqual(b[0]["site"], "epassport.gov.bd")
        t = WS.parse_tavily(TAVILY_DOC)
        self.assertEqual(t[1]["site"], "probashi.gov.bd")
        with self.assertRaises(WS.SearchError):
            WS.parse_tavily({"detail": {"error": "Unauthorized"}})

    def test_citations_renumbered_and_invalid_dropped(self):
        res = WS.parse_brave(BRAVE_DOC)
        out = WS.finalize("The fee is listed [২]. See also [1] and [9].", res, "passport fee", "en")
        self.assertEqual(out["answer"], "The fee is listed [1]. See also [2] and.")
        self.assertEqual([s["n"] for s in out["sources"]], [1, 2])
        self.assertEqual(out["sources"][0]["url"], "https://www.epassport.gov.bd/faq")
        self.assertTrue(out["cited"])
        none = WS.finalize("No numbers here.", res, "q", "en")
        self.assertFalse(none["cited"])
        self.assertEqual(none["sources"], [])

    def test_caution(self):
        self.assertIn("health", WS.caution_of("What dose of paracetamol for fever?"))
        self.assertIn("legal", WS.caution_of("জমির মামলা কীভাবে করব"))
        self.assertEqual(WS.caution_of("কী করতে হবে পাসপোর্টের জন্য"), [])   # 'কর' is not tax
        self.assertTrue(WS.caution_notes(["health"], "bn")[0].startswith("এটি"))

    def test_prompt_puts_sources_in_data(self):
        task, data, extra = WS.build_prompt("q?", WS.parse_tavily(TAVILY_DOC), "bn", "2026-10-23")
        self.assertIn("[1] BMET clearance", data)
        self.assertIn("Bangla", task)
        self.assertIn("never a medicine dose", extra)


# =========================================================================== pure: content / MCQ / pricing
class ContentTests(SimpleTestCase):
    def test_links_are_official_shape(self):
        links = WC.all_links()
        self.assertGreater(len(links), 50)
        for u in links:
            self.assertTrue(u.startswith(("https://", "http://")), u)

    def test_every_item_reviewed_and_bilingual(self):
        for hid in WC.HUBS:
            bn, en = WC.hub_public(hid, "bn"), WC.hub_public(hid, "en")
            self.assertEqual(len(bn["sections"]), len(en["sections"]))
            for s in en["sections"]:
                for it in s["items"]:
                    self.assertEqual(it["reviewed"], WC.REVIEWED)
                    self.assertTrue(it["title"])
        self.assertIsNone(WC.hub_public("nope", "bn"))

    def test_jobs_portals_and_lawful_feed_flag(self):
        j = WC.jobs_public("bn")
        ids = {p["id"] for p in j["portals"]}
        for want in ("bpsc", "bdjobs", "teletalk", "bb", "linkedin", "boesl", "chakri",
                     "careerjet", "govportal", "ngoforum"):
            self.assertIn(want, ids)
        self.assertEqual([p["id"] for p in j["portals"] if p["feed"]], ["careerjet"])
        self.assertEqual({c["id"] for c in j["categories"]}, {"govt", "bank", "private", "overseas", "ngo"})

    def test_farmer_and_health_notes(self):
        f = json.dumps(WC.hub_public("farmers", "bn"), ensure_ascii=False)
        self.assertIn("১৬১২৩", f)
        e = json.dumps(WC.hub_public("expat", "en"))
        for c in ("Saudi Arabia", "United Arab Emirates", "Qatar", "Oman", "Kuwait", "Malaysia",
                  "Singapore", "Italy", "United Kingdom"):
            self.assertIn(c, e)
        g = WC.hub_public("gov", "en")
        keys = [i["id"] for i in g["sections"][0]["items"]]
        for k in ("epassport", "nid", "birth", "driving", "emutation"):
            self.assertIn(k, keys)
        self.assertTrue(all(i.get("fee") for i in g["sections"][0]["items"]))


class McqTests(SimpleTestCase):
    def test_bank_size_and_shape(self):
        self.assertGreaterEqual(len(MCQ.BANK), 60)
        self.assertEqual(len({q["id"] for q in MCQ.BANK}), len(MCQ.BANK))
        for t in MCQ.TOPICS:
            self.assertGreaterEqual(sum(1 for q in MCQ.BANK if q["topic"] == t), 15)
        for q in MCQ.BANK:
            for i in (0, 1):
                self.assertEqual(len({o[i] for o in q["opts"]}), 4, q["id"])

    def test_round_has_no_answers_and_bn_digits(self):
        r = MCQ.pick_round("math", 7, "bn")
        self.assertEqual(len(r), MCQ.ROUND_SIZE)
        self.assertNotIn("answer", r[0])
        self.assertFalse(any(ch.isascii() and ch.isdigit() for q in r for o in q["options"] for ch in o))
        self.assertEqual(MCQ.pick_round("math", 7, "bn"), r)   # seeded

    def test_scoring(self):
        q1, q2 = MCQ.BANK[0], MCQ.BANK[1]
        res = MCQ.score([{"id": q1["id"], "choice": q1["ans"]}, {"id": q2["id"], "choice": "x"},
                         {"id": q1["id"], "choice": 0}, {"id": "nope", "choice": 1}], "en")
        self.assertEqual(res["total"], 2)
        self.assertEqual(res["correct"], 1)
        self.assertTrue(res["results"][0]["correct"])
        self.assertEqual(res["results"][1]["choice"], -1)
        self.assertIn("why", res["results"][0])


class PricingTests(SimpleTestCase):
    def test_web_answer_keeps_margin(self):
        d = P.DEFAULTS()
        row = d["action_costs"]["web_answer"]
        self.assertGreaterEqual(row["credits"], P.recompute_from_provider_cost("web_answer", d))
        self.assertGreaterEqual(row["credits"], P.action_credit_floor("web_answer", d))
        self.assertEqual(P.validate_edit(d), [])

    def test_world_block_bounds(self):
        w = P.world_cfg({"world": {"web_answers_per_day": 0, "job_alerts_per_day": 99, "news_interval_min": "x"}})
        self.assertEqual(w["web_answers_per_day"], 1)
        self.assertEqual(w["job_alerts_per_day"], 3)
        self.assertEqual(w["news_interval_min"], 30)


class VisionPurposeTests(SimpleTestCase):
    def test_purpose_prompt_and_note(self):
        self.assertIn("farmer", CV.system_prompt("bn", "crop"))
        self.assertIn("prescription", CV.system_prompt("en", "rx"))
        self.assertEqual(CV.system_prompt("en", "zzz"), CV.system_prompt("en"))
        a = CV.add_purpose_note("Leaf blight likely.", "crop", "en")
        self.assertIn("16123", a)
        self.assertEqual(CV.add_purpose_note(a, "crop", "en"), a)
        self.assertIn("ডাক্তার", CV.add_purpose_note("x", "rx", "bn"))
        self.assertEqual(CV.add_purpose_note("x", "", "bn"), "x")


# =========================================================================== API
class _FakeNet:
    """Recorded responses by URL prefix; counts calls."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, method, url, headers=None, body=None, timeout=None):
        self.calls.append(url)
        for prefix, resp in self.routes.items():
            if url.startswith(prefix):
                if isinstance(resp, Exception):
                    raise resp
                return resp
        return 404, b""


def _net(**extra):
    routes = {
        "https://api.met.no/": (200, _raw("met_dhaka.json")),
        "https://open.er-api.com/": (200, _raw("er_usd.json")),
        "https://feeds.bbci.co.uk/bengali/": (200, _raw("rss_bbc_style.xml")),
        "https://www.prothomalo.com/": (200, _raw("rss_prothomalo_style.xml")),
        "https://en.prothomalo.com/": (200, b"<!DOCTYPE html><html>blocked</html>"),
        "https://feeds.bbci.co.uk/news/world/": (200, _raw("rss_entities_style.xml")),
        "https://www.aljazeera.com/": (503, b""),
        "https://api.search.brave.com/": (200, json.dumps(BRAVE_DOC).encode()),
        "https://api.tavily.com/": (200, json.dumps(TAVILY_DOC).encode()),
    }
    routes.update(extra)
    return _FakeNet(routes)


class _WBase(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="W", phone="01700009101", password="pw")
        self.u.plan = "free"
        self.u.ai_credits = 20
        self.u.save()
        self.client.force_authenticate(self.u)
        self.net = _net()
        p = mock.patch.object(SVC, "_fetch", self.net)
        p.start()
        self.addCleanup(p.stop)

    def keys(self, **slugs):
        def is_enabled(s):
            return s in slugs

        def get(s):
            return dict(slugs.get(s) or {})
        p1 = mock.patch("core.integrations.is_enabled", side_effect=is_enabled)
        p2 = mock.patch("core.integrations.get", side_effect=get)
        p1.start(); p2.start()
        self.addCleanup(p1.stop); self.addCleanup(p2.stop)

    def llm(self, text="The fee table is on the portal [1].", fail=False):
        def call(key, model, system, prompt, max_tokens, history=None):
            if fail:
                raise RuntimeError("down")
            return text, 900, 120
        p1 = mock.patch("core.ai.active_api_key", return_value="sk-test-not-real")
        p2 = mock.patch("core.ai._call_anthropic", side_effect=call)
        p1.start(); p2.start()
        self.addCleanup(p1.stop); self.addCleanup(p2.stop)

    def ask(self, q="How much is the passport fee?", lang="en"):
        return self.client.post("/api/v1/world/ask", {"question": q, "lang": lang}, format="json")


class HiddenWithoutKeyTests(_WBase):
    def test_config_hides_key_gated(self):
        j = self.client.get("/api/v1/world/config", HTTP_ACCEPT_LANGUAGE="en").json()
        self.assertFalse(j["search_ready"])
        self.assertFalse(j["sports"]["cricket"])
        self.assertFalse(j["sports"]["football"])
        self.assertFalse(j["job_alerts_ready"])
        self.assertEqual(j["web_answer_credits"], 4)
        self.assertTrue(any(c["id"] == "dhaka" for c in j["cities"]))

    def test_ask_not_connected_no_network_no_charge(self):
        r = self.ask()
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "not_connected")
        self.assertEqual(self.net.calls, [])
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 20)

    def test_requires_auth(self):
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get("/api/v1/world/today").status_code, 401)


class WebAnswerTests(_WBase):
    def setUp(self):
        super().setUp()
        self.keys(web_search={"provider": "brave", "brave_api_key": "b-test", "cost_per_search_usd": "0.005"})

    def test_answer_cited_and_charged_then_cached_free(self):
        self.llm()
        r = self.ask()
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertEqual(j["answer"], "The fee table is on the portal [1].")
        self.assertEqual(j["sources"][0]["url"], "https://www.epassport.gov.bd/fees")
        self.assertTrue(j["cited"])
        self.assertEqual(j["charged"], 4)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 16)
        self.assertEqual(WorldAnswer.objects.filter(cached=False).count(), 1)
        # identical question again -> cache, no search, no charge
        n = len(self.net.calls)
        j2 = self.ask().json()
        self.assertTrue(j2["cached"])
        self.assertEqual(j2["charged"], 0)
        self.assertEqual(len(self.net.calls), n)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 16)

    def test_tavily_adapter(self):
        self.keys(web_search={"provider": "tavily", "tavily_api_key": "t-test"})
        self.llm("লাগবে স্মার্ট কার্ড [১]।")
        j = self.ask("BMET ছাড়পত্র কীভাবে?", "bn").json()
        self.assertTrue(any("api.tavily.com" in c for c in self.net.calls))
        self.assertEqual(j["answer"], "লাগবে স্মার্ট কার্ড [1]।")
        self.assertEqual(j["sources"][0]["site"], "bmet.gov.bd")

    def test_uncited_answer_gets_links_and_note(self):
        self.llm("Some answer without numbers.")
        j = self.ask("What is the fever medicine dose?").json()
        self.assertFalse(j["cited"])
        self.assertTrue(j["sources"])
        self.assertTrue(any("medical advice" in c for c in j["caution"]))
        self.assertTrue(any("cites no source" in c for c in j["caution"]))

    def test_insufficient_credits_blocks_before_search(self):
        self.llm()
        self.u.ai_credits = 1
        self.u.save()
        r = self.ask()
        self.assertEqual(r.status_code, 402)
        self.assertFalse(any("brave" in c for c in self.net.calls))

    def test_search_failure_no_charge(self):
        self.net.routes["https://api.search.brave.com/"] = (500, b"")
        self.llm()
        r = self.ask()
        self.assertEqual(r.status_code, 502)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 20)

    def test_llm_failure_refunds(self):
        self.llm(fail=True)
        r = self.ask()
        self.assertEqual(r.status_code, 503)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 20)

    def test_daily_cap(self):
        self.llm()
        row = billing.get_config()
        d = dict(row.data)
        d["world"] = {"web_answers_per_day": 1, "answer_cache_hours": 0}
        row.data = d
        row.save()
        self.assertEqual(self.ask("first question?").status_code, 200)
        r = self.ask("second question?")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["reason"], "daily_cap")

    def test_profit_guard_over_blocks_free(self):
        self.llm()
        with mock.patch("core.billing.guard_state", return_value={"over": True, "state": "over"}):
            r = self.ask()
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["reason"], "guard_over")

    def test_short_question(self):
        self.assertEqual(self.ask("a").status_code, 400)


class TodayTests(_WBase):
    def test_cards_with_real_data_only(self):
        j = self.client.get("/api/v1/world/today", HTTP_ACCEPT_LANGUAGE="bn").json()
        c = j["cards"]
        self.assertIn("fajr", c["prayer"]["times"])
        self.assertIn("temp", c["weather"])
        self.assertEqual(c["currency"]["rows"][0]["code"], "USD")
        self.assertEqual(j["hidden"]["gold"], "not_entered")
        self.assertEqual(j["hidden"]["fuel"], "not_entered")
        self.assertEqual(j["hidden"]["cricket"], "needs_key")
        self.assertEqual(j["hidden"]["football"], "needs_key")
        # news comes from the cron cache, not from the request
        self.assertEqual(j["hidden"]["news_bd"], "unavailable")

    def test_news_after_refresh_and_errors_recorded(self):
        with mock.patch.object(timezone, "now", return_value=NOW):
            out = SVC.refresh_news()
            self.assertTrue(out["news_bbc_bangla"])
            self.assertTrue(out["news_prothomalo"])
            self.assertFalse(out["news_prothomalo_en"])        # HTML page -> error
            self.assertFalse(out["news_aljazeera"])            # HTTP 503
            self.assertNotIn("news_dailystar", out)            # shipped OFF
            row = WorldFeed.objects.get(slug="news_aljazeera")
            self.assertIn("503", row.last_error)
            j = self.client.get("/api/v1/world/today", HTTP_ACCEPT_LANGUAGE="bn").json()
        bd = j["cards"]["news_bd"]["items"]
        self.assertTrue(all(len(i["snippet"]) <= 200 for i in bd))
        self.assertIn("বিবিসি বাংলা", {i["source"] for i in bd})
        self.assertNotIn("Old story", [i["title"] for i in bd])
        self.assertIn("news_world", j["cards"])

    def test_cache_no_refetch(self):
        self.client.get("/api/v1/world/today")
        n = len(self.net.calls)
        self.client.get("/api/v1/world/today")
        self.assertEqual(len(self.net.calls), n)
        SVC.refresh_news()
        m = len(self.net.calls)
        SVC.refresh_news()                       # not due yet
        self.assertEqual(len(self.net.calls), m)

    def test_failing_weather_backs_off_and_hides(self):
        self.net.routes["https://api.met.no/"] = (500, b"")
        j = self.client.get("/api/v1/world/today").json()
        self.assertEqual(j["hidden"]["weather"], "unavailable")
        self.assertEqual(WorldFeed.objects.get(slug="weather_dhaka").error_count, 1)

    def test_admin_values_show_with_source(self):
        SVC.set_admin_value(None, "gold_22k", 150000, timezone.localdate())
        j = self.client.get("/api/v1/world/today", HTTP_ACCEPT_LANGUAGE="en").json()
        g = j["cards"]["gold"]
        self.assertEqual(g["rows"][0]["bdt"], 150000.0)
        self.assertTrue(g["entered_by_assisto"])
        self.assertIn("fuel", j["hidden"])

    def test_prefs_toggle_and_city_synced(self):
        r = self.client.post("/api/v1/world/prefs", {"cards": {"weather": False, "x": True},
                                                     "city": "sylhet", "job_types": ["it", "bad", "it"],
                                                     "job_alerts": True}, format="json").json()
        self.assertFalse(r["cards"]["weather"])
        self.assertEqual(r["city"], "sylhet")
        self.assertEqual(r["job_types"], ["it"])
        j = self.client.get("/api/v1/world/today").json()
        self.assertNotIn("weather", j["cards"])
        self.assertNotIn("weather", j["hidden"])
        self.assertEqual(j["city"]["id"], "sylhet")
        self.assertEqual(WorldPrefs.objects.get(user=self.u).city, "sylhet")

    def test_sports_with_key_capped(self):
        self.keys(sports_cricket={"api_key": "c-test", "cost_per_call_usd": "0.001"})
        self.net.routes["https://api.cricapi.com/"] = (200, json.dumps(
            {"status": "success", "data": [{"name": "BAN vs IND", "status": "Live", "matchStarted": True,
                                            "matchEnded": False, "score": []}]}).encode())
        j = self.client.get("/api/v1/world/today").json()
        self.assertEqual(j["cards"]["cricket"]["matches"][0]["name"], "BAN vs IND")
        row = WorldFeed.objects.get(slug="sports_cricket")
        self.assertEqual(row.calls_today, 1)
        self.assertAlmostEqual(row.cost_usd_today, 0.001)


class HubApiTests(_WBase):
    def test_hubs_render(self):
        for hid in ("expat", "students", "farmers", "gov", "health"):
            j = self.client.get("/api/v1/world/hub/%s" % hid, HTTP_ACCEPT_LANGUAGE="bn").json()
            self.assertTrue(j["sections"])
        self.assertEqual(self.client.get("/api/v1/world/hub/zzz").status_code, 404)
        h = self.client.get("/api/v1/world/hub/health").json()
        self.assertFalse(h["medicine_price_ready"])     # curated sample -> hidden
        self.assertFalse(h["photo_ready"])               # no vision key
        self.assertFalse(self.client.get("/api/v1/world/hub/gov").json()["ai_ready"])

    def test_hub_ai_honest_when_off(self):
        r = self.client.post("/api/v1/world/hub/gov/ai", {"question": "How to fill the NID form?"}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(self.client.post("/api/v1/world/hub/health/ai", {"question": "xyz?"},
                                          format="json").status_code, 404)

    def test_hub_ai_charges_cheap_and_adds_note(self):
        self.llm("Field 1 is your name as on the NID.")
        r = self.client.post("/api/v1/world/hub/gov/ai", {"question": "How to fill the NID form?",
                                                         "lang": "en"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertIn("never submits", r.json()["note"])
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 20 - P.credit_cost("ai_msg_cheap", P.DEFAULTS()))

    def test_jobs(self):
        j = self.client.get("/api/v1/world/jobs").json()
        self.assertFalse(j["alerts_ready"])
        self.assertEqual(len(j["portals"]), 10)

    def test_mcq_round_and_score(self):
        j = self.client.get("/api/v1/world/mcq?topic=gk").json()
        self.assertEqual(len(j["questions"]), MCQ.ROUND_SIZE)
        self.assertNotIn("answer", json.dumps(j["questions"]))
        ans = [{"id": q["id"], "choice": MCQ.BY_ID[q["id"]]["ans"]} for q in j["questions"]]
        r = self.client.post("/api/v1/world/mcq", {"topic": "gk", "answers": ans}, format="json").json()
        self.assertEqual(r["correct"], MCQ.ROUND_SIZE)
        self.assertEqual(r["history"][0]["correct"], MCQ.ROUND_SIZE)
        self.assertEqual(WorldMcqAttempt.objects.filter(user=self.u).count(), 1)


class JobAlertTests(_WBase):
    CJ = {"type": "JOBS", "jobs": [
        {"title": "Software <b>Engineer</b>", "company": "Acme", "url": "https://jobviewtrack.com/abc1"},
        {"title": "QA Engineer", "company": "Beta", "url": "https://jobviewtrack.com/abc2"}]}

    def test_not_ready_sends_nothing(self):
        self.assertEqual(SVC.run_job_alerts(), 0)

    def test_capped_one_per_day(self):
        self.keys(jobs_careerjet={"api_key": "cj-test"})
        self.net.routes["https://search.api.careerjet.net/"] = (200, json.dumps(self.CJ).encode())
        WorldPrefs.objects.create(user=self.u, job_alerts=True, job_types=["it"])
        sent = []
        n = SVC.run_job_alerts(now=NOW, send=lambda *a, **k: sent.append((a, k)))
        self.assertEqual(n, 1)
        self.assertEqual(sent[0][0][3], "New job: Software Engineer")
        self.assertEqual(sent[0][1]["data"]["url"], "https://jobviewtrack.com/abc1")
        self.assertEqual(SVC.run_job_alerts(now=NOW + timedelta(hours=3), send=lambda *a, **k: sent.append(a)), 0)
        self.assertEqual(SVC.run_job_alerts(now=NOW + timedelta(hours=25), send=lambda *a, **k: sent.append((a, k))), 1)
        self.assertEqual(sent[-1][0][3], "New job: QA Engineer")       # never the same job twice
        self.assertEqual(sum(1 for c in self.net.calls if "careerjet" in c), 2)   # cached 12 h
