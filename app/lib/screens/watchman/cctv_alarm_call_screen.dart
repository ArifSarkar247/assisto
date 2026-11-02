import 'dart:async';

import 'package:flutter/material.dart';

import '../../calls/call_runtime.dart';
import '../../l10n/app_localizations.dart';
import '../../push/push_notifier.dart';
import '../../push/push_payload.dart';
import '../../widgets/app_sheet.dart';
import 'cctvx_inbox.dart';

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

class _CctvAlarmCallScreenState extends State<CctvAlarmCallScreen> {
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
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 16, 16, 16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.videocam_rounded, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(t.cescCallKicker,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: scheme.error, fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              [place, cam].where((s) => s.isNotEmpty).join(' — '),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(t.cescCallWhy),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: 4 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  color: scheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: photo.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(t.cescCallNoPhoto, textAlign: TextAlign.center))
                      : Image.network(photo,
                          fit: BoxFit.contain,
                          semanticLabel: t.cescCallPhotoLabel,
                          errorBuilder: (_, __, ___) => Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(t.cescCallNoPhoto, textAlign: TextAlign.center))),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(t.cescCallStopsNote, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 56)),
              onPressed: _open,
              icon: const Icon(Icons.visibility_rounded),
              label: Text(t.cescCallOpen),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: _later,
              child: Text(t.cescCallLater),
            ),
          ]),
        ),
      ),
    );
  }
}
