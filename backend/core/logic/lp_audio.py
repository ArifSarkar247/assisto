"""
lp_audio.py — lpaudio: the recorded IELTS listening audio (PURE: dicts in,
dicts out; no Django, no network). Used by three places:

  tools/lp/audio/render.py        CI: plan -> Kokoro-82M TTS -> AAC .m4a + manifest.json
                                  -> GitHub release "lp-audio" (never rendered on the server)
  manage.py lp_audio              server: download the release, verify sha256, store the
                                  files in private media (signed links), attach them
  core.logic.lp_seed.ielts_item   keeps the attached audio when the content is re-seeded

A part's audio is attached only when the PLAN HASH in the release manifest is the
hash of the CURRENT script (speakers, turns, intro, voices): an edited script never
plays old audio. Voices: Kokoro-82M v1.0 (Apache-2.0) British + American English
voices; there is NO licence-clean Australian voice, so an "au" part is voiced with
British and American speakers (as the real exam mixes accents) and the part's
`accents` list says so honestly. No voice cloning — these are stock synthetic
voices, never an imitation of a real named person. Licences:
owner_actions/LP_AUDIO_LICENSE_BN.md.

The phone never receives the script: the app gets only audio_url + timings.
"""
import hashlib
import json
import re

FORMAT = "assisto.lp.audio/1"
RELEASE_TAG = "lp-audio"
ENGINE = "kokoro-82m-v1.0"
SPEED = 0.96          # a little slower than default: IELTS recordings are clear, not rushed
SAMPLE_RATE = 24000
PREVIEW_SEC = 30      # time to read the questions before each part (in the app, with a countdown)
CHECK_SEC = 30        # time to check answers after each part
FINAL_CHECK_SEC = 120  # after the last part (computer-delivered test)
GAP_TURN = 0.55       # silence between two speakers
GAP_PARA = 0.9        # silence between two paragraphs of one speaker (talks, lectures)
GAP_NARR = 1.2        # after a narrator line

NARRATOR = "bm_george"
# Kokoro v1.0 stock voices (lang b = British English, a = American English).
VOICES = {
    "uk": {"F": ["bf_emma", "bf_isabella", "bf_alice"],
           "M": ["bm_fable", "bm_lewis", "bm_daniel"]},
    "us": {"F": ["af_heart", "af_bella", "af_nicole", "af_sarah"],
           "M": ["am_michael", "am_fenrir", "am_puck", "am_eric"]},
}
# No licence-clean Australian voice exists (see the licence file): speakers of an
# "au" part alternate British / American voices.
ACCENT_POOLS = {"uk": ["uk"], "us": ["us"], "au": ["uk", "us"]}
LOCALE = {"b": "en-GB", "a": "en-US"}

_WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
          "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
          "eighteen", "nineteen"]
_TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def num_words(n):
    """0..99 in words (narrator lines: 'questions eleven to twenty')."""
    n = int(n)
    if n < 20:
        return _WORDS[n]
    t, u = divmod(n, 10)
    return _TENS[t] + ("" if u == 0 else "-" + _WORDS[u])


def _year(y):
    hi, lo = divmod(int(y), 100)
    if lo == 0:
        return num_words(hi) + " hundred"
    if 2000 <= int(y) < 2010:
        return "two thousand and " + num_words(lo)
    return num_words(hi) + " " + ("oh " + _WORDS[lo] if lo < 10 else num_words(lo))


def _decade(y):
    hi, lo = divmod(int(y), 100)
    if lo == 0:
        return num_words(hi) + " hundreds"
    w = num_words(lo)
    w = w[:-1] + "ies" if w.endswith("y") else w + "s"
    return num_words(hi) + " " + w


def speakable(text):
    """Script text -> what the TTS should say (spelled names letter by letter,
    years and decades as people say them). Only the AUDIO uses this."""
    s = str(text or "")
    s = re.sub(r"\b[A-Z](?:-[A-Z]){2,}\b", lambda m: ", ".join(m.group(0).split("-")), s)
    s = re.sub(r"\b(1[1-9]\d\d|20\d\d)s\b", lambda m: _decade(m.group(1)), s)
    s = re.sub(r"(?<![\d.,£$])\b(1[1-9]\d\d|20[0-4]\d)\b(?![\d,.]\d)", lambda m: _year(m.group(1)), s)
    s = s.replace("&", " and ")
    return re.sub(r"\s+", " ", s).strip()


def assign_voices(accent, speakers, seed=""):
    """{spk: voice}: by gender, from the part's accent pool(s), two speakers never
    share a voice, the narrator's voice is never a speaker's; `seed` (bundle +
    part) rotates between the two best voices so every test does not sound alike."""
    pools = ACCENT_POOLS.get(accent) or ["uk"]
    used = set([NARRATOR])
    out = {}
    rot = int(hashlib.sha256(str(seed).encode("utf-8")).hexdigest()[:4], 16) % 2
    for i, (sid, sp) in enumerate(sorted((speakers or {}).items())):
        g = "M" if str((sp or {}).get("gender") or "F").upper().startswith("M") else "F"
        pool = VOICES[pools[i % len(pools)]][g]
        pool = pool[rot:] + pool[:rot]
        voice = next((v for v in pool if v not in used), pool[0])
        used.add(voice)
        out[sid] = voice
    return out


def locale_of(voice):
    return LOCALE.get(str(voice)[:1], "en-GB")


def part_plan(bundle_id, part, last=False):
    """One listening part -> the render plan (segments) + its hash. The narrator
    introduces the part and closes it; question time and check time are run by
    the app with a visible countdown (preview_sec / check_sec)."""
    qs = [q.get("n") for q in part.get("questions") or [] if isinstance(q.get("n"), int)]
    a, b = (min(qs), max(qs)) if qs else (1, 10)
    n = int(part.get("n") or 1)
    vmap = assign_voices(part.get("accent"), part.get("speakers") or {}, "%s-%d" % (bundle_id, n))
    segs = [{"voice": NARRATOR, "text": "Part %s." % num_words(n), "gap": 0.8}]
    if part.get("intro"):
        segs.append({"voice": NARRATOR, "text": speakable(part["intro"]), "gap": 0.8})
    segs.append({"voice": NARRATOR, "text": "Now listen carefully and answer questions %s to %s."
                 % (num_words(a), num_words(b)), "gap": GAP_NARR})
    prev = None
    for t in part.get("turns") or []:
        if not isinstance(t, dict) or not str(t.get("text") or "").strip():
            continue
        spk = t.get("spk") or ""
        if segs and prev is not None:
            segs[-1]["gap"] = GAP_PARA if spk == prev else GAP_TURN
        segs.append({"voice": vmap.get(spk) or NARRATOR, "text": speakable(t["text"]), "gap": GAP_TURN})
        prev = spk
    segs[-1]["gap"] = GAP_NARR
    segs.append({"voice": NARRATOR, "gap": 0.3,
                 "text": "That is the end of the listening test." if last else
                 "That is the end of part %s." % num_words(n)})
    plan = {"bundle": bundle_id, "part": n, "engine": ENGINE, "speed": SPEED, "segments": segs}
    plan["hash"] = plan_hash(plan)
    voices = [{"spk": k, "voice": v, "accent": locale_of(v)} for k, v in sorted(vmap.items())]
    plan["voices"] = voices
    plan["accents"] = sorted({x["accent"] for x in voices}) or [locale_of(NARRATOR)]
    plan["preview_sec"] = PREVIEW_SEC
    plan["check_sec"] = FINAL_CHECK_SEC if last else CHECK_SEC
    plan["file"] = "%s-p%d-%s.m4a" % (bundle_id, n, plan["hash"][:12])
    return plan


def plan_hash(plan):
    core = {k: plan[k] for k in ("bundle", "part", "engine", "speed", "segments")}
    return hashlib.sha256(json.dumps(core, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def bundle_plans(d):
    """An assisto.lp.ielts/1 file (the repo JSON, with speaker genders) -> plans."""
    parts = [p for p in (d.get("listening") or {}).get("parts") or [] if isinstance(p, dict)]
    return [part_plan(d["bundle_id"], p, last=(i == len(parts) - 1)) for i, p in enumerate(parts)]


def attach(listening, d, index):
    """lp_seed: put the stored audio onto the listening parts whose plan hash
    is the hash of the CURRENT script (index = {bundle: {part: entry}} built by
    `manage.py lp_audio`); an edited part stays without audio until re-rendered."""
    got = (index or {}).get(d.get("bundle_id")) or {}
    if not got:
        return listening
    now = {str(pl["part"]): pl["hash"] for pl in bundle_plans(d)}
    for p in listening.get("parts") or []:
        e = got.get(str(p.get("n")))
        if not e or not e.get("audio") or e.get("plan_hash") != now.get(str(p.get("n"))):
            continue
        p["audio"] = e["audio"]
        p["audio_meta"] = {k: e[k] for k in ("duration_sec", "accents", "preview_sec", "check_sec",
                                             "plan_hash", "sha256", "bytes") if k in e}
    return listening


# ------------------------------------------------- stage 2/3 language tracks
# Test listening questions of the language courses (assisto.lp.test/1). Only
# languages with a cleared Kokoro voice (tools/lp/tts/VOICES_TRACKS.json +
# .phaseB/MODEL_LICENSES.md): Japanese, Chinese, French. Korean, German and
# Arabic keep the phone's own voice until a licence-clean voice exists.
TRACK_VOICES = {
    "ja": {"F": ["jf_alpha", "jf_gongitsune", "jf_nezumi"], "M": ["jm_kumo"]},
    "zh": {"F": ["zf_xiaoxiao", "zf_xiaoyi"], "M": ["zm_yunjian", "zm_yunxi"]},
    # one French Kokoro voice: the male speaker is the same synthetic voice
    # pitch-lowered (an audio effect, not cloning — MODEL_LICENSES.md stage 3)
    "fr": {"F": ["ff_siwis"], "M": ["ff_siwis+low"]},
}
TRACK_SPEED = 0.9
TRACK_REPEAT_GAP = 3.0


def track_voices(lang, speakers):
    pool = TRACK_VOICES.get(lang)
    if not pool:
        return None
    used = {"F": 0, "M": 0}
    out = {}
    for sid, sp in sorted((speakers or {}).items()):
        g = "M" if str((sp or {}).get("gender") or "F").upper().startswith("M") else "F"
        cands = pool.get(g) or pool["F"]
        out[sid] = cands[used[g] % len(cands)]
        used[g] += 1
    return out


def track_job(bundle_id, job, lang, script):
    """One scripted listening question -> plan (None = no cleared voice)."""
    vmap = track_voices(lang, script.get("speakers") or {})
    if vmap is None:
        return None
    segs = []
    for t in script.get("turns") or []:
        if not isinstance(t, dict):
            continue
        if "pause" in t:
            if segs:
                segs[-1]["gap"] = round(float(segs[-1].get("gap") or 0) + float(t["pause"]), 2)
            continue
        text = str(t.get("text") or "").strip()
        if text:
            first = next(iter(vmap.values()), None)
            segs.append({"voice": vmap.get(t.get("spk")) or first, "text": text, "gap": 0.5})
    if not segs or any(not s["voice"] for s in segs):
        return None
    plays = max(1, min(3, int(script.get("repeat") or 1)))
    plan = {"bundle": bundle_id, "part": job, "engine": ENGINE, "speed": TRACK_SPEED, "lang": lang,
            "plays": plays, "repeat_gap": TRACK_REPEAT_GAP, "segments": segs}
    plan["hash"] = hashlib.sha256(json.dumps(
        {k: plan[k] for k in ("bundle", "part", "engine", "speed", "lang", "plays", "segments")},
        sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
    plan["voices"] = [{"spk": k, "voice": v, "accent": lang} for k, v in sorted(vmap.items())]
    plan["accents"] = [lang]
    plan["preview_sec"] = 0
    plan["check_sec"] = 0
    plan["file"] = "%s-%s-%s.m4a" % (bundle_id, job, plan["hash"][:12])
    return plan


def track_plans(d, lang):
    """A stage-2/3 test file -> plans of its scripted listening questions."""
    out = []
    if d.get("format") != "assisto.lp.test/1":
        return out
    for s in d.get("sections") or []:
        for p in (s.get("parts") or []) if isinstance(s, dict) else []:
            for q in p.get("questions") or []:
                if isinstance(q.get("script"), dict) and isinstance(q.get("n"), int):
                    pl = track_job(d["bundle_id"], "q%d" % q["n"], lang, q["script"])
                    if pl:
                        out.append(pl)
    return out


def attach_track(data, bundle_id, lang, raw, index):
    """lp_seed: a test's questions get tts.audio when the stored file's plan
    hash is the CURRENT script's; the phone then streams it and gets no lines."""
    got = (index or {}).get(bundle_id) or {}
    if not got:
        return data
    now = {pl["part"]: pl["hash"] for pl in track_plans(raw, lang)}
    for s in data.get("sections") or []:
        for p in s.get("parts") or []:
            for q in p.get("questions") or []:
                job = "q%s" % q.get("n")
                e = got.get(job)
                if e and e.get("audio") and e.get("plan_hash") == now.get(job) and isinstance(q.get("tts"), dict):
                    q["tts"]["audio"] = e["audio"]
                    q["tts"]["audio_meta"] = {k: e[k] for k in ("duration_sec", "plan_hash", "sha256")
                                              if k in e}
    return data
