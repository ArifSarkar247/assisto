// fcscreen — ONE registration line per Family Care v3 agent, each marked with
// its branch, e.g.  FcSlots.openSosSender = openFcSosSender; // fcsos
// Called once from the Family screen's initState (idempotent).
// ignore: unused_import
import 'fc_slots.dart';

bool _done = false;

void fcRegisterSlots() {
  if (_done) return;
  _done = true;
  // fcsos:   FcSlots.openSosSender = ...;
  // fcbrain: FcSlots.nightNewsCard = ...; FcSlots.askParser = ...;
  // fcelder: FcSlots.moreRows = ...;
}
