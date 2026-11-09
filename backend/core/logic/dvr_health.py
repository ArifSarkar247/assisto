"""
dvr_health.py — DVR / NVR / camera HEALTH rules (CCTV Guard V3 part B,
agent cctvconnect). Pure Python, no Django: the same report shape comes from
every source —

  * the Guard Box on the shop's Wi-Fi reading Hikvision ISAPI or the Dahua
    HTTP API (edge/shopbox/shopbox/camlink/health_probe.py), or
  * a brand-cloud adapter (logic/cctv_connect/*) for EZVIZ / Imou /
    Hik-Connect / DoLynk storage + online status.

Report (normalize_report keeps only these keys, bounded):
  {"source", "device", "at",
   "disks":    [{"id", "state": ok|error|full|unformatted|none|formatting|unknown,
                 "total_gb", "free_gb"}],
   "overwrite": True|False|None,          # DVR set to overwrite the oldest video
   "channels": [{"no", "name", "online": bool|None, "recording": bool|None}],
   "oldest_record": epoch|None,           # first recording still on the disk
   "latest_record": epoch|None}           # newest recording end

evaluate() turns one report into problems:
  hdd_fail     a disk reports error / unformatted / missing          (red)
  hdd_full     disk full and the DVR will NOT overwrite (it stops)    (red)
  rec_stopped  an online channel is not recording, or the newest
               recording ended more than REC_STALE_S ago              (red)
  cam_offline  a channel / camera reports offline (video loss)        (red)
  few_days     recorded days below the owner's target (default 7)     (amber)
covered / moved / dark come from the existing still check
(logic/cctv_rules.assess_still) — the card merges them in (glue).

The daily green-check card says "everything is fine" only when EVERY check
that could be read passed; a check that could not be read is shown as
"not checked" — never as green (honest).
"""
import time

REC_STALE_S = 30 * 60          # newest recording older than this = stopped
DEFAULT_TARGET_DAYS = 7
MAX_DISKS = 16
MAX_CHANNELS = 64
DISK_STATES = ("ok", "error", "full", "unformatted", "none", "formatting", "unknown")
KINDS = ("hdd_fail", "hdd_full", "rec_stopped", "cam_offline", "few_days")
RED = ("hdd_fail", "hdd_full", "rec_stopped", "cam_offline", "covered", "moved", "dark")

WHAT = {
    "hdd_fail": ("DVR-এর হার্ডডিস্কে সমস্যা — ভিডিও রেকর্ড হচ্ছে না হতে পারে",
                 "The DVR hard disk has a problem — video may not be recording"),
    "hdd_none": ("DVR-এ কোনো হার্ডডিস্ক পাওয়া যায়নি — কিছুই রেকর্ড হচ্ছে না",
                 "No hard disk found in the DVR — nothing is being recorded"),
    "hdd_full": ("DVR-এর হার্ডডিস্ক ভরে গেছে এবং পুরনো ভিডিও মুছে নতুন রাখছে না — রেকর্ডিং থেমে যাবে",
                 "The DVR disk is full and is not overwriting old video — recording will stop"),
    "rec_stopped": ("রেকর্ডিং বন্ধ আছে", "Recording has stopped"),
    "cam_offline": ("ক্যামেরা বন্ধ / সংযোগ নেই (ভিডিও আসছে না)",
                    "Camera is off / not connected (no video)"),
    "few_days": ("রেকর্ড মাত্র %s দিনের — লক্ষ্য %s দিন", "Only %s days recorded — target %s days"),
}
FIX = {
    "hdd_fail": ("টেকনিশিয়ান ডেকে হার্ডডিস্ক পরীক্ষা / বদলান। ততক্ষণ ক্লাউড ক্লিপ চালু রাখুন।",
                 "Ask a technician to test / replace the disk. Keep cloud clips on meanwhile."),
    "hdd_none": ("হার্ডডিস্ক লাগানো আছে কিনা টেকনিশিয়ানকে দেখাতে বলুন।",
                 "Ask a technician to check a disk is fitted."),
    "hdd_full": ("DVR-এর মেনু → Storage → Overwrite চালু করুন (পুরনো ভিডিও নিজে মুছবে)।",
                 "DVR menu → Storage → turn Overwrite on (old video is replaced automatically)."),
    "rec_stopped": ("DVR-এর রেকর্ড শিডিউল চালু আছে কিনা দেখুন, দরকারে DVR একবার রিস্টার্ট করুন।",
                    "Check the DVR record schedule is on; restart the DVR once if needed."),
    "cam_offline": ("ক্যামেরার তার, অ্যাডাপ্টার ও বিদ্যুৎ দেখুন।",
                    "Check the camera cable, adapter and power."),
    "few_days": ("বড় হার্ডডিস্ক লাগান বা সাব-স্ট্রিমে রেকর্ড করুন — বেশি দিনের ভিডিও থাকবে।",
                 "Fit a bigger disk or record the sub-stream — video is kept for more days."),
}


def _f(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x if x == x and x >= 0 else None   # NaN / negative -> None


def _b(v):
    if v in (True, False):
        return v
    s = str(v).strip().lower()
    if s in ("true", "1", "yes", "on", "online", "recording"):
        return True
    if s in ("false", "0", "no", "off", "offline"):
        return False
    return None


def normalize_report(raw, now=None):
    """Bound and clean a report from a Guard Box / adapter. Never raises."""
    now = now if now is not None else time.time()
    raw = raw if isinstance(raw, dict) else {}
    disks = []
    for d in (raw.get("disks") or [])[:MAX_DISKS]:
        if not isinstance(d, dict):
            continue
        st = str(d.get("state") or "unknown").lower()
        disks.append({"id": str(d.get("id") or len(disks) + 1)[:8],
                      "state": st if st in DISK_STATES else "unknown",
                      "total_gb": _f(d.get("total_gb")), "free_gb": _f(d.get("free_gb"))})
    chans = []
    for c in (raw.get("channels") or [])[:MAX_CHANNELS]:
        if not isinstance(c, dict):
            continue
        try:
            no = int(c.get("no"))
        except (TypeError, ValueError):
            continue
        chans.append({"no": no, "name": str(c.get("name") or "")[:60],
                      "online": _b(c.get("online")), "recording": _b(c.get("recording"))})
    at = _f(raw.get("at")) or now
    return {"source": str(raw.get("source") or "")[:16],
            "device": str(raw.get("device") or "")[:60],
            "at": min(at, now + 300),
            "disks": disks, "overwrite": _b(raw.get("overwrite")),
            "channels": chans,
            "oldest_record": _f(raw.get("oldest_record")),
            "latest_record": _f(raw.get("latest_record"))}


def recorded_days(report, now=None):
    now = now if now is not None else time.time()
    o = report.get("oldest_record")
    if not o or o > now:
        return None
    return int((now - o) // 86400)


def evaluate(report, now=None, target_days=DEFAULT_TARGET_DAYS, ignore_channels=()):
    """-> {"problems": [{"kind", "channel", "detail"}], "checks": {name: ok|bad|unknown},
    "recorded_days"}. `ignore_channels`: channel numbers the owner said are
    unused (an empty DVR input is not 'offline')."""
    now = now if now is not None else time.time()
    r = report
    probs, checks = [], {}
    # 1. disks
    disks = r.get("disks") or []
    if not disks:
        checks["disk"] = "unknown"
    else:
        bad = [d for d in disks if d["state"] in ("error", "unformatted")]
        none = all(d["state"] == "none" for d in disks)
        full = [d for d in disks if d["state"] == "full" or (
            d.get("total_gb") and d.get("free_gb") is not None
            and d["free_gb"] <= max(0.5, d["total_gb"] * 0.005))]
        if none:
            probs.append({"kind": "hdd_fail", "channel": None, "detail": "hdd_none"})
        for d in bad:
            probs.append({"kind": "hdd_fail", "channel": None, "detail": "disk_%s" % d["id"]})
        if full and r.get("overwrite") is False:
            probs.append({"kind": "hdd_full", "channel": None, "detail": "no_overwrite"})
        checks["disk"] = "bad" if (none or bad or (full and r.get("overwrite") is False)) else (
            "ok" if all(d["state"] in ("ok", "full") for d in disks) else "unknown")
    # 2. channels online / recording
    chans = [c for c in r.get("channels") or [] if c["no"] not in set(ignore_channels or ())]
    off = [c for c in chans if c["online"] is False]
    for c in off:
        probs.append({"kind": "cam_offline", "channel": c["no"], "detail": c["name"]})
    checks["cameras"] = "bad" if off else ("ok" if chans and all(
        c["online"] is True for c in chans) else "unknown")
    not_rec = [c for c in chans if c["online"] is not False and c["recording"] is False]
    for c in not_rec:
        probs.append({"kind": "rec_stopped", "channel": c["no"], "detail": c["name"]})
    latest = r.get("latest_record")
    stale = bool(latest) and (now - latest) > REC_STALE_S and not off
    if stale and not not_rec:
        probs.append({"kind": "rec_stopped", "channel": None,
                      "detail": "latest_%dm" % int((now - latest) // 60)})
    if not_rec or stale:
        checks["recording"] = "bad"
    elif latest or any(c["recording"] is True for c in chans):
        checks["recording"] = "ok"
    else:
        checks["recording"] = "unknown"
    # 3. recorded days
    days = recorded_days(r, now)
    if days is None:
        checks["days"] = "unknown"
    elif days < int(target_days or DEFAULT_TARGET_DAYS):
        probs.append({"kind": "few_days", "channel": None, "detail": str(days)})
        checks["days"] = "low"
    else:
        checks["days"] = "ok"
    return {"problems": probs, "checks": checks, "recorded_days": days}


def _digits(lang, v):
    s = str(v)
    if lang == "bn":
        return s.translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))
    return s


def problem_text(p, lang, target_days=DEFAULT_TARGET_DAYS, cam_names=None):
    """One problem -> (what, fix) in bn / en."""
    i = 0 if lang == "bn" else 1
    kind = p["kind"]
    if kind == "hdd_fail" and p.get("detail") == "hdd_none":
        return WHAT["hdd_none"][i], FIX["hdd_none"][i]
    if kind == "few_days":
        return (WHAT["few_days"][i] % (_digits(lang, p.get("detail") or 0),
                                       _digits(lang, target_days)), FIX["few_days"][i])
    if kind in ("covered", "moved", "dark"):
        from . import cctv_rules as CR
        what = CR.what(kind, lang)
        fix = ("ক্যামেরার সামনে কিছু আছে কিনা / দিক ঠিক আছে কিনা দেখুন।"
               if lang == "bn" else "Check nothing blocks the camera and it points the right way.")
    else:
        what, fix = WHAT.get(kind, WHAT["rec_stopped"])[i], FIX.get(kind, FIX["rec_stopped"])[i]
    ch = p.get("channel")
    if p.get("cam"):
        what = "%s — %s" % (p["cam"], what)
    elif ch is not None:
        name = (cam_names or {}).get(ch) or (
            ("ক্যামেরা %s" % _digits(lang, ch)) if lang == "bn" else "Camera %s" % ch)
        what = "%s — %s" % (name, what)
    return what, fix


def card(evaluations, extra_problems=(), now=None, lang="bn", target_days=DEFAULT_TARGET_DAYS,
         cam_names=None):
    """The daily green-check card for a site from all its device evaluations
    (+ still-check problems: covered / moved / dark). Returns
    {"status": green|amber|red|unknown, "title", "lines": [{"kind","sev","what","fix"}],
     "checks": merged, "recorded_days": min}."""
    now = now if now is not None else time.time()
    probs = []
    merged = {}
    days = []
    order = {"bad": 3, "low": 2, "unknown": 1, "ok": 0}
    for ev in evaluations:
        probs.extend(ev.get("problems") or [])
        for k, v in (ev.get("checks") or {}).items():
            if k not in merged or order.get(v, 1) > order.get(merged[k], 1):
                merged[k] = v      # the worst value of any device wins
        if ev.get("recorded_days") is not None:
            days.append(ev["recorded_days"])
    probs.extend(extra_problems or [])
    lines = []
    for p in probs:
        what, fix = problem_text(p, lang, target_days, cam_names)
        lines.append({"kind": p["kind"], "channel": p.get("channel"),
                      "sev": "red" if p["kind"] in RED else "amber", "what": what, "fix": fix})
    if any(l["sev"] == "red" for l in lines):
        status = "red"
    elif lines:
        status = "amber"
    elif not evaluations or all(v == "unknown" for v in merged.values()):
        status = "unknown"
    else:
        status = "green"
    if status == "green":
        unread = [k for k, v in merged.items() if v == "unknown"]
        title = ("সব ঠিক আছে — রেকর্ডিং চলছে, ডিস্ক ভালো, সব ক্যামেরা অনলাইনে"
                 if lang == "bn" else "All good — recording, disk healthy, every camera online")
        if unread:
            title = ("পরীক্ষা করা অংশ ঠিক আছে (কিছু অংশ এই DVR জানায় না)" if lang == "bn"
                     else "Everything that could be checked is fine (this DVR does not report some parts)")
    elif status == "unknown":
        title = ("আজ DVR পরীক্ষা করা যায়নি — Guard Box বা ক্লাউড সংযোগ দেখুন"
                 if lang == "bn" else "Could not check the DVR today — check the Guard Box or cloud link")
    else:
        n = len(lines)
        title = ("%s টি সমস্যা — নিচে কী করবেন দেখুন" % _digits("bn", n) if lang == "bn"
                 else "%d problem%s — see what to do below" % (n, "" if n == 1 else "s"))
    return {"status": status, "title": title, "lines": lines[:20], "checks": merged,
            "recorded_days": min(days) if days else None, "at": now}
