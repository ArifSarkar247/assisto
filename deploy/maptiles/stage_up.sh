#!/usr/bin/env bash
# Upload files to the draft staging release; files > 1.9 GB go up as NAME.stgaa, .stgab ... (2 GB asset limit).
set -euo pipefail
for f in "$@"; do
  if [ "$(stat -c %s "$f")" -gt 1992294400 ]; then
    split -b 1900M "$f" "$f.stg"
    gh release upload "$STAGE_TAG" "$f".stg* --clobber
    rm -f "$f".stg*
  else
    gh release upload "$STAGE_TAG" "$f" --clobber
  fi
done
