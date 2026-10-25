import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_admin_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/admin_notes.dart';

/// Appeal a moderation decision within the appeal window.
///
/// A user whose content/account was actioned can ask for a human re-review.
/// The backend enforces `can_appeal` (window + eligibility); if the window has
/// closed the server returns an error we surface honestly. Original Assisto
/// identity; all copy via AppLocalizations (no Bangla in source).
class ModerationAppealScreen extends StatefulWidget {
  /// The moderation item id being appealed.
  final String itemId;

  /// Optional human label of what was actioned (shown in the header only).
  final String? targetLabel;

  /// Optional last decision (e.g. removed/suspended) for context, localized by
  /// the caller or passed through as a backend string.
  final String? decisionLabel;

  const ModerationAppealScreen({
    super.key,
    required this.itemId,
    this.targetLabel,
    this.decisionLabel,
  });

  @override
  State<ModerationAppealScreen> createState() => _ModerationAppealScreenState();
}

class _ModerationAppealScreenState extends State<ModerationAppealScreen> {
  final _reason = TextEditingController();
  bool _sending = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await context
          .read<AppState>()
          .api
          .moderationAppeal(widget.itemId, _reason.text.trim());
      if (!mounted) return;
      setState(() {
        _sending = false;
        _done = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = t.msgrModAppealFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final canSend = _reason.text.trim().isNotEmpty && !_sending;

    return Scaffold(
      appBar: AppBar(title: Text(t.msgrModAppealTitle)),
      body: _done
          ? _Submitted(t: t)
          : ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Gap.lg),
                  decoration: BoxDecoration(
                    gradient: Brand.gradient,
                    borderRadius: BorderRadius.circular(Radii.lg),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.gavel_rounded, color: Colors.white),
                      const SizedBox(height: Gap.sm),
                      Text(
                        widget.targetLabel?.trim().isNotEmpty == true
                            ? t.msgrModAppealHeaderNamed(widget.targetLabel!)
                            : t.msgrModAppealHeader,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          height: 1.3,
                        ),
                      ),
                      if (widget.decisionLabel?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: Gap.xs),
                        Text(
                          t.msgrModAppealDecisionLine(widget.decisionLabel!),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Gap.lg),
                Text(
                  t.msgrModAppealIntro,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
                ),
                const SizedBox(height: Gap.lg),
                TextField(
                  controller: _reason,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: t.msgrModAppealReasonLabel,
                    hintText: t.msgrModAppealReasonHint,
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: Gap.sm),
                Text(
                  t.msgrModAppealWindowNote,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(height: Gap.md),
                // A human reviewer re-reads the decision; the outcome and its
                // reason are written to the append-only audit trail, and records
                // of illegal content are kept for legally-required reporting.
                AdminLegalNote(text: t.msgrModAppealRecordsNote),
                if (_error != null) ...[
                  const SizedBox(height: Gap.md),
                  Container(
                    padding: const EdgeInsets.all(Gap.md),
                    decoration: BoxDecoration(
                      color: Brand.danger.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: Row(children: [
                      const Icon(Icons.error_outline_rounded,
                          color: Brand.danger, size: 20),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(_error!,
                            style: const TextStyle(color: Brand.danger)),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: Gap.lg),
                FilledButton.icon(
                  onPressed: canSend ? _submit : null,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.outgoing_mail),
                  label: Text(t.msgrModAppealSubmit),
                ),
              ],
            ),
    );
  }
}

class _Submitted extends StatelessWidget {
  final AppLocalizations t;
  const _Submitted({required this.t});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 72,
              width: 72,
              decoration: BoxDecoration(
                color: Brand.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mark_email_read_rounded,
                  size: 34, color: Brand.success),
            ),
            const SizedBox(height: Gap.lg),
            Text(
              t.msgrModAppealDoneTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: Gap.sm),
            Text(
              t.msgrModAppealDoneBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: Gap.lg),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t.msgrModDone),
            ),
          ],
        ),
      ),
    );
  }
}
