import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../calls/call_sound_tiles.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';
import '../circle_privacy_screen.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

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
  bool _loadFailed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
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
      _loadFailed = false;
    } catch (e) {
      _loadFailed = true;
      _failCause = e;
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
      _load(); // re-read the server's truth instead of keeping a fake value
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
          : _loadFailed
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(honestFailText(t, _failCause, otherwise: t.msgLoadFailed), textAlign: TextAlign.center),
                    const SizedBox(height: Gap.md),
                    FilledButton(
                        onPressed: () {
                          setState(() => _loading = true);
                          _load();
                        },
                        child: Text(t.retry)),
                  ]),
                )
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
                // c2-calls: ringtone / Assisto melody (message sound: Notifications)
                const Divider(),
                const CallSoundsSection(),
              ],
            ),
    );
  }
}
