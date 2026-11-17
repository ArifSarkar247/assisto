"""gboxlinux — `sudo assisto-guardbox setup`: set up a headless Guard Box
(Raspberry Pi / mini PC with no screen) from an SSH or keyboard session.

Every line is shown in Bangla and English. Steps:
  1. find cameras / DVRs on this network (ONVIF) — or type the IP;
  2. brand, channel, the camera user + password (typed hidden, stored
     encrypted ON THIS BOX only — never sent to Assisto);
  3. test: one picture must come from the camera before it is saved;
  4. the pairing code from the owner's Assisto app (CCTV -> Add phone
     camera / Guard Box) -> this camera appears in the owner's app;
  5. another camera? Then the service restarts and starts guarding.
"""
from __future__ import annotations

import getpass
from typing import Callable, List, Optional

from . import pairing, vendors

BRANDS = [("hikvision", "Hikvision / HiLook / Prama"), ("dahua", "Dahua / CP Plus"),
          ("imou", "Imou"), ("tapo", "TP-Link Tapo"), ("ezviz", "EZVIZ"),
          ("rtsp", "অন্য / Other (RTSP address)")]


def say(bn: str, en: str, out: Callable[[str], None] = print) -> None:
    out("  " + bn)
    out("  " + en)


def ask(prompt_bn: str, prompt_en: str, default: str = "",
        inp: Callable[[str], str] = input, out: Callable[[str], None] = print) -> str:
    say(prompt_bn, prompt_en, out)
    v = inp("  > " + ("[%s] " % default if default else "")).strip()
    return v or default


def choose(items: List[str], inp=input, out=print) -> int:
    for i, label in enumerate(items, 1):
        out("   %d) %s" % (i, label))
    while True:
        v = inp("  > ").strip()
        if v.isdigit() and 1 <= int(v) <= len(items):
            return int(v) - 1
        out("   1-%d" % len(items))


def find_cameras(discover=None) -> List[dict]:
    try:
        if discover is None:
            from .onvif import discover as discover
        return discover(timeout_s=4.0)
    except Exception:
        return []


def run(cfg, store, save: Callable[[], None], *, inp=input, secret=getpass.getpass,
        out=print, grab=None, discover=None, session=None) -> int:
    if grab is None:
        from .camera import grab_one_frame as grab
    out("")
    say("আসিস্টো পাহারা বক্স — সেটআপ", "Assisto Guard Box — setup", out)
    out("")
    added = 0
    while True:
        say("এই নেটওয়ার্কে ক্যামেরা/ডিভিআর খোঁজা হচ্ছে…",
            "Looking for cameras / DVRs on this network…", out)
        found = find_cameras(discover)
        host = ""
        if found:
            labels = ["%s  %s %s" % (d.get("host"), d.get("manufacturer") or "",
                                     d.get("model") or "") for d in found[:20]]
            labels.append("আইপি নিজে লিখব / Type the IP myself")
            i = choose(labels, inp, out)
            if i < len(found[:20]):
                host = str(found[i].get("host") or "")
        else:
            say("কিছু পাওয়া যায়নি (অনেক ডিভিআর-এ ONVIF বন্ধ থাকে)।",
                "Nothing found (ONVIF is off on many DVRs).", out)
        say("ব্র্যান্ড বেছে নিন:", "Choose the brand:", out)
        vendor = BRANDS[choose([b[1] for b in BRANDS], inp, out)][0]
        if vendor == "rtsp":
            url = ask("ক্যামেরার RTSP ঠিকানা (rtsp://…):", "The camera's RTSP address (rtsp://…):",
                      inp=inp, out=out)
            user = ask("ইউজারনেম (না থাকলে খালি রাখুন):", "User name (leave empty if none):",
                       inp=inp, out=out)
        else:
            host = ask("ক্যামেরা/ডিভিআর-এর আইপি:", "Camera / DVR IP address:", host, inp, out)
            ch = ask("চ্যানেল নম্বর (ডিভিআর-এ ক্যামেরার নম্বর):",
                     "Channel number (the camera's number on the DVR):", "1", inp, out)
            user = ask("ইউজারনেম:", "User name:", vendors.default_user(vendor, None) or "admin",
                       inp, out)
            try:
                url = vendors.build_rtsp_url(vendor, host, None, int(ch) if ch.isdigit() else 1,
                                             "main")
            except ValueError:
                say("আইপি ঠিক নেই।", "That IP address is not valid.", out)
                continue
        say("পাসওয়ার্ড (লেখার সময় দেখা যাবে না; শুধু এই বক্সে গোপনে থাকবে):",
            "Password (hidden while typing; kept encrypted on this box only):", out)
        pwd = secret("  > ")
        name = ask("ক্যামেরার নাম (যেমন: গেট, ক্যাশ):", "Camera name (e.g. Gate, Cash):",
                   "Camera %d" % (len(cfg.cameras) + 1), inp, out)
        try:
            cam = pairing.add_camera(cfg, store, name, url, user or None, pwd or None)
        except ValueError:
            say("ঠিকানাটি rtsp:// দিয়ে শুরু হতে হবে।", "The address must start with rtsp://.", out)
            continue
        if vendor != "rtsp" and cam.source is None:
            cam.source = {"vendor": vendor, "host": host}
        say("ক্যামেরা থেকে একটি ছবি আনা হচ্ছে…", "Getting one picture from the camera…", out)
        from .engine import camera_url
        ok, _f, msg = grab(camera_url(cfg, store, cam.id))
        if not ok:
            cfg.cameras.remove(cam)
            say("ছবি আসেনি — আইপি, পাসওয়ার্ড বা চ্যানেল দেখুন (%s)।" % msg,
                "No picture — check the IP, password or channel (%s)." % msg, out)
            continue
        say("ছবি এসেছে ✓ (%s)" % msg, "Picture received ✓ (%s)" % msg, out)
        save()
        while True:
            code = ask("মালিকের অ্যাসিস্টো অ্যাপে: সিসিটিভি → ফোন ক্যামেরা / পাহারা বক্স যোগ করুন → কোডটি এখানে লিখুন:",
                       "In the owner's Assisto app: CCTV → Add phone camera / Guard Box → type the code here:",
                       inp=inp, out=out)
            res = pairing.pair_camera(cfg, store, cam, code, session=session)
            bn, en = pairing.MESSAGES.get(res, pairing.MESSAGES["bad_code"])
            say(bn, en, out)
            if res == "ok":
                save()
                added += 1
                break
            if res in ("camera_cap", "feature_off"):
                break
        again = ask("আরেকটি ক্যামেরা যোগ করবেন? (y/n)", "Add another camera? (y/n)", "n", inp, out)
        if not again.lower().startswith("y"):
            break
    say("শেষ! পাহারা চালু হচ্ছে। অবস্থা দেখতে: assisto-guardbox status",
        "Done! Guarding starts now. To see the state: assisto-guardbox status", out)
    return 0 if added else 1
