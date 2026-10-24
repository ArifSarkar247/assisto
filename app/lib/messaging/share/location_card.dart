import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../date_separators.dart' show fmtDate, localDigits;
import 'live_location.dart';
import 'share_payload.dart';

/// mc-media2 — opening a shared point: the phone's own maps app (geo:) first,
/// the browser (maps.google.com/?q=) when no maps app answers. No maps API key,
/// nothing loaded from a tile server.
class LocationOpener {
  LocationOpener._();

  /// Seam for tests: returns whether something opened the URI.
  static Future<bool> Function(Uri uri) launcher = (uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  };

  static Future<bool> open(LocationShare s) async {
    if (await launcher(s.geoUri)) return true;
    return launcher(s.webUri);
  }
}

String _lang(BuildContext c) => Localizations.localeOf(c).languageCode;

/// "Updated just now / 5 min ago / at 3:05 PM".
String liveUpdatedText(AppLocalizations t, LocationShare s, DateTime now, String lang) {
  if (s.at <= 0) return '';
  final at = DateTime.fromMillisecondsSinceEpoch(s.at);
  final mins = now.difference(at).inMinutes;
  if (mins < 1) return t.mc2UpdatedNow;
  if (mins < 60) return t.mc2UpdatedMin(localDigits('$mins', lang));
  return t.mc2UpdatedAt(fmtDate('h:mm a', at, lang));
}

/// The bubble body of a location message: a drawn (offline) map-style
/// preview with the pin, the place label, the coordinates, the accuracy,
/// "Open in Maps", and for a LIVE share its end / last update — plus "Stop
/// sharing" on the sender's own phone while the share runs here.
class LocationCard extends StatefulWidget {
  final LocationShare share;
  final bool mine;
  final Color fg;
  final String? messageId; // for the sender's Stop button
  final DateTime Function()? clock; // tests
  const LocationCard({
    super.key,
    required this.share,
    required this.mine,
    required this.fg,
    this.messageId,
    this.clock,
  });

  @override
  State<LocationCard> createState() => _LocationCardState();
}

class _LocationCardState extends State<LocationCard> {
  Timer? _tick;
  bool _stopping = false;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _armTick();
  }

  @override
  void didUpdateWidget(LocationCard old) {
    super.didUpdateWidget(old);
    _armTick();
  }

  void _armTick() {
    // a live card re-draws itself once a minute ("updated N min ago", the end)
    if (widget.share.live && _tick == null && widget.clock == null) {
      _tick = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    final ok = await LocationOpener.open(widget.share);
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).mc2OpenFailed)));
    }
  }

  Future<void> _stop() async {
    final id = widget.messageId;
    if (id == null) return;
    setState(() => _stopping = true);
    final ok = await LiveLocation.instance.stop(id);
    if (!mounted) return;
    setState(() => _stopping = false);
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).mc2StopFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = _lang(context);
    final s = widget.share;
    final now = _now;
    final liveNow = s.isLiveAt(now);
    final scheme = Theme.of(context).colorScheme;
    final title = s.label.isNotEmpty
        ? s.label
        : (s.live ? t.circleAttachLiveLocation : t.circleAttachLocation);
    final lines = <String>[];
    if (s.live) {
      lines.add(liveNow
          ? t.mc2LiveUntil(fmtDate('h:mm a', DateTime.fromMillisecondsSinceEpoch(s.until), lang))
          : t.mc2LiveEnded);
      final up = liveUpdatedText(t, s, now, lang);
      if (up.isNotEmpty) lines.add(up);
    }
    final muted = widget.fg.withValues(alpha: 0.78);
    return ValueListenableBuilder<Map<String, LiveSession>>(
      valueListenable: LiveLocation.instance.sessions,
      builder: (context, active, _) {
        final canStop = widget.mine &&
            liveNow &&
            widget.messageId != null &&
            active.containsKey(widget.messageId);
        return SizedBox(
          width: 248,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: '${t.mc2OpenInMaps}: $title',
                child: InkWell(
                  key: const Key('mc2-loc-open-map'),
                  borderRadius: BorderRadius.circular(Radii.md),
                  onTap: _open,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.md),
                    child: SizedBox(
                      height: 120,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _MapCardPainter(
                          live: liveNow,
                          dark: Theme.of(context).brightness == Brightness.dark,
                          seed: (s.lat * 1000).round() ^ (s.lng * 1000).round(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Gap.sm),
              Row(children: [
                Icon(s.live ? Icons.my_location : Icons.location_on,
                    size: 18, color: liveNow ? const Color(0xFF16A34A) : widget.fg),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(title,
                      key: const Key('mc2-loc-title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: widget.fg, fontWeight: FontWeight.w600, fontSize: 14)),
                ),
              ]),
              const SizedBox(height: 2),
              Text(localDigits(s.coords, lang),
                  key: const Key('mc2-loc-coords'),
                  style: TextStyle(color: muted, fontSize: 12)),
              if (s.accuracy != null && s.accuracy! > 0)
                Text(t.mc2Accuracy(localDigits('${s.accuracy!.round()}', lang)),
                    style: TextStyle(color: muted, fontSize: 12)),
              for (final l in lines)
                Text(l,
                    key: Key('mc2-loc-live-${lines.indexOf(l)}'),
                    style: TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.xs, runSpacing: 0, children: [
                TextButton.icon(
                  key: const Key('mc2-loc-open'),
                  style: TextButton.styleFrom(
                      foregroundColor: widget.mine ? widget.fg : scheme.primary,
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      minimumSize: const Size(48, 40)),
                  onPressed: _open,
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(t.mc2OpenInMaps),
                ),
                if (canStop)
                  TextButton.icon(
                    key: const Key('mc2-loc-stop'),
                    style: TextButton.styleFrom(
                        foregroundColor: widget.mine ? widget.fg : scheme.error,
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                        minimumSize: const Size(48, 40)),
                    onPressed: _stopping ? null : _stop,
                    icon: _stopping
                        ? const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.stop_circle_outlined, size: 18),
                    label: Text(t.mc2StopSharing),
                  ),
              ]),
              if (canStop)
                Text(t.mc2ForegroundNote,
                    key: const Key('mc2-loc-fg-note'),
                    style: TextStyle(color: muted, fontSize: 11, height: 1.3)),
            ],
          ),
        );
      },
    );
  }
}

/// A calm, map-like drawing (streets + blocks + a pin) — no tiles, no key,
/// nothing downloaded. Deterministic per point so a card never "changes map".
class _MapCardPainter extends CustomPainter {
  final bool live;
  final bool dark;
  final int seed;
  _MapCardPainter({required this.live, required this.dark, required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = dark ? const Color(0xFF1E293B) : const Color(0xFFE8EEF4);
    final block = dark ? const Color(0xFF273449) : const Color(0xFFD9E3EC);
    final park = dark ? const Color(0xFF1F3B2F) : const Color(0xFFCDE8D3);
    final road = dark ? const Color(0xFF475569) : Colors.white;
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final rnd = math.Random(seed);
    for (var i = 0; i < 7; i++) {
      final r = Rect.fromLTWH(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height,
          30 + rnd.nextDouble() * 60, 18 + rnd.nextDouble() * 30);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)),
          Paint()..color = i == 0 ? park : block);
    }
    final p = Paint()
      ..color = road
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final y = size.height * (0.2 + 0.3 * i) + rnd.nextDouble() * 10;
      canvas.drawLine(Offset(0, y), Offset(size.width, y + rnd.nextDouble() * 20 - 10), p);
    }
    for (var i = 0; i < 3; i++) {
      final x = size.width * (0.15 + 0.32 * i) + rnd.nextDouble() * 14;
      canvas.drawLine(Offset(x, 0), Offset(x + rnd.nextDouble() * 24 - 12, size.height), p);
    }
    final c = Offset(size.width / 2, size.height / 2 + 6);
    final pin = live ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    canvas.drawCircle(c, 22, Paint()..color = pin.withValues(alpha: 0.16));
    canvas.drawCircle(c + const Offset(0, 2), 4, Paint()..color = Colors.black26);
    final path = Path()
      ..moveTo(c.dx, c.dy)
      ..cubicTo(c.dx - 4, c.dy - 8, c.dx - 13, c.dy - 14, c.dx - 13, c.dy - 24)
      ..arcToPoint(Offset(c.dx + 13, c.dy - 24), radius: const Radius.circular(13))
      ..cubicTo(c.dx + 13, c.dy - 14, c.dx + 4, c.dy - 8, c.dx, c.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = pin);
    canvas.drawCircle(Offset(c.dx, c.dy - 24), 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_MapCardPainter old) =>
      old.live != live || old.dark != dark || old.seed != seed;
}
