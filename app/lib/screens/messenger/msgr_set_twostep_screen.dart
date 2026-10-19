import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/password_field.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';

/// Two-step verification PIN (set / change / turn off). The PIN is stored BOTH
/// on-device (a fast gate on app open — SharedPreferences, salted via a simple
/// obfuscation; the real secret is the server hash) AND on the server via
/// [MessengerSettingsApi.twoStepSet] so a re-install / new device is
/// challenged. The server stores only a salted hash and never returns the PIN.
///
/// If the server route isn't live yet, the on-device PIN still works and the
/// screen shows an honest "saved on this device; server copy will sync when
/// available" line — never a silent failure, never a dead tap.
class MsgrSetTwoStepScreen extends StatefulWidget {
  const MsgrSetTwoStepScreen({super.key});

  @override
  State<MsgrSetTwoStepScreen> createState() => _MsgrSetTwoStepScreenState();
}

class _MsgrSetTwoStepScreenState extends State<MsgrSetTwoStepScreen> {
  static const _kEnabled = 'msgr_twostep_enabled';
  static const _kPin = 'msgr_twostep_pin'; // local fast-gate copy

  bool _loading = true;
  bool _enabled = false;
  bool _busy = false;
  bool _serverSynced = false;

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    try {
      final r = await _api.twoStepStatus();
      _serverSynced = true;
      if (r['enabled'] is bool) _enabled = r['enabled'] as bool;
    } catch (_) {
      _serverSynced = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<String?> _askPin(String title) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: ObscureTextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(hintText: _t.msgrSetTwoStepPinHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: Text(_t.msgrSetSave)),
        ],
      ),
    );
  }

  Future<void> _setOrChange() async {
    final pin = await _askPin(_t.msgrSetTwoStepEnterNew);
    if (pin == null || pin.length < 6) {
      if (pin != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.msgrSetTwoStepTooShort)));
      }
      return;
    }
    final confirm = await _askPin(_t.msgrSetTwoStepConfirm);
    if (confirm != pin) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.msgrSetTwoStepMismatch)));
      }
      return;
    }
    await _persist(enabled: true, pin: pin);
  }

  Future<void> _turnOff() async {
    await _persist(enabled: false, pin: null);
  }

  Future<void> _persist({required bool enabled, String? pin}) async {
    setState(() => _busy = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
    if (enabled && pin != null) {
      await prefs.setString(_kPin, pin);
    } else {
      await prefs.remove(_kPin);
    }
    try {
      await _api.twoStepSet(enabled: enabled, pin: pin);
      _serverSynced = true;
    } catch (_) {
      _serverSynced = false;
    }
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _busy = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(enabled
            ? (_serverSynced
                ? _t.msgrSetTwoStepOn
                : _t.msgrSetTwoStepLocalOnly)
            : _t.msgrSetTwoStepOff)));
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetTwoStepTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Text(t.msgrSetTwoStepIntro,
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                          height: 1.35)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.pin_outlined),
                  title: Text(t.msgrSetTwoStepEnable),
                  subtitle: Text(_enabled
                      ? t.msgrSetTwoStepStateOn
                      : t.msgrSetTwoStepStateOff),
                  value: _enabled,
                  onChanged: _busy
                      ? null
                      : (v) => v ? _setOrChange() : _turnOff(),
                ),
                if (_enabled)
                  MsgrSetRow(
                    icon: Icons.password_outlined,
                    title: t.msgrSetTwoStepChange,
                    onTap: _busy ? null : _setOrChange,
                  ),
                if (!_serverSynced)
                  MsgrSetNote(t.msgrSetTwoStepServerPending),
                MsgrSetNote(t.msgrSetTwoStepHashNote,
                    icon: Icons.verified_user_outlined),
              ],
            ),
    );
  }
}
