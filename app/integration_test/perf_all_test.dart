// perf2gb — launch-critical flows measured on a 2 GB-class emulator profile.
// Run by .github/workflows/perf2gb.yml as a PROFILE build (real AOT timings)
// launched straight on the device (no flutter drive / VM service): the
// results stream to logcat as PERF_RESULT lines (tools/perf2gb/collect.py).
//
//   flutter build apk --profile --target=integration_test/perf_all_test.dart \
//     --dart-define=REALITY_API_BASE=http://10.0.2.2:8700 --dart-define=ASSISTO_PERF=true
//
// The Start flows (language, login, onboarding) run first so the perf flows
// open on a signed-in home, exactly like the reality audit.
import 'flows/onboarding_flow.dart';
import 'perf/perf_flows.dart';
import 'support/harness.dart';

void main() {
  Harness.I.init();
  const only = String.fromEnvironment('PERF_ONLY'); // e.g. "p02,p07"
  registerOnboardingFlows();
  registerPerfFlows(only: only.isEmpty ? null : only.split(','));
}
