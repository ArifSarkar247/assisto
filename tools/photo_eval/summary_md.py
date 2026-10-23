#!/usr/bin/env python3
"""d1-photo: print the D1_EVAL.md tables from run_eval.py's results.json."""
import json
import sys

r = json.load(open(sys.argv[1]))
S = r["summary"]
print("| category (5 photos each) | damaged PSNR / SSIM | **Assisto** PSNR / SSIM | Remini PSNR / SSIM "
      "| PSNR better on | sharpness damaged → Assisto (clean) | mean |ΔL| damaged → Assisto | time / photo here |")
print("|---|---|---|---|---|---|---|---|")
for cat, s in S.items():
    d, a = s["damaged"], s["assisto"]
    rem = s.get("remini")
    print("| %s | %.1f / %.3f | **%.1f / %.3f** | %s | %d / 5 | %d → %d (%d) | %.1f → %.1f | %.1f s |" % (
        cat.replace("_", " "), d["psnr"], d["ssim"], a["psnr"], a["ssim"],
        ("%.1f / %.3f" % (rem["psnr"], rem["ssim"])) if rem else "not run (owner)",
        a.get("improved_psnr", 0), d["sharp"], a["sharp"], s["clean_sharp"], d["dL"], a["dL"],
        s["ms_mean"] / 1000))
print()
print("| photo | category | damaged PSNR | Assisto PSNR | Assisto SSIM | faces clean/damaged/Assisto | run |")
print("|---|---|---|---|---|---|---|")
for p in r["photos"]:
    m = p["metrics"]
    run = {k: v for k, v in p["run"].items() if k in ("ai_tiles", "ai_ms", "classic_ms", "server_ms",
                                                      "colorized", "total_ms")}
    print("| %s | %s | %.1f | %.1f | %.3f | %d/%d/%d | %s |" % (
        p["photo"], p["category"], m["damaged"]["psnr"], m["assisto"]["psnr"], m["assisto"]["ssim"],
        m["clean"]["faces"], m["damaged"]["faces"], m["assisto"]["faces"],
        ", ".join("%s %s" % (k, v) for k, v in run.items())))
