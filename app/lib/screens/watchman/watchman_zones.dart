import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctv1 ZONES DRAWN ON SCREEN: on the camera's check still (or its latest
/// alert photo, else a plain grid) the owner taps points to draw a
/// restricted area, a cash area or a 2-point entry line; plus the guard
/// schedule (days + hours), sensitivity and quiet hours. Saved to
/// ShopCamera.zone_config (schema v2, points normalised 0..1); the gateway
/// pulls it with its next config check.
class WatchmanZonesScreen extends StatefulWidget {
  final WatchmanSource source;
  final Map<String, dynamic> camera;
  const WatchmanZonesScreen({super.key, required this.source, required this.camera});

  @override
  State<WatchmanZonesScreen> createState() => _WatchmanZonesScreenState();
}

class _Zone {
  String type;
  List<Offset> points;
  _Zone(this.type, this.points);
}

class _WatchmanZonesScreenState extends State<WatchmanZonesScreen> {
  bool _loading = true;
  String? _loadError;
  String? _previewUrl;
  final List<_Zone> _zones = [];
  String _tool = 'restricted';
  List<Offset> _draft = [];
  bool _always = true;
  Set<int> _days = {0, 1, 2, 3, 4, 5, 6};
  TimeOfDay _start = const TimeOfDay(hour: 21, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 9, minute: 0);
  String _sens = 'medium';
  bool _quiet = false;
  TimeOfDay _qStart = const TimeOfDay(hour: 23, minute: 0);
  TimeOfDay _qEnd = const TimeOfDay(hour: 7, minute: 0);
  Map<String, dynamic> _tuning = const {};
  bool _saving = false;
  String? _saveError;

  int get _camId => (widget.camera['id'] as num).toInt();

  @override
  void initState() {
    super.initState();
    _load();
  }

  static TimeOfDay? _tod(Object? v) {
    final p = (v ?? '').toString().split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  static String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final z = await widget.source.zones(_camId);
      final cfg = wmMap(z['zone_config']);
      _tuning = wmMap(z['tuning']);
      _zones
        ..clear()
        ..addAll(wmList(cfg['zones']).map((m) => _Zone(
            (m['type'] ?? 'restricted').toString(),
            [
              for (final p in (m['points'] as List? ?? const []))
                if (p is List && p.length >= 2)
                  Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())
            ])));
      final s = cfg['schedule'];
      _always = s == null;
      if (s is Map) {
        _days = {for (final d in (s['days'] as List? ?? const [])) (d as num).toInt()};
        _start = _tod(s['start']) ?? _start;
        _end = _tod(s['end']) ?? _end;
      }
      _sens = (cfg['sensitivity'] ?? 'medium').toString();
      final q = cfg['quiet_hours'];
      _quiet = q is Map;
      if (q is Map) {
        _qStart = _tod(q['start']) ?? _qStart;
        _qEnd = _tod(q['end']) ?? _qEnd;
      }
    } catch (e) {
      _loadError = wmError(e) ?? '';
    }
    try {
      final p = await widget.source.preview(_camId);
      _previewUrl = (p['url'] ?? '').toString();
      if (_previewUrl!.isEmpty) _previewUrl = null;
    } catch (_) {
      _previewUrl = null; // honest: a blank grid + a hint
    }
    if (mounted) setState(() => _loading = false);
  }

  void _tap(Offset local, Size size) {
    final p = Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));
    setState(() {
      _draft = [..._draft, p];
      if (_tool == 'entry_line' && _draft.length == 2) _finish();
    });
  }

  void _finish() {
    final need = _tool == 'entry_line' ? 2 : 3;
    if (_draft.length < need) return;
    _zones.add(_Zone(_tool, _draft));
    _draft = [];
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final cfg = {
      'zones': [
        for (var i = 0; i < _zones.length; i++)
          {
            'id': 'z${i + 1}',
            'type': _zones[i].type,
            'points': [
              for (final p in _zones[i].points)
                [double.parse(p.dx.toStringAsFixed(4)), double.parse(p.dy.toStringAsFixed(4))]
            ],
          }
      ],
      'schedule': _always ? null : {'days': _days.toList()..sort(), 'start': _hhmm(_start), 'end': _hhmm(_end)},
      'sensitivity': _sens,
      'quiet_hours': _quiet ? {'start': _hhmm(_qStart), 'end': _hhmm(_qEnd)} : null,
    };
    try {
      await widget.source.saveZones(_camId, cfg);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.wmZonesSaved)));
      Navigator.of(context).pop(true);
      return;
    } catch (e) {
      _saveError = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<TimeOfDay?> _pick(TimeOfDay init) => showTimePicker(context: context, initialTime: init);

  String _zoneName(AppLocalizations t, String type) => switch (type) {
        'cash' => t.wmZoneCash,
        'entry_line' => t.wmZoneLine,
        _ => t.wmZoneRestricted,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final loc = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.wmZonesTitle((widget.camera['name'] ?? '').toString()))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
              if (_loadError != null)
                Text(_loadError!.isEmpty ? t.wmLoadErrorBody : _loadError!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              Text(t.wmZonesHowTo),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final z in const ['restricted', 'cash', 'entry_line'])
                  ChoiceChip(
                    label: Text(_zoneName(t, z)),
                    selected: _tool == z,
                    onSelected: (_) => setState(() {
                      _tool = z;
                      _draft = [];
                    }),
                  ),
              ]),
              const SizedBox(height: 8),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: LayoutBuilder(builder: (ctx, c) {
                  final size = Size(c.maxWidth, c.maxHeight);
                  return Semantics(
                    label: t.wmZonesCanvasLabel,
                    child: GestureDetector(
                      onTapUp: (d) => _tap(d.localPosition, size),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(fit: StackFit.expand, children: [
                          if (_previewUrl != null)
                            Image.network(_previewUrl!, fit: BoxFit.fill,
                                errorBuilder: (_, __, ___) => const _Grid())
                          else
                            const _Grid(),
                          CustomPaint(painter: _ZonePainter(_zones, _draft, _tool)),
                        ]),
                      ),
                    ),
                  );
                }),
              ),
              if (_previewUrl == null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(t.wmZonesNoPreview, style: Theme.of(context).textTheme.bodySmall),
                ),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.undo_rounded),
                  label: Text(t.wmUndoPoint),
                  onPressed: _draft.isEmpty ? null : () => setState(() => _draft = _draft.sublist(0, _draft.length - 1)),
                ),
                if (_tool != 'entry_line')
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.done_rounded),
                    label: Text(t.wmFinishZone),
                    onPressed: _draft.length < 3 ? null : () => setState(_finish),
                  ),
              ]),
              const SizedBox(height: 8),
              if (_zones.isEmpty) Text(t.wmNoZones, style: Theme.of(context).textTheme.bodySmall),
              for (var i = 0; i < _zones.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_zones[i].type == 'entry_line' ? Icons.horizontal_rule_rounded : Icons.pentagon_outlined,
                      color: _ZonePainter.colorOf(_zones[i].type)),
                  title: Text('${_zoneName(t, _zones[i].type)} ${wmDigits(lang, i + 1)}'),
                  trailing: IconButton(
                    tooltip: t.wmDeleteZone,
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => setState(() => _zones.removeAt(i)),
                  ),
                ),
              const Divider(height: 28),
              Text(t.wmScheduleTitle, style: Theme.of(context).textTheme.titleMedium),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.wmAlwaysOnGuard),
                subtitle: Text(t.wmAlwaysOnGuardBody),
                value: _always,
                onChanged: (v) => setState(() => _always = v),
              ),
              if (!_always) ...[
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (var d = 0; d < 7; d++)
                    FilterChip(
                      label: Text(DateFormat.E(lang).format(DateTime(2026, 10, 26 + d))),
                      selected: _days.contains(d),
                      onSelected: (v) => setState(() => v ? _days.add(d) : _days.remove(d)),
                    ),
                ]),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () async {
                      final v = await _pick(_start);
                      if (v != null) setState(() => _start = v);
                    },
                    child: Text(t.wmFrom(loc.formatTimeOfDay(_start))),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () async {
                      final v = await _pick(_end);
                      if (v != null) setState(() => _end = v);
                    },
                    child: Text(t.wmTo(loc.formatTimeOfDay(_end))),
                  ),
                ]),
                if (_days.isEmpty)
                  Text(t.wmPickADay, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const Divider(height: 28),
              Text(t.wmSensitivity, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'low', label: Text(t.wmSensLow)),
                  ButtonSegment(value: 'medium', label: Text(t.wmSensMedium)),
                  ButtonSegment(value: 'high', label: Text(t.wmSensHigh)),
                ],
                selected: {_sens},
                onSelectionChanged: (s) => setState(() => _sens = s.first),
              ),
              const SizedBox(height: 4),
              Text(t.wmSensHelp, style: Theme.of(context).textTheme.bodySmall),
              const Divider(height: 28),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.wmQuietHours),
                subtitle: Text(t.wmQuietHoursBody),
                value: _quiet,
                onChanged: (v) => setState(() => _quiet = v),
              ),
              if (_quiet)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () async {
                      final v = await _pick(_qStart);
                      if (v != null) setState(() => _qStart = v);
                    },
                    child: Text(t.wmFrom(loc.formatTimeOfDay(_qStart))),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () async {
                      final v = await _pick(_qEnd);
                      if (v != null) setState(() => _qEnd = v);
                    },
                    child: Text(t.wmTo(loc.formatTimeOfDay(_qEnd))),
                  ),
                ]),
              if (((_tuning['correct'] as num?) ?? 0) + ((_tuning['wrong'] as num?) ?? 0) > 0) ...[
                const Divider(height: 28),
                Text(t.wmLearned(wmDigits(lang, (_tuning['correct'] as num?)?.toInt() ?? 0),
                    wmDigits(lang, (_tuning['wrong'] as num?)?.toInt() ?? 0))),
              ],
              if (_saveError != null) ...[
                const SizedBox(height: 12),
                Text(_saveError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                onPressed: _saving || (!_always && _days.isEmpty) ? null : _save,
                child: _saving
                    ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Text(t.wmSave),
              ),
            ]),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid();
  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: CustomPaint(painter: _GridPainter(Theme.of(context).colorScheme.outlineVariant)),
      );
}

class _GridPainter extends CustomPainter {
  final Color color;
  _GridPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8, y = size.height * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

class _ZonePainter extends CustomPainter {
  final List<_Zone> zones;
  final List<Offset> draft;
  final String tool;
  _ZonePainter(this.zones, this.draft, this.tool);

  static Color colorOf(String type) => switch (type) {
        'cash' => const Color(0xFFE0A500),
        'entry_line' => const Color(0xFF22D3EE),
        _ => const Color(0xFFE0485A),
      };

  void _shape(Canvas c, Size s, String type, List<Offset> pts, {bool closed = true}) {
    if (pts.isEmpty) return;
    final col = colorOf(type);
    final px = [for (final p in pts) Offset(p.dx * s.width, p.dy * s.height)];
    final line = Paint()
      ..color = col
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    if (type == 'entry_line' || !closed) {
      for (var i = 0; i + 1 < px.length; i++) {
        c.drawLine(px[i], px[i + 1], line);
      }
    } else {
      final path = Path()..addPolygon(px, true);
      c.drawPath(path, Paint()..color = col.withValues(alpha: 0.28));
      c.drawPath(path, line);
    }
    for (final p in px) {
      c.drawCircle(p, 6, Paint()..color = Colors.white);
      c.drawCircle(p, 4, Paint()..color = col);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final z in zones) {
      _shape(canvas, size, z.type, z.points);
    }
    _shape(canvas, size, tool, draft, closed: false);
  }

  @override
  bool shouldRepaint(_ZonePainter old) => true;
}
