import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../theme.dart';
import '../widgets/journey_ride.dart' show jDigits;
import 'maps_api.dart';

/// mapscost — "Road time with traffic": ONE Google Routes call, only when the
/// user taps (owner order 3 Nov 18:40; the server caches it 10 min and caps
/// it per day). The free own-speed estimate above keeps working without it.
/// When the call is off / capped / fails, the button becomes "Open directions
/// in Google Maps" (free) — never a dead end.
class RoadEtaButton extends StatefulWidget {
  final ApiClient api;
  final double fromLat, fromLng, toLat, toLng;
  final String mode;
  const RoadEtaButton({super.key, required this.api, required this.fromLat,
      required this.fromLng, required this.toLat, required this.toLng, this.mode = ''});

  @override
  State<RoadEtaButton> createState() => _RoadEtaButtonState();
}

class _RoadEtaButtonState extends State<RoadEtaButton> {
  bool _busy = false;
  int? _min;
  String? _gmaps; // set when the paid answer is not available

  String get _dirUrl =>
      'https://www.google.com/maps/dir/?api=1&destination='
      '${widget.toLat.toStringAsFixed(6)},${widget.toLng.toStringAsFixed(6)}';

  Future<void> _ask() async {
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await widget.api.mapsEta(widget.fromLat, widget.fromLng, widget.toLat, widget.toLng,
          mode: widget.mode);
    } catch (_) {
      r = const {'state': 'failed'};
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      final ok = r['state'] == 'ok' || r['state'] == 'cache';
      _min = ok && r['minutes'] is num ? (r['minutes'] as num).toInt() : null;
      _gmaps = _min == null ? ('${r['gmaps_url'] ?? ''}'.isEmpty ? _dirUrl : '${r['gmaps_url']}') : null;
    });
  }

  Future<void> _open() async {
    try {
      await launchUrl(Uri.parse(_gmaps ?? _dirUrl), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) showActionFailed(context, 'maps.directions', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    if (_min != null) {
      return Text(t.mapscRoadEtaResult(jDigits(context, _min!)),
          key: const ValueKey('mc_eta_result'), style: AType.bodyMedium);
    }
    if (_gmaps != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.mapscRoadEtaCapped, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
        TextButton.icon(
          key: const ValueKey('mc_eta_open'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.directions_rounded),
          label: Text(t.mapscRoadEtaOpen),
          onPressed: _open,
        ),
      ]);
    }
    return TextButton.icon(
      key: const ValueKey('mc_eta_ask'),
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      icon: _busy
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.traffic_rounded),
      label: Text(t.mapscRoadEta),
      onPressed: _busy ? null : _ask,
    );
  }
}
