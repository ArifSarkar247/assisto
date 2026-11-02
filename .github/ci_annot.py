"""CI-only (agent/missing): turn failures in a captured log into public
check-run annotations (the agent cannot read raw job logs). Never merged."""
import re
import sys

kind, path = sys.argv[1], sys.argv[2]
lines = open(path, errors="replace").read().splitlines()
blocks = []
if kind == "django":
    i = 0
    while i < len(lines):
        if re.match(r"^(FAIL|ERROR): ", lines[i]):
            j = i + 1
            while j < len(lines) and not re.match(r"^(=){20,}$", lines[j]):
                j += 1
            blocks.append("\n".join(lines[i:j])[-3500:])
            i = j
        else:
            i += 1
    tail = [l for l in lines if l.startswith(("Ran ", "FAILED", "OK", "System check", "SystemCheckError"))]
    blocks.append("SUMMARY " + " | ".join(tail[-5:]))
    if not any(b.startswith(("FAIL", "ERROR")) for b in blocks):
        blocks.append("TAIL\n" + "\n".join(lines[-60:]))
elif kind == "analyze":
    blocks = [l for l in lines if " error " in l or "error -" in l or "error •" in l][:40]
    blocks = ["\n".join(blocks[k:k + 10]) for k in range(0, len(blocks), 10)] or ["\n".join(lines[-30:])]
else:  # flutter test
    for i, l in enumerate(lines):
        if "[E]" in l or "EXCEPTION CAUGHT" in l or "Test failed" in l:
            blocks.append("\n".join(lines[max(0, i - 2): i + 45])[-3500:])
    if not blocks:
        blocks = ["\n".join(lines[-40:])]
seen = set()
n = 0
for b in blocks:
    if b in seen:
        continue
    seen.add(b)
    msg = b.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print("::error title=%s %d::%s" % (kind, n, msg))
    n += 1
    if n >= 9:
        break
