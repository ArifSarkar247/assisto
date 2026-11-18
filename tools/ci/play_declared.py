#!/usr/bin/env python3
"""play-decl (owner standing order 18 Nov): NOTHING is kept out of the Play app
silently. Every feature that Google Play lets in only after a Console form
(declaration + video) has ONE switch here. The Play AAB step in
.github/workflows/android.yml reads the env list PLAY_DECLARED (space
separated keys of ITEMS):

  * key NOT in the list (default, today's state): the item's permissions get
    tools:node="remove" in the Play manifest, its components / foreground
    service types are dropped, and the Play bundle gate FAILS the build if any
    of them still reaches the bundle. The website APK is never touched.
  * key IN the list (the owner filed the form): the item ships in Play; its
    dart-define (e.g. PLAY_MEDICAL=true) is passed to `flutter build
    appbundle` and exported as an env var for older per-item steps.

Flip = add the key to PLAY_DECLARED, ONLY after the owner filed the form in
owner_actions/PLAY_DECLARATIONS_BN.md (section <a id="decl-KEY">) AND the
item's entry exists on the app permission page (backend/web/legal_content.py,
`legal_id`). core.tests_play_declared enforces both. Stdlib only.

CLI (run from app/):
  play_declared.py check   "<declared>"            unknown key -> exit 1
  play_declared.py env     "<declared>"            NAME=true lines (eval)
  play_declared.py defines "<declared>"            --dart-define=NAME=true ...
  play_declared.py perms   "<declared>"            declared permission names
  play_declared.py patch   <AndroidManifest.xml> "<declared>"
  play_declared.py gate    <bundle manifest.pb>  "<declared>"
"""
import re
import sys

# key -> what the Play build must not carry until the form is filed.
#   perms       android.permission.* names (stripped while undeclared)
#   fgs_types   foregroundServiceType tokens (dropped; a service left with no
#               type is removed as a whole)
#   components  fully-qualified service/receiver/activity names (removed)
#   add_perms   permissions ADDED to the Play manifest once declared
#   define      dart-define / env name set to true once declared
#   legal_id    id of the entry on the permission page (None = no permission)
#   owner_lane  the lane that builds the feature code
ITEMS = {
    "guardbox_camera": dict(
        title="Guard Box / phone camera keeps watching with the screen off (camera FGS)",
        perms=("FOREGROUND_SERVICE_CAMERA",), fgs_types=("camera",), components=(),
        add_perms=(), define="PLAY_CAMERA_FGS", legal_id="fgs_camera",
        owner_lane="cctv-guardbox"),
    "screen_share": dict(
        title="Screen sharing in a My Circle video call (mediaProjection FGS)",
        perms=("FOREGROUND_SERVICE_MEDIA_PROJECTION",), fgs_types=("mediaProjection",),
        components=("com.assisto.assisto.calls.ScreenShareService",),
        add_perms=(), define="PLAY_SCREEN_SHARE", legal_id="fgs_screen_share",
        owner_lane="circle-screenshare"),
    "bg_location": dict(
        title="Family Care arrival news with the app closed (background location)",
        perms=("ACCESS_BACKGROUND_LOCATION",), fgs_types=(), components=(),
        add_perms=("ACCESS_BACKGROUND_LOCATION",), define="PLAY_BG_LOCATION",
        legal_id="bg_location", owner_lane="fcbrain"),
    "medical": dict(
        title="Medicine schedules, prescriptions, health timeline (Health apps, organization account)",
        perms=(), fgs_types=(), components=(), add_perms=(),
        define="PLAY_MEDICAL", legal_id=None, owner_lane="play-nomed"),
}

ANDROID = "android.permission."


def parse(declared):
    keys = [k for k in re.split(r"[\s,]+", declared or "") if k]
    bad = [k for k in keys if k not in ITEMS]
    if bad:
        raise ValueError("unknown PLAY_DECLARED key(s): %s (known: %s)"
                         % (" ".join(bad), " ".join(sorted(ITEMS))))
    return set(keys)


def _remove_component(s, name):
    tag = r"(?:service|receiver|activity|provider)"
    q = re.escape(name)
    s = re.sub(r'\s*<(%s)\b[^>]*android:name="%s"[^>]*/>' % (tag, q), "", s)
    s = re.sub(r'\s*<(%s)\b[^>]*android:name="%s"[^>]*>.*?</\1>' % (tag, q), "", s,
               flags=re.S)
    return s


def _drop_fgs_type(s, typ):
    """Drop one foregroundServiceType token; a service left without any type
    is removed as a whole (it could only have run as that type)."""
    out, pos = [], 0
    pat = re.compile(r'<service\b[^>]*android:foregroundServiceType="([^"]*)"[^>]*?(/>|>)', re.S)
    for m in pat.finditer(s):
        tokens = [t for t in m.group(1).split("|") if t]
        if typ not in tokens:
            continue
        rest = [t for t in tokens if t != typ]
        start, end = m.start(), m.end()
        if rest:
            new = s[start:end].replace('android:foregroundServiceType="%s"' % m.group(1),
                                       'android:foregroundServiceType="%s"' % "|".join(rest))
        else:
            if m.group(2) == ">":
                close = s.find("</service>", end)
                end = close + len("</service>") if close != -1 else end
            new = ""
        out.append(s[pos:start])
        out.append(new)
        pos = end
    out.append(s[pos:])
    return "".join(out)


def _insert_after_manifest_tag(s, line):
    return re.sub(r"(<manifest[^>]*>)", lambda m: m.group(1) + "\n    " + line, s, count=1)


def patch(manifest, declared):
    """Return (new manifest text, log lines) for the Play build."""
    d = parse(declared) if isinstance(declared, str) else set(declared)
    s, log = manifest, []
    for key, it in ITEMS.items():
        if key in d:
            for p in it["add_perms"]:
                if not re.search(r'android:name="%s%s"(?![^>]*tools:node)' % (re.escape(ANDROID), p), s):
                    s = _insert_after_manifest_tag(
                        s, '<uses-permission android:name="%s%s"/>' % (ANDROID, p))
            log.append("play-decl: %s DECLARED -> ships in Play" % key)
            continue
        for p in it["perms"]:
            full = re.escape(ANDROID + p)
            s = re.sub(r'<uses-permission\s+android:name="%s"(?![^>]*tools:node)([^>]*)/>' % full,
                       lambda m: '<uses-permission android:name="%s%s"%s tools:node="remove"/>'
                       % (ANDROID, p, m.group(1).rstrip()), s)
            if not re.search(r'android:name="%s"[^>]*tools:node="remove"' % full, s):
                s = _insert_after_manifest_tag(
                    s, '<uses-permission android:name="%s%s" tools:node="remove"/>' % (ANDROID, p))
        for c in it["components"]:
            s = _remove_component(s, c)
        for t in it["fgs_types"]:
            s = _drop_fgs_type(s, t)
        log.append("play-decl: %s not declared -> kept out of the Play manifest" % key)
    return s, log


def gate(bundle_manifest_text, declared):
    """Errors for every undeclared item that still reached the bundle."""
    d = parse(declared) if isinstance(declared, str) else set(declared)
    errs = []
    for key, it in ITEMS.items():
        if key in d:
            continue
        for p in it["perms"]:
            if (ANDROID + p) in bundle_manifest_text:
                errs.append("%s%s is in the Play bundle but '%s' is not in PLAY_DECLARED"
                            % (ANDROID, p, key))
        for c in it["components"]:
            if c in bundle_manifest_text:
                errs.append("%s is in the Play bundle but '%s' is not in PLAY_DECLARED" % (c, key))
    return errs


def defines(declared):
    return " ".join("--dart-define=%s=true" % ITEMS[k]["define"] for k in sorted(parse(declared)))


def env_lines(declared):
    return "\n".join("export %s=true" % ITEMS[k]["define"] for k in sorted(parse(declared)))


def perms(declared):
    return " ".join(p for k in sorted(parse(declared)) for p in ITEMS[k]["perms"])


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    try:
        if cmd == "check":
            d = parse(argv[2] if len(argv) > 2 else "")
            print("play-decl: declared = %s" % (" ".join(sorted(d)) or "(none)"))
        elif cmd == "env":
            print(env_lines(argv[2] if len(argv) > 2 else ""))
        elif cmd == "defines":
            print(defines(argv[2] if len(argv) > 2 else ""))
        elif cmd == "perms":
            print(perms(argv[2] if len(argv) > 2 else ""))
        elif cmd == "patch":
            path, dec = argv[2], (argv[3] if len(argv) > 3 else "")
            with open(path) as f:
                src = f.read()
            new, log = patch(src, dec)
            with open(path, "w") as f:
                f.write(new)
            print("\n".join(log))
        elif cmd == "gate":
            path, dec = argv[2], (argv[3] if len(argv) > 3 else "")
            with open(path, "rb") as f:
                text = f.read().decode("latin-1")
            errs = gate(text, dec)
            for e in errs:
                print("::error::" + e)
            if errs:
                return 1
            print("play-decl gate: every undeclared item is out of the Play bundle")
        else:
            print("unknown command " + cmd)
            return 2
    except ValueError as e:
        print("::error::" + str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
