#!/usr/bin/env bash
# stage_down.sh DIR PATTERN...  — download from the draft staging release and re-join split files.
set -euo pipefail
dir="$1"; shift
args=(); for p in "$@"; do args+=(-p "$p"); case "$p" in *.pmtiles) args+=(-p "$p.stg*");; esac; done
gh release download "$STAGE_TAG" -D "$dir" "${args[@]}"
for first in "$dir"/*.stgaa; do
  [ -e "$first" ] || continue
  base="${first%.stgaa}"
  cat "$base".stg* > "$base" && rm -f "$base".stg*
done
ls -la "$dir"
