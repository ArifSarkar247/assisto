import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../state.dart';
import 'fc_ask_parser.dart';
import 'fc_night_news_card.dart';

/// fcbrain — what fcbrain ASSIGNS to fcscreen's FcSlots (contract:
/// owner_actions/FAMILY_CARE_V3_API.md §5). The two lines in
/// app/lib/family_v3/fc_slots_register.dart (marked // fcbrain):
///
///   FcSlots.nightNewsCard = fcBrainNightNewsCard; // fcbrain
///   FcSlots.askParser = (q, ctx) { final r = fcBrainAskMaps(q, ctx.members);
///       return r == null ? null : FcAskAnswer(r.text,
///           memberUserId: r.memberUserId, action: r.action); }; // fcbrain
///   FcSlots.privacyScreen = (ctx, fid) => FcBrainSettingsScreen(
///       api: ctx.read<AppState>().api, familyId: fid); // fcbrain
///
/// The language the parser answers in follows the app (updated whenever a
/// Family screen with the night card builds).
String fcBrainLang = 'bn';

Widget? fcBrainNightNewsCard(BuildContext context, int familyId) {
  try {
    fcBrainLang = Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'bn';
    return FcNightNewsCard(api: context.read<AppState>().api, familyId: familyId);
  } catch (_) {
    return null; // no AppState above (a preview): no card, never a crash
  }
}

/// fcscreen's member maps use camelCase (userId, placeLabel, lastSeen ...);
/// the server's use snake_case — both are read.
FcAskResult? fcBrainAskMaps(String q, List<Map<String, dynamic>> members,
    {String? lang, DateTime? now}) {
  Object? g(Map<String, dynamic> m, String camel, String snake) => m[camel] ?? m[snake];
  final list = <FcAskMember>[];
  for (final m in members) {
    final id = (g(m, 'userId', 'user_id') as num?)?.toInt();
    if (id == null || m['me'] == true) continue; // never answer about the asker
    list.add(FcAskMember(
      userId: id,
      name: (m['name'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      relation: (m['relation'] ?? '').toString(),
      state: (m['state'] ?? 'stale').toString(),
      reason: (m['reason'] ?? '').toString(),
      placeLabel: (g(m, 'placeLabel', 'place_label') ?? '').toString(),
      lastSeen: DateTime.tryParse((g(m, 'lastSeen', 'last_seen') ?? '').toString()),
      battery: (m['battery'] as num?)?.toInt(),
      paused: m['paused'] == true || m['state'] == 'paused',
    ));
  }
  return fcAskAnswer(q, list, lang: lang ?? fcBrainLang, now: now);
}
