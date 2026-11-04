// wakeword (owner vision checklist 4 Nov 02:22): Assisto's OWN real actions
// for "Hey Assisto" / Assisto Voice — write in My Circle, Care Call, Safe
// Journey — plus the AI router that turns a command the offline parser did
// not understand into ONE of the fixed actions (POST /voice/route). Every
// action shows a confirm card first; nothing runs by itself.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../crypto/identity_vault.dart';
import '../screens/circle_chat_screen.dart';
import '../state.dart';
import '../widgets/chatnav.dart';
import 'va_actions.dart';
import 'va_confirm_sheet.dart';
import 'voice_intents.dart';

/// Maps the server router's answer to a [VaIntent] (null = not an action).
/// Pure: unit-tested in test/wakeword_actions_test.dart.
class VaRouter {
  VaRouter._();

  static VaClock? _clock(Map<String, dynamic> j) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('${j['time'] ?? ''}');
    if (m == null) return null;
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) return null;
    return VaClock(h, mi, ampmKnown: true, tomorrow: j['day'] == 'tomorrow');
  }

  static String? _s(Object? v) {
    final s = '${v ?? ''}'.trim();
    return s.isEmpty ? null : s;
  }

  static VaIntent? fromJson(Map<String, dynamic> j, String raw) {
    final target = _s(j['target']);
    final message = _s(j['message']);
    final place = _s(j['place']);
    switch ('${j['action'] ?? ''}') {
      case 'call':
        return target == null ? null : VaIntent(VaAction.call, raw, target: target);
      case 'whatsapp':
        return target == null
            ? null
            : VaIntent(VaAction.whatsapp, raw, target: target, message: message);
      case 'circle_message':
        return target == null
            ? null
            : VaIntent(VaAction.circleMessage, raw, target: target, message: message);
      case 'alarm':
        final c = _clock(j);
        return c == null ? null : VaIntent(VaAction.alarm, raw, clock: c);
      case 'reminder':
        return message == null
            ? null
            : VaIntent(VaAction.reminder, raw, message: message, clock: _clock(j));
      case 'care_call':
        return target == null
            ? null
            : VaIntent(VaAction.careCall, raw, target: target, clock: _clock(j));
      case 'safe_journey':
        return VaIntent(VaAction.safeJourney, raw, target: place);
      case 'navigate':
        return place == null ? null : VaIntent(VaAction.navigate, raw, target: place);
    }
    return null;
  }

  /// Ask the server router. null when not logged in / offline / no AI key /
  /// not an action — the caller then uses the normal Assisto agent.
  static Future<VaIntent?> ask(BuildContext context, String raw,
      {String lang = 'bn'}) async {
    try {
      final app = context.read<AppState>();
      if (!app.loggedIn || raw.trim().isEmpty) return null;
      final r = await app.api
          .postJson('/voice/route', {'text': raw, 'lang': lang})
          .timeout(const Duration(seconds: 8));
      return fromJson(r, raw);
    } catch (_) {
      return null;
    }
  }
}

/// My Circle person matching (same scoring as the phonebook).
class VaCircle {
  VaCircle._();

  static String memberName(Map<String, dynamic> m) =>
      '${m['name'] ?? m['display_name'] ?? ''}'.trim();

  /// Best matches for a spoken name among My Circle members (max 5).
  static List<Map<String, dynamic>> match(
      String spoken, List<Map<String, dynamic>> members) {
    final byKey = <String, Map<String, dynamic>>{};
    final rows = <Map<String, String>>[];
    for (final m in members) {
      final id = '${m['id'] ?? ''}';
      final name = memberName(m);
      final state = '${m['state'] ?? 'accepted'}';
      if (id.isEmpty || name.isEmpty || state != 'accepted') continue;
      byKey[id] = m;
      rows.add({'name': name, 'phone': id});
      // "ammu" also finds the person saved with relation "mother"
      final rel = '${m['relation'] ?? ''}'.trim();
      if (rel.isNotEmpty) rows.add({'name': rel, 'phone': id});
    }
    final seen = <String>{};
    return [
      for (final r in VaContacts.rank(spoken, rows))
        if (seen.add(r['phone']!)) byKey[r['phone']]!,
    ].take(5).toList();
  }
}

extension VaAssistoActions on VaExecutor {
  /// "my circle e ammu ke likho khaiso?" -> confirm card (who + text) ->
  /// the end-to-end encrypted chat opens and SENDS it (the confirm is the
  /// user's yes). No text -> the chat opens with the keyboard.
  Future<VaOutcome> circleMessage(VaIntent i) async {
    final app = context.read<AppState>();
    final who = i.target ?? '';
    final body = (i.message ?? '').trim();
    List<Map<String, dynamic>> members;
    try {
      final r = await app.api.getJson('/circle/members');
      members = ((r['results'] ?? r['members'] ?? const []) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return VaOutcome(t.vaErrOffline, icon: Icons.cloud_off_rounded, ok: false);
    }
    final found = VaCircle.match(who, members);
    if (found.isEmpty) {
      return VaOutcome(t.vaCircleNoOne(who),
          icon: Icons.person_search_rounded,
          ok: false,
          buttons: [
            VaButton(t.vaCircleOpen, Icons.forum_rounded, () async {
              if (context.mounted) ChatNav.push(context, 'circle');
            }),
          ]);
    }
    if (!context.mounted) return VaOutcome(t.vaCancelled);
    final first = VaCircle.memberName(found.first);
    final pick = await VaConfirmSheet.show(
      context,
      icon: Icons.forum_rounded,
      title: t.vaConfirmCircleTitle(first),
      detail: body.isEmpty ? t.vaNoMessageBody : '“$body”',
      choices: [
        for (final m in found)
          {'name': VaCircle.memberName(m), 'phone': t.vaCircleLabel, 'id': '${m['id']}'},
      ],
      confirmLabel: body.isEmpty ? t.vaCircleOpenChat : t.vaCircleSend,
      voice: confirmVoice,
      spokenQuestion: t.vaConfirmCircleSpoken(first),
    );
    if (pick == null) return VaOutcome(t.vaCancelled, icon: Icons.close_rounded);
    final member = found.firstWhere((m) => '${m['id']}' == pick['id'],
        orElse: () => found.first);
    final name = VaCircle.memberName(member);
    if (!context.mounted) return VaOutcome(t.vaCancelled);
    final nav = Navigator.of(context);
    final identity = await IdentityVault.instance.get();
    unawaited(nav.push(MaterialPageRoute(
        builder: (_) => CircleChatScreen(
            member: member,
            identity: identity,
            initialText: body.isEmpty ? null : body,
            autoSend: body.isNotEmpty))));
    return VaOutcome(body.isEmpty ? t.vaCircleOpened(name) : t.vaCircleSent(name),
        icon: Icons.forum_rounded, title: name, subtitle: body.isEmpty ? null : body);
  }

  /// "Nanu ke care call dao" -> confirm card -> the Care Call screen (pick
  /// time/days there; consent + quiet hours live on that screen).
  Future<VaOutcome> careCall(VaIntent i) async {
    if (!ChatNav.routes.containsKey('carecall')) return agent(i.raw);
    final who = i.target;
    final go = await VaConfirmSheet.show(
      context,
      icon: Icons.support_agent_rounded,
      title: who == null ? t.vaConfirmCareCallAny : t.vaConfirmCareCallTitle(who),
      detail: t.vaCareCallDetail,
      confirmLabel: t.vaCareCallOpen,
      voice: confirmVoice,
      spokenQuestion: who == null ? t.vaConfirmCareCallAny : t.vaConfirmCareCallTitle(who),
    );
    if (go == null) return VaOutcome(t.vaCancelled, icon: Icons.close_rounded);
    if (context.mounted) ChatNav.push(context, 'carecall');
    return VaOutcome(t.vaCareCallOpened, icon: Icons.support_agent_rounded);
  }

  /// "safe journey shuru koro Mirpur" -> confirm card -> Safe Journey (the
  /// user picks who sees the live location and taps Start there).
  Future<VaOutcome> safeJourney(VaIntent i) async {
    final place = i.target;
    final go = await VaConfirmSheet.show(
      context,
      icon: Icons.shield_moon_rounded,
      title: place == null ? t.vaConfirmJourneyAny : t.vaConfirmJourneyTo(place),
      detail: t.vaJourneyDetail,
      confirmLabel: t.vaJourneyOpen,
      voice: confirmVoice,
      spokenQuestion: place == null ? t.vaConfirmJourneyAny : t.vaConfirmJourneyTo(place),
    );
    if (go == null) return VaOutcome(t.vaCancelled, icon: Icons.close_rounded);
    if (context.mounted) ChatNav.push(context, 'journey');
    return VaOutcome(t.vaJourneyOpened, icon: Icons.shield_moon_rounded);
  }
}
