// Reality audit — every flow, in the owner's priority order, in ONE app
// process (one APK build). Run by .github/workflows/reality.yml:
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/reality_all_test.dart \
//     --dart-define=REALITY_API_BASE=http://10.0.2.2:8700
//
// Evidence: <external files>/reality/{results.json,shots/*.png} on the device
// (pulled by tools/reality/run_flows.sh) + the driver's response JSON.
// A single flow's failure is recorded (class C) and the next flow still runs.
import 'flows/budget_remittance_flow.dart';
import 'flows/business_flow.dart';
import 'flows/circle_real_call_flow.dart';
import 'flows/docs_voice_settings_flow.dart';
import 'flows/family_alerts_flow.dart';
import 'flows/family_circle_flow.dart';
import 'flows/home_flow.dart';
import 'flows/my_circle_add_flow.dart';
import 'flows/my_circle_ticks_flow.dart';
import 'flows/onboarding_flow.dart';
import 'flows/personal_flow.dart';
import 'flows/remmeter_flow.dart';
import 'flows/safe_journey_flow.dart';
import 'flows/sweep_flow.dart';
import 'support/harness.dart';

void main() {
  Harness.I.init();
  const only = String.fromEnvironment('REALITY_ONLY'); // e.g. "home,personal"
  bool on(String g) => only.isEmpty || only.split(',').contains(g);
  if (on('start')) registerOnboardingFlows();
  if (on('home')) registerHomeFlows();
  if (on('personal')) registerPersonalFlows();
  if (on('personal')) registerRemMeterFlows(); // remmeter
  if (on('personal')) registerBudgetRemittanceFlows(); // budrem (flag allow-listed for A by the seed)
  if (on('family')) registerFamilyCircleFlows();
  if (on('family')) registerSafeJourneyFlows(); // journey100
  if (on('family')) registerFamilyAlertsFlows(); // family100
  // rt2: My Circle is its own CI group (its own runner + emulator), so a
  // device death in the long family+circle run can no longer cost both.
  if (on('circle')) registerMyCircleAddFlows(); // m3-circle
  if (on('circle')) registerMyCircleTicksFlows(); // c3-msg
  if (on('circle') || on('calls')) registerCircleRealCallFlows(); // c2-calls
  if (on('business')) registerBusinessFlows();
  if (on('docs')) registerDocsVoiceSettingsFlows();
  if (on('sweep')) registerSweepFlow();
}
