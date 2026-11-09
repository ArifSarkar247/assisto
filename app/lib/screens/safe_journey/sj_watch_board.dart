import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../messaging/media/voice_player.dart';
import '../../state.dart';
import '../../theme.dart';
import '../journey_watch_screen.dart';
import '../../widgets/journey_ride.dart' show jDigits;
import 'sj_during_api.dart';

/// sjduring — the WATCHER side of Safe Journey V2.
///
/// [SjBoardExtras] adds the V2 lines to a watcher card on
/// [JourneyWatchScreen]: amber "Check on NAME" / red "Urgent — call now",
/// the arrival window, the green "No alert even if late" note when the
/// traveller is nearly there and stopped, the finished-list badges
/// (Confirmed with PIN = green shield; Unusually fast arrival, PIN asked =
/// amber) and the 30-second audio after a danger PIN.
///
/// [SjActiveJourneysTile] is the "journeys on the way" count for the Family
/// screen (fcscreen): count from GET /journey/watch-board, tap -> the
/// watcher screen. Never a dead tile: with nobody travelling it says so and
/// still opens the list (which explains how to start one).
class SjBoardExtras extends StatefulWidget {
  final Map<String, dynamic> card;
  const SjBoardExtras({super.key, required this.card});

  @override
  State<SjBoardExtras> createState() => _SjBoardExtrasState();
}

class _SjBoardExtrasState extends State<SjBoardExtras> {
  bool _loadingAudio = false;

  Future<void> _play() async {
    if (_loadingAudio) return;
    setState(() => _loadingAudio = true);
    final t = AppLocalizations.of(context);
    final msg = ScaffoldMessenger.maybeOf(context);
    final api = context.read<AppState>().api;
    try {
      final r = await api.sjDangerAudio((widget.card['id'] as num).toInt());
      final b64 = '${r['audio_b64'] ?? ''}';
      if (b64.isEmpty) throw StateError('empty');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/sjd_watch_${widget.card['id']}.m4a');
      await f.writeAsBytes(base64Decode(b64), flush: true);
      final ok = await VoicePlayer.instance.toggle(f.path);
      if (!ok) throw StateError('play');
    } catch (_) {
      msg?.showSnackBar(SnackBar(content: Text(t.sjdAudioFailed)));
    } finally {
      if (mounted) setState(() => _loadingAudio = false);
    }
  }

  Widget _chip(BuildContext context, IconData icon, String text, Color color, Key key) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: color.withValues(alpha: 0.5))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: Brand.onTint(context, color)),
        const SizedBox(width: Gap.xs),
        Flexible(
            child: Text(text,
                style: AType.bodyMedium.copyWith(
                    color: Brand.onTint(context, color), fontWeight: FontWeight.w600))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final c = widget.card;
    final cs = Theme.of(context).colorScheme;
    final active = c['status'] == 'active';
    final badges = (c['badges'] as List?)?.map((e) => '$e').toSet() ?? const <String>{};
    final from = sjClock(context, c['window_from'] as String?);
    final to = sjClock(context, c['window_to'] as String?);
    final why = sjPhoneOffWhy(t, c);
    final kids = <Widget>[
      if (active && c['level'] == 'red')
        _chip(context, Icons.warning_rounded, t.sjdLevelRed, cs.error, const ValueKey('sjd_red')),
      if (active && c['level'] == 'amber')
        _chip(context, Icons.help_rounded, t.sjdLevelAmber('${c['name'] ?? ''}'),
            Brand.warning, const ValueKey('sjd_amber')),
      if (active && from.isNotEmpty && to.isNotEmpty)
        Text(t.sjdWindow(from, to),
            key: const ValueKey('sjd_window'),
            style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
      // sjp0: the earliest possible arrival (C) under the window
      if (active && from.isNotEmpty && sjClock(context, c['earliest_at'] as String?).isNotEmpty)
        Text(t.qjEarliest(sjClock(context, c['earliest_at'] as String?)),
            key: const ValueKey('sjd_earliest'),
            style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
      if (active && why.isNotEmpty) Text(why, style: AType.bodyMedium),
      if (active && c['near_note'] == true)
        Text(t.sjdNearNote,
            key: const ValueKey('sjd_near_note'),
            style: AType.bodyMedium.copyWith(color: Brand.successFill, fontWeight: FontWeight.w600)),
      if (badges.contains('pin_ok'))
        _chip(context, Icons.verified_user_rounded, t.sjdBadgePin, Brand.success,
            const ValueKey('sjd_badge_pin')),
      if (badges.contains('fast_pin'))
        _chip(context, Icons.speed_rounded, t.sjdBadgeFast, Brand.warning,
            const ValueKey('sjd_badge_fast')),
      if (c['audio'] == true)
        OutlinedButton.icon(
          key: const ValueKey('sjd_play_audio'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: _loadingAudio
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow_rounded),
          label: Text(t.sjdPlayAudio),
          onPressed: _play,
        ),
    ];
    if (kids.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: kids),
    );
  }
}

/// Family screen: "Active journeys (N)" + the first names, one tap to the
/// watcher screen. Pass [api]-free: reads the app's client.
class SjActiveJourneysTile extends StatefulWidget {
  const SjActiveJourneysTile({super.key});

  @override
  State<SjActiveJourneysTile> createState() => _SjActiveJourneysTileState();
}

class _SjActiveJourneysTileState extends State<SjActiveJourneysTile> {
  Map<String, dynamic>? _b;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final b = await context.read<AppState>().api.sjWatchBoard();
      if (mounted) setState(() => _b = b);
    } catch (_) {
      if (mounted) setState(() => _b = const {'count': 0, 'active': []});
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final b = _b;
    if (b == null) return const SizedBox.shrink();
    final n = (b['count'] as num?)?.toInt() ?? 0;
    final rows = [for (final r in (b['active'] as List? ?? const [])) if (r is Map) r];
    final red = rows.any((r) => r['level'] == 'red');
    final amber = rows.any((r) => r['level'] == 'amber');
    final color = red
        ? Theme.of(context).colorScheme.error
        : amber
            ? Brand.warnInk(context)
            : Theme.of(context).colorScheme.primary;
    return Card(
      key: const ValueKey('sjd_family_tile'),
      child: ListTile(
        minTileHeight: 56,
        leading: Icon(Icons.route_rounded, color: color),
        title: Text(t.sjdActiveCount(jDigits(context, n)),
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
        subtitle: Text(n == 0
            ? t.sjdFamilyNone
            : rows.map((r) => '${r['name']}: ${sjStateLook(context, t, r.cast<String, dynamic>()).label}').join(' · ')),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const JourneyWatchScreen()));
          if (mounted) unawaited(_load());
        },
      ),
    );
  }
}
