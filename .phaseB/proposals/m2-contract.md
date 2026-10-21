# m2-contract — permanent CI "API contract test" (proposal for android.yml)

**Why:** `tools/route_check.py` (new) found 46 client API calls with no working
backend route (MISSING / 405 METHOD / trailing-SLASH 404) — screens that can
never work no matter how good the UI is. This step makes that a hard gate in
`build-apk`, before Gradle runs.

**What it checks:** every API path in `app/lib/**/*.dart` — literal and
string-built (`'/x/$id'`, `'/x/${m['id']}/y'`, glued query suffixes like
`'/chat/sessions$q'`, `'/money/report.$fmt'`), plus the generic
`listItems/createItem/updateItem/deleteItem` helpers (which append `/`).
Placeholders are tried as int / str / uuid samples and, one position at a
time, as every literal word in the URLconf — so `<int:pk>` vs `<str:x>` vs
`<uuid>` shapes and DRF router actions (`actions` map per method) are honoured.
It then checks the resolved view has a handler for the client's HTTP method.
Exit 1 with a clear list on any miss. `--report-only` never fails.

**Same gate in the backend suite:** `backend/core/tests_api_contract.py` runs it
in-process, so `manage.py test` (the pre-deploy suite) fails too.

**Expected state when applied:** RED until slot m1-messenger lands its routes
(family/accounting/*, circle group URL shapes, circle/chats|info|clear|account/*
|settings/*, groups/<id>/ai/<task>, community/<id>/leave|notifications,
community/message-requests, notif/reminders/<id>/done, journey/<id>/timeline,
disaster/feed, medicine-db/report). Remaining non-m1 misses are listed in
`.phaseB/REALITY_AUDIT.md` (section "API contract").

**Apply:** `git apply -p1 .phaseB/proposals/m2-contract.diff` (same diff below).
Verified with `git apply --check` against the current `android.yml`.

```diff
--- a/.github/workflows/android.yml	2026-10-21 07:06:41.206119737 +0000
+++ b/.github/workflows/android.yml	2026-10-21 07:06:41.237607323 +0000
@@ -23,6 +23,30 @@
     steps:
       - uses: actions/checkout@v4
 
+      # API CONTRACT GATE (m2-reality): every endpoint the Flutter app calls
+      # (literal + string-built paths, ${id} normalised) must resolve to a
+      # Django route that handles that HTTP method (DRF router actions and
+      # <int>/<str>/<slug>/<uuid> converter shapes included). A miss means a
+      # screen that can never work -> fail before spending 20 min on Gradle.
+      # No DB, no network: URL resolution only, under settings_test.
+      - uses: actions/setup-python@v5
+        with:
+          python-version: '3.12'
+      - name: API contract (every app endpoint has a backend route)
+        env:
+          DJANGO_SETTINGS_MODULE: assisto_backend.settings_test
+        run: |
+          python -m pip install -q -r backend/requirements.txt
+          timeout 600 python tools/route_check.py --md route_check.md
+      - name: Upload API contract report
+        if: always()
+        uses: actions/upload-artifact@v4
+        with:
+          name: api-contract-report
+          path: route_check.md
+          retention-days: 14
+          if-no-files-found: ignore
+
       - uses: actions/setup-java@v4
         with:
           distribution: temurin
```
