import 'package:flutter/material.dart';

import '../calls/call_sound_tiles.dart';
import '../l10n/app_localizations.dart';
import '../widgets/msgr_set_tiles.dart';
import 'msg_native.dart';
import 'msg_prefs.dart';

/// c3-msg — "On this phone" block of My Circle → Settings → Notifications:
///   * Hide message content in notifications (privacy; device-level)
///   * Message sound: the ONE picker (c2-calls' [SoundPickTile], shared keys
///     snd_msg_uri / snd_msg_title — phone default, silent, or any phone
///     notification sound via the system picker; no bundled audio)
///   * Chat bubbles: global on/off (Android 11+) + the system bubble page.
class MsgDeviceNotifSection extends StatefulWidget {
  const MsgDeviceNotifSection({super.key});

  @override
  State<MsgDeviceNotifSection> createState() => _MsgDeviceNotifSectionState();
}

class _MsgDeviceNotifSectionState extends State<MsgDeviceNotifSection> {
  bool _hide = false;
  bool _bubbles = true;
  bool _bubblesSupported = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hide = await MsgPrefs.hideContent();
    final b = await MsgPrefs.bubblesOn();
    final sup = await MsgNative.bubblesSupported();
    if (!mounted) return;
    setState(() {
      _hide = hide;
      _bubbles = b;
      _bubblesSupported = sup;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MsgrSetSection(t.c3SetOnThisPhone),
        SwitchListTile(
          key: const Key('c3-hide-content'),
          secondary: const Icon(Icons.visibility_off_outlined),
          title: Text(t.c3SetHideContent),
          subtitle: Text(t.c3SetHideContentSub),
          value: _hide,
          onChanged: (v) async {
            setState(() => _hide = v);
            await MsgPrefs.setHideContent(v);
          },
        ),
        const SoundPickTile(kind: SoundPickKind.message),
        if (_bubblesSupported) ...[
          SwitchListTile(
            key: const Key('c3-bubbles-global'),
            secondary: const Icon(Icons.bubble_chart_outlined),
            title: Text(t.c3SetBubbles),
            subtitle: Text(t.c3SetBubblesSub),
            value: _bubbles,
            onChanged: (v) async {
              setState(() => _bubbles = v);
              await MsgPrefs.setBubblesOn(v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: Text(t.c3SetBubblesSystem),
            onTap: MsgNative.openBubbleSettings,
          ),
        ],
      ],
    );
  }
}
