// quranread: the "I read, check me" sheet and the honest "no audio yet" sheet.
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_digits.dart';
import '../widgets/voice_help_sheet.dart';
import 'recite_check.dart';
import 'recite_listener.dart';

const String kQlArabicFont = 'AmiriQuran';

TextStyle qlArabic(double size, {Color? color}) => TextStyle(
    fontFamily: kQlArabicFont, fontSize: size, height: 1.9, color: color);

/// "Audio not available yet" - why, and what to do instead (never a fake
/// sound, never a machine voice for the Quran).
Future<void> showQlNoAudio(BuildContext context) => showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final t = AppLocalizations.of(ctx);
        return SingleChildScrollView(
          key: const Key('ql-no-audio'),
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Icon(Icons.headset_off_rounded,
                    color: Theme.of(ctx).colorScheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(t.qlNoAudioTitle, style: AType.titleLarge)),
              ]),
              const SizedBox(height: Gap.md),
              Text(t.qlNoAudioBody, style: AType.bodyLarge),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, kMinTap)),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(t.qlGotIt),
                ),
              ),
            ],
          ),
        );
      },
    );

/// Opens the recitation helper for [expected] (Arabic shown to the learner).
/// Returns the score (0-100) when a reading was compared, else null.
Future<int?> showReciteSheet(BuildContext context,
        {required String expected,
        List<String> alsoAccept = const [],
        bool letterName = false,
        ValueChanged<int>? onScore,
        ReciteListener? listener}) =>
    showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ReciteSheet(
          expected: expected,
          alsoAccept: alsoAccept,
          letterName: letterName,
          onScore: onScore,
          listener: listener),
    );

class ReciteSheet extends StatefulWidget {
  final String expected;
  final List<String> alsoAccept;
  final bool letterName;
  final ReciteListener? listener;
  final ValueChanged<int>? onScore;

  /// Gallery / tests: start with this already-heard text (the real flow fills
  /// it from the speech engine).
  @visibleForTesting
  final String? initialHeard;

  const ReciteSheet(
      {super.key,
      required this.expected,
      this.alsoAccept = const [],
      this.letterName = false,
      this.listener,
      this.onScore,
      this.initialHeard});

  @override
  State<ReciteSheet> createState() => _ReciteSheetState();
}

class _ReciteSheetState extends State<ReciteSheet> {
  late final ReciteListener _l = widget.listener ?? ReciteListener();
  ReciteResult? _result;

  @override
  void initState() {
    super.initState();
    _l.addListener(_changed);
    _l.onFinished = _compare;
    final h = widget.initialHeard;
    if (h != null && h.isNotEmpty) {
      _result = checkRecitation(widget.expected, h, alsoAccept: widget.alsoAccept);
    }
  }

  @override
  void dispose() {
    _l.removeListener(_changed);
    _l.onFinished = null;
    if (widget.listener == null) _l.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _compare() {
    if (!mounted) return;
    final r = checkRecitation(widget.expected, _l.heard,
        alsoAccept: widget.alsoAccept);
    setState(() => _result = r);
    widget.onScore?.call(r.score);
  }

  Future<void> _toggle() async {
    if (_l.listening) {
      await _l.stop();
    } else {
      setState(() => _result = null);
      await _l.start(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final tok = AssistoTokens.of(context);
    final r = _result;
    final busy = _l.listening || _l.starting;
    return SingleChildScrollView(
      key: const Key('ql-recite-sheet'),
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t.qlReciteTitle, style: AType.titleLarge),
          const SizedBox(height: Gap.xs),
          _HelperBadge(text: t.qlHelperLabel),
          const SizedBox(height: Gap.md),
          // The text to read; after a check, each word coloured.
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: r == null
                ? Text(widget.expected,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.rtl,
                    style: qlArabic(34, color: cs.onSurface))
                : Wrap(
                    alignment: WrapAlignment.center,
                    textDirection: TextDirection.rtl,
                    spacing: Gap.sm,
                    children: [
                      for (final w in r.words)
                        Semantics(
                          label: w.ok ? t.qlWordOk : t.qlWordMissed,
                          child: Text(w.text,
                              textDirection: TextDirection.rtl,
                              style: qlArabic(34,
                                  color: w.ok ? tok.success : cs.error)),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: Gap.md),
          Text(widget.letterName ? t.qlReciteLetterHint : t.qlReciteHint,
              style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          Center(
            child: SizedBox(
              height: 64,
              child: FilledButton.icon(
                key: const Key('ql-recite-mic'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size(160, 64),
                    backgroundColor: _l.listening ? cs.error : cs.primary,
                    foregroundColor: _l.listening ? cs.onError : cs.onPrimary),
                onPressed: _l.starting ? null : _toggle,
                icon: Icon(_l.listening ? Icons.stop_rounded : Icons.mic_rounded),
                label: Text(_l.listening
                    ? t.qlReciteStop
                    : (r == null ? t.qlReciteStart : t.qlReciteAgain)),
              ),
            ),
          ),
          if (busy) ...[
            const SizedBox(height: Gap.sm),
            Text(t.qlReciteListening,
                textAlign: TextAlign.center, style: AType.bodyMedium),
          ],
          if (_l.heard.isNotEmpty && r == null) ...[
            const SizedBox(height: Gap.sm),
            Text(_l.heard,
                textAlign: TextAlign.center,
                textDirection: TextDirection.rtl,
                style: qlArabic(22, color: cs.onSurfaceVariant)),
          ],
          if (_l.issue != ReciteIssue.none) ...[
            const SizedBox(height: Gap.md),
            _issue(context, t, _l.issue),
          ],
          if (r != null) ...[
            const SizedBox(height: Gap.md),
            _resultCard(context, t, r),
          ],
          const SizedBox(height: Gap.md),
          Text(t.qlReciteLimits,
              style: AType.bodySmall.copyWith(color: tok.textMuted)),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
              onPressed: () => Navigator.of(context).pop(r?.score),
              child: Text(t.qlDone),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(BuildContext context, AppLocalizations t, ReciteResult r) {
    final tok = AssistoTokens.of(context);
    final (bg, fg, msg, icon) = switch (r.verdict) {
      ReciteVerdict.good => (tok.successContainer, tok.onSuccessContainer,
          t.qlReciteGood, Icons.check_circle_rounded),
      ReciteVerdict.close => (tok.warningContainer, tok.onWarningContainer,
          t.qlReciteClose, Icons.error_outline_rounded),
      ReciteVerdict.retry => (Theme.of(context).colorScheme.errorContainer,
          Theme.of(context).colorScheme.onErrorContainer, t.qlReciteRetry,
          Icons.replay_rounded),
    };
    return Container(
      key: const Key('ql-recite-result'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: fg),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.qlReciteScore(ld(context, r.score)),
                  style: AType.titleMedium
                      .copyWith(color: fg, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(msg, style: AType.bodyMedium.copyWith(color: fg)),
          if (r.heard.trim().isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.qlReciteHeard, style: AType.bodySmall.copyWith(color: fg)),
            Text(r.heard,
                textDirection: TextDirection.rtl,
                style: qlArabic(20, color: fg)),
          ],
        ],
      ),
    );
  }

  Widget _issue(BuildContext context, AppLocalizations t, ReciteIssue i) {
    final cs = Theme.of(context).colorScheme;
    final (msg, action) = switch (i) {
      ReciteIssue.denied => (t.voiceNoPermission, 'settings'),
      ReciteIssue.noArabic => (t.qlReciteNoArabic, 'help'),
      ReciteIssue.noMatch => (t.voiceNoMatch, ''),
      ReciteIssue.network => (t.voiceNeedsNet, ''),
      ReciteIssue.busy => (t.voiceBusy, ''),
      ReciteIssue.unavailable || ReciteIssue.other => (t.micEnableSpeech, 'help'),
      ReciteIssue.none => ('', ''),
    };
    return Container(
      key: const Key('ql-recite-issue'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: cs.errorContainer, borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(msg, style: AType.bodyMedium.copyWith(color: cs.onErrorContainer)),
          if (action == 'settings')
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
              onPressed: () async {
                try {
                  await openAppSettings();
                } catch (_) {/* best-effort: the message above already says where the switch is */}
              },
              child: Text(t.qlOpenSettings),
            ),
          if (action == 'help')
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
              onPressed: () => VoiceHelpSheet.show(context),
              child: Text(t.aivVoiceHelp),
            ),
        ],
      ),
    );
  }
}

class _HelperBadge extends StatelessWidget {
  final String text;
  const _HelperBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    final tok = AssistoTokens.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(
            color: tok.infoContainer, borderRadius: BorderRadius.circular(Radii.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.info_outline_rounded, size: 16, color: tok.onInfoContainer),
          const SizedBox(width: Gap.xs),
          Flexible(
            child: Text(text,
                style: AType.labelMedium.copyWith(color: tok.onInfoContainer)),
          ),
        ]),
      ),
    );
  }
}

/// The badge reused on lesson screens.
class QlHelperBadge extends StatelessWidget {
  const QlHelperBadge({super.key});
  @override
  Widget build(BuildContext context) =>
      _HelperBadge(text: AppLocalizations.of(context).qlHelperLabel);
}
