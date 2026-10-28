"""photoperf: the free preview size applies to EVERY on-device step (enhance,
tools, batch) — the server says so in the Photo Studio config; the app caps
each interactive step at preview_max_px and renders full size only after the
export gate (app/test/photoperf_test.dart)."""
from core.logic import photo_studio as PS
from core.tests_ps1_photo import _Base


class PreviewScopeTests(_Base):
    def test_free_config_caps_tools_like_enhance(self):
        self.as_(self.free)
        j = self.client.get("/api/v1/photo-studio/config").json()
        self.assertTrue(j["free"])
        self.assertEqual(j["preview_max_px"], 1024)
        self.assertEqual(set(j["preview_scope"]), {"enhance", "tools", "batch"})

    def test_scope_is_the_logic_constant_for_every_plan(self):
        for u in (self.free, self.prem):
            self.as_(u)
            j = self.client.get("/api/v1/photo-studio/config").json()
            self.assertEqual(j["preview_scope"], list(PS.PREVIEW_SCOPE))
