// perf2gb — launch-critical flows measured on a 2 GB-class emulator profile.
// Run by .github/workflows/perf2gb.yml as a PROFILE build (real AOT timings)
// launched straight on the device (no flutter drive / VM service): the
// results stream to logcat as PERF_RESULT lines (tools/perf2gb/collect.py).
//
//   flutter build apk --profile --target=integration_test/perf_all_test.dart \
//     --dart-define=REALITY_API_BASE=http://10.0.2.2:8700 --dart-define=ASSISTO_PERF=true
//
// p00 signs in first (language, login and onboarding through AppState, not
// the UI: the UI start flows are the reality audit's job) so every perf flow
// opens on a signed-in home.
import 'perf/perf_flows.dart';
import 'support/harness.dart';

void main() {
  Harness.I.init();
  const only = String.fromEnvironment('PERF_ONLY'); // e.g. "p02,p07"
  registerPerfSignIn();
  registerPerfFlows(only: only.isEmpty ? null : only.split(','));
}
