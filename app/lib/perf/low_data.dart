// faststart (owner 10 Nov, item 6): "Low-data mode" — one switch in
// Settings. ON = optional pictures (Home Discover cards, sponsor cards) show
// only when already saved on the phone (no new downloads), and My Circle
// calls use the low-data call profile. Stored on the phone (SharedPreferences),
// read once after the first frame; never on the cold-start path.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calls/call_data_prefs.dart';
import '../l10n/app_localizations.dart';

class LowDataMode {
  LowDataMode._();

  static const key = 'low_data_mode';

  /// Current value (false until [load] ran — the safe default: images load).
  static final ValueNotifier<bool> on = ValueNotifier<bool>(false);

  /// test seam
  static Future<SharedPreferences> Function() prefs =
      SharedPreferences.getInstance;

  static bool _loaded = false;

  /// Read the stored switch once (never throws).
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      on.value = (await prefs()).getBool(key) ?? false;
    } catch (_) {}
  }

  static Future<void> set(bool v) async {
    on.value = v;
    _loaded = true;
    try {
      await (await prefs()).setBool(key, v);
    } catch (_) {}
    // one switch for the user: calls follow it too
    await CallDataPrefs.setLowData(v);
  }

  @visibleForTesting
  static void resetForTest() {
    _loaded = false;
    on.value = false;
    prefs = SharedPreferences.getInstance;
  }
}

/// Settings switch: "Low-data mode".
class LowDataTile extends StatefulWidget {
  const LowDataTile({super.key});

  @override
  State<LowDataTile> createState() => _LowDataTileState();
}

class _LowDataTileState extends State<LowDataTile> {
  @override
  void initState() {
    super.initState();
    LowDataMode.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: LowDataMode.on,
      builder: (context, v, _) => SwitchListTile(
        key: const Key('low-data-mode-setting'),
        secondary: const Icon(Icons.data_saver_on_rounded),
        title: Text(t.fsLowDataTitle),
        subtitle: Text(t.fsLowDataSub),
        isThreeLine: true,
        value: v,
        onChanged: (nv) => LowDataMode.set(nv),
      ),
    );
  }
}
