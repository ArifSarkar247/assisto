import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../screens/battery_guidance_screen.dart';
import '../theme.dart';

/// family100 — honest "your family's SOS can't ring this phone" banner.
///
/// Shown on the Family screen and the Family alerts screen when Android does
/// not let Assisto post notifications (Android 13+ POST_NOTIFICATIONS denied,
/// or notifications switched off for the app). "Turn on" asks again (or opens
/// the app's system settings when the prompt can no longer be shown); a
/// second link opens the brand-by-brand battery-saver guide, because on
/// Xiaomi / Realme / Oppo / Vivo a killed app also misses alerts.
/// Hidden when notifications are on — never a banner we can't justify.
class FamilyPushBanner extends StatefulWidget {
  const FamilyPushBanner(
      {super.key,
      this.isEnabled,
      this.request,
      this.titleOf,
      this.bodyOf,
      this.guideOf});

  /// notifs: the same banner for My Circle messages (own title / body).
  const FamilyPushBanner.messages(
      {super.key, this.request, Future<bool> Function()? enabled})
      : isEnabled = enabled ?? Notifications.messagesEnabled,
        titleOf = _msgTitle,
        bodyOf = _msgBody,
        guideOf = _msgGuide;

  static String _msgTitle(AppLocalizations t) => t.notifsMsgOffTitle;
  static String _msgBody(AppLocalizations t) => t.notifsMsgOffBody;
  static String _msgGuide(AppLocalizations t) => t.notifsMsgGuide;

  final String Function(AppLocalizations t)? titleOf;
  final String Function(AppLocalizations t)? bodyOf;
  final String Function(AppLocalizations t)? guideOf;

  /// Test seams (default: [Notifications.isEnabled] / requestPermission).
  final Future<bool> Function()? isEnabled;
  final Future<bool> Function()? request;

  @override
  State<FamilyPushBanner> createState() => _FamilyPushBannerState();
}

class _FamilyPushBannerState extends State<FamilyPushBanner>
    with WidgetsBindingObserver {
  bool _off = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // back from the system settings page -> re-check
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    bool on;
    try {
      on = await (widget.isEnabled ?? Notifications.isEnabled)();
    } catch (_) {
      on = true;
    }
    if (mounted && _off == on) setState(() => _off = !on);
  }

  Future<void> _allow() async {
    final ok = await (widget.request ?? Notifications.requestPermission)();
    if (!ok && widget.request == null) await Notifications.openSettings();
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (!_off) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('fa100-push-off'),
        margin: const EdgeInsets.only(bottom: Gap.md),
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.notifications_off_rounded,
                color: scheme.onErrorContainer, size: 26),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.titleOf?.call(t) ?? t.fa100PushOffTitle,
                        style: AType.titleMedium.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onErrorContainer)),
                    const SizedBox(height: Gap.xs),
                    Text(widget.bodyOf?.call(t) ?? t.fa100PushOffBody,
                        style: AType.bodyMedium
                            .copyWith(color: scheme.onErrorContainer)),
                  ]),
            ),
          ]),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _allow,
              child: Text(t.fa100PushOffAllow),
            ),
            TextButton(
              style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: scheme.onErrorContainer),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const BatteryGuidanceScreen())),
              child: Text(widget.guideOf?.call(t) ?? t.fa100BatteryGuide),
            ),
          ]),
        ]),
      ),
    );
  }
}
