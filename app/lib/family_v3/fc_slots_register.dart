// fcscreen — ONE registration line per Family Care v3 agent, each marked with
// its branch, e.g.  FcSlots.openSosSender = openFcSosSender; // fcsos
// Called once from the Family screen's initState (idempotent).
import 'package:provider/provider.dart';

import '../eldercare/elder_more_rows.dart'; // fcelder
import '../family_sos/sos_sender_screen.dart'; // fcsos
import '../screens/safe_journey/sj_watch_board.dart'; // sjduring
import '../state.dart'; // fcbrain
import 'brain/fc_brain_settings_screen.dart'; // fcbrain
import 'brain/fc_brain_slots.dart'; // fcbrain
import 'fc_slots.dart';

/// Tests that install their own slots set this to true first.
bool fcSlotsRegistered = false;

void fcRegisterSlots() {
  if (fcSlotsRegistered) return;
  fcSlotsRegistered = true;
  FcSlots.openSosSender = (ctx, {familyId}) =>
      SosSenderScreen.open(ctx, source: 'family_v3', familyId: familyId); // fcsos
  FcSlots.nightNewsCard = fcBrainNightNewsCard; // fcbrain
  FcSlots.askParser = (q, ctx) {
    final r = fcBrainAskMaps(q, ctx.members);
    return r == null ? null : FcAskAnswer(r.text, memberUserId: r.memberUserId, action: r.action);
  }; // fcbrain
  FcSlots.privacyScreen = (ctx, fid) =>
      FcBrainSettingsScreen(api: ctx.read<AppState>().api, familyId: fid); // fcbrain
  FcSlots.journeyTile = (ctx, fid) => const SjActiveJourneysTile(); // sjduring
  FcSlots.moreRows = fcelderMoreRows; // fcelder
}
