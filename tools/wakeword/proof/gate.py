"""Gate + markdown summary for wakeword-proof.yml. Fails the job when the
shipped model misses most synthetic positives at Normal or wakes on any
negative clip at Low (the app default)."""
import json
import sys

r = json.load(open(sys.argv[1]))
clips = r["clips"]
pos = {k: v for k, v in clips.items() if k.startswith("pos_")}
neg = {k: v for k, v in clips.items() if k.startswith("neg_")}
rows = ["| level | positives detected | negative clips with a false wake |", "|---|---|---|"]
res = {}
for lvl in ("low", "normal", "high"):
    p = sum(1 for v in pos.values() if v[lvl] > 0)
    n = sum(1 for v in neg.values() if v[lvl] > 0)
    res[lvl] = (p, n)
    rows.append(f"| {lvl} | {p}/{len(pos)} | {n}/{len(neg)} |")
print("## Hey Assisto — phone engine on synthetic clips\n")
print("\n".join(rows))
print(f"\nAudio {r['audio_seconds']:.0f} s; CPU {r['cpu_ms_per_audio_second']:.1f} ms per audio second "
      f"(x86 CI runner, one thread) = {r['cpu_ms_per_audio_second'] / 10:.2f} % of one core.")
print("\nmissed at normal: " + ", ".join(k for k, v in pos.items() if v["normal"] == 0))
print("false wakes at low: " + ", ".join(k for k, v in neg.items() if v["low"] > 0))
ok = res["normal"][0] >= 0.6 * len(pos) and res["low"][1] == 0 and len(pos) >= 10
print("\nGATE:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
