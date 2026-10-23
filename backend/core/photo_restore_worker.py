"""d1-photo: the short-lived worker process for server restore jobs.

Started by core.photo_restore._run_worker with one JSON argument
{feature, in, out, paths, faces, colorize}. Loads core/photo_restore.py by
file path (no Django setup, no DB), runs process(), writes the PNG to `out`
and prints ONE JSON line: {"ok": true, "info": {...}} or
{"ok": false, "error": "<short code>"}. Its memory (the ~1.3 GB colour model)
is returned to the OS when it exits.
"""
import importlib.util
import json
import os
import sys


def main():
    job = json.loads(sys.argv[1])
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("photo_restore_iso", os.path.join(here, "photo_restore.py"))
    R = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(R)
    try:
        with open(job["in"], "rb") as fh:
            raw = fh.read()
        png, info = R.process(job["feature"], raw, job.get("paths") or {},
                              faces=job.get("faces") or [], colorize=bool(job.get("colorize")))
        with open(job["out"], "wb") as fh:
            fh.write(png)
        print(json.dumps({"ok": True, "info": info}))
    except R.RestoreError as e:
        print(json.dumps({"ok": False, "error": str(e)[:60]}))
    except MemoryError:
        print(json.dumps({"ok": False, "error": "oom"}))
    except Exception as e:  # noqa: BLE001 — a short type code, never a path
        print(json.dumps({"ok": False, "error": "crash:%s" % type(e).__name__}))


if __name__ == "__main__":
    main()
