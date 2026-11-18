"""cctv-accuracy: writes SOURCES.md from clips.json (run after editing it).

    python tools/cctvacc/sources.py
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    clips = json.load(open(os.path.join(HERE, "clips.json"), encoding="utf-8"))
    used = [c for c in clips if c.get("labels")]
    out = [
        "# CCTV smart-alert accuracy — clip sources and licences",
        "",
        "Openly licensed videos from **Wikimedia Commons**, as published on each",
        "file page (licence as declared there; author / credit as Commons shows it).",
        "Nothing is committed: `fetch.py` downloads each ORIGINAL on the CI runner,",
        "checks its SHA-1 against the value Commons publishes, re-encodes it once",
        "to H.264 (same frame times) and deletes it after the run.",
        "",
        "Labels are written BY A PERSON from the contact sheets (`sheets.py`, one",
        "picture per 1-2 s) — never from any model output. A label is a time",
        "interval in seconds where at least one person is visible anywhere in the",
        "picture (people on motorbikes count; statues, dogs and other animals do",
        "not). Privacy: no faces are identified and no identity is used; the",
        "harness only counts person boxes.",
        "",
        "Split: odd clip ids = development (thresholds are tuned there), even ids",
        "= held-out (reported).",
        "",
        "| id | scene | camera | night | person intervals (s) | length | licence | author / credit | source |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for c in used:
        lab = c["labels"]
        iv = ", ".join("%g-%g" % (a, b) for a, b in lab["person"]) or "none"
        out.append("| %s | %s | %s | %s | %s | %ss | %s | %s | [%s](%s) |" % (
            c["id"], c["scene"], c.get("camera", ""), "yes" if lab.get("night") else "no", iv,
            round(c.get("duration") or 0), c["licence"], (c.get("author") or "").replace("|", "/"),
            c["title"][5:].replace("|", "/"), c["page"]))
    dropped = [c for c in clips if c.get("dropped")]
    if dropped:
        out += ["", "## Looked at and NOT used (and why)", ""]
        for c in dropped:
            out.append("- %s — [%s](%s) (%s): %s" % (c["id"], c["title"][5:], c["page"], c["licence"],
                                                    c["dropped"]))
    out += ["", "Totals: %d clips used, %.1f minutes, %d with people, %d without." % (
        len(used), sum((c.get("duration") or 0) for c in used) / 60,
        sum(1 for c in used if c["labels"]["person"]), sum(1 for c in used if not c["labels"]["person"]))]
    with open(os.path.join(HERE, "SOURCES.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
