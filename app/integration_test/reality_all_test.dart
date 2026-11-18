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
import 'flows/antitheft_snatch_flow.dart'; // at100
import 'flows/billing_flow.dart';
import 'flows/budget_remittance_flow.dart';
import 'flows/city_flow.dart'; // gap-city
import 'flows/business_flow.dart';
import 'flows/camflows_flow.dart'; // camflows
import 'flows/bizq_flow.dart'; // qbiz
import 'flows/crm100_flow.dart'; // crm100
import 'flows/circle_real_call_flow.dart';
import 'flows/docs_voice_settings_flow.dart';
import 'flows/e2e_proof_flows.dart'; // e2eproof
import 'flows/offline_first_flow.dart'; // offline1st
import 'flows/family_alerts_flow.dart';
import 'flows/flagproof_flow.dart'; // flagproof
import 'flows/mess_v2_flow.dart'; // messv2
import 'flows/family_circle_flow.dart';
import 'flows/family_v3_flow.dart'; // fcscreen
import 'flows/home_flow.dart';
import 'flows/my_circle_add_flow.dart';
import 'flows/invite_join_flow.dart'; // invite-join
import 'flows/my_circle_ticks_flow.dart';
import 'flows/onboarding_flow.dart';
import 'flows/personal_flow.dart';
import 'flows/remmeter_flow.dart';
import 'flows/safe_journey_flow.dart';
import 'flows/sos_journey_flow.dart'; // qjourney
import 'flows/journey_v2_flow.dart'; // qjourney
import 'flows/sj_proof_flow.dart'; // sjproof
import 'flows/sweep_flow.dart';
import 'flows/save_sweep_flow.dart'; // savesweep
import 'flows/lp_flow.dart'; // gap-lp
import 'flows/voice_proof_flow.dart'; // voice-proof
import 'support/harness.dart';

void main() {
  Harness.I.init();
  const only = String.fromEnvironment('REALITY_ONLY'); // e.g. "home,personal"
  bool on(String g) => only.isEmpty || only.split(',').contains(g);
  if (on('start')) registerOnboardingFlows();
  if (on('home')) registerHomeFlows();
  if (on('personal')) registerPersonalFlows();
  if (on('personal')) registerRemMeterFlows(); // remmeter
  if (on('personal') || on('city')) registerCityFlows(); // gap-city (City Service, CI sample data)
  if (on('personal')) registerBudgetRemittanceFlows(); // budrem (flag allow-listed for A by the seed)
  if (on('personal') || on('billing')) registerBillingFlows(); // billapp
  if (on('family')) registerFamilyCircleFlows();
  if (on('family')) registerSafeJourneyFlows(); // journey100
  if (on('family')) registerFamilyAlertsFlows(); // family100
  if (on('family')) registerFamilyV3Flows(); // fcscreen
  if (on('family') || on('mess')) registerMessV2Flows(); // messv2
  if (on('family')) registerSosJourneyFlows(); // qjourney
  if (on('family')) registerJourneyV2Flows(); // qjourney
  if (on('family')) registerAntiTheftSnatchFlows(); // at100: two-phone snatch proof
  // rt2: My Circle is its own CI group (its own runner + emulator), so a
  // device death in the long family+circle run can no longer cost both.
  if (on('circle')) registerMyCircleAddFlows(); // m3-circle
  if (on('circle')) registerInviteJoinFlows(); // invite-join
  if (on('circle')) registerMyCircleTicksFlows(); // c3-msg
  if (on('circle') || on('calls')) registerCircleRealCallFlows(); // c2-calls
  if (on('business')) registerBusinessFlows();
  if (on('business')) registerCrm100Flows(); // crm100
  if (on('business')) registerBizQualityFlows(); // qbiz
  if (on('docs')) registerDocsVoiceSettingsFlows();
  if (on('lp')) registerLpFlows(); // gap-lp: Language Partner (seed allow-lists A + lp_seed)
  // savesweep: per-form fill -> Save -> reopen -> still there (group 'save')
  if (on('save')) registerSaveSweepFlows();
  // flagproof: hidden features' two-account proofs (group 'flagproof')
  if (on('flagproof')) registerFlagproofFlows();
  if (on('sweep')) registerSweepFlow();
  // e2eproof: the 8 proof flows need settings_e2eproof's fakes -> opt-in only (e2e.yml)
  if (only.split(',').contains('e2e')) registerE2eProofFlows();
  // camflows: CCTV brand clouds need settings_e2eproof + the vendor sim -> opt-in (camflows.yml)
  if (only.split(',').contains('camflows')) registerCamflowsFlows();
  // sjproof: Safe Journey V2 proof needs settings_e2eproof's sj-sim + fakes -> opt-in (e2e.yml start+sjproof)
  if (only.split(',').contains('sjproof')) registerSjProofFlows();
  // voice-proof: "Hey Assisto" + voice actions through the emulator's virtual
  // mic -> opt-in only (voice-emu.yml start+voiceproof)
  if (only.split(',').contains('voiceproof')) registerVoiceProofFlows();
  // offline1st: the offline proof (real airplane mode) — nightly with the
  // e2e proof flows, or alone with REALITY_ONLY=offline (e2e.yml input)
  if (only.split(',').contains('e2e') || only.split(',').contains('offline')) {
    registerOfflineFirstFlows();
  }
}
