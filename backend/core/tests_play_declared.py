"""play-decl: one switch per Play-declaration item (tools/ci/play_declared.py).

Strict guards: the default PLAY_DECLARED is '' (today's Play build), every
item has a filled section in owner_actions/PLAY_DECLARATIONS_BN.md, every item
that carries a permission names its permission-page entry, and a DECLARED item
must already have that entry on the live permission page text. The manifest
patch keeps undeclared items out of the Play manifest; the bundle gate fails on
a leak."""
import importlib.util
import re
from pathlib import Path

from django.test import RequestFactory, SimpleTestCase

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("play_declared", ROOT / "tools/ci/play_declared.py")
PD = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(PD)

SAMPLE = """<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission android:name="android.permission.CAMERA"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"/>
    <application>
        <service android:name="com.assisto.assisto.calls.ScreenShareService" android:foregroundServiceType="mediaProjection" android:exported="false"/>
        <service android:name="com.example.GuardCam" android:foregroundServiceType="camera" android:exported="false"/>
        <service android:name="com.example.Mixed" android:foregroundServiceType="camera|microphone" android:exported="false">
            <meta-data android:name="x" android:value="y"/>
        </service>
        <service android:name="com.example.Journey" android:foregroundServiceType="location" android:exported="false"/>
    </application>
</manifest>
"""


def _yml():
    return (ROOT / ".github/workflows/android.yml").read_text()


def _default_declared():
    m = re.search(r"^\s*PLAY_DECLARED:\s*'([^']*)'", _yml(), re.M)
    assert m, "PLAY_DECLARED env missing from the Play AAB step"
    return m.group(1)


class PlayDeclaredWorkflowTests(SimpleTestCase):
    def test_default_is_todays_play_build(self):
        # flipping a key is a reviewed one-line change, made only after the
        # owner filed that form; the default stays the current state
        self.assertEqual(_default_declared().strip(), "")

    def test_declared_keys_are_known(self):
        PD.parse(_default_declared())

    def test_workflow_wires_every_step(self):
        play = _yml()[_yml().index("Build + sign release AAB (Google Play)"):]
        for needle in ('play_declared.py check "$PLAY_DECLARED"',
                       'play_declared.py patch android/app/src/main/AndroidManifest.xml "$PLAY_DECLARED"',
                       "--dart-define=PLAY_STORE=true $PLAY_DECL_DEFINES",
                       'play_declared.py gate /tmp/play-manifest.pb "$PLAY_DECLARED"',
                       'case "$PLAY_DECL_PERMS" in'):
            self.assertIn(needle, play, needle)
        # the patch runs BEFORE the bundle is built, the gate AFTER it
        self.assertLess(play.index("play_declared.py patch"), play.index("flutter build appbundle"))
        self.assertLess(play.index("flutter build appbundle"), play.index("play_declared.py gate"))


class PlayDeclaredRegistryTests(SimpleTestCase):
    def test_every_item_has_a_full_doc_section(self):
        doc = (ROOT / "owner_actions/PLAY_DECLARATIONS_BN.md").read_text()
        for key in PD.ITEMS:
            anchor = '<a id="decl-%s">' % key
            self.assertIn(anchor, doc, key)
            sec = doc[doc.index(anchor):]
            nxt = sec.find('<a id="decl-', 1)
            sec = sec[: nxt if nxt != -1 else len(sec)]
            for part in ("Policy", "Console", "```", "Video", "Risk", "Switch"):
                self.assertIn(part, sec, "%s: section lacks %s" % (key, part))
            self.assertIn("`%s`" % key, sec, key)

    def test_items_with_permissions_name_a_permission_page_entry(self):
        for key, it in PD.ITEMS.items():
            if it["perms"]:
                self.assertTrue(it["legal_id"], key)
            self.assertTrue(it["define"].startswith("PLAY_"), key)

    def test_declared_items_are_on_the_permission_page(self):
        from web import legal_content as LC
        ids = {p.get("id") for p in LC.PERMISSIONS_V2}
        for key in PD.parse(_default_declared()):
            lid = PD.ITEMS[key]["legal_id"]
            if lid:
                self.assertIn(lid, ids, "%s is declared but the permission page has no '%s' entry" % (key, lid))

    def test_unknown_key_fails(self):
        with self.assertRaises(ValueError):
            PD.parse("screen_share typo_key")
        self.assertEqual(PD.main(["x", "check", "nope"]), 1)


class PlayDeclaredPatchTests(SimpleTestCase):
    def test_nothing_declared_strips_every_item(self):
        s, log = PD.patch(SAMPLE, "")
        self.assertIn('FOREGROUND_SERVICE_CAMERA" tools:node="remove"', s)
        self.assertIn('FOREGROUND_SERVICE_MEDIA_PROJECTION" tools:node="remove"', s)
        self.assertIn('ACCESS_BACKGROUND_LOCATION" tools:node="remove"', s)
        self.assertNotIn("ScreenShareService", s)
        self.assertNotIn("GuardCam", s)
        self.assertIn('com.example.Mixed" android:foregroundServiceType="microphone"', s)
        self.assertIn('<meta-data android:name="x"', s)         # mixed service kept whole
        self.assertIn('foregroundServiceType="location"', s)    # unrelated service untouched
        self.assertIn('android.permission.CAMERA"/>', s)        # CAMERA itself is not an item
        self.assertEqual(len(log), len(PD.ITEMS))
        # idempotent: no duplicate remove lines on a second run
        s2, _ = PD.patch(s, "")
        self.assertEqual(s2.count('FOREGROUND_SERVICE_CAMERA" tools:node="remove"'), 1)

    def test_declared_item_ships_untouched(self):
        s, _ = PD.patch(SAMPLE, "screen_share guardbox_camera")
        self.assertIn('ScreenShareService" android:foregroundServiceType="mediaProjection"', s)
        self.assertIn("GuardCam", s)
        self.assertIn('<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA"/>', s)
        self.assertNotIn('FOREGROUND_SERVICE_CAMERA" tools:node="remove"', s)

    def test_bg_location_is_added_only_when_declared(self):
        s, _ = PD.patch(SAMPLE, "bg_location")
        self.assertIn('<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>', s)
        s, _ = PD.patch(SAMPLE, "")
        self.assertNotRegex(s, r'ACCESS_BACKGROUND_LOCATION"/>')

    def test_gate_catches_a_leak(self):
        leak = "xx android.permission.FOREGROUND_SERVICE_CAMERA xx com.assisto.assisto.calls.ScreenShareService"
        errs = PD.gate(leak, "")
        self.assertEqual(len(errs), 2)
        self.assertEqual(PD.gate(leak, "guardbox_camera screen_share"), [])
        self.assertEqual(PD.gate("android.permission.CAMERA", ""), [])

    def test_defines_env_and_perms(self):
        self.assertEqual(PD.defines(""), "")
        self.assertEqual(PD.defines("medical"), "--dart-define=PLAY_MEDICAL=true")
        self.assertIn("export PLAY_SCREEN_SHARE=true", PD.env_lines("screen_share"))
        self.assertEqual(PD.perms("bg_location"), "ACCESS_BACKGROUND_LOCATION")


class PlayMedicalHeaderTests(SimpleTestCase):
    def test_medical_hidden_only_for_play_without_the_declared_build(self):
        from core.i18n import play_medical_hidden
        rf = RequestFactory()
        self.assertFalse(play_medical_hidden(rf.get("/")))                                 # website APK
        self.assertTrue(play_medical_hidden(rf.get("/", HTTP_X_ASSISTO_FLAVOUR="play")))  # Play today
        self.assertFalse(play_medical_hidden(rf.get("/", HTTP_X_ASSISTO_FLAVOUR="play",
                                                    HTTP_X_ASSISTO_MEDICAL="1")))      # declared build

    def test_app_sends_the_header_only_from_a_declared_play_build(self):
        api = (ROOT / "app/lib/api.dart").read_text()
        self.assertIn("if (AppConfig.playLike && AppConfig.playMedical) 'X-Assisto-Medical': '1'", api)
        gates = (ROOT / "app/lib/feature_gates.dart").read_text()
        self.assertIn("(!AppConfig.playLike || AppConfig.playMedical)", gates)
        cfg = (ROOT / "app/lib/config.dart").read_text()
        self.assertIn("bool.fromEnvironment('PLAY_MEDICAL')", cfg)
        self.assertEqual(PD.ITEMS["medical"]["define"], "PLAY_MEDICAL")
