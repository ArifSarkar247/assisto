import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../missing_alert_api.dart';
import '../../services/missing_nearby_sync.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/permission_reason.dart';
import 'ma_common.dart';

/// missing (owner 2 Nov) — "Nearby safety alerts" opt-in (also reachable
/// from Settings). Honest: Assisto has NO background location. We keep only
/// a COARSE home area (a district, or a point rounded to about 1 km) and,
/// only if switched on, the area of the phone when Assisto is OPEN (rounded,
/// forgotten after 12 hours). Turning it off deletes all of it.
class MissingOptinScreen extends StatefulWidget {
  const MissingOptinScreen({super.key, this.locate});
  final Future<({double lat, double lng})?> Function()? locate;

  @override
  State<MissingOptinScreen> createState() => _MissingOptinScreenState();
}

class _MissingOptinScreenState extends State<MissingOptinScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  bool _enabled = false;
  bool _openLoc = false;
  bool _hasPoint = false;
  String _district = '';
  ({double lat, double lng})? _newPoint;
  List<Map<String, dynamic>> _districts = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.maPref();
      if (!mounted) return;
      final p = (r['pref'] is Map) ? Map<String, dynamic>.from(r['pref'] as Map) : <String, dynamic>{};
      setState(() {
        _enabled = p['enabled'] == true;
        _openLoc = p['use_open_location'] == true;
        _hasPoint = p['has_point'] == true;
        _district = '${p['district'] ?? ''}';
        _districts = maRows(r, 'districts');
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

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<({double lat, double lng})?> _locate() async {
    if (widget.locate != null) return widget.locate!();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      // Play: in-app disclosure before Android's prompt (play_disclosure_guard)
      final perm = await askLocationWithReason(context);
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
      return (lat: p.latitude, lng: p.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _useHere() async {
    final t = AppLocalizations.of(context);
    final p = await _locate();
    if (!mounted) return;
    if (p == null) {
      _snack(t.maLocationFailed);
      return;
    }
    setState(() => _newPoint = (lat: maCoarse(p.lat), lng: maCoarse(p.lng)));
    _snack(t.maOptinPointSet);
  }

  Future<void> _toggleOpen(bool v) async {
    final t = AppLocalizations.of(context);
    if (v) {
      // ask for the permission ONCE, here, with the reason on screen
      final p = await _locate();
      if (!mounted) return;
      if (p == null) {
        _snack(t.maLocationFailed);
        return;
      }
    }
    setState(() => _openLoc = v);
  }

  Future<void> _save({bool? enabled}) async {
    final t = AppLocalizations.of(context);
    final on = enabled ?? _enabled;
    if (on && _district.isEmpty && _newPoint == null && !_hasPoint) {
      _snack(t.maErrArea);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await _api.maSetPref({
        'enabled': on,
        if (_district.isNotEmpty) 'district': _district,
        if (_newPoint != null) 'lat': _newPoint!.lat,
        if (_newPoint != null) 'lng': _newPoint!.lng,
        'use_open_location': on && _openLoc,
      });
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['ok'] == true) {
        await MissingNearbySync.setEnabled(on && _openLoc);
        if (!mounted) return;
        final p = (r['pref'] is Map) ? Map<String, dynamic>.from(r['pref'] as Map) : <String, dynamic>{};
        setState(() {
          _enabled = p['enabled'] == true;
          _hasPoint = p['has_point'] == true;
          _openLoc = p['use_open_location'] == true;
          _district = '${p['district'] ?? _district}';
          _newPoint = null;
        });
        _snack(_enabled ? t.maOptinSaved : t.maOptinOffSaved);
      } else {
        _snack(maReason(t, r['reason'] as String?));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(t.maErrGeneric);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.maOptinTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: MaError(onRetry: _load))
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
                  children: [
                    Text(t.maOptinIntro, style: text.bodyMedium),
                    const SizedBox(height: Gap.md),
                    SwitchListTile(
                      key: const ValueKey('ma-optin-switch'),
                      contentPadding: EdgeInsets.zero,
                      value: _enabled,
                      onChanged: _busy
                          ? null
                          : (v) {
                              if (v) {
                                setState(() => _enabled = true);
                              } else {
                                _save(enabled: false);
                              }
                            },
                      title: Text(t.maOptinSwitch),
                      subtitle: Text(_enabled ? t.maOptinSwitchOn : t.maOptinSwitchOff),
                    ),
                    if (_enabled) ...[
                      const SizedBox(height: Gap.sm),
                      DropdownButtonFormField<String>(
                        key: const ValueKey('ma-optin-district'),
                        initialValue: _district.isEmpty ? null : _district,
                        isExpanded: true,
                        decoration: InputDecoration(
                            labelText: t.maOptinDistrict, border: const OutlineInputBorder()),
                        items: [
                          for (final d in _districts)
                            DropdownMenuItem(value: '${d['code']}', child: Text('${d['name']}')),
                        ],
                        onChanged: (v) => setState(() => _district = v ?? ''),
                      ),
                      const SizedBox(height: Gap.sm),
                      OutlinedButton.icon(
                        key: const ValueKey('ma-optin-here'),
                        onPressed: _useHere,
                        icon: const Icon(Icons.my_location_rounded),
                        label: Text(_newPoint != null || _hasPoint ? t.maOptinPointUpdate : t.maOptinPointSetCta),
                      ),
                      Text(t.maOptinPointHelp, style: text.bodySmall),
                      const SizedBox(height: Gap.sm),
                      SwitchListTile(
                        key: const ValueKey('ma-optin-open'),
                        contentPadding: EdgeInsets.zero,
                        value: _openLoc,
                        onChanged: _toggleOpen,
                        title: Text(t.maOptinOpen),
                        subtitle: Text(t.maOptinOpenSub),
                      ),
                      const SizedBox(height: Gap.md),
                      ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
                        child: FilledButton(
                          key: const ValueKey('ma-optin-save'),
                          onPressed: _busy ? null : () => _save(),
                          child: Text(t.maOptinSave),
                        ),
                      ),
                    ],
                    const SizedBox(height: Gap.lg),
                    Text(t.maOptinWhatWeKeep, style: text.titleSmall),
                    const SizedBox(height: Gap.xs),
                    Text(t.maOptinWhatWeKeepBody),
                    const SizedBox(height: Gap.lg),
                    const MaWhoGetsCard(),
                  ],
                ),
    );
  }
}
