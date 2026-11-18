#!/usr/bin/env bash
# guardbox-play: the emulator step of guardbox-fgs.yml — the shell sidecar
# (screen off/on, dumpsys, notification Stop) next to the normal flow runner.
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "${REALITY_OUT:?}"
setsid bash "$HERE/pcfgs_sidecar.sh" > "$REALITY_OUT/pcfgs_sidecar.out" 2>&1 < /dev/null &
SC=$!
bash "$HERE/../reality/run_flows.sh"; rc=$?
kill -- -"$SC" 2>/dev/null || kill "$SC" 2>/dev/null || true
exit $rc
