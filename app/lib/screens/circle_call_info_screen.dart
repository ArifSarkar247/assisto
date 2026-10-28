import 'package:flutter/material.dart';

import '../calls/call_avatar.dart';
import '../l10n/app_localizations.dart';
import '../messaging/date_separators.dart' show dateChipLabel, fmtTime, localDigits;
import '../theme.dart';
import '../widgets/circle_relation.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// wa-polish2 — WhatsApp's "Call info": tap a call-log row to see each call
/// of that row (date, time, incoming / outgoing / missed, voice / video,
/// talk time or the outcome) with Message / Voice call / Video call. Built
/// ONLY from the call-history rows the app already has (GET /circle/calls:
/// the group row + the individual rows its `ids` name) — no new endpoint.
class CircleCallInfoScreen extends StatelessWidget {
  const CircleCallInfoScreen({
    super.key,
    required this.call,
    required this.entries,
    this.onCall,
    this.onMessage,
  });

  /// The call-log row that was tapped (name, photo, relation, kind…).
  final Map<String, dynamic> call;

  /// The individual calls of that row, newest first (>= 1).
  final List<Map<String, dynamic>> entries;

  /// Place a call ('voice' | 'video'); null = this person can't be called
  /// from here (no chat with them).
  final void Function(String kind)? onCall;

  /// Open the chat; null = no chat with this person.
  final VoidCallback? onMessage;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = '${call['name'] ?? call['member_name'] ?? ''}';
    final relation = '${call['relation'] ?? 'friend'}';
    final lang = Localizations.localeOf(context).languageCode;
    return Scaffold(
      appBar: AppBar(title: Text(t.wa2CallInfoTitle)),
      body: ListView(
        key: const Key('wa2-call-info'),
        padding: withNavBarInset(context, const EdgeInsets.symmetric(vertical: Gap.lg)),
        children: [
          Padding(
            padding: Gap.screen,
            child: Row(children: [
              CallAvatar(
                  name: name,
                  photoUrl: '${call['photo_url'] ?? ''}',
                  version: '${call['photo_v'] ?? ''}',
                  radius: 28,
                  onDark: false),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: AType.titleMedium.copyWith(
                            color: scheme.onSurface, fontWeight: FontWeight.w600)),
                    Text(
                        CircleRelation.labelFor(t, relation,
                            custom: call['custom_label'] as String?),
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ]),
          ),
          const SizedBox(height: Gap.lg),
          Padding(
            padding: Gap.screen,
            child: Row(children: [
              Expanded(
                child: _Action(
                  key: const Key('wa2-call-info-message'),
                  icon: Icons.chat_rounded,
                  label: t.wa2CallInfoMessage,
                  onTap: onMessage,
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: _Action(
                  key: const Key('wa2-call-info-voice'),
                  icon: Icons.call_rounded,
                  label: t.wa2CallInfoVoice,
                  onTap: onCall == null ? null : () => onCall!('voice'),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: _Action(
                  key: const Key('wa2-call-info-video'),
                  icon: Icons.videocam_rounded,
                  label: t.wa2CallInfoVideo,
                  onTap: onCall == null ? null : () => onCall!('video'),
                ),
              ),
            ]),
          ),
          const SizedBox(height: Gap.lg),
          const Divider(height: 1),
          const SizedBox(height: Gap.sm),
          for (final e in entries) _entry(context, t, scheme, lang, e),
        ],
      ),
    );
  }

  static DateTime? _atOf(Map<String, dynamic> e) =>
      DateTime.tryParse('${e['started_at'] ?? e['created_at'] ?? ''}')?.toLocal();

  Widget _entry(BuildContext context, AppLocalizations t, ColorScheme scheme,
      String lang, Map<String, dynamic> e) {
    final info = callInfoOf(e);
    final at = _atOf(e);
    final color = info.missed ? scheme.error : scheme.onSurfaceVariant;
    final dir = info.missed
        ? t.wa2CallMissed
        : info.outgoing
            ? t.wa2CallOutgoing
            : t.wa2CallIncoming;
    final kind = info.video ? t.wa2CallInfoVideo : t.wa2CallInfoVoice;
    final outcome = '${e['outcome'] ?? ''}';
    final right = info.talkSec > 0
        ? localDigits(callTalkLabel(info.talkSec), lang)
        : (info.missed ? '' : outcome);
    return Padding(
      key: ValueKey('wa2-call-entry-${e['id']}'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
                info.missed
                    ? Icons.call_missed_rounded
                    : info.outgoing
                        ? Icons.call_made_rounded
                        : Icons.call_received_rounded,
                size: 18,
                color: color),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$dir · $kind',
                    style: AType.bodyMedium.copyWith(
                        color: info.missed ? scheme.error : scheme.onSurface)),
                if (at != null)
                  Text(
                      '${dateChipLabel(t, at, lang: lang)}, ${fmtTime(at, lang)}',
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (right.isNotEmpty) ...[
            const SizedBox(width: Gap.sm),
            ConstrainedBox(
              // the talk time / outcome sits at the row's end (WhatsApp)
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.35),
              child: Text(right,
                  key: ValueKey('wa2-call-entry-right-${e['id']}'),
                  textAlign: TextAlign.end,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ],
        ],
      ),
    );
  }
}

/// One call, as the info screen reads it from a history row.
class CallInfoFacts {
  final bool outgoing, missed, video;
  final int talkSec;
  const CallInfoFacts(
      {required this.outgoing, required this.missed, required this.video, required this.talkSec});
}

/// Only an INCOMING unanswered call is "missed" (same rule as the log).
CallInfoFacts callInfoOf(Map<String, dynamic> e) {
  final state = '${e['state'] ?? 'ended'}';
  final outgoing = e['outgoing'] == true;
  final sec = (e['duration_sec'] as num?)?.toInt() ?? _parseMmSs('${e['duration'] ?? ''}');
  return CallInfoFacts(
    outgoing: outgoing,
    missed: !outgoing && (state == 'missed' || state == 'canceled'),
    video: '${e['kind'] ?? 'voice'}' == 'video',
    talkSec: sec,
  );
}

int _parseMmSs(String s) {
  // the server's "01:05" / "1:02:03" (maybe Bangla digits)
  final latin = String.fromCharCodes(s.codeUnits.map(
      (c) => c >= 0x09E6 && c <= 0x09EF ? 0x30 + c - 0x09E6 : c));
  final parts = latin.split(':').map(int.tryParse).toList();
  if (parts.isEmpty || parts.any((p) => p == null)) return 0;
  return parts.fold<int>(0, (a, p) => a * 60 + p!);
}

/// "4:07" / "1:02:03" (Latin digits; callers localize).
String callTalkLabel(int sec) {
  final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

class _Action extends StatelessWidget {
  const _Action({super.key, required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = onTap != null;
    final fg = on ? scheme.primary : scheme.onSurface.withValues(alpha: 0.38);
    return Semantics(
      button: true,
      enabled: on,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm, horizontal: Gap.xs),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: fg),
                  const SizedBox(height: Gap.xs),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: AType.labelMedium.copyWith(
                          color: on ? scheme.onSurface : fg, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
