import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../widgets/app_sheet.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvalerts (W3) — per-camera ALERT TYPES: person / vehicle / animal /
/// line / loitering / sound and camera health (covered / moved / dark / SD).
/// The server says, per vendor, what this camera can really report; a type
/// it cannot report shows "Not on this camera" with the switch disabled —
/// never pretended. Shapes mirror backend/core/cctv_alerts.py.
abstract class AlertTypesSource {
  Future<Map<String, dynamic>> load(int cameraId);
  Future<Map<String, dynamic>> save(int cameraId, Map<String, bool> types);
}

class ApiAlertTypesSource implements AlertTypesSource {
  final ApiClient api;
  ApiAlertTypesSource(this.api);
  @override
  Future<Map<String, dynamic>> load(int cameraId) =>
      api.getJson('/shop/cameras/$cameraId/alert-types');
  @override
  Future<Map<String, dynamic>> save(int cameraId, Map<String, bool> types) =>
      api.postJson('/shop/cameras/$cameraId/alert-types', {'types': types});
}

const _health = {'covered', 'moved', 'dark', 'sd_fail'};

IconData _icon(String kind) => switch (kind) {
      'person' => Icons.person_rounded,
      'vehicle' => Icons.directions_car_rounded,
      'animal' => Icons.pets_rounded,
      'line' => Icons.linear_scale_rounded,
      'loiter' => Icons.nightlight_round,
      'sound' => Icons.volume_up_rounded,
      'covered' => Icons.visibility_off_rounded,
      'moved' => Icons.screen_rotation_alt_rounded,
      'dark' => Icons.dark_mode_rounded,
      'sd_fail' => Icons.sd_card_alert_rounded,
      _ => Icons.notifications_rounded,
    };

/// The settings row that opens the screen (camera settings + zones screen).
class CameraAlertTypesTile extends StatelessWidget {
  final int cameraId;
  final String cameraName;
  final AlertTypesSource? source;
  const CameraAlertTypesTile(
      {super.key, required this.cameraId, required this.cameraName, this.source});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 12,
      leading: const Icon(Icons.tune_rounded),
      title: Text(t.cxatEntry),
      subtitle: Text(t.cxatEntrySub),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CameraAlertTypesScreen(
              cameraId: cameraId, cameraName: cameraName, source: source))),
    );
  }
}

class CameraAlertTypesScreen extends StatefulWidget {
  final int cameraId;
  final String cameraName;
  final AlertTypesSource? source;
  const CameraAlertTypesScreen(
      {super.key, required this.cameraId, required this.cameraName, this.source});

  @override
  State<CameraAlertTypesScreen> createState() => _CameraAlertTypesScreenState();
}

class _CameraAlertTypesScreenState extends State<CameraAlertTypesScreen> {
  late final AlertTypesSource _src;
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;
  final Set<String> _saving = {};

  @override
  void initState() {
    super.initState();
    _src = widget.source ?? ApiAlertTypesSource(context.read<AppState>().api);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final d = await _src.load(widget.cameraId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  List<Map<String, dynamic>> get _types => ((_data?['types'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();

  Future<void> _toggle(String kind, bool on) async {
    final t = AppLocalizations.of(context);
    final before = _data;
    final types = {for (final r in _types) r['kind'].toString(): r['on'] == true};
    types[kind] = on;
    setState(() {
      _saving.add(kind);
      _data = {
        ...?_data,
        'types': [
          for (final r in _types) r['kind'] == kind ? {...r, 'on': on} : r,
        ],
      };
    });
    try {
      final d = await _src.save(widget.cameraId, types);
      if (!mounted) return;
      setState(() => _data = d);
    } catch (e) {
      if (!mounted) return;
      setState(() => _data = before);
      final msg = e is ApiException && e.message.isNotEmpty ? e.message : t.cxatSaveFailed;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _saving.remove(kind));
    }
  }

  /// cctvaicheck: the per-camera "Check with AI" switch (server words).
  Map<String, dynamic> get _ai => (_data?['ai_check'] as Map?)?.cast<String, dynamic>() ?? const {};

  Future<void> _toggleAi(bool on) async {
    final t = AppLocalizations.of(context);
    final before = _data;
    final types = <String, bool>{
      for (final r in _types) r['kind'].toString(): r['on'] == true,
      'ai_check': on,
    };
    setState(() {
      _saving.add('ai_check');
      _data = {
        ...?_data,
        'ai_check': {..._ai, 'on': on},
      };
    });
    try {
      final d = await _src.save(widget.cameraId, types);
      if (!mounted) return;
      setState(() => _data = d);
    } catch (e) {
      if (!mounted) return;
      setState(() => _data = before);
      final msg = e is ApiException && e.message.isNotEmpty ? e.message : t.cxatSaveFailed;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _saving.remove('ai_check'));
    }
  }

  Widget _aiRow() {
    final ai = _ai;
    final ready = ai['ready'] == true;
    final scheme = Theme.of(context).colorScheme;
    return SwitchListTile(
      key: const ValueKey('cxat_ai_check'),
      contentPadding: EdgeInsets.zero,
      secondary: Icon(Icons.auto_awesome_rounded,
          color: ready ? scheme.primary : scheme.onSurfaceVariant),
      value: ready && ai['on'] == true,
      title: Text((ai['title'] ?? '').toString()),
      subtitle: Text((ai['note'] ?? '').toString(),
          style: TextStyle(color: scheme.onSurfaceVariant)),
      onChanged: !ready || _saving.contains('ai_check') ? null : _toggleAi,
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final kind = r['kind'].toString();
    final available = r['available'] == true;
    final scheme = Theme.of(context).colorScheme;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(_icon(kind),
          color: available ? scheme.primary : scheme.onSurfaceVariant),
      value: available && r['on'] == true,
      title: Text((r['label'] ?? kind).toString()),
      subtitle: Text((r['note'] ?? '').toString(),
          style: TextStyle(
              color: available ? scheme.onSurfaceVariant : scheme.error,
              fontWeight: available ? FontWeight.normal : FontWeight.w600)),
      onChanged: !available || _saving.contains(kind) ? null : (v) => _toggle(kind, v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final theme = Theme.of(context);
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_failed || _data == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_rounded, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(t.cxatLoadFailed, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.cxatRetry),
            ),
          ]),
        ),
      );
    } else {
      final rows = _types;
      final seen = rows.where((r) => !_health.contains(r['kind'])).toList();
      final health = rows.where((r) => _health.contains(r['kind'])).toList();
      final night = (_data!['night'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (_data!['line_today'] as Map?)?.cast<String, dynamic>() ?? const {};
      final sd = (_data!['sd'] as Map?)?.cast<String, dynamic>() ?? const {};
      String n(Object? v) => wmDigits(lang, (v as num?)?.toInt() ?? 0);
      body = ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
        children: [
          Text(t.cxatIntro, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          Text(t.cxatSeenHead, style: theme.textTheme.titleMedium),
          ...seen.map(_row),
          if (night.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.bedtime_rounded, size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        t.cxatNight((night['text'] ?? '').toString(),
                            (night['start'] ?? '').toString(), (night['end'] ?? '').toString()),
                        style: theme.textTheme.bodySmall)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.linear_scale_rounded, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(t.cxatLineToday(n(line['total']), n(line['a_to_b']), n(line['b_to_a'])),
                      style: theme.textTheme.bodySmall)),
            ]),
          ),
          if (_ai.isNotEmpty && (_ai['title'] ?? '').toString().isNotEmpty) ...[
            const Divider(height: 28),
            _aiRow(),
          ],
          const Divider(height: 28),
          Text(t.cxatHealthHead, style: theme.textTheme.titleMedium),
          ...health.map(_row),
          if ((sd['text'] ?? '').toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(sd['state'] == 'problem' ? Icons.sd_card_alert_rounded : Icons.sd_card_rounded,
                    size: 20,
                    color: sd['state'] == 'problem'
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(sd['text'].toString(), style: theme.textTheme.bodySmall)),
              ]),
            ),
          // "no AI looks at your pictures" is only true while the AI check is off
          if (!(_ai['ready'] == true && _ai['on'] == true)) ...[
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline_rounded, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(t.cxatNoAi, style: theme.textTheme.bodySmall)),
            ]),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.cxatTitle(widget.cameraName))),
      body: body,
    );
  }
}
