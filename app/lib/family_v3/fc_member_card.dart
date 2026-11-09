import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'fc_status.dart';
import 'fc_text.dart';

/// fcscreen — one member card (owner order d + e). The state is RE-CHECKED
/// with the phone's clock at build time ([fcRecheck]): stale data is a gray
/// card with a DASHED border, the reason in plain words and a fix button.
class FcMemberCard extends StatelessWidget {
  final Map<String, dynamic> member;
  final DateTime now;
  final VoidCallback? onTap;
  final VoidCallback? onCall;
  final VoidCallback? onCareCall;
  final VoidCallback? onLocation;
  final VoidCallback? onFix;
  const FcMemberCard({
    super.key,
    required this.member,
    required this.now,
    this.onTap,
    this.onCall,
    this.onCareCall,
    this.onLocation,
    this.onFix,
  });

  String _name(AppLocalizations t) {
    if (member['me'] == true) return t.fc3You;
    final l = '${member['label'] ?? ''}'.trim();
    return l.isNotEmpty ? l : '${member['name'] ?? ''}';
  }

  String? _chip(BuildContext context, FcStatus st) {
    final t = AppLocalizations.of(context);
    if (st.state == 'stale') return t.fc3StateStale;
    final c = member['chip'];
    if (c is! Map) return st.state == 'paused' ? t.fc3ChipPaused : null;
    final pk = fcPlace(context, {'place_kind': c['place_kind'], 'place_label': c['place']});
    final place = pk.isNotEmpty ? pk : '${c['place'] ?? ''}'.trim();
    final auto = c['auto'] == true ? ' · ${t.fc3ChipAuto}' : '';
    return switch ('${c['kind']}') {
      'arrived' => '${t.fc3ChipArrived(place, fcClock(context, c['at']))}$auto',
      'left' => '${t.fc3ChipLeft(place, fcClock(context, c['at']))}$auto',
      'journey' => c['eta'] != null
          ? t.fc3ChipJourney(fcClock(context, c['eta']))
          : t.fc3ChipJourneyNoEta,
      'carecall_done' => t.fc3ChipCareDone,
      'carecall_missed' => t.fc3ChipCareMissed,
      'paused' => t.fc3ChipPaused,
      'no_news' => t.fc3StateStale,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final st = fcRecheck(member, now);
    final brain = (member['brain'] as Map?) ?? const {};
    final name = _name(t);
    final stale = st.state == 'stale';
    final ink = fcInk(context, st.state);
    final seen = fcParseTs(brain['last_seen']);
    final place = fcPlace(context, brain);
    final batt = brain['battery'];
    final chip = _chip(context, st);
    final meta = <String>[
      if (seen != null) t.fc3Seen(fcAgo(context, seen, now)),
      if (batt != null)
        brain['charging'] == true
            ? '${t.fc3Battery(fcDigits(context, batt))} · ${t.fc3Charging}'
            : t.fc3Battery(fcDigits(context, batt)),
    ].join(' · ');
    final showReason = st.state != 'ok' && st.state != 'paused';
    final reason = showReason ? fcReason(context, st.reason, brain) : '';
    final bg = switch (st.state) {
      'sos' => Brand.danger.withValues(alpha: 0.10),
      'check' => Brand.warning.withValues(alpha: 0.10),
      'stale' => scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      _ => scheme.surfaceContainerLow,
    };
    final border = switch (st.state) {
      'sos' => const BorderSide(color: Brand.danger, width: 2),
      'check' => const BorderSide(color: Brand.warning, width: 1.5),
      'ok' => BorderSide(color: Brand.success.withValues(alpha: 0.6)),
      _ => BorderSide(color: scheme.outlineVariant),
    };
    final body = Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(name: name, state: st.state),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    if (place.isNotEmpty && !stale)
                      Text(place, style: TextStyle(color: scheme.onSurface)),
                    if (meta.isNotEmpty)
                      Text(meta,
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          if (chip != null) ...[
            const SizedBox(height: Gap.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                key: ValueKey('fc3-chip-${member['user_id']}'),
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
                decoration: BoxDecoration(
                  color: ink.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(chip,
                    style: TextStyle(color: ink, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ),
          ],
          if (reason.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(reason,
                key: ValueKey('fc3-reason-${member['user_id']}'),
                style: TextStyle(color: ink, fontWeight: FontWeight.w600)),
          ],
          if (_hasButtons(st)) ...[
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              children: [
                if (stale && onFix != null)
                  FilledButton.tonalIcon(
                    key: ValueKey('fc3-fix-${member['user_id']}'),
                    onPressed: onFix,
                    icon: const Icon(Icons.build_circle_rounded),
                    label: Text(t.fc3Fix),
                  ),
                if (onCall != null)
                  OutlinedButton.icon(
                    key: ValueKey('fc3-call-${member['user_id']}'),
                    onPressed: onCall,
                    icon: const Icon(Icons.call_rounded),
                    label: Text(t.fc3Call),
                  ),
                if (onCareCall != null)
                  OutlinedButton.icon(
                    onPressed: onCareCall,
                    icon: const Icon(Icons.record_voice_over_rounded),
                    label: Text(t.fc3CareCall),
                  ),
                if (onLocation != null)
                  OutlinedButton.icon(
                    onPressed: onLocation,
                    icon: const Icon(Icons.place_rounded),
                    label: Text(t.fc3Location),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    final a11y = t.fc3CardA11y(name, fcStateWord(t, st.state),
        [place, meta, reason].where((s) => s.isNotEmpty).join('. '));
    final radius = BorderRadius.circular(16);
    Widget card = Material(
      color: bg,
      shape: stale ? RoundedRectangleBorder(borderRadius: radius)
          : RoundedRectangleBorder(borderRadius: radius, side: border),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: body),
    );
    if (stale) {
      card = CustomPaint(
        key: ValueKey('fc3-dashed-${member['user_id']}'),
        foregroundPainter: FcDashedBorder(color: scheme.outline, radius: 16),
        child: card,
      );
    }
    return Semantics(
      container: true,
      label: a11y,
      child: KeyedSubtree(
        key: ValueKey('fc3-member-${member['user_id']}-${st.state}'),
        child: card,
      ),
    );
  }

  bool _hasButtons(FcStatus st) =>
      (st.state == 'stale' && onFix != null) ||
      onCall != null ||
      onCareCall != null ||
      onLocation != null;
}

class _Avatar extends StatelessWidget {
  final String name;
  final String state;
  const _Avatar({required this.name, required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: scheme.primaryContainer,
            child: Text(fcInitial(name),
                style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 20)),
          ),
          PositionedDirectional(
            end: 0,
            bottom: 0,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: fcDot(context, state),
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dashed rounded border — the "no fresh news" look (owner order e).
class FcDashedBorder extends CustomPainter {
  final Color color;
  final double radius;
  const FcDashedBorder({required this.color, this.radius = 16});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final rr = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius)).deflate(0.8);
    final path = Path()..addRRect(rr);
    for (final PathMetric m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 7, m.length)), p);
        d += 12;
      }
    }
  }

  @override
  bool shouldRepaint(FcDashedBorder old) => old.color != color || old.radius != radius;
}
