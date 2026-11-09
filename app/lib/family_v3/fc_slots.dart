import 'package:flutter/widgets.dart';

/// fcscreen — hooks other Family Care v3 agents ASSIGN (never edit this file;
/// add one line to fc_slots_register.dart marked with your branch).
/// Contract: owner_actions/FAMILY_CARE_V3_API.md §5.
class FcAskContext {
  final int familyId;

  /// [{userId, name, label, role, placeLabel, state}]
  final List<Map<String, dynamic>> members;
  const FcAskContext(this.familyId, this.members);
}

class FcAskAnswer {
  final String text;
  final int? memberUserId;

  /// none | open_member | call | location
  final String action;
  const FcAskAnswer(this.text, {this.memberUserId, this.action = 'none'});

  factory FcAskAnswer.fromServer(Map m) => FcAskAnswer('${m['text'] ?? ''}',
      memberUserId: (m['member_user_id'] as num?)?.toInt(),
      action: '${m['action'] ?? 'none'}');
}

class FcSlots {
  FcSlots._();

  /// fcsos: open the 5-second SOS sender. null = the old family SOS confirm.
  static Future<void> Function(BuildContext context, {int? familyId})? openSosSender;

  /// fcbrain: the night news card (null / returns null = no card).
  static Widget? Function(BuildContext context, int familyId)? nightNewsCard;

  /// fcbrain: offline ask parser on the phone (free). null / returns null ->
  /// POST /family/brain/ask.
  static FcAskAnswer? Function(String question, FcAskContext ctx)? askParser;

  /// fcbrain: server ask (POST /family/brain/ask; rules first, AI only when
  /// needed). null = only the phone parser + local name match.
  static Future<FcAskAnswer?> Function(int familyId, String question)? serverAsk;

  /// fcbrain: "Privacy & alerts" (who can see me, pause 1/2/8 h, arrival
  /// news, night news, leave). null = the row is not shown.
  static Widget Function(BuildContext context, int familyId)? privacyScreen;

  /// fcelder: extra More rows (Elder easy home, set up an elder phone).
  static List<Widget> Function(BuildContext context, int familyId)? moreRows;
}
