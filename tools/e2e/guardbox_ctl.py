"""gboxlinux — DB side of the Linux Guard Box E2E (guardbox-linux.yml).

    python guardbox_ctl.py wait_alert  [timeout_s]   person alert WITH a picture
    python guardbox_ctl.py mark                       remember the event count now
    python guardbox_ctl.py wait_notif KIND [timeout]  a Guard Box notification
                                                      (net_back / power_back)
    python guardbox_ctl.py wait_more [timeout_s]      new alerts since `mark`
    python guardbox_ctl.py proof                      $E2E_DIR/guardbox_proof.json

Reuses the seed / Django set-up of ipcam_ctl.py (same scratch sqlite DB, the
same made-up owner). Prints one line per check; exit 1 on timeout.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ipcam_ctl as IC  # noqa: E402

PROOF = os.path.join(IC.E2E_DIR, "guardbox_proof.json")
MARK = os.path.join(IC.E2E_DIR, "guardbox_mark.json")


def _state():
    IC.django_setup()
    from django.db import connection
    connection.close()          # fresh view of the sqlite file each poll
    from core.models import NotifEvent, ShopCamera
    cams, evs = IC._events()
    ours = [e for e in evs if any(c["id"] == e["camera"] for c in cams)]
    notifs = []
    for n in NotifEvent.objects.order_by("id"):
        m = n.meta or {}
        if m.get("source") == "guard_box" or m.get("kind") == "box_cam_lost":
            notifs.append({"kind": m.get("kind"), "title_en": n.title_en,
                           "body_en": n.body_en, "body_bn": n.body_bn,
                           "queued_alerts": m.get("queued_alerts")})
    info = [ShopCamera.objects.filter(pk=c["id"]).values_list("device_info", flat=True).first()
            for c in cams]
    return cams, ours, notifs, info


def _wait(pred, timeout, what):
    end = time.time() + timeout
    while time.time() < end:
        try:
            got = pred()
            if got:
                print("GBOX_E2E ok: %s" % what, flush=True)
                return got
        except Exception as e:  # noqa: BLE001
            print("poll error: %s" % e, flush=True)
        time.sleep(5)
    print("GBOX_E2E TIMEOUT: %s" % what, flush=True)
    return None


def wait_alert(timeout):
    def p():
        IC.django_setup()
        IC._arm_new_cameras()
        _c, ours, _n, _i = _state()
        return [e for e in ours if e["snapshot"] and e["type"] == "person_detected"
                and str(e["source"] or "").startswith("guard_box_linux")]
    return _wait(p, timeout, "person alert with picture from the Linux box")


def mark():
    _c, ours, _n, _i = _state()
    with open(MARK, "w") as f:
        json.dump({"events": len(ours)}, f)
    print("marked", len(ours))


def wait_more(timeout):
    with open(MARK) as f:
        base = json.load(f)["events"]
    return _wait(lambda: len(_state()[1]) > base, timeout,
                 "alerts made while offline arrived after reconnect")


def wait_notif(kind, timeout):
    return _wait(lambda: [n for n in _state()[2] if n["kind"] == kind], timeout,
                 "notification %s" % kind)


def proof():
    cams, ours, notifs, info = _state()
    out = {"cameras": [{"id": c["id"], "name": c["name"]} for c in cams],
           "device_info": info,
           "alerts": ours,
           "alert_with_photo": any(e["snapshot"] and e["type"] == "person_detected"
                                   for e in ours),
           "notifications": notifs}
    with open(PROOF, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(json.dumps({k: v for k, v in out.items() if k != "alerts"}, indent=1,
                     ensure_ascii=False)[:4000])
    print("events:", [(e["type"], e["source"], e["detector"], e["snapshot"]) for e in ours][:20])
    return 0 if out["alert_with_photo"] else 1


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    t = lambda i, d: float(sys.argv[i]) if len(sys.argv) > i else d  # noqa: E731
    if cmd == "wait_alert":
        sys.exit(0 if wait_alert(t(2, 900)) else 1)
    elif cmd == "mark":
        mark()
    elif cmd == "wait_more":
        sys.exit(0 if wait_more(t(2, 300)) else 1)
    elif cmd == "wait_notif":
        sys.exit(0 if wait_notif(sys.argv[2], t(3, 300)) else 1)
    elif cmd == "proof":
        sys.exit(proof())
    else:
        print(__doc__)
        sys.exit(2)
