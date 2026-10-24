import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// a1-circle — 1:1 call events INSIDE the chat timeline, like WhatsApp
/// (owner bug report #4): "Missed voice call · 10:05", "Voice call · 3:12".
///
/// Source: GET circle/calls?member=<edge id> -> {events:[{id, kind,
/// outgoing, category, duration_sec, started_at}]} — the server already
/// collapses glare / double-placement duplicates; [parseCallEvents] drops
/// any repeated id as well. Tapping a chip calls back with the SAME kind.
class CallEvent {
  final int id;
  final String kind; // voice | video
  final bool outgoing;

  /// answered | missed | no_answer | declined | busy | failed
  final String category;
  final int durationSec;
  final DateTime at;
  const CallEvent({
    required this.id,
    required this.kind,
    required this.outgoing,
    required this.category,
    required this.durationSec,
    required this.at,
  });

  bool get video => kind == 'video';

  /// Red: an incoming call I missed.
  bool get missed => category == 'missed';
}

List<CallEvent> parseCallEvents(Object? body) {
  final raw = body is Map ? body['events'] : null;
  if (raw is! List) return const [];
  final seen = <int>{};
  final out = <CallEvent>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final id = int.tryParse('${e['id'] ?? ''}');
    final at = DateTime.tryParse('${e['started_at'] ?? ''}')?.toLocal();
    if (id == null || at == null || !seen.add(id)) continue;
    out.add(CallEvent(
      id: id,
      kind: '${e['kind'] ?? 'voice'}' == 'video' ? 'video' : 'voice',
      outgoing: e['outgoing'] == true,
      category: '${e['category'] ?? ''}',
      durationSec: (e['duration_sec'] as num?)?.toInt() ?? 0,
      at: at,
    ));
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

String _digits(String ascii, String lang) {
  if (lang != 'bn') return ascii;
  const bnZero = 0x09E6;
  final b = StringBuffer();
  for (final cu in ascii.codeUnits) {
    b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? bnZero + (cu - 0x30) : cu);
  }
  return b.toString();
}

/// m:ss (h:mm:ss over an hour), Bangla digits in bn.
String callDuration(int sec, String lang) {
  final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
  final ss = s.toString().padLeft(2, '0');
  final v = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  return _digits(v, lang);
}

/// The chip's main label: "Missed voice call", "Voice call · 3:12",
/// "Video call · No answer", "Voice call · Declined"…
String callEventLabel(AppLocalizations t, CallEvent e, String lang) {
  final kind = e.video ? t.a1CallVideo : t.a1CallVoice;
  switch (e.category) {
    case 'missed':
      return e.video ? t.a1CallMissedVideo : t.a1CallMissedVoice;
    case 'answered':
      return e.durationSec > 0
          ? '$kind · ${callDuration(e.durationSec, lang)}'
          : kind;
    case 'no_answer':
      return '$kind · ${t.a1CallNoAnswer}';
    case 'declined':
      return '$kind · ${t.a1CallDeclined}';
    case 'busy':
      return '$kind · ${t.a1CallBusy}';
    case 'failed':
      return '$kind · ${t.a1CallFailed}';
    default:
      return kind;
  }
}

IconData callEventIcon(CallEvent e) {
  // direction first (the kind is the trailing call-back icon)
  if (e.missed) return Icons.call_missed;
  return e.outgoing ? Icons.call_made : Icons.call_received;
}

/// Centred event chip in the chat timeline. [onCallBack] null = calls are
/// not open for this chat (no dead tap: the chip is then not tappable).
class CallEventChip extends StatelessWidget {
  final CallEvent event;
  final VoidCallback? onCallBack;
  const CallEventChip({super.key, required this.event, this.onCallBack});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final red = dark ? const Color(0xFFF87171) : const Color(0xFFB91C1C);
    final fg = event.missed ? red : scheme.onSurface;
    final time = DateFormat.Hm(lang == 'bn' ? 'bn' : 'en').format(event.at);
    final label = callEventLabel(t, event, lang);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(callEventIcon(event), size: 16, color: event.missed ? red : scheme.primary),
        const SizedBox(width: Gap.sm),
        Flexible(
          child: Text(label,
              key: const Key('a1-call-label'),
              style: AType.labelLarge
                  .copyWith(fontWeight: FontWeight.w600, color: fg)),
        ),
        const SizedBox(width: Gap.sm),
        Text(time,
            style: AFonts.figures(AType.labelMedium)!
                .copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(width: Gap.sm),
        // the kind; brand-coloured when it calls back on tap
        Icon(event.video ? Icons.videocam : Icons.call,
            size: 16,
            color: onCallBack != null ? scheme.primary : scheme.onSurfaceVariant),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Center(
        child: Semantics(
          button: onCallBack != null,
          hint: onCallBack != null ? t.a1CallBack : null,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('a1-call-${event.id}'),
              borderRadius: BorderRadius.circular(Radii.pill),
              onTap: onCallBack,
              // f3: the pill stays compact; its tap area is 48 dp tall
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Gap.xxxl),
                child: Align(widthFactor: 1, heightFactor: 1, child: chip),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
