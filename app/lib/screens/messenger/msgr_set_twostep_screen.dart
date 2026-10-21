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

/// Two-step verification PIN (set / change / turn off). The PIN lives ONLY on
/// the server, as a Django password hash ([MessengerSettingsApi.twoStepSet]);
/// nothing is kept on the device. Changing or turning off an enabled PIN asks
/// for the current one, and the server rate-limits wrong tries (5, then a
/// 15-minute lock). It is required to confirm a number change.
class MsgrSetTwoStepScreen extends StatefulWidget {
  const MsgrSetTwoStepScreen({super.key});

  @override
  State<MsgrSetTwoStepScreen> createState() => _MsgrSetTwoStepScreenState();
}

class _MsgrSetTwoStepScreenState extends State<MsgrSetTwoStepScreen> {
  bool _loading = true;
  bool _loadFailed = false;
  bool _enabled = false;
  bool _busy = false;
  int _lockedSec = 0;

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    // Older builds kept a plaintext copy of the PIN on the device; wipe it.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('msgr_twostep_pin');
      await prefs.remove('msgr_twostep_enabled');
    } catch (_) {}
    try {
      final r = await _api.twoStepStatus();
      _enabled = r['enabled'] == true;
      _lockedSec = (r['retry_after_sec'] as num?)?.toInt() ?? 0;
    } catch (_) {
      _loadFailed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

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
    String? current;
    if (_enabled) {
      current = await _askPin(_t.msgTwoStepCurrentPin);
      if (current == null || current.isEmpty) return;
    }
    if (!mounted) return;
    final pin = await _askPin(_t.msgrSetTwoStepEnterNew);
    if (pin == null || pin.length < 6) {
      if (pin != null && mounted) _snack(_t.msgrSetTwoStepTooShort);
      return;
    }
    if (!mounted) return;
    final confirm = await _askPin(_t.msgrSetTwoStepConfirm);
    if (confirm != pin) {
      if (mounted) _snack(_t.msgrSetTwoStepMismatch);
      return;
    }
    await _persist(enabled: true, pin: pin, current: current);
  }

  Future<void> _turnOff() async {
    final current = await _askPin(_t.msgTwoStepCurrentPin);
    if (current == null || current.isEmpty) return;
    await _persist(enabled: false, current: current);
  }

  Future<void> _persist(
      {required bool enabled, String? pin, String? current}) async {
    setState(() => _busy = true);
    try {
      final r = await _api.twoStepSet(
          enabled: enabled, pin: pin, currentPin: current);
      _enabled = r['enabled'] == true;
      if (mounted) {
        _snack(_enabled ? _t.msgrSetTwoStepOn : _t.msgrSetTwoStepOff);
      }
    } on ApiException catch (e) {
      if (mounted) {
        if (e.status == 429) {
          _snack(_t.msgTwoStepLocked);
        } else if (e.status == 403) {
          _snack(_t.msgTwoStepWrongPin);
        } else {
          _snack(e.message.isNotEmpty ? e.message : _t.grpActionFailed);
        }
      }
    } catch (_) {
      if (mounted) _snack(_t.grpActionFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetTwoStepTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(t.msgLoadFailed, textAlign: TextAlign.center),
                    const SizedBox(height: Gap.md),
                    FilledButton(onPressed: _load, child: Text(t.retry)),
                  ]),
                )
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
                if (_lockedSec > 0) MsgrSetNote(t.msgTwoStepLocked),
                MsgrSetNote(t.msgrSetTwoStepHashNote,
                    icon: Icons.verified_user_outlined),
              ],
            ),
    );
  }
}
