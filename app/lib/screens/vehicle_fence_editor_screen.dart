import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/route_canvas.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/veh_map.dart';

/// veh100: draw a POLYGON geofence by tapping its corners on the real map
/// (3-50 points), name it and choose when to alert (entering, leaving or
/// both). Returns the fence map for the settings screen to save; the server
/// validates it again (size, points). Needs the configured map tiles — with
/// no tile provider it says so honestly and offers the circle instead.
class VehicleFenceEditorScreen extends StatefulWidget {
  final double? centerLat, centerLng;
  const VehicleFenceEditorScreen({super.key, this.centerLat, this.centerLng});

  @override
  State<VehicleFenceEditorScreen> createState() => _VehicleFenceEditorScreenState();
}

class _VehicleFenceEditorScreenState extends State<VehicleFenceEditorScreen> {
  static const maxPoints = 50;
  VehMapConfig? _cfg;
  final List<GeoPt> _pts = [];
  final _name = TextEditingController();
  String _alert = 'both';

  @override
  void initState() {
    super.initState();
    VehMapConfig.load(context.read<AppState>().api).then((c) {
      if (mounted) setState(() => _cfg = c);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(context, {
      'id': 'p${DateTime.now().millisecondsSinceEpoch % 100000}',
      'name': _name.text.trim(),
      'alert': _alert,
      'points': [
        for (final p in _pts) [p.lat, p.lng]
      ],
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cfg = _cfg;
    final center = (widget.centerLat != null && widget.centerLng != null)
        ? GeoPt(widget.centerLat!, widget.centerLng!)
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(tr.v100FenceDraw)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: FilledButton(
            key: const ValueKey('veh-fence-save'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _pts.length >= 3 ? _save : null,
            child: Text(tr.save),
          ),
        ),
      ),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : !cfg.hasTiles
              ? Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Text(tr.v100FenceNoMap,
                      style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
                )
              : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                  Text(tr.v100FenceDrawHelp,
                      style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
                  const SizedBox(height: Gap.sm),
                  AspectRatio(
                    aspectRatio: 1,
                    child: VehMap(
                      config: cfg,
                      route: const [],
                      live: center,
                      fences: [
                        if (_pts.length >= 3)
                          GeoFenceView(_pts.first.lat, _pts.first.lng, 0, '', points: _pts),
                        for (final p in _pts) GeoFenceView(p.lat, p.lng, 8, ''),
                      ],
                      semanticsLabel:
                          tr.v100FenceA11y(vehNumStr(context, _pts.length)),
                      onTap: (p) {
                        if (_pts.length < maxPoints) setState(() => _pts.add(p));
                      },
                    ),
                  ),
                  const SizedBox(height: Gap.xs),
                  Row(children: [
                    Expanded(
                      child: Text(tr.v100FencePoints(vehNumStr(context, _pts.length)),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: _pts.isEmpty ? null : () => setState(() => _pts.removeLast()),
                      icon: const Icon(Icons.undo_rounded),
                      label: Text(tr.v100FenceUndo),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: _pts.isEmpty ? null : () => setState(() => _pts.clear()),
                      child: Text(tr.v100FenceClear),
                    ),
                  ]),
                  const SizedBox(height: Gap.sm),
                  TextField(
                    controller: _name,
                    maxLength: 40,
                    decoration: InputDecoration(labelText: tr.vehFenceName),
                  ),
                  Text(tr.v100FenceWhen, style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: Gap.xs),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    for (final a in const ['both', 'enter', 'exit'])
                      ChoiceChip(
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        label: Text(switch (a) {
                          'enter' => tr.v100FenceAlertEnter,
                          'exit' => tr.v100FenceAlertExit,
                          _ => tr.v100FenceAlertBoth,
                        }),
                        selected: _alert == a,
                        onSelected: (_) => setState(() => _alert = a),
                      ),
                  ]),
                ]),
    );
  }
}
