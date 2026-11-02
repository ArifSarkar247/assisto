import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import 'call_log.dart';

/// callsbar: "Low-data calls" (WhatsApp: "Use less data for calls").
///
/// Stored on the phone (no server round trip — works offline, read in a few
/// ms before a call starts). ON = voice at 16 kbit/s (12 on a poor network)
/// and video at 200 kbit/s, 15 fps, half resolution — for BOTH directions:
/// the other phone is told through the call's `media` signal.
class CallDataPrefs {
  CallDataPrefs._();

  static const key = 'calls_low_data';

  /// test seam
  static Future<SharedPreferences> Function() prefs =
      SharedPreferences.getInstance;

  static Future<bool> lowData() async {
    try {
      return (await prefs()).getBool(key) ?? false;
    } catch (e) {
      callLog('call_data_prefs#1', e);
      return false;
    }
  }

  static Future<void> setLowData(bool on) async {
    try {
      await (await prefs()).setBool(key, on);
    } catch (e) {
      callLog('call_data_prefs#2', e);
    }
  }
}

/// "~1.4 MB" / "~৮৫০ KB" for [bytes] — digits are localized by the caller.
String callDataAmount(int bytes) {
  if (bytes < 1024 * 1024) {
    final kb = (bytes / 1024).round();
    return '${kb < 1 ? 1 : kb} KB';
  }
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round().toString()} MB';
}

/// The settings switch (Messenger settings -> Calls). Self-contained: reads
/// and writes [CallDataPrefs]; the next call uses it.
class CallLowDataTile extends StatefulWidget {
  const CallLowDataTile({super.key});

  @override
  State<CallLowDataTile> createState() => _CallLowDataTileState();
}

class _CallLowDataTileState extends State<CallLowDataTile> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    CallDataPrefs.lowData().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SwitchListTile(
      key: const Key('calls-low-data-setting'),
      secondary: const Icon(Icons.data_saver_on_rounded),
      title: Text(t.cbarLowDataTitle),
      subtitle: Text(t.cbarLowDataSub),
      value: _on,
      onChanged: (v) {
        setState(() => _on = v);
        CallDataPrefs.setLowData(v);
      },
    );
  }
}
