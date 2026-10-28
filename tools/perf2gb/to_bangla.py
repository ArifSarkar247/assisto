#!/usr/bin/env python3
"""perf2gb: owner_actions/PERF_2GB_BN.md (Bangla) from collect.py output.

usage: to_bangla.py --after 2gb.json [--before 2gb_before.json] [--mid mid.json]
                    [--out owner_actions/PERF_2GB_BN.md]

One row per flow with the measured numbers and pass/fail against the targets;
"before -> after" when --before is given. Honest about emulator vs phone.
"""
import argparse
import json
from pathlib import Path

BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
FLOW_BN = {
    "p01_home_chat": "হোম + Assisto চ্যাট",
    "p02_circle_chat": "My Circle: চ্যাট তালিকা → ২০০ মেসেজের চ্যাট",
    "p03_call_screen": "কল স্ক্রিন (ভয়েস + ভিডিও, আসল কল ছাড়া)",
    "p04_safe_journey": "নিরাপদ যাত্রা: শুরু + লাইভ স্ক্রিন",
    "p05_family": "পরিবারের যত্ন",
    "p06_reminders": "রিমাইন্ডার তালিকা (৫০০টি)",
    "p07_photo_studio": "ফটো স্টুডিও + ১২ MP ছবি + একটা এডিট",
    "p08_business_ledger": "বিজনেস + খাতা (৫০০ কাস্টমার)",
    "p09_crm": "CRM (৫০০ লিড)",
    "p10_ai_sales_inbox": "AI সেলস ইনবক্স (১৫০ চ্যাট)",
    "p11_cctv": "CCTV: শপ বক্স + পাহারাদার",
    "p12_vehicle_map": "গাড়ি ট্র্যাকিং (ম্যাপ)",
    "p13_budget": "বাজেট + হিসাব (৩০০ লেনদেন)",
    "p14_plans_credits": "প্ল্যান + ক্রেডিট",
}


def b(v, unit=""):
    if v is None:
        return "—"
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return (f"{v}{unit}").translate(BN)


def ok(x):
    return "✅" if x else "❌"


def pair(before, after, unit=""):
    if before is None:
        return b(after, unit)
    return f"{b(before, unit)} → {b(after, unit)}"


def flows_by_id(d):
    return {f["id"]: f for f in (d or {}).get("flows", [])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--after", required=True)
    ap.add_argument("--before")
    ap.add_argument("--mid")
    ap.add_argument("--out", default="owner_actions/PERF_2GB_BN.md")
    a = ap.parse_args()
    A = json.loads(Path(a.after).read_text())
    B = json.loads(Path(a.before).read_text()) if a.before else None
    M = json.loads(Path(a.mid).read_text()) if a.mid else None
    t = A["targets"]
    d = A["device"]
    L = ["# ২ GB ফোনে গতি — আসল মাপা সংখ্যা (perf2gb)", ""]
    runs = f"রান {b(A.get('run_id'))}" + (f" (আগের মাপ: রান {b(B.get('run_id'))})" if B else "")
    L += [f"**কোথায় মাপা:** GitHub-এর এমুলেটর, ২ GB প্রোফাইল — {runs}। Android API {b(d.get('ro.build.version.sdk'))}, "
          f"RAM {b(d.get('mem_total_mb'))} MB দেখা যায়, {b(d.get('nproc'))} কোর, স্ক্রিন {d.get('wm_size', '').replace('Physical size: ', '')} "
          f"({d.get('wm_density', '').replace('Physical density: ', '')} dpi), অ্যানিমেশন চালু, Java heap সীমা {d.get('dalvik.vm.heapgrowthlimit') or '—'}। "
          "অ্যাপ PROFILE বিল্ড (আসল রিলিজের মতো AOT কোড), সার্ভার = রানারের ভেতরে নকল-নয় এমন টেস্ট Django, আসল-আকারের ডেটা "
          "(৫০০ রিমাইন্ডার, ৫০০ খাতা-কাস্টমার, ৫০০ লিড, ১৫০ সেলস চ্যাট, ২০০টা সত্যিকারের এনক্রিপ্টেড মেসেজ)।", ""]
    L += ["**লক্ষ্য:** ঠান্ডা চালু (কোল্ড স্টার্ট) থেকে হোম ≤ ৩.০ সেকেন্ড · প্রতিটি স্ক্রিন খুলতে ≤ ৮০০ ms · "
          "স্ক্রলে ফ্রেমের p90 ≤ ১৬ ms আর ৫%-এর কম ঝাঁকুনি (jank) · মেমরি (PSS) ≤ ২৫০ MB · লো-মেমরিতে অ্যাপ মেরে ফেলা (LMK) একবারও নয়।", ""]

    # ---------------------------------------------------- cold start
    def cold(x):
        s = (x or {}).get("cold", {}).get("summary", {})
        return s.get("home", {}), s.get("fresh", {})
    h, fr = cold(A)
    hb, frb = cold(B) if B else ({}, {})
    L += ["## ঠান্ডা চালু (কোল্ড স্টার্ট) — মাঝামাঝি মান", "",
          "| কোন অবস্থা | Android-এর মাপ (am start) | প্রথম Flutter ফ্রেম | স্ক্রিন দেখা গেল | লক্ষ্য | ফল |",
          "|---|---|---|---|---|---|",
          f"| প্রথমবার ইনস্টলের পর → ভাষা বাছাই | {pair(frb.get('am_total_ms_median'), fr.get('am_total_ms_median'), ' ms')} | "
          f"{pair(frb.get('first_frame_ms_median'), fr.get('first_frame_ms_median'), ' ms')} | "
          f"{pair(frb.get('screen_ms_median'), fr.get('screen_ms_median'), ' ms')} | — | — |",
          f"| লগইন করা → হোম | {pair(hb.get('am_total_ms_median'), h.get('am_total_ms_median'), ' ms')} | "
          f"{pair(hb.get('first_frame_ms_median'), h.get('first_frame_ms_median'), ' ms')} | "
          f"{pair(hb.get('screen_ms_median'), h.get('screen_ms_median'), ' ms')} | ≤ ৩০০০ ms (মান-মাপকাঠি: ২ GB < ৩৫০০) | {ok(A.get('cold_ok'))} |"]
    if M:
        mh, _ = cold(M)
        L.append(f"| মাঝারি ফোন প্রোফাইল (৪ GB, ৪ কোর) → হোম | {b(mh.get('am_total_ms_median'), ' ms')} | "
                 f"{b(mh.get('first_frame_ms_median'), ' ms')} | {b(mh.get('screen_ms_median'), ' ms')} | < ২০০০ ms | {ok(M.get('cold_bar_ok'))} |")
    L.append("")

    # ---------------------------------------------------- flows
    bf = flows_by_id(B)
    L += ["## প্রতিটি ফ্লো", "",
          "| ফ্লো | সবচেয়ে ধীর স্ক্রিন খোলা | স্ক্রল ফ্রেম p90 | ঝাঁকুনি % | শুধু UI থ্রেড p90 / % | সর্বোচ্চ মেমরি (PSS) | ফল |",
          "|---|---|---|---|---|---|---|"]
    for f in A.get("flows", []):
        v = f["verdict"]
        pv = (bf.get(f["id"]) or {}).get("verdict") or {}
        name = FLOW_BN.get(f["id"], f.get("feature", f["id"]))
        part = "" if v["ran_ok"] else " (আংশিক — মাঝপথে থেমেছে)"
        L.append(f"| {name}{part} | {pair(pv.get('worst_open_ms'), v['worst_open_ms'], ' ms')}{' (সময় শেষ)' if v['open_timed_out'] else ''} {ok(v['ok_open'])} | "
                 f"{pair(pv.get('frame_p90_ms'), v['frame_p90_ms'], ' ms')} | {pair(pv.get('janky_pct'), v['janky_pct'])} {ok(v['ok_jank'])} | "
                 f"{b(v['ui_p90_ms'], ' ms')} / {b(v['janky_ui_pct'])} {ok(v['ok_jank_ui'])} | "
                 f"{pair(pv.get('peak_pss_mb'), v['peak_pss_mb'], ' MB')}"
                 # photoperf2: flows with a "before" sample are judged on their own share
                 f"{(' (নিজের অংশ +' + b(v['delta_pss_mb'], ' MB') + ', শুরু ' + b(v.get('baseline_pss_mb'), ' MB') + ')') if v.get('delta_pss_mb') is not None else ''}"
                 f" {ok(v['ok_mem'])} | {ok(v['pass'])} |")
    missing = [k for k in FLOW_BN if k not in flows_by_id(A)]
    if missing:
        L += ["", "**মাপা যায়নি (ফল নেই):** " + ", ".join(FLOW_BN[k] for k in missing)]
    lmk = A.get("lmk", {})
    L += ["", f"**লো-মেমরি কিল:** lmkd {b(lmk.get('lmkd_kills', 0))}টি, exit-info LOW_MEMORY {b(lmk.get('exit_info_low_memory', 0))}টি, "
          f"ফ্লো চলাকালীন অ্যাপ বন্ধ {b(len(lmk.get('app_deaths_during_flows', [])))}বার {ok(A.get('lmk_ok'))}। "
          f"সবচেয়ে বেশি RSS (৩ সেকেন্ড পরপর মাপা): {b(A.get('rss_peak_mb'), ' MB')}।"]
    bat = A.get("battery_bg")
    if bat:
        L += [f"**ব্যাকগ্রাউন্ডে ৫ মিনিট (স্ক্রিন বন্ধ):** CPU {b(bat.get('cpu_ms'), ' ms')}, wakelock {b(bat.get('wakelocks'))}টি, "
              f"ঘুম-ভাঙানো অ্যালার্ম {b(bat.get('wakeup_alarms'))}টি (এমুলেটরের ব্যাটারি-হিসাব আনুমানিক; CPU সময় আর wakelock সংখ্যা আসল)।"]
    if A.get("apk"):
        L += ["**APK আকার:** " + " · ".join(f"{k}: {b(v)}" for k, v in A["apk"].items()
                                          if not k.endswith("error"))]
    L += ["", "## সৎ সতর্কতা — এমুলেটর বনাম আসল ফোন", "",
          "- এমুলেটরের CPU (GitHub-এর সার্ভার, x86) একটা সস্তা ২ GB ফোনের ARM Cortex-A53 কোরের চেয়ে **দ্রুত** — তাই UI থ্রেডের সময় আসল ফোনে প্রায় ১.৫–৩ গুণ বেশি হতে পারে।",
          "- গ্রাফিক্স এখানে সফটওয়্যারে আঁকা হয় (SwiftShader, Skia) — আসল ফোনের GPU-র চেয়ে **ধীর**; তাই 'ঝাঁকুনি %' কলামে raster সময় খারাপ দেখায়। 'শুধু UI থ্রেড' কলাম আমাদের Dart কোডের ভার দেখায়।",
          "- আসল ফোনে অ্যাপ Impeller (Vulkan) দিয়ে আঁকে; এখানে Skia (Impeller এই এমুলেটরে ক্র্যাশ করে)।",
          "- মেমরি (PSS) আর LMK মাপ আসলের কাছাকাছি: RAM সত্যিই ২ GB, কিন্তু আসল ফোনে অন্য অ্যাপ (Facebook, Messenger…) পেছনে থাকে বলে চাপ আরো বেশি।",
          "- Firebase Test Lab-এ আসল ২ GB ফোনে মাপা হয়নি: `GCP_TESTLAB_SA` গোপন চাবি সেট করা নেই (মালিকের কাজ — `TESTLAB_SETUP.md`)।",
          "", "প্রমাণ: GitHub Actions → `Perf 2 GB` রান → আর্টিফ্যাক্ট `perf2gb-2gb` (perf2gb.json, perf2gb.md, meminfo, logcat)।", ""]
    Path(a.out).write_text("\n".join(L))
    print("\n".join(L))


if __name__ == "__main__":
    main()
