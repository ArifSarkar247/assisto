#!/usr/bin/env bash
# relgate: which release build does this gate run judge?
#   workflow_run      -> the android.yml run that just finished (its head_sha)
#   workflow_dispatch -> input run_id (any android.yml run), else input ref
#                        (sha/branch; default main) -> its newest green build
#   push (ci/relgate*) -> newest green android.yml run on main
# Outputs (GITHUB_OUTPUT): go=true|false, sha, run_id, why.
# Sets the commit status `release-gate` = pending on that sha.
set -euo pipefail
R="$GITHUB_REPOSITORY"
out() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }
stop() { out go false; out why "$1"; echo "::notice::release gate not run: $1"; echo "RELEASE_GATE=SKIPPED ($1)" >> "$GITHUB_STEP_SUMMARY"; exit 0; }
EV="$GITHUB_EVENT_NAME"; RID=""; SHA=""
if [ "$EV" = workflow_run ]; then
  RID="$WR_ID"; SHA="$WR_SHA"
  [ "$WR_CONCLUSION" = success ] || {
    if [ "$WR_CONCLUSION" = failure ]; then
      gh api -X POST "repos/$R/statuses/$SHA" -f state=failure -f context=release-gate \
        -f description="release build (android.yml) failed - nothing to gate" \
        -f target_url="$RUN_URL" >/dev/null
      echo "RELEASE_GATE=FAIL $SHA (android.yml run $RID failed)" >> "$GITHUB_STEP_SUMMARY"
    fi
    stop "android.yml run $RID ended '$WR_CONCLUSION'"; }
elif [ -n "${IN_RUN_ID:-}" ]; then
  RID="$IN_RUN_ID"
  SHA=$(gh api "repos/$R/actions/runs/$RID" -q .head_sha)
  c=$(gh api "repos/$R/actions/runs/$RID" -q .conclusion)
  wf=$(gh api "repos/$R/actions/runs/$RID" -q .path)
  [ "$wf" = ".github/workflows/android.yml" ] || stop "run $RID is $wf, not android.yml"
  [ "$c" = success ] || stop "android.yml run $RID is '$c', not success"
else
  REF="${IN_REF:-main}"
  if [ "$EV" = push ] || [ "$REF" = main ]; then
    # newest green release build on main (a docs-only main commit has no build)
    RID=$(gh api "repos/$R/actions/workflows/android.yml/runs?branch=main&event=push&status=success&per_page=1" -q '.workflow_runs[0].id')
    SHA=$(gh api "repos/$R/actions/runs/$RID" -q .head_sha)
  else
    SHA=$(gh api "repos/$R/commits/$REF" -q .sha)
    RID=$(gh api "repos/$R/actions/workflows/android.yml/runs?head_sha=$SHA&status=success&per_page=1" -q '.workflow_runs[0].id // empty')
    [ -n "$RID" ] || stop "no green android.yml run for $SHA"
  fi
fi
[ -n "$RID" ] && [ -n "$SHA" ] || stop "could not resolve the release build"
# the x86_64 release APK (kept 2 days); an older build (e.g. the live production
# one) only keeps its release AAB -> the smoke legs make a universal APK from it
ARTS=$(gh api "repos/$R/actions/runs/$RID/artifacts?per_page=100" -q '.artifacts[] | select(.expired|not) | .name')
if echo "$ARTS" | grep -qx assisto-apk-emu; then APK_ART=assisto-apk-emu
elif echo "$ARTS" | grep -qx assisto-aab; then APK_ART=assisto-aab
else stop "android.yml run $RID has neither assisto-apk-emu nor assisto-aab (expired?)"; fi
out apk_artifact "$APK_ART"
gh api -X POST "repos/$R/statuses/$SHA" -f state=pending -f context=release-gate \
  -f description="release gate running (build run $RID)" -f target_url="$RUN_URL" >/dev/null
out go true; out sha "$SHA"; out run_id "$RID"; out why ok
{ echo "### Release gate target"; echo "commit \`$SHA\` - release build android.yml run [$RID]($GITHUB_SERVER_URL/$R/actions/runs/$RID) (artifact $APK_ART)"; } >> "$GITHUB_STEP_SUMMARY"
echo "gating $SHA (android.yml run $RID)"
