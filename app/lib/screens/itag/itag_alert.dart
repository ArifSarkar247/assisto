// flag-itag: the full-screen alert for "left behind" and "your tag is
// looking for this phone" + a notification for a locked screen. Installed
// by the tag screen (the controller itself has no UI).
import 'package:flutter/material.dart';

import '../../ds/ds.dart';
import '../../itag/itag_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../notifications.dart';
import '../../push/push_service.dart' show appNavigatorKey;
import '../../widgets/app_sheet.dart' show withNavBarInset;

const int kItagNotifId = 90610;
bool _alertOpen = false;

void itagInstallAlertHook(ItagController c) {
  c.onAlert = (kind, tag) {
    final nav = appNavigatorKey.currentState;
    final ctx = appNavigatorKey.currentContext;
    if (nav == null || ctx == null) return;
    final t = AppLocalizations.of(ctx);
    final title = kind == ItagAlertKind.leftBehind ? t.itgLeftTitle(tag.name) : t.itgFindTitle;
    final body = kind == ItagAlertKind.leftBehind ? t.itgLeftBody : t.itgFindBody(tag.name);
    Notifications.show(kItagNotifId, title, body);
    if (_alertOpen) return;
    _alertOpen = true;
    nav
        .push(MaterialPageRoute<void>(
            builder: (_) => ItagAlertScreen(controller: c, kind: kind, tagName: tag.name)))
        .whenComplete(() => _alertOpen = false);
  };
}

class ItagAlertScreen extends StatefulWidget {
  const ItagAlertScreen(
      {super.key, required this.controller, required this.kind, required this.tagName});
  final ItagController controller;
  final ItagAlertKind kind;
  final String tagName;

  @override
  State<ItagAlertScreen> createState() => _ItagAlertScreenState();
}

class _ItagAlertScreenState extends State<ItagAlertScreen> {
  bool _closing = false;

  bool get _active => widget.kind == ItagAlertKind.leftBehind
      ? widget.controller.leftBehind != null
      : widget.controller.phoneRinging;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    // the tag came back in reach / the ring timed out: close by itself
    if (!_active && mounted && !_closing) {
      _closing = true;
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _stop() async {
    _closing = true;
    if (widget.kind == ItagAlertKind.leftBehind) {
      await widget.controller.dismissLeftBehind();
    } else {
      await widget.controller.stopPhone();
    }
    try {
      await Notifications.cancelId(kItagNotifId);
    } catch (_) {} // best-effort: clearing a notification; the alarm is already stopped
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final left = widget.kind == ItagAlertKind.leftBehind;
    return Scaffold(
      key: Key(left ? 'itag-alert-left' : 'itag-alert-find'),
      body: SafeArea(
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
          children: [
            const SizedBox(height: Gap.xxl),
            DsIllustration(
                icon: left ? Icons.luggage_rounded : Icons.phonelink_ring_rounded),
            const SizedBox(height: Gap.xl),
            Text(left ? t.itgLeftTitle(widget.tagName) : t.itgFindTitle,
                textAlign: TextAlign.center, style: text.headlineSmall),
            const SizedBox(height: Gap.md),
            Text(left ? t.itgLeftBody : t.itgFindBody(widget.tagName),
                textAlign: TextAlign.center, style: text.bodyLarge?.copyWith(height: 1.4)),
            const SizedBox(height: Gap.xxl),
            DsButton.danger(
              buttonKey: const Key('itag-alert-stop'),
              label: t.itgStopAlarm,
              icon: Icons.stop_circle_rounded,
              expand: true,
              onPressed: _stop,
            ),
          ],
        ),
      ),
    );
  }
}
