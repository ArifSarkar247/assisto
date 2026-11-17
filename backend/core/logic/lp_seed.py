"""
lp_seed.py — turn the repo's ORIGINAL Language Partner content into lpcore
import ITEMs (owner_actions/LANGUAGE_PARTNER_API.md §6). PURE (files in, dicts
out); `manage.py lp_seed` imports them into the DB.

  tools/lp/content/ielts/ielts-(ac|gt)-NNN.json   format assisto.lp.ielts/1 (lpfinish)
  tools/lp/content/<lang>/*.json                  stage 2/3 tracks (FORMAT.md §10-§11)

IELTS listening (lpaudio): recorded audio made in CI (.github/workflows/lp-audio.yml)
is attached from the audio index that `manage.py lp_audio` builds — only for parts
whose script is unchanged (plan hash); the script itself stays on the server.
Stage 2/3 tracks keep phone-TTS lines until their audio exists.
"""
import copy
import glob
import json
import os

from . import lp_audio as AU

IELTS_FORMAT = "assisto.lp.ielts/1"
TRACK_LANGS = ("ja", "ko", "de", "zh", "fr", "ar")
LEVELS = {"jlpt_n5": "N5", "jft_basic": "A2", "eps_topik": "EPS", "de_a1": "A1",
          "hsk1": "HSK1", "fr_a1": "A1", "ar_work": "A1"}
# phone TTS locale per content language / IELTS accent
TTS_LOCALE = {"ja": "ja-JP", "ko": "ko-KR", "de": "de-DE", "zh": "zh-CN", "fr": "fr-FR", "ar": "ar-SA",
              "uk": "en-GB", "us": "en-US", "au": "en-AU"}


def _load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def ielts_item(d, audio_index=None):
    """One assisto.lp.ielts/1 file -> a lpcore `mock` ITEM (inline sections;
    the importer splits them into section items). `audio_index` (lpaudio) =
    {bundle: {part: stored audio}} from `manage.py lp_audio`."""
    if d.get("format") != IELTS_FORMAT:
        raise ValueError("not an IELTS bundle: %s" % d.get("bundle_id"))
    general = d.get("module") == "general"
    lis = copy.deepcopy(d.get("listening") or {})
    for p in lis.get("parts") or []:
        names = {k: (v or {}).get("name") or k for k, v in (p.get("speakers") or {}).items()}
        turns = [t for t in p.get("turns") or [] if isinstance(t, dict) and t.get("text")]
        p["speakers"] = len(names) or 1
        p["transcript"] = "\n".join("%s: %s" % (names.get(t.get("spk"), t.get("spk") or ""), t["text"])
                                    for t in turns)
        p["turns"] = [{"spk": t.get("spk") or "", "text": t["text"]} for t in turns]
        p["tts_lang"] = TTS_LOCALE.get(p.get("accent"), "en-GB")
    AU.attach(lis, d, audio_index)
    data = {"title_en": (d.get("title") or {}).get("en", ""), "title_bn": (d.get("title") or {}).get("bn", ""),
            "module": "general" if general else "academic",
            "listening": lis, "reading": copy.deepcopy(d.get("reading") or {}),
            "writing": copy.deepcopy(d.get("writing") or {}),
            "speaking": copy.deepcopy(d.get("speaking") or {})}
    return {"kind": "mock", "key": d["bundle_id"], "track": "ielts_gt" if general else "ielts_ac",
            "level": "", "data": data}


def _tts_of(script, lang):
    if not isinstance(script, dict):
        return None
    lines = [str(t["text"]).strip() for t in script.get("turns") or []
             if isinstance(t, dict) and str(t.get("text") or "").strip()]
    return {"lang": TTS_LOCALE.get(lang, lang), "lines": lines, "repeat": int(script.get("repeat") or 1)} \
        if lines else None


def track_items(content_dir, audio_index=None):
    """Stage 2/3 syllabus, lesson and test files -> ITEMs; test listening
    questions get their recorded audio when `audio_index` has it (lpaudio)."""
    items = []
    for lang in TRACK_LANGS:
        for p in sorted(glob.glob(os.path.join(content_dir, lang, "*.json"))):
            d = _load(p)
            fmt = d.get("format")
            if fmt == "assisto.lp.syllabus/1":
                items.append({"kind": "syllabus", "key": "syl-%s" % d["track"], "track": d["track"],
                              "level": d.get("level") or LEVELS.get(d["track"], ""), "data": d})
            elif fmt == "assisto.lp.lessons/1":
                tr = d["tracks"][0]
                for les in d.get("lessons") or []:
                    data = copy.deepcopy(les)
                    data.update({"lang": lang, "week": d.get("week"), "tracks": d["tracks"],
                                 "practice_label": d.get("practice_label")})
                    for it in (data.get("practice") or {}).get("listening") or []:
                        t = _tts_of(it.get("script"), lang)
                        if t:
                            it["tts"] = t
                    items.append({"kind": "lesson", "key": les["id"], "track": tr,
                                  "level": LEVELS.get(tr, ""), "data": data})
            elif fmt == "assisto.lp.test/1":
                data = {"title_en": d["title"]["en"], "title_bn": d["title"]["bn"], "exam": d.get("exam", ""),
                        "lang": lang, "practice_label": d.get("practice_label"), "scoring": d.get("scoring") or {},
                        "sections": copy.deepcopy(d.get("sections") or [])}
                for s in data["sections"]:
                    for part in s.get("parts") or []:
                        shared = _tts_of(part.get("script"), lang)
                        if shared:
                            part["tts"] = shared
                        for q in part.get("questions") or []:
                            t = _tts_of(q.get("script"), lang)
                            if t:
                                q["tts"] = t
                AU.attach_track(data, d["bundle_id"], lang, d, audio_index)
                items.append({"kind": "mock", "key": d["bundle_id"], "track": d["track"],
                              "level": LEVELS.get(d["track"], ""), "data": data})
    return items


def ielts_items(content_dir, audio_index=None):
    return [ielts_item(_load(p), audio_index)
            for p in sorted(glob.glob(os.path.join(content_dir, "ielts", "ielts-*.json")))]


def all_items(content_dir, audio_index=None):
    return ielts_items(content_dir, audio_index) + track_items(content_dir, audio_index)
