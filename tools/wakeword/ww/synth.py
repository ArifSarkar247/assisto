"""Synthetic speech for training: positive "Hey/Hi/Ok Assisto" clips and
adversarial near-miss negatives, from COMMERCIALLY USABLE TTS only:

  kokoro   Kokoro-82M v1.0 (Apache-2.0 weights, trained on permissive data):
           American + British English voices and the Hindi voices (Indian
           accent), plus voice BLENDS (averaged speaker vectors) for many more
           synthetic speakers.
  espeak   eSpeak NG (GPL-3.0 program; we only RUN it — its output audio is
           not covered by the GPL): Bangla, Hindi, Indian/other English
           accents x voice variants x speed x pitch.
  piper    OPTIONAL, OFF by default (config tts.piper=true): Piper voices
           bn_BD-google (Bangla accent), en_US-libritts_r, en_GB-vctk. Their
           datasets are CC BY / CC BY-SA, but they are fine-tuned from the
           "lessac" voice whose Blizzard-2013 data licence restricts
           commercial use -> lineage UNCERTAIN; see MODEL_LICENSES.md.

Each clip -> 16 kHz mono int16 wav, silence-trimmed.
"""
from __future__ import annotations

import os
import random
import shutil
import subprocess
import tempfile

import numpy as np

from . import audio

POSITIVE_EN = ["Hey Assisto", "Hey, Assisto", "Hi Assisto", "Ok Assisto", "Okay Assisto",
               "Hey Assisto!", "Hey Asisto", "Hay Assisto", "Hey Ah-sisto", "Hi, Assisto"]
# Bangla / Hindi script spellings make the bn / hi voices say it with a
# South-Asian accent (input text for TTS only; never shown in the app).
POSITIVE_BN = ["হেই অ্যাসিস্টো", "হেই এসিস্টো", "হাই অ্যাসিস্টো", "ওকে অ্যাসিস্টো", "হেই আসিস্টো"]
POSITIVE_HI = ["हे असिस्टो", "हे अस्सिस्टो", "हाय असिस्टो", "ओके असिस्टो"]

NEGATIVE_EN = [
    "Hey assistant", "assistance please", "Hey Siri", "Hey sister", "Hey Google", "OK Google",
    "Alexa", "Hey Alexa", "Hi Austin", "Hey Aston", "Hey Asif", "a sister", "consist", "insist",
    "persist", "Hey Mister", "Hey Christo", "Hey Calisto", "Hey Assam", "Hey Sisko", "his toe",
    "Hey, is this it", "assist me", "a system", "Hey Kristo", "Ali's toe", "hey you", "hello",
    "Hey Alisha", "Hey Esther", "pesto", "presto", "Hey listen", "Oh, I see",
    # ww3: phonetically confusable with "Hey Assisto" (hard negatives)
    "assist", "assistance", "Hey assistance", "the assistant", "my assistant", "assisted",
    "Hey Assi", "Hey Sisto", "Hey Augusto", "Hey Ernesto", "Hey Alberto", "Hey Gusto",
    "Hey Calypso", "Hey Disco", "Hey, I insist", "Hey, a system", "Hey Asus", "Hey Aussie",
    "Hey Assisi", "Hey, assist me", "a cyst", "Hey siesta", "Hey Rosita", "Hey, it's me",
    "hey, a sister", "pistachio", "Hey Mustafa", "Hey Aziz", "Hey Assad", "Hey Sister Ann",
    "Hey, is it so", "Hey, I see two", "Hey, a city", "Hey Sita", "Hey Vista", "Hey Ristretto",
]
NEGATIVE_BN = [
    "হেই আসিফ", "আস্তে বলো", "অস্থির লাগছে", "সিস্টেম নষ্ট", "হাই আসমা", "ওকে ঠিক আছে",
    "হেই শোনো", "এই যে ভাই", "আসি তাহলে", "সিস্টার কোথায়", "এসিস্ট্যান্ট", "হেই রিস্তা",
    "আজকে কী বার", "ভাত খেয়েছ", "আসছি একটু পরে", "হেই মিস্টার",
    # ww3: confusable Bangla (hard negatives)
    "হেই", "এসিস্ট", "হে আসিফ", "এসিস্ট্যান্স", "হেই এসিস্ট্যান্ট", "হেই আসিফ ভাই",
    "অ্যাসিস্ট করো", "হেই সিস্টেম", "আসিস না", "হেই আসো", "এই আসিস তো", "হেই রাসেল",
    "হেই আজিজ", "হেই মিষ্টি", "হাই আশিক", "হেই আশা", "হ্যালো আসমা", "আছিস তো",
    "হেই সুস্মিতা", "হেই বিস্কুট", "দেখিস তো", "হেই আসিস্ট", "হেই বেস্ট", "ও সিস্টার",
    "হেই আস্তে", "হেই রাস্তা", "এই যে শুনছ", "হেই পেস্ট",
]
NEGATIVE_HI = ["हे सिस्टर", "असिस्टेंट", "हाय आसिफ", "ओके ठीक है",
               "हे असिस्ट", "असिस्टेंस", "हे आसिफ भाई", "हे सिस्टम", "हे दोस्त", "अरे सुनो",
               "हे मिस्टर", "हे आस्था"]

KOKORO_VOICES = {
    "a": ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole",
          "af_nova", "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric",
          "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck"],
    "b": ["bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable",
          "bm_george", "bm_lewis"],
    "h": ["hf_alpha", "hf_beta", "hm_omega", "hm_psi"],
}
ESPEAK_LANGS = {"bn": POSITIVE_BN, "hi": POSITIVE_HI, "en-us": POSITIVE_EN, "en": POSITIVE_EN,
                "en-029": POSITIVE_EN, "en-gb-scotland": POSITIVE_EN}
ESPEAK_NEG = {"bn": NEGATIVE_BN, "hi": NEGATIVE_HI, "en-us": NEGATIVE_EN, "en": NEGATIVE_EN}
ESPEAK_VARIANTS = ["", "+m1", "+m2", "+m3", "+m4", "+m5", "+m7", "+f1", "+f2", "+f3", "+f4", "+f5",
                   "+klatt", "+croak", "+whisper"]


def _save(x: np.ndarray, rate: int, path: str) -> bool:
    x = audio.trim_silence(audio.resample(np.asarray(x, np.float32), rate, audio.SR))
    if len(x) < audio.SR * 0.25 or audio.rms(x) < 1e-4:
        return False
    audio.write_wav(path, audio.normalise(x, -3.0))
    return True


def espeak_available() -> bool:
    return shutil.which("espeak-ng") is not None


def espeak_clips(out_dir: str, n: int, positive: bool, rng: random.Random) -> list[str]:
    if not espeak_available():
        return []
    os.makedirs(out_dir, exist_ok=True)
    table = ESPEAK_LANGS if positive else ESPEAK_NEG
    # negatives: Bangla weighted x2 (the users' language; only eSpeak speaks it)
    langs = list(table) if positive else ["bn", "bn"] + list(table)
    paths = []
    with tempfile.TemporaryDirectory() as td:
        tries = 0
        while len(paths) < n and tries < n * 3:
            tries += 1
            lang = rng.choice(langs)
            text = rng.choice(table[lang])
            voice = lang + rng.choice(ESPEAK_VARIANTS)
            tmp = os.path.join(td, "x.wav")
            cmd = ["espeak-ng", "-v", voice, "-s", str(rng.randint(120, 200)),
                   "-p", str(rng.randint(25, 80)), "-a", "150", "-w", tmp, text]
            try:
                subprocess.run(cmd, check=True, capture_output=True, timeout=20)
                x = audio.read_audio(tmp)
            except Exception:  # noqa: BLE001 (missing voice variant etc.)
                continue
            p = os.path.join(out_dir, f"es_{'p' if positive else 'n'}_{len(paths):06d}.wav")
            if _save(x, audio.SR, p):
                paths.append(p)
    return paths


def kokoro_clips(out_dir: str, n: int, positive: bool, rng: random.Random,
                 blend_ratio: float = 0.5) -> list[str]:
    """Kokoro-82M (Apache-2.0). Needs `pip install kokoro` (+ espeak-ng for
    its G2P fallback). Returns [] when not installed."""
    try:
        from kokoro import KPipeline
    except ImportError:
        return []
    os.makedirs(out_dir, exist_ok=True)
    pipes = {}
    paths = []
    tries = 0
    while len(paths) < n and tries < n * 3:
        tries += 1
        lang = rng.choice(["a", "a", "b", "h"])
        if positive:
            text = rng.choice(POSITIVE_HI if lang == "h" and rng.random() < 0.6 else POSITIVE_EN)
        else:
            text = rng.choice(NEGATIVE_HI if lang == "h" and rng.random() < 0.5 else NEGATIVE_EN)
        vs = KOKORO_VOICES[lang]
        voice = rng.choice(vs)
        if rng.random() < blend_ratio:
            voice = voice + "," + rng.choice(vs)  # averaged speaker = new voice
        try:
            if lang not in pipes:
                pipes[lang] = KPipeline(lang_code=lang)
            chunks = [a for _, _, a in pipes[lang](text, voice=voice, speed=rng.uniform(0.8, 1.25))]
            if not chunks:
                continue
            x = np.concatenate([np.asarray(c, dtype=np.float32).reshape(-1) for c in chunks])
        except Exception:  # noqa: BLE001
            continue
        p = os.path.join(out_dir, f"kk_{'p' if positive else 'n'}_{len(paths):06d}.wav")
        if _save(x, 24000, p):
            paths.append(p)
    return paths


def piper_clips(out_dir: str, n: int, positive: bool, rng: random.Random,
                voices: list[tuple[str, int]]) -> list[str]:
    """OPTIONAL (licence lineage uncertain). voices = [(model.onnx, n_speakers)]."""
    if not shutil.which("piper") or not voices:
        return []
    os.makedirs(out_dir, exist_ok=True)
    paths = []
    with tempfile.TemporaryDirectory() as td:
        tries = 0
        while len(paths) < n and tries < n * 3:
            tries += 1
            model, nspk = rng.choice(voices)
            bn = os.path.basename(model).startswith("bn_")
            pool = (POSITIVE_BN if bn else POSITIVE_EN) if positive else (NEGATIVE_BN if bn else NEGATIVE_EN)
            tmp = os.path.join(td, "p.wav")
            cmd = ["piper", "-m", model, "-f", tmp, "--length-scale", f"{rng.uniform(0.8, 1.3):.2f}",
                   "--noise-scale", f"{rng.uniform(0.5, 0.9):.2f}"]
            if nspk > 1:
                cmd += ["--speaker", str(rng.randrange(nspk))]
            try:
                subprocess.run(cmd, input=rng.choice(pool).encode(), check=True,
                               capture_output=True, timeout=60)
                x = audio.read_audio(tmp)
            except Exception:  # noqa: BLE001
                continue
            p = os.path.join(out_dir, f"pp_{'p' if positive else 'n'}_{len(paths):06d}.wav")
            if _save(x, audio.SR, p):
                paths.append(p)
    return paths


def tone_clips(out_dir: str, n: int, rng: random.Random, positive: bool) -> list[str]:
    """Licence-free synthetic stand-in used ONLY by the tiny smoke run/tests
    when no TTS engine is installed: positives = a fixed 3-tone 'phrase',
    negatives = random tone sequences. Never used for a real model."""
    os.makedirs(out_dir, exist_ok=True)
    out = []
    for i in range(n):
        t = np.arange(int(audio.SR * 0.3)) / audio.SR
        freqs = [440, 660, 550] if positive else [rng.uniform(200, 900) for _ in range(3)]
        x = np.concatenate([np.sin(2 * np.pi * f * rng.uniform(0.95, 1.05) * t) for f in freqs])
        p = os.path.join(out_dir, f"tone_{'p' if positive else 'n'}_{i:05d}.wav")
        audio.write_wav(p, 0.5 * x.astype(np.float32))
        out.append(p)
    return out
