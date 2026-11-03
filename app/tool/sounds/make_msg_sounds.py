#!/usr/bin/env python3
"""circlebub (owner 3 Nov 16:30, part C): Assisto's OWN message sounds.

Synthesised from scratch with plain sine waves and envelopes (no samples, no
recordings, no third-party audio) -> license-clean, owned by Assisto.

  assisto_pop.wav  - new My Circle message (notification channel sound)
                     a soft "pop" (a sine that glides down quickly, like a
                     bubble surfacing) followed by a small, quieter bright
                     note a fifth above; 0.42 s total.
  assisto_tick.wav - the softer in-app tick when that chat is already open
                     on screen; one short, quiet glide; 0.09 s.

Deterministic: same script -> byte-identical files (the CI test checks the
committed files are short, mono, 16-bit and under 1 second).

Run (stdlib only; numpy is NOT needed):
    python3 app/tool/sounds/make_msg_sounds.py
"""
import math
import os
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "..",
                   "android_overlay", "app", "src", "main", "res", "raw")


def env(t, attack, decay):
    """Fast linear attack, exponential decay (seconds)."""
    if t < attack:
        return t / attack
    return math.exp(-(t - attack) / decay)


def glide_tone(dur, f0, f1, glide, attack, decay, amp, partial=0.0):
    """A sine whose pitch falls from f0 to f1 over `glide` seconds (smooth
    exponential curve), with an optional quiet 2nd harmonic."""
    n = int(dur * RATE)
    out = [0.0] * n
    phase = 0.0
    for i in range(n):
        t = i / RATE
        k = min(1.0, t / glide) if glide > 0 else 1.0
        # ease-out so the fall is quick at first, then settles
        k = 1.0 - (1.0 - k) ** 3
        f = f0 * (f1 / f0) ** k
        phase += 2 * math.pi * f / RATE
        s = math.sin(phase) + partial * math.sin(2 * phase)
        out[i] = amp * env(t, attack, decay) * s / (1.0 + partial)
    return out


def mix(a, b, offset_s):
    off = int(offset_s * RATE)
    n = max(len(a), off + len(b))
    out = [0.0] * n
    for i, v in enumerate(a):
        out[i] += v
    for i, v in enumerate(b):
        out[off + i] += v
    return out


def fade_tail(x, ms=12):
    """Short linear fade at the very end so the file never ends on a click."""
    m = min(len(x), int(ms / 1000 * RATE))
    for j in range(m):
        x[len(x) - m + j] *= 1.0 - (j + 1) / m
    return x


def write(name, x, peak=0.80):
    top = max(abs(v) for v in x) or 1.0
    scale = peak / top
    frames = b"".join(struct.pack("<h", int(round(v * scale * 32767))) for v in x)
    path = os.path.normpath(os.path.join(OUT, name))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)
    print("%s  %.3f s  %d bytes" % (path, len(x) / RATE, os.path.getsize(path)))


def main():
    os.makedirs(os.path.normpath(OUT), exist_ok=True)
    # pop: 880 Hz -> 520 Hz in 45 ms, warm 2nd harmonic, quick decay
    body = glide_tone(0.30, 880.0, 520.0, 0.045, 0.003, 0.060, 1.0, partial=0.18)
    # sparkle: a short quiet note a fifth above the landing pitch (~780 Hz x2)
    spark = glide_tone(0.28, 1610.0, 1560.0, 0.020, 0.004, 0.070, 0.38)
    pop = fade_tail(mix(body, spark, 0.085)[: int(0.42 * RATE)])
    write("assisto_pop.wav", pop, peak=0.80)
    # tick: one tiny, quieter glide (softer than the pop, for the open chat)
    tick = fade_tail(glide_tone(0.09, 1250.0, 900.0, 0.015, 0.002, 0.016, 1.0), ms=8)
    write("assisto_tick.wav", tick, peak=0.35)


if __name__ == "__main__":
    main()
