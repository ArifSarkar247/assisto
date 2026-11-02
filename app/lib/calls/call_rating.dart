import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'call_controller.dart';

/// callsbar: the optional one-tap "How was the call?" after a call.
///
/// Asked only after a call that really connected for >= 10 s. A call with a
/// visible problem (reconnected, video paused for the network, high loss /
/// delay, dropped) is ALWAYS asked — that is the feedback that matters; a
/// normal call only 1 in 3 times (by call id, so both phones don't both
/// get asked about every call). Never a dialog: one quiet row on the
/// call-ended screen, skipped by just closing.
bool shouldAskCallRating(CallController c) {
  final talk = c.talkTime;
  if (talk == null || talk.inSeconds < 10) return false;
  if (c.endReason == CallEndReason.lost) return true;
  if (c.endReason != CallEndReason.hangup &&
      c.endReason != CallEndReason.none) {
    return false;
  }
  if (c.hadProblem) return true;
  return (c.callId ?? 0) % 3 == 0;
}

/// The issues offered after "Bad" (server: call_quality.ISSUES).
const callRatingIssues = <String>[
  'choppy',
  'echo',
  'delay',
  'noise',
  'video',
  'dropped',
  'other'
];

String callIssueLabel(AppLocalizations t, String issue) => switch (issue) {
      'choppy' => t.cbarIssueChoppy,
      'echo' => t.cbarIssueEcho,
      'delay' => t.cbarIssueDelay,
      'noise' => t.cbarIssueNoise,
      'video' => t.cbarIssueVideo,
      'dropped' => t.cbarIssueDropped,
      _ => t.cbarIssueOther,
    };

class CallRatingRow extends StatefulWidget {
  const CallRatingRow({
    super.key,
    required this.onSend,
    this.onInteract,
    this.onDone,
    this.video = false,
  });

  /// rating 'good' | 'bad' (+ issue for bad). Errors are swallowed by the
  /// caller (a rating is never worth an error message).
  final Future<void> Function(String rating, String? issue) onSend;

  /// The person started answering (the screen stops its auto-close).
  final VoidCallback? onInteract;

  /// Answered — the screen may close after a short "thanks".
  final VoidCallback? onDone;

  /// a video call (offers the "video problem" issue)
  final bool video;

  @override
  State<CallRatingRow> createState() => _CallRatingRowState();
}

enum _Step { ask, issue, thanks }

class _CallRatingRowState extends State<CallRatingRow> {
  _Step _step = _Step.ask;

  void _send(String rating, [String? issue]) {
    setState(() => _step = _Step.thanks);
    // a rating is never worth an error (no network, signed out, …)
    Future<void>.sync(() => widget.onSend(rating, issue))
        .catchError((Object _) {});
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ink = AType.bodyMedium.copyWith(color: CallInk.text);
    final outline = OutlinedButton.styleFrom(
      foregroundColor: CallInk.text,
      side: const BorderSide(color: CallInk.textHint),
      minimumSize: const Size(48, 48),
    );
    Widget body;
    switch (_step) {
      case _Step.ask:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.cbarRateAsk,
              key: const Key('call-rate-ask'),
              textAlign: TextAlign.center,
              style: ink),
          const SizedBox(height: Gap.sm),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: Gap.md,
            runSpacing: Gap.sm,
            children: [
              OutlinedButton.icon(
                key: const Key('call-rate-good'),
                style: outline,
                icon: const Icon(Icons.thumb_up_alt_outlined),
                label: Text(t.cbarRateGood),
                onPressed: () {
                  widget.onInteract?.call();
                  _send('good');
                },
              ),
              OutlinedButton.icon(
                key: const Key('call-rate-bad'),
                style: outline,
                icon: const Icon(Icons.thumb_down_alt_outlined),
                label: Text(t.cbarRateBad),
                onPressed: () {
                  widget.onInteract?.call();
                  setState(() => _step = _Step.issue);
                },
              ),
            ],
          ),
        ]);
      case _Step.issue:
        final issues = widget.video
            ? callRatingIssues
            : callRatingIssues.where((i) => i != 'video').toList();
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.cbarRateWhat,
              key: const Key('call-rate-what'),
              textAlign: TextAlign.center,
              style: ink),
          const SizedBox(height: Gap.sm),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final i in issues)
                OutlinedButton(
                  key: Key('call-rate-issue-$i'),
                  style: outline,
                  onPressed: () => _send('bad', i),
                  child: Text(callIssueLabel(t, i)),
                ),
            ],
          ),
        ]);
      case _Step.thanks:
        body = Text(t.cbarRateThanks,
            key: const Key('call-rate-thanks'),
            textAlign: TextAlign.center,
            style: ink);
    }
    return Semantics(
      container: true,
      liveRegion: _step == _Step.thanks,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
        child: body,
      ),
    );
  }
}
