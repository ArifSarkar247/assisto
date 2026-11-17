import 'dart:async';

import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import '../../theme.dart' show AType;

import '../../calls/call_runtime.dart';
import '../../l10n/app_localizations.dart';
import '../../push/push_notifier.dart';
import '../../push/push_payload.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifAgo;
import 'watchman_widgets.dart' show wmEventWhat;
import 'cctvx_inbox.dart';
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

/// cctvescalate C3 — the CCTV ALARM CALL page. The server rang this phone
/// with the SAME call push My Circle calls use (native full-screen ring,
/// lock screen, Telecom) because nobody opened a CCTV alert in time. This
/// page shows the alert's snapshot with two big buttons: open the alert (the
/// chain stops for everyone, the ring stops) or "not now" (the ring stops on
/// this phone only; the next person is rung after the wait). It is never a
/// voice line and never shows an ad.
class CctvAlarmCallScreen extends StatefulWidget {
  final PushPayload payload;

  /// Tests: replaces opening the alert (no AppState there).
  final void Function(BuildContext context, int eventId)? onOpen;
  const CctvAlarmCallScreen({super.key, required this.payload, this.onOpen});

  @override
  State<CctvAlarmCallScreen> createState() => _CctvAlarmCallScreenState();
}

class _CctvAlarmCallScreenState extends State<CctvAlarmCallScreen>
    with AdBlockedState<CctvAlarmCallScreen> {
  // design2-b13: "2 min ago" stays true while the page is open
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _stopRing() {
    final id = widget.payload.callId;
    unawaited(PushNotifier.cancelCall(id).catchError((_) {}));
    try {
      unawaited(CallRuntime.instance.stopRinging().catchError((_) {}));
    } catch (_) {}
  }

  void _open() {
    _stopRing();
    final ev = widget.payload.cctvEventId;
    if (ev == null) {
      Navigator.of(context).maybePop();
      return;
    }
    final cb = widget.onOpen;
    if (cb != null) {
      cb(context, ev);
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => GuardInboxScreen(openEvent: ev)));
  }

  void _later() {
    _stopRing();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = widget.payload;
    final photo = (p.data['snapshot_url'] ?? '').trim();
    final place = (p.data['site_name'] ?? '').trim();
    final cam = (p.data['camera_name'] ?? '').trim();
    final ds = scheme.ds;
    final evType = (p.data['event_type'] ?? '').trim();
    final whenWhat = [
      notifAgo(context, p.data['event_at']),
      if (evType.isNotEmpty) wmEventWhat(t, evType),
    ].where((x) => x.isNotEmpty).join(' · ');
    return Scaffold(
      backgroundColor: ds.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // the urgent thing first: the red DS hero (what, where, why)
            DsHeroCard(
              danger: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.videocam_rounded),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(t.cescCallKicker,
                        style: AType.labelLarge.copyWith(
                            color: ds.onDangerHero, fontWeight: FontWeight.w800)),
                  ),
                  const DsStatusDot(),
                ]),
                const SizedBox(height: Gap.sm),
                Text(
                  [place, cam].where((s) => s.isNotEmpty).join(' — '),
                  style: AType.headlineSmall.copyWith(
                      color: ds.onDangerHero, fontWeight: FontWeight.w800),
                ),
                // when + what triggered it (from the alert itself)
                if (whenWhat.isNotEmpty) ...[
                  const SizedBox(height: Gap.xxs),
                  Text(whenWhat,
                      key: const Key('cesc-when-what'),
                      style: AType.titleSmall.copyWith(
                          color: ds.onDangerHero, fontWeight: FontWeight.w700)),
                ],
                const SizedBox(height: Gap.xs),
                Text(t.cescCallWhy,
                    style: AType.bodyMedium.copyWith(color: ds.onDangerHeroSoft)),
              ]),
            ),
            const SizedBox(height: Gap.md),
            // no picture: a half-height box, so the two buttons sit higher
            // (thumb reach)
            AspectRatio(
              aspectRatio: photo.isEmpty ? 8 / 3 : 4 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(DsRadius.card),
                child: Container(
                  color: ds.cardHighest,
                  alignment: Alignment.center,
                  child: photo.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(Gap.xl),
                          child: Text(t.cescCallNoPhoto,
                              textAlign: TextAlign.center,
                              style: AType.bodyMedium.copyWith(color: ds.muted)))
                      : Image.network(photo,
                          fit: BoxFit.contain,
                          semanticLabel: t.cescCallPhotoLabel,
                          errorBuilder: (_, __, ___) => Padding(
                              padding: const EdgeInsets.all(Gap.xl),
                              child: Text(t.cescCallNoPhoto,
                                  textAlign: TextAlign.center,
                                  style: AType.bodyMedium.copyWith(color: ds.muted)))),
                ),
              ),
            ),
            const SizedBox(height: Gap.md),
            // one big glowing "open the alert", then "not now"
            DsButton.danger(
              onPressed: _open,
              icon: Icons.visibility_rounded,
              label: t.cescCallOpen,
              expand: true,
            ),
            const SizedBox(height: Gap.sm),
            DsButton.secondary(
              onPressed: _later,
              label: t.cescCallLater,
              expand: true,
            ),
            const SizedBox(height: Gap.md),
            Text(t.cescCallStopsNote,
                style: AType.bodySmall.copyWith(color: ds.muted)),
          ]),
        ),
      ),
    );
  }
}
