import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'fc_manage.dart'; // fcrest
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
    final ds = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
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
    // fcrest: Probashi both clocks + the 15 % battery last place
    final clocks = fcrBothClocks(context, member, now);
    final lastLoc = st.state == 'paused' ? null : fcrLastLocation(brain);
    final showReason = st.state != 'ok' && st.state != 'paused';
    final reason = showReason ? fcReason(context, st.reason, brain) : '';
    // designv2: white "alive" card (radius 12, V2 shadow) when all is well;
    // tinted + strong border for SOS / check; flat gray + dashed when stale.
    final bg = switch (st.state) {
      'sos' => ds.dangerBg,
      'check' => AssistoTokens.of(context).warningContainer,
      'stale' => scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      _ => ds.card,
    };
    final border = switch (st.state) {
      'sos' => BorderSide(color: ds.danger, width: 2),
      'check' => const BorderSide(color: Brand.warning, width: 1.5),
      'ok' => BorderSide(color: ds.success.withValues(alpha: 0.6)),
      _ => BorderSide(color: ds.border),
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
                        style: tx.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700, color: ds.text)),
                    if (place.isNotEmpty && !stale)
                      Text(place, style: tx.bodyMedium?.copyWith(color: ds.text)),
                    if (meta.isNotEmpty)
                      Text(meta, style: tx.bodySmall?.copyWith(color: ds.muted)),
                    if (clocks.isNotEmpty)
                      Text(clocks,
                          key: ValueKey('fcr-clocks-${member['user_id']}'),
                          style: tx.bodySmall?.copyWith(color: ds.muted)),
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
                  borderRadius: BorderRadius.circular(DsRadius.chip),
                ),
                child: Text(chip,
                    style: tx.labelLarge?.copyWith(color: ink)),
              ),
            ),
          ],
          if (lastLoc != null) ...[
            const SizedBox(height: Gap.sm),
            Column(
              key: ValueKey('fcr-lastloc-${member['user_id']}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.battery_alert_rounded, color: fcInk(context, 'check')),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(
                          t.fcrLastPlace(fcDigits(context, lastLoc['pct'] ?? brain['battery'] ?? 15),
                              fcClock(context, lastLoc['at'])),
                          style: tx.bodyMedium?.copyWith(color: ds.text)),
                    ),
                  ],
                ),
                TextButton.icon(
                  key: ValueKey('fcr-map-${member['user_id']}'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => fcrOpenMap(context, lastLoc),
                  icon: const Icon(Icons.map_rounded),
                  label: Text(t.fcrOpenMap),
                ),
              ],
            ),
          ],
          if (reason.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(reason,
                key: ValueKey('fc3-reason-${member['user_id']}'),
                style: tx.bodyMedium?.copyWith(color: ink, fontWeight: FontWeight.w600)),
          ],
          if (_hasButtons(st)) ...[
            const SizedBox(height: Gap.sm),
            // designv2: one even row of actions (never an odd second row);
            // labels wrap under their icon at large font.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in <Widget>[
                  if (stale && onFix != null)
                    _CardAction(
                      key: ValueKey('fc3-fix-${member['user_id']}'),
                      onPressed: onFix,
                      icon: Icons.build_circle_rounded,
                      label: t.fc3Fix,
                      primary: true,
                    ),
                  if (onCall != null)
                    _CardAction(
                      key: ValueKey('fc3-call-${member['user_id']}'),
                      onPressed: onCall,
                      icon: Icons.call_rounded,
                      label: t.fc3Call,
                    ),
                  if (onCareCall != null)
                    _CardAction(
                      onPressed: onCareCall,
                      icon: Icons.record_voice_over_rounded,
                      label: t.fc3CareCall,
                    ),
                  if (onLocation != null)
                    _CardAction(
                      onPressed: onLocation,
                      icon: Icons.place_rounded,
                      label: t.fc3Location,
                    ),
                ].indexed) ...[
                  if (a.$1 > 0) const SizedBox(width: Gap.sm),
                  Expanded(child: a.$2),
                ],
              ],
            ),
          ],
        ],
      ),
    );
    final a11y = t.fc3CardA11y(name, fcStateWord(t, st.state),
        [place, meta, clocks, reason].where((s) => s.isNotEmpty).join('. '));
    final radius = BorderRadius.circular(DsRadius.card);
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
        foregroundPainter: FcDashedBorder(color: scheme.outline, radius: DsRadius.card),
        child: card,
      );
    } else {
      final lite = DsPerf.liteOf(context);
      card = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: st.state == 'sos'
              ? (lite ? ds.liteShadows : ds.dangerGlow)
              : (lite ? ds.liteShadows : ds.shadows),
        ),
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
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
          ),
          // designv2: the live dot gently pulses (ok / SOS; still on lite).
          PositionedDirectional(
            end: -6,
            bottom: -6,
            child: DsStatusDot(
              color: fcDot(context, state),
              size: 14,
              pulse: state == 'ok' || state == 'sos',
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

/// designv2: an even action cell — icon over a wrapping label, ≥ 56 dp tall.
class _CardAction extends StatelessWidget {
  const _CardAction({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.primary = false,
  });
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final ds = DsTokens.of(context);
    final fg = primary ? ds.onPrimary : ds.primaryInk;
    final style = OutlinedButton.styleFrom(
      backgroundColor: primary ? ds.primaryInk : ds.primarySoft,
      foregroundColor: fg,
      side: BorderSide(color: primary ? ds.primaryInk : ds.border),
      minimumSize: const Size(kMinTap, 56),
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.sm),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DsRadius.button)),
    );
    return OutlinedButton(
      onPressed: onPressed,
      style: style,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 22),
        const SizedBox(height: Gap.xxs),
        Text(label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fg)),
      ]),
    );
  }
}
