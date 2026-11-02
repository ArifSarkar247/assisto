import 'package:flutter/material.dart';

import '../calls/call_sound_tiles.dart';
import '../l10n/app_localizations.dart';
import '../widgets/msgr_set_tiles.dart';
import 'msg_native.dart';
import 'msg_prefs.dart';
import 'date_separators.dart' show localDigits; // bubbles
import 'link_preview_client.dart'; // circlea

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
  bool _previews = true; // circlea
  bool _bubbles = true;
  bool _bubblesSupported = false;
  bool _loaded = false; // bubbles: no "needs Android 11" flash before load
  int _offChats = 0; // bubbles: chats whose bubble the user turned off

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hide = await MsgPrefs.hideContent();
    final b = await MsgPrefs.bubblesOn();
    final sup = await MsgNative.bubblesSupported();
    final pv = await LinkPreviewPrefs.on(); // circlea
    final off = (await MsgPrefs.bubbleOffChats()).length;
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _offChats = off;
      _previews = pv;
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
          secondary: const Icon(Icons.visibility_off_rounded),
          title: Text(t.c3SetHideContent),
          subtitle: Text(t.c3SetHideContentSub),
          value: _hide,
          onChanged: (v) async {
            setState(() => _hide = v);
            await MsgPrefs.setHideContent(v);
          },
        ),
        const SoundPickTile(kind: SoundPickKind.message),
        // circlea: previews are built on this phone and sent encrypted
        SwitchListTile(
          key: const Key('cla-link-previews'),
          secondary: const Icon(Icons.link_rounded),
          title: Text(t.claLinkPreviewsSetting),
          subtitle: Text(t.claLinkPreviewsSettingSub),
          value: _previews,
          onChanged: (v) async {
            setState(() => _previews = v);
            await LinkPreviewPrefs.set(v);
          },
        ),
        if (_bubblesSupported) ...[
          SwitchListTile(
            key: const Key('c3-bubbles-global'),
            secondary: const Icon(Icons.bubble_chart_rounded),
            title: Text(t.c3SetBubbles),
            subtitle: Text(t.bblSetSub),
            value: _bubbles,
            onChanged: (v) async {
              setState(() => _bubbles = v);
              await MsgPrefs.setBubblesOn(v);
            },
          ),
          // bubbles: every chat is ON by default; chats turned off from the
          // chat's ⋮ menu are counted here with one tap to undo them all.
          if (_bubbles && _offChats > 0)
            ListTile(
              key: const Key('bbl-all-on'),
              leading: const Icon(Icons.restart_alt_rounded),
              title: Text(t.bblAllOn),
              subtitle: Text(t.bblOffCount(localDigits(
                  '$_offChats', Localizations.localeOf(context).languageCode))),
              onTap: () async {
                final messenger = ScaffoldMessenger.maybeOf(context);
                await MsgPrefs.clearBubbleOffChats();
                if (!mounted) return;
                setState(() => _offChats = 0);
                messenger?.showSnackBar(SnackBar(content: Text(t.bblAllOnDone)));
              },
            ),
          ListTile(
            leading: const Icon(Icons.open_in_new_rounded),
            title: Text(t.c3SetBubblesSystem),
            onTap: MsgNative.openBubbleSettings,
          ),
        ] else if (_loaded && Theme.of(context).platform == TargetPlatform.android)
          // Android 10 and below: say so honestly instead of a dead switch.
          ListTile(
            key: const Key('bbl-unsupported'),
            leading: const Icon(Icons.info_outline_rounded),
            title: Text(t.c3SetBubbles),
            subtitle: Text(t.bblUnsupported),
          ),
      ],
    );
  }
}
