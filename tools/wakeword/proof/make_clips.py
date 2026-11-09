"""wakeword proof clips: SYNTHETIC only (eSpeak NG voices; no real person's
voice). Positives = "Hey/Hi/Ok Assisto" in several voices/speeds inside
silence + light noise; negatives = near-miss phrases, Bangla/English speech and
noise. Writes 16 kHz mono int16 LE *.raw files. usage: make_clips.py <out dir>
Note: eSpeak voices were also part of TRAINING positives, so this proves the
phone engine + shipped model work end to end on files; it is NOT a held-out
accuracy number (that is eval_report.md + the real-phone test)."""
import os
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(2026)


def tts(text, voice, speed=150, pitch=50):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        p = f.name
    subprocess.run(["espeak-ng", "-v", voice, "-s", str(speed), "-p", str(pitch), "-w", p, text],
                   check=True, capture_output=True)
    sr, x = wavfile.read(p)
    os.unlink(p)
    x = x.astype(np.float32) / 32768.0
    if x.ndim > 1:
        x = x.mean(axis=1)
    g = np.gcd(sr, 16000)
    return resample_poly(x, 16000 // g, sr // g).astype(np.float32)


def place(x, before=1.0, after=1.5, snr_db=20.0):
    y = np.concatenate([np.zeros(int(before * 16000), np.float32), x * 0.6,
                        np.zeros(int(after * 16000), np.float32)])
    sig = float(np.sqrt(np.mean((x * 0.6) ** 2)) + 1e-9)
    noise = rng.standard_normal(len(y)).astype(np.float32)
    noise *= sig / (10 ** (snr_db / 20.0))
    return y + noise


def save(name, y):
    pcm = (np.clip(y, -1, 1) * 32767).astype("<i2")
    pcm.tofile(os.path.join(OUT, name + ".raw"))


n = 0
for phrase in ("Hey Assisto", "Hi Assisto", "Okay Assisto"):
    for voice in ("en-us", "en-gb", "en-gb-x-rp", "hi", "bn"):
        for speed, pitch in ((140, 45), (170, 60)):
            try:
                save(f"pos_{n:02d}_{voice}_{speed}", place(tts(phrase, voice, speed, pitch)))
                n += 1
            except subprocess.CalledProcessError:
                pass
print("positives", n)

neg_text = [
    ("en-us", "Hey assistant, what is the weather today?"),
    ("en-us", "I need some assistance with my homework please."),
    ("en-gb", "He is a sister of my best friend from Dhaka."),
    ("en-us", "Hey Siri, set a timer for ten minutes."),
    ("hi", "Aaj mausam bahut accha hai, chalo bahar chalte hain."),
    ("bn", "আমি আজ বাজারে যাচ্ছি, তুমি কি কিছু লাগবে?"),
    ("bn", "হে আসিফ, কেমন আছো? আমি একটু পরে আসছি।"),
    ("bn", "এসিস্ট্যান্স লাগলে বলবেন।"),
]
m = 0
for voice, text in neg_text:
    for speed in (140, 175):
        save(f"neg_{m:02d}_{voice}_{speed}", place(tts(text, voice, speed), 0.5, 0.5, 15.0))
        m += 1
# 60 s of a long English + Bangla mix with noise (TV-like babble, synthetic)
long = np.concatenate([tts(t, v, 160) for v, t in neg_text] * 3)
save("neg_long_mix", place(long, 0.5, 0.5, 10.0))
save("neg_noise_60s", rng.standard_normal(60 * 16000).astype(np.float32) * 0.05)
print("negatives", m + 2)
