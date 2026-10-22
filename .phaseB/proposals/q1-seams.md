# q1-seams — proposals (pubspec / native). Not applied; integrator decides.

## 1. Spreadsheet picker for Products → "Import from Excel"

Why: `ProductImportSheet._pick()` used `ImagePicker().pickMedia()`, which can
only return photos/videos — an `.xlsx`/`.csv` can never be selected, so the
import could never work. The entry point is now hidden behind
`kProductImportPickerWired = false` (app/lib/screens/business/products_screen.dart).

```diff
--- a/app/pubspec.yaml
+++ b/app/pubspec.yaml
@@ dependencies:
+  file_picker: 8.1.2
```

Then in `products_screen.dart`:

```diff
-    final x = await ImagePicker().pickMedia();
-    if (x != null) {
+    final res = await FilePicker.platform.pickFiles(
+        type: FileType.custom, allowedExtensions: ['xlsx', 'csv']);
+    final path = res?.files.single.path;
+    if (path != null) {
       setState(() {
-        _filePath = x.path;
+        _filePath = path;
```

and flip `kProductImportPickerWired` to `true`. Needs a CI launch smoke (API 33):
file_picker registers no startup ContentProvider, but verify on ColorOS.

## 2. Customer-facing quote acceptance page (CRM)

Why: `acceptance_link` returns `/api/crm/accept/<token>/` — a RELATIVE JSON API
path. A customer cannot open or accept it, so the button is hidden behind
`kQuoteAcceptPageWired = false` (crm_proposal_advanced_screen.dart). To wire:
a public server-rendered page (e.g. `crm/weburls.py` → `q/<token>`) that calls
`logic_quote.acceptance_transition`, plus an ABSOLUTE https URL in the API
response. Backend only — no native change.

## 3. Live WhatsApp Cloud sender

Why: no code POSTs the assembled Graph request; `crm.whatsapp.LIVE_SEND_BUILT`
is False, so the API now reports a would-be "queued" send as a logged `draft`.
To wire: a server-side sender that POSTs `plan["send"]` with the stored
access token (timeout + error mapping), then set `LIVE_SEND_BUILT = True`.
