"""aifinal PART 3: Owner Admin -> AI answer levels (edit, audit, 40 % floor)."""
from core import ai_levels_service as ALS
from web.tests_o2_owner_admin import OwnerBase


class AiLevelsPageTests(OwnerBase):
    def test_page_shows_worst_case_table(self):
        self.ready()
        r = self.c.get("/owner/ai-levels?lang=en")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        for s in ('id="ail-table"', "gemini-2.5-flash-lite", "claude-haiku-5-5",
                  "claude-sonnet-5-5", "/owner/ai"):
            self.assertIn(s, html)

    def test_save_turns_levels_on_and_keeps_the_floor(self):
        self.ready()
        r = self.post("/owner/ai-levels", {"enabled": "on", "default": "normal",
                                           "free_normal": "on", "best_credits": "2",
                                           "best_out_cap": "1000", "reason": "test"})
        self.assertEqual(r.status_code, 302, r.content[:300])
        lv, _ = ALS.cfg()
        self.assertTrue(lv["enabled"])
        self.assertEqual(lv["levels"]["best"]["out_cap"], 1000)
        self.assertGreater(ALS.credits("best"), 2)        # never below the 40 % minimum
