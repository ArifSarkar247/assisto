import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';
import '../circle_privacy_screen.dart';

/// Call preferences for the hub: turn incoming calls on/off, and silence
/// unknown callers (ring suppressed for people outside the circle — they still
/// show in the calls list). Mirrored to the server via
/// [MessengerSettingsApi.callPrefs] / setCallPrefs; who-can-call lives in the
/// existing [CirclePrivacyScreen] and is linked, not duplicated.
class MsgrSetCallsScreen extends StatefulWidget {
  const MsgrSetCallsScreen({super.key});

  @override
  State<MsgrSetCallsScreen> createState() => _MsgrSetCallsScreenState();
}

class _MsgrSetCallsScreenState extends State<MsgrSetCallsScreen> {
  bool _loading = true;
  bool _synced = true;
  bool _incoming = true;
  bool _silenceUnknown = false;

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.callPrefs();
      _incoming = r['incoming_calls'] != false;
      _silenceUnknown = r['silence_unknown'] == true;
      _synced = true;
    } catch (_) {
      _synced = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    try {
      await _api.setCallPrefs({
        'incoming_calls': _incoming,
        'silence_unknown': _silenceUnknown,
      });
      _synced = true;
    } catch (_) {
      _synced = false;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetCalls)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.call_received_outlined),
                  title: Text(t.msgrSetCallsIncoming),
                  subtitle: Text(t.msgrSetCallsIncomingSub),
                  value: _incoming,
                  onChanged: (v) {
                    setState(() => _incoming = v);
                    _save();
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.phone_disabled_outlined),
                  title: Text(t.msgrSetCallsSilenceUnknown),
                  subtitle: Text(t.msgrSetCallsSilenceUnknownSub),
                  value: _silenceUnknown,
                  onChanged: (v) {
                    setState(() => _silenceUnknown = v);
                    _save();
                  },
                ),
                const Divider(),
                MsgrSetRow(
                  icon: Icons.lock_outline,
                  title: t.msgrSetCallsWhoCanCall,
                  subtitle: t.msgrSetCallsWhoCanCallSub,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const CirclePrivacyScreen())),
                ),
                if (!_synced) MsgrSetNote(t.msgrSetNotSynced),
              ],
            ),
    );
  }
}
