# m2-reality — proposals (pubspec)

## 1. dev_dependencies: integration_test + flutter_driver (optional)

**Why:** the reality flows (`app/integration_test/`, `app/test_driver/`) import them.

**Not required for CI.** `reality.yml` adds both deps at run time (step "Add integration_test + flutter_driver (CI-only dev deps)"), so the shipped build, `pubspec.lock` and android.yml stay exactly as they are.

**What applying it gives:** local `flutter analyze integration_test` without the temporary edit. Both packages are SDK packages and dev-only, so they never reach the release APK.

```diff
 dev_dependencies:
   flutter_test:
     sdk: flutter
+  integration_test:
+    sdk: flutter
+  flutter_driver:
+    sdk: flutter
   flutter_lints: ^4.0.0
```

## 2. android.yml API-contract gate

See `m2-contract.md` / `m2-contract.diff`.

## 3. reality.yml (new workflow file)

The file is in this branch at `.github/workflows/reality.yml`. Pushing it needs the `workflow` scope.

No secrets are needed. It never builds a release APK and never contacts `api.lifeassisto.com`.
