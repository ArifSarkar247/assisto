import 'package:flutter/material.dart';
import '../../ds/ds.dart';
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
                // what is being appealed = the soft DS hero (no white text
                // on the brand gradient)
                DsHeroCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DsAvatar(child: Icon(Icons.gavel_rounded, color: scheme.ds.primaryInk)),
                      const SizedBox(height: Gap.md),
                      Text(
                        widget.targetLabel?.trim().isNotEmpty == true
                            ? t.msgrModAppealHeaderNamed(widget.targetLabel!)
                            : t.msgrModAppealHeader,
                        style: AType.titleLarge.copyWith(
                            color: scheme.ds.text, fontWeight: FontWeight.w800),
                      ),
                      if (widget.decisionLabel?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: Gap.xs),
                        Text(
                          t.msgrModAppealDecisionLine(widget.decisionLabel!),
                          style: AType.bodyMedium.copyWith(color: scheme.ds.muted),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Gap.lg),
                Text(
                  t.msgrModAppealIntro,
                  style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.45),
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
                  style: AType.bodySmall.copyWith(color: scheme.ds.muted),
                ),
                const SizedBox(height: Gap.md),
                // A human reviewer re-reads the decision; the outcome and its
                // reason are written to the append-only audit trail, and records
                // of illegal content are kept for legally-required reporting.
                AdminLegalNote(text: t.msgrModAppealRecordsNote),
                if (_error != null) ...[
                  const SizedBox(height: Gap.md),
                  DsCard(
                    tone: DsTone.danger,
                    padding: const EdgeInsets.all(Gap.md),
                    child: Row(children: [
                      Icon(Icons.error_outline_rounded, color: scheme.ds.dangerInk, size: 20),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(_error!,
                            style: AType.bodyMedium.copyWith(color: scheme.ds.dangerInk)),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: Gap.lg),
                DsButton(
                  onPressed: canSend ? _submit : null,
                  busy: _sending,
                  icon: Icons.outgoing_mail,
                  label: t.msgrModAppealSubmit,
                  expand: true,
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
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      const SizedBox(height: Gap.xl),
      DsEmptyState(
        icon: Icons.mark_email_read_rounded,
        title: t.msgrModAppealDoneTitle,
        benefit: t.msgrModAppealDoneBody,
        actionLabel: t.msgrModDone,
        onAction: () => Navigator.of(context).pop(true),
      ),
    ]);
  }
}
