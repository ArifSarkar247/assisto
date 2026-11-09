// fcscreen — ONE registration line per Family Care v3 agent, each marked with
// its branch, e.g.  FcSlots.openSosSender = openFcSosSender; // fcsos
// Called from the Family screen's initState and before the elder Danger
// button opens SOS (idempotent; the api is refreshed on every call).
import 'package:provider/provider.dart';

import '../api.dart';
import '../eldercare/elder_common.dart'; // fcrest
import '../eldercare/elder_more_rows.dart'; // fcelder
import '../family_sos/sos_sender_screen.dart'; // fcsos
import '../screens/safe_journey/sj_watch_board.dart'; // sjduring
import '../state.dart';
import 'brain/fc_brain_api.dart'; // fcbrain
import 'brain/fc_brain_settings_screen.dart'; // fcbrain
import 'brain/fc_brain_slots.dart'; // fcbrain
import 'fc_slots.dart';

bool _done = false;
ApiClient? _api; // fcrest: the signed-in client for the server ask

void fcRegisterSlots([ApiClient? api]) {
  if (api != null) _api = api;
  if (_done) return;
  _done = true;
  // fcsos
  FcSlots.openSosSender = (ctx, {familyId}) =>
      SosSenderScreen.open(ctx, source: 'family_v3', familyId: familyId);
  // fcbrain
  FcSlots.nightNewsCard = fcBrainNightNewsCard;
  FcSlots.askParser = (q, ctx) {
    final r = fcBrainAskMaps(q, ctx.members);
    return r == null
        ? null
        : FcAskAnswer(r.text, memberUserId: r.memberUserId, action: r.action);
  };
  FcSlots.serverAsk = (fid, q) async {
    final a = _api;
    if (a == null) return null;
    return FcAskAnswer.fromServer(await a.fcbAsk(q, familyId: fid));
  };
  FcSlots.privacyScreen =
      (ctx, fid) => FcBrainSettingsScreen(api: ctx.read<AppState>().api, familyId: fid);
  // fcelder
  FcSlots.moreRows = fcelderMoreRows;
  ElderHooks.openSos = (ctx) => SosSenderScreen.open(ctx, source: 'elder'); // fcelder + fcsos
  // sjduring
  FcSlots.journeyTile = (ctx, fid) => const SjActiveJourneysTile();
}

/// Tests: forget the registration (slots stay as tests set them).
void fcResetSlotsForTest() => _done = false;
