#!/usr/bin/env python3
"""career: the career-lane E2E verdict (career-proof.yml).

usage: career_proof.py <reality_out_dir>
Every flow in app/integration_test/flows/career_flow.dart must be "pass" (a
flow that never ran is "notrun", never green by omission). The Bangla /
English CV PDFs the flow saved (device/**/career_cv_*.pdf) are rasterised
(pypdfium2) to career_pdf/*.png and their text layer written to
career_pdf/*.txt for the shaping / clipping review. Writes career_proof.json
+ a table to the job summary; exit 1 unless all passed.
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "reality"))
import summarize  # noqa: E402


def expected():
    src = (ROOT / "app/integration_test/flows/career_flow.dart").read_text()
    return re.findall(r"realityFlow\('(cr\d\d_[a-z0-9_]+)'", src)


def render_pdfs(out):
    """-> [(name, pages, bytes)] after writing PNG pages + the text layer."""
    done = []
    dest = out / "career_pdf"
    for pdf in sorted(out.glob("device/**/career_cv_*.pdf")):
        dest.mkdir(exist_ok=True)
        try:
            import pypdfium2 as pdfium
            doc = pdfium.PdfDocument(str(pdf))
            texts = []
            for i in range(len(doc)):
                doc[i].render(scale=2).to_pil().save(dest / ("%s_p%d.png" % (pdf.stem, i + 1)))
                texts.append(doc[i].get_textpage().get_text_range())
            (dest / (pdf.stem + ".txt")).write_text("\n\f".join(texts), encoding="utf-8")
            done.append((pdf.name, len(doc), pdf.stat().st_size))
        except Exception as e:  # noqa: BLE001 — evidence only, never the verdict
            done.append((pdf.name, "render failed: %s" % e, pdf.stat().st_size))
    return done


def main():
    out = Path(sys.argv[1])
    flows, src = summarize.load(out)
    by_id = {f["id"]: f for f in flows}
    rows, bad = [], []
    for fid in expected():
        f = by_id.get(fid) or {"status": "notrun", "steps": [], "error": "never ran"}
        fs = next((s for s in f.get("steps", []) if not s.get("ok")), None)
        rows.append({"id": fid, "status": f["status"], "seconds": f.get("seconds"),
                     "note": f.get("note", ""), "error": f.get("error"),
                     "failed_step": (fs or {}).get("name"),
                     "steps": [{"name": s.get("name"), "ok": s.get("ok"), "ms": s.get("ms")}
                               for s in f.get("steps", [])]})
        if f["status"] != "pass":
            bad.append(fid)
    proof = {"run": os.environ.get("GITHUB_RUN_ID", ""), "commit": os.environ.get("GITHUB_SHA", ""),
             "source": src, "green": not bad, "not_green": bad, "flows": rows}
    proof["pdfs"] = render_pdfs(out)
    (out / "career_proof.json").write_text(json.dumps(proof, ensure_ascii=False, indent=1))
    md = ["## Career lane E2E (CV PDF, mock interview, certificate) — %s" % ("GREEN" if not bad else "NOT green: " + ", ".join(bad)),
          "", "| flow | status | time | failed step | error |", "|---|---|---|---|---|"]
    for r in rows:
        md.append("| %s | %s | %ss | %s | %s |" % (
            r["id"], r["status"], round(r["seconds"] or 0), r["failed_step"] or "",
            (r["error"] or "").replace("\n", " ").replace("|", "/")[:160]))
    for name, pages, size in proof["pdfs"]:
        md.append("")
        md.append("PDF evidence: %s — pages %s, %s bytes" % (name, pages, size))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write("\n".join(md) + "\n")
    print("\n".join(md))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
