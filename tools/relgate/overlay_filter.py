"""relgate: give an OLDER build commit the flow-id filter (REALITY_FLOW_IDS)
without replacing its harness / runner: two lines inserted in place.
Run from the repo root of the gated commit. No-op when already present."""
import re
import sys

h = "app/integration_test/support/harness.dart"
s = open(h).read()
if "REALITY_FLOW_IDS" not in s:
    m = re.search(r"void realityFlow\(.*?\)\s*\{\n", s, re.S)
    if not m:
        sys.exit("::error::realityFlow() not found in " + h)
    s = (s[:m.start()] + "const _gateFlowIds = String.fromEnvironment('REALITY_FLOW_IDS');\n"
         + s[m.start():m.end()]
         + "  if (_gateFlowIds.isNotEmpty && !_gateFlowIds.split(',').contains(id)) return;\n"
         + s[m.end():])
    open(h, "w").write(s)
    print("filter added to", h)
r = "tools/reality/run_flows.sh"
s = open(r).read()
if "REALITY_FLOW_IDS" not in s:
    old = '    --dart-define=REALITY_ONLY="${g//+/,}" \\\n'
    if old in s:
        s = s.replace(old, old + '    --dart-define=REALITY_FLOW_IDS="${REALITY_FLOW_IDS:-}" \\\n', 1)
        open(r, "w").write(s)
        print("filter added to", r)
