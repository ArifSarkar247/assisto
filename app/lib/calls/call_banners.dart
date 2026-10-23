import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'call_recording.dart';

/// b3-group B4/B5 banners shared by the 1:1 and the group call screens
/// (dark call background, white text, WCAG-contrast fills).

/// B4: "You are sharing your screen" + Stop — always on top while sharing.
class ScreenShareBanner extends StatelessWidget {
  const ScreenShareBanner({super.key, required this.onStop});
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const Key('screen-share-banner'),
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, Gap.xs),
        decoration: BoxDecoration(
          color: Brand.dangerFill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.screen_share_outlined, color: Colors.white),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.b3SharingBanner,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14)),
            ),
            TextButton(
              key: const Key('screen-share-stop'),
              style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.white.withValues(alpha: 0.18)),
              onPressed: onStop,
              child: Text(t.b3StopSharing),
            ),
          ],
        ),
      ),
    );
  }
}

/// B5: the red "Recording" banner every participant sees while recording.
class RecordingBanner extends StatelessWidget {
  const RecordingBanner(
      {super.key, required this.consent, required this.requesterName});
  final RecordingConsent consent;
  final String requesterName;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final String text;
    final bool red;
    switch (consent.status) {
      case RecordStatus.recording:
        red = true;
        text = consent.iRecord
            ? t.b3RecordingYou
            : t.b3RecordingBy(requesterName);
      case RecordStatus.paused:
        red = false;
        text = t.b3RecordingPaused;
      case RecordStatus.pending:
        if (consent.iMustAnswer) return const SizedBox.shrink();
        red = false;
        text = t.b3RecordWaiting;
      default:
        return const SizedBox.shrink();
    }
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: Key('recording-banner-${consent.status.name}'),
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
        padding:
            const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        decoration: BoxDecoration(
          color: red ? Brand.dangerFill : Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              key: red ? const Key('recording-dot') : null,
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: red ? Colors.white : Brand.warning,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

/// B5: "X wants to record this call" — Allow / Don't allow. Shown to every
/// participant who still has to answer (also a newcomer while paused).
class RecordingConsentCard extends StatelessWidget {
  const RecordingConsentCard({
    super.key,
    required this.requesterName,
    required this.onAllow,
    required this.onDecline,
    this.busy = false,
  });
  final String requesterName;
  final VoidCallback onAllow;
  final VoidCallback onDecline;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const Key('recording-consent'),
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: const Color(0xF2171B2E),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Brand.danger, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              const Icon(Icons.fiber_manual_record, color: Brand.danger),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.b3RecordAskTitle(requesterName),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            Text(t.b3RecordAskBody(requesterName),
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 13)),
            const SizedBox(height: Gap.md),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                OutlinedButton(
                  key: const Key('recording-decline'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54)),
                  onPressed: busy ? null : onDecline,
                  child: Text(t.b3RecordDecline),
                ),
                FilledButton(
                  key: const Key('recording-allow'),
                  style: FilledButton.styleFrom(
                      backgroundColor: Brand.dangerFill,
                      foregroundColor: Colors.white),
                  onPressed: busy ? null : onAllow,
                  child: Text(t.b3RecordAllow),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// B5: the requester confirms before everyone is asked.
Future<bool> confirmRecordRequest(BuildContext context) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.b3RecordConfirmTitle),
      content: Text(t.b3RecordConfirmBody),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.b3Cancel)),
        FilledButton(
            key: const Key('recording-ask'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.b3RecordAskEveryone)),
      ],
    ),
  );
  return ok == true;
}

/// Short notice text for a recording event (null = none).
String? recordNoticeText(AppLocalizations t, RecordNotice n) => switch (n) {
      RecordNotice.none => null,
      RecordNotice.declined => t.b3RecordDeclinedNotice,
      RecordNotice.paused => t.b3RecordingPaused,
      RecordNotice.saved => t.b3RecordSaved,
      RecordNotice.failed => t.b3RecordFailed,
      RecordNotice.requestFailed => t.b3RecordRequestFailed,
    };
