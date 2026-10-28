import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// ai-report (Google Play AI-generated content policy): every AI answer the
/// user sees can be reported / flagged from inside the app. Shared by the home
/// chat ([AgentThreadScreen]), Assisto AI chat, photo answers in chat and the
/// business AI draft.
///
/// Two ways in, both 48dp and TalkBack-labelled:
///  * a small flag [AiReportButton] next to the answer;
///  * a long-press on the answer -> [AiReport.showAnswerMenu] (Copy / Report).
///
/// The sheet asks for a reason (offensive / harmful / wrong / other) and an
/// optional note, then POSTs /chat/report. A stored chat answer is reported by
/// its message id (the server keeps its own text snapshot); anything else
/// sends the shown text. Text only — never a photo.
class AiReportTarget {
  /// chat | home | photo | business (server stores unknown ones as "other").
  final String surface;
  final String? messageId;
  final String? sessionId;

  /// The answer as shown (sent when there is no [messageId]; used for Copy).
  final String text;
  const AiReportTarget(
      {required this.surface,
      required this.text,
      this.messageId,
      this.sessionId});
}

/// Test seam: replaces the network call.
typedef AiReportSubmit = Future<void> Function(
    AiReportTarget target, String reason, String note);

class AiReport {
  AiReport._();

  /// Tests set this to capture submissions instead of calling the API.
  static AiReportSubmit? debugSubmit;

  static const reasons = ['offensive', 'harmful', 'wrong', 'other'];

  static Future<void> _submit(BuildContext context, AiReportTarget target,
      String reason, String note) async {
    final s = debugSubmit;
    if (s != null) return s(target, reason, note);
    await context.read<AppState>().api.aiReport(
        reason: reason,
        surface: target.surface,
        messageId: target.messageId,
        sessionId: target.sessionId,
        text: target.messageId == null ? target.text : null,
        note: note);
  }

  /// Opens the report sheet; shows the thank-you snackbar when sent.
  static Future<void> open(BuildContext context, AiReportTarget target) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final t = AppLocalizations.of(context);
    final sent = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => AiReportSheet(target: target),
    );
    if (sent == true) {
      messenger?.showSnackBar(SnackBar(content: Text(t.aiReportThanks)));
    }
  }

  /// Long-press menu on an AI answer: Copy + Report this answer.
  static Future<void> showAnswerMenu(
      BuildContext context, AiReportTarget target) async {
    final t = AppLocalizations.of(context);
    HapticFeedback.selectionClick();
    final pick = await showAppSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Semantics(
          label: t.aiAnswerMenu,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (target.text.trim().isNotEmpty)
              ListTile(
                key: const ValueKey('ai_answer_copy'),
                minTileHeight: 48,
                leading: const Icon(Icons.copy_rounded),
                title: Text(t.copy),
                onTap: () => Navigator.pop(ctx, 'copy'),
              ),
            ListTile(
              key: const ValueKey('ai_answer_report'),
              minTileHeight: 48,
              leading: const Icon(Icons.outlined_flag_rounded),
              title: Text(t.aiReportAction),
              onTap: () => Navigator.pop(ctx, 'report'),
            ),
            const SizedBox(height: Gap.sm),
          ]),
        ),
      ),
    );
    if (!context.mounted) return;
    if (pick == 'copy') {
      await Clipboard.setData(ClipboardData(text: target.text));
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(t.copied)));
      }
    } else if (pick == 'report') {
      await open(context, target);
    }
  }
}

/// The small 48dp flag icon shown next to an AI answer.
class AiReportButton extends StatelessWidget {
  final AiReportTarget target;
  const AiReportButton({super.key, required this.target});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return IconButton(
      key: const ValueKey('ai_report_flag'),
      tooltip: t.aiReportAction,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      iconSize: 18,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      icon: const Icon(Icons.outlined_flag_rounded),
      onPressed: () => AiReport.open(context, target),
    );
  }
}

/// Wraps an AI answer bubble: long-press opens the answer menu, and TalkBack
/// gets the same "Report this answer" as a custom action.
class AiAnswerLongPress extends StatelessWidget {
  final AiReportTarget target;
  final Widget child;
  const AiAnswerLongPress(
      {super.key, required this.target, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Semantics(
      onLongPressHint: t.aiAnswerMenu,
      customSemanticsActions: {
        CustomSemanticsAction(label: t.aiReportAction): () =>
            AiReport.open(context, target),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => AiReport.showAnswerMenu(context, target),
        child: child,
      ),
    );
  }
}

class AiReportSheet extends StatefulWidget {
  final AiReportTarget target;
  const AiReportSheet({super.key, required this.target});

  @override
  State<AiReportSheet> createState() => _AiReportSheetState();
}

class _AiReportSheetState extends State<AiReportSheet> {
  String? _reason;
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _label(AppLocalizations t, String r) => switch (r) {
        'offensive' => t.aiReportOffensive,
        'harmful' => t.aiReportHarmful,
        'wrong' => t.aiReportWrong,
        _ => t.aiReportOther,
      };

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final r = _reason;
    if (r == null) {
      setState(() => _error = t.aiReportPickReason);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AiReport._submit(context, widget.target, r, _note.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = (e is ApiException && e.status == 429)
            ? t.aiReportLimit
            : t.aiReportFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          key: const ValueKey('ai_report_sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(t.aiReportAction,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: Gap.xs),
            Text(t.aiReportBody,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: Gap.sm),
            RadioGroup<String>(
              groupValue: _reason,
              onChanged: (v) => setState(() {
                _reason = v;
                _error = null;
              }),
              child: Column(children: [
                for (final r in AiReport.reasons)
                  RadioListTile<String>(
                    key: ValueKey('ai_report_reason_$r'),
                    value: r,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_label(t, r)),
                  ),
              ]),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
              key: const ValueKey('ai_report_note'),
              controller: _note,
              minLines: 1,
              maxLines: 4,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t.aiReportNoteHint,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.md)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Gap.xs),
              Semantics(
                liveRegion: true,
                child: Text(_error!,
                    key: const ValueKey('ai_report_error'),
                    style: TextStyle(color: scheme.error, height: 1.4)),
              ),
            ],
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              key: const ValueKey('ai_report_send'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : _send,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.outlined_flag_rounded),
              label: Text(t.aiReportSend),
            ),
          ],
        ),
      ),
    );
  }
}
