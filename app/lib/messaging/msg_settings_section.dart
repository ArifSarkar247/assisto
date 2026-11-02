import 'package:flutter/material.dart';

import '../calls/call_sound_tiles.dart';
import '../l10n/app_localizations.dart';
import '../widgets/msgr_set_tiles.dart';
import 'bubble_ask.dart'; // bubbles2
import 'bubble_card.dart'; // bubbles2
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
            title: Text(t.bbl2SettingsTitle),
            subtitle: Text(t.bbl2SetSub),
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
          // bubbles2 (point 6): what the PHONE allows, always with
          // "Turn on" while it isn't on (Android: the user picks "All
          // conversations can bubble" on the system page).
          if (_bubbles) const BubbleStatusTile(),
        ] else if (_loaded && Theme.of(context).platform == TargetPlatform.android)
          // Android 10 and below: say so honestly instead of a dead switch.
          ListTile(
            key: const Key('bbl-unsupported'),
            leading: const Icon(Icons.info_outline_rounded),
            title: Text(t.bbl2SettingsTitle),
            subtitle: Text(t.bblUnsupported),
          ),
      ],
    );
  }
}

/// bubbles2: the phone's bubble state in My Circle settings — "on" (tap:
/// the system page to change it), an honest "this phone blocks bubbles",
/// or "Turn on" (the card in a sheet). Re-checks when the app resumes.
class BubbleStatusTile extends StatefulWidget {
  const BubbleStatusTile({super.key, this.initial});
  final BubbleStatus? initial;

  @override
  State<BubbleStatusTile> createState() => _BubbleStatusTileState();
}

class _BubbleStatusTileState extends State<BubbleStatusTile> {
  BubbleStatus? _st;
  AppLifecycleListener? _life;

  @override
  void initState() {
    super.initState();
    _st = widget.initial;
    if (_st == null) _load();
    _life = AppLifecycleListener(onResume: _load);
  }

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await BubbleAsk.status();
    if (mounted) setState(() => _st = s);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ready = _st?.ready ?? BubbleReady.unknown;
    switch (ready) {
      case BubbleReady.on:
        return ListTile(
          key: const Key('bbl2-set-on'),
          leading: const Icon(Icons.check_circle_rounded),
          title: Text(t.bbl2On),
          subtitle: Text(t.c3SetBubblesSystem),
          onTap: MsgNative.openBubbleSettings,
        );
      case BubbleReady.blocked:
        return ListTile(
          key: const Key('bbl2-set-blocked'),
          leading: const Icon(Icons.info_outline_rounded),
          title: Text(t.bbl2Blocked),
        );
      case BubbleReady.unsupported:
        return const SizedBox.shrink();
      default:
        // 200 % text: the button sits under the text, never squeezed beside it
        return Column(
          key: const Key('bbl2-set-off'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.bubble_chart_outlined),
              title: Text(t.bbl2SettingsOff),
              subtitle: ready == BubbleReady.selectedOnly
                  ? Text(t.bbl2SelectedOnly)
                  : ready == BubbleReady.notifsOff
                      ? Text(t.bbl2NotifsOff)
                      : null,
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(72, 0, 16, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton(
                  key: const Key('bbl2-set-turn-on'),
                  style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
                  onPressed: () async {
                    await showBubbleCard(context, initial: _st);
                    await _load();
                  },
                  child: Text(t.bbl2TurnOn),
                ),
              ),
            ),
          ],
        );
    }
  }
}
