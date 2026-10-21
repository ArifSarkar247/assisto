# Parallel-agent brief (owner order 21 Oct: 6 agents, main session integrates)

You are ONE of 6 parallel agents. The main session is the integrator: it merges your branch, runs final checks, builds, deploys and publishes. You only build your own area. Read this whole file before you start.

## Where you work
- Your git worktree is `/home/ubuntu/wt/<slot>` on branch `agent/<slot>`. Work and commit there, and nowhere else.
- **Never touch `/home/ubuntu/assisto`.** It is the main checkout and also serves the live backend.
- **Never push.** Never run `gh`. Never change repo visibility. The repo is PUBLIC.
- Commit often with clear messages, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never commit secrets, tokens, keys, .env files, google-services.json, service-account JSON, or camera passwords.
- Before every commit, check the staged diff for secrets: `git diff --cached | grep -iE 'secret|password|token|api[_-]?key|BEGIN .*PRIVATE'`. Test fixtures with obviously fake values are fine.

## Never on the LIVE system
- Do not deploy.
- Do not restart `assisto.service`, nginx or coturn.
- Do not run migrations or `manage.py` against the real DB (`backend/.env`).
- Do not edit `/etc/*`, crontabs or systemd units. Write them as files in your worktree (for example `deploy/<area>/…`) and describe the install steps in your final report. The main session installs them.
- Do not touch the old Asalify server (65.2.155.10).

## Heavy commands: always through the shared lock
The box has 2 CPUs and 8 GB RAM, and six agents share it. Wrap EVERY heavy command:
```
~/assisto/bin/heavy.sh <cmd…>
```
Heavy means: `flutter pub get`, `flutter analyze`, `flutter test`, `flutter gen-l10n`, the backend test suite, `pyinstaller`, `npm install`/`npm run build`.
- `heavy.sh` waits for the lock and for ≥1.5 GB free RAM, and sets `DART_VM_OPTIONS`.
- Keep runs targeted: analyze only your own files (`flutter analyze lib/screens/x.dart …`), and run only your own test files (`flutter test --concurrency=1 test/x_test.dart`).
- Backend tests: `cd backend && ~/assisto/bin/heavy.sh ~/assisto/.venv/bin/python manage.py test core.tests_<yours> --settings=assisto_backend.settings_test`. Run the full suite once, at the end.

## Tools
- Flutter: `~/assisto/tools/flutter/bin/flutter`. Android SDK: `~/assisto/tools/android-sdk`.
- Python venv: `~/assisto/.venv`.
- **Never build an APK locally.** APKs are built by CI only.
- In a fresh worktree run `~/assisto/bin/heavy.sh ~/assisto/tools/flutter/bin/flutter pub get` once, inside `app/`.

## Shared-file rules (merge conflicts are the integrator's main risk)
- **ARB / strings: never edit `app/lib/l10n/*.arb` in a commit.**
  - Put new keys in `app/up_<slot>_arb.json` as `{"en": {"key": "…", "@key": {placeholders}}, "bn": {"key": "…"}}`. Every key must be in both en and bn, with real Bangla (no Banglish in bn).
  - To compile and test locally: `python3 ~/assisto/bin/arb_apply.py --app app app/up_<slot>_arb.json && ~/assisto/bin/heavy.sh ~/assisto/tools/flutter/bin/flutter gen-l10n`. Then `git checkout app/lib/l10n` before committing. Generated `app_localizations*.dart` must not be committed either.
  - Prefix your keys with your area (`shopLive…`, `va…`, `rs…`, `at…`, `ads…`) to avoid collisions.
  - Bangla characters are banned in Dart outside `lib/l10n`; `python3 ~/assisto/bin/lang_gate.py app` must stay clean (after applying your ARB file).
- **AndroidManifest / Gradle / pubspec dependencies / MainActivity.kt: do NOT edit directly.**
  - Write a proposal: `.phaseB/proposals/<slot>.md` containing the exact unified diffs, plus why each change is needed.
  - New native Kotlin files of your own are fine under `app/android_overlay/app/src/main/kotlin/com/assisto/assisto/<yourarea>/`.
  - The integrator applies proposals one part at a time, and only after a real launch smoke on CI (API 33).
- **Django migrations:** put your model changes in ONE migration named `00NN_<slot>_<what>.py`, depending on the latest migration in your worktree. The integrator renumbers or re-chains it at merge time. Keep model edits in a clearly separated block of `core/models.py` (append at the end of the file) so merges are clean.
- `core/urls.py`: append your routes in one contiguous block with a `# ---- <slot> ----` comment.
- **Home screen is frozen.** Change `home_screen.dart` only if your task explicitly says so.

## Hard product rules (owner)
- **Lazy + crash-guarded native.** Nothing heavy at app launch; native code initialises on first use, wrapped in try/catch. A crash path must never take down the app.
- **WorkManager is banned**, because it crashed on launch on ColorOS. No startup ContentProviders.
- **Strict bn/en**, and honest limits: never fake output or claim something works when it doesn't. Wording for alerts is "please check", never accusations.
- **Credits:** every metered cost uses `core/logic/pricing.py` actions, and every price or limit must be admin-editable (`/admin/pricing` reads that table).
- **Premium "Silicon Valley" quality:**
  - Material 3;
  - no clipped text at 360 px or with a large font;
  - dark and light;
  - Bangla and English.
  - Add your screens to the screenshot gallery harness (`app/test/screenshots_test.dart`, `FakeApi` in `app/test/fake_api.dart`), so the integrator can review them.
- Version info lives only in Settings → About.

## Context to read first
- `.phaseB/OWNER_ORDERS_CHECKLIST.md`
- `NEW_SERVER_START.md`
- `ASSISTO_SPEC_v2.pdf` (your part)
- `/home/ubuntu/.claude/projects/-home-ubuntu-assisto/memory/` (antitheft-module.md, assisto-design-standards.md, oom-prevention.md, and others as needed)
- Existing code in your area.

## Finish
Your final report MUST list:
1. Commits on your branch.
2. Tests run, with their results (paste the counts).
3. Every proposal file (manifest/gradle/pubspec) and every live-install step (systemd/nginx/cron/DNS).
4. ARB proposal file name and key count.
5. What is NOT done or not verifiable here, stated honestly. For example: "needs a real device", "needs CI Windows build", "needs owner key X".
