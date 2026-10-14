import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../messenger_admin_api.dart';
import '../state.dart';
import '../theme.dart';

/// Reusable REPORT sheet for any PUBLIC surface (channel / post / community /
/// group / person). Original Assisto identity — brand tokens, own wording and
/// icons; never a copy of any other app's reporting UI.
///
/// Any screen can trigger it with [MsgrReportSheet.show] — it is the single
/// entry point other screens call (e.g. a channel header, a post overflow menu,
/// a person's profile). On submit it is honest about what happens: the SEVERE
/// set (child sexual abuse, violent threats, terrorism, scams/fraud) is hidden
/// immediately; everything else goes to human review.
///
/// All copy flows through AppLocalizations; this file contains zero Bangla.
class MsgrReportSheet extends StatefulWidget {
  /// What is being reported (see [ModTargets]).
  final String targetKind;

  /// Id of the target within that kind (stringified — ids may be int or uuid).
  final String targetId;

  /// Optional human label of the target (shown in the sheet header only).
  final String? targetLabel;

  const MsgrReportSheet({
    super.key,
    required this.targetKind,
    required this.targetId,
    this.targetLabel,
  });

  /// Open the report sheet from anywhere. Returns true if a report was
  /// submitted, null/false if dismissed. Call this from any content surface.
  static Future<bool?> show(
    BuildContext context, {
    required String targetKind,
    required String targetId,
    String? targetLabel,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => MsgrReportSheet(
        targetKind: targetKind,
        targetId: targetId,
        targetLabel: targetLabel,
      ),
    );
  }

  @override
  State<MsgrReportSheet> createState() => _MsgrReportSheetState();
}

class _MsgrReportSheetState extends State<MsgrReportSheet> {
  final Set<String> _selected = {};
  final _note = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _hasSevere => _selected.any(ModReasons.isSevere);

  String _targetLabel(AppLocalizations t) {
    switch (widget.targetKind) {
      case ModTargets.channel:
        return t.msgrModTargetChannel;
      case ModTargets.post:
        return t.msgrModTargetPost;
      case ModTargets.community:
        return t.msgrModTargetCommunity;
      case ModTargets.group:
        return t.msgrModTargetGroup;
      case ModTargets.person:
        return t.msgrModTargetPerson;
      default:
        return t.msgrModTargetContent;
    }
  }

  String _reasonLabel(AppLocalizations t, String code) {
    switch (code) {
      case ModReasons.childSafety:
        return t.msgrModReasonChildSafety;
      case ModReasons.violentThreat:
        return t.msgrModReasonViolentThreat;
      case ModReasons.terrorism:
        return t.msgrModReasonTerrorism;
      case ModReasons.scamFraud:
        return t.msgrModReasonScamFraud;
      case ModReasons.harassment:
        return t.msgrModReasonHarassment;
      case ModReasons.hateSpeech:
        return t.msgrModReasonHateSpeech;
      case ModReasons.selfHarm:
        return t.msgrModReasonSelfHarm;
      case ModReasons.nudity:
        return t.msgrModReasonNudity;
      case ModReasons.impersonation:
        return t.msgrModReasonImpersonation;
      case ModReasons.misinformation:
        return t.msgrModReasonMisinformation;
      case ModReasons.spam:
        return t.msgrModReasonSpam;
      default:
        return t.msgrModReasonOther;
    }
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    if (_selected.isEmpty) {
      setState(() => _error = t.msgrModReportPickReason);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await context.read<AppState>().api.moderationReport(
            targetKind: widget.targetKind,
            targetId: widget.targetId,
            categories: _selected.toList(),
            note: _note.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      // Honest confirmation depends on severity of what was picked.
      final msg =
          _hasSevere ? t.msgrModReportDoneSevere : t.msgrModReportDoneReview;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
        _error = t.msgrModReportFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final header = widget.targetLabel?.trim().isNotEmpty == true
        ? t.msgrModReportHeaderNamed(_targetLabel(t), widget.targetLabel!)
        : t.msgrModReportHeader(_targetLabel(t));

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.flag_outlined, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  header,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(
              t.msgrModReportSubtitle,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: Gap.lg),

            // SEVERE set — flagged as urgent so the user understands the
            // immediate-hide consequence before picking.
            _GroupLabel(t.msgrModReportSevereGroup, danger: true),
            const SizedBox(height: Gap.sm),
            for (final code in ModReasons.severeOrder)
              _ReasonTile(
                label: _reasonLabel(t, code),
                severe: true,
                selected: _selected.contains(code),
                onChanged: (v) => setState(() {
                  _error = null;
                  v ? _selected.add(code) : _selected.remove(code);
                }),
              ),
            const SizedBox(height: Gap.lg),

            _GroupLabel(t.msgrModReportOtherGroup),
            const SizedBox(height: Gap.sm),
            for (final code in ModReasons.otherOrder)
              _ReasonTile(
                label: _reasonLabel(t, code),
                severe: false,
                selected: _selected.contains(code),
                onChanged: (v) => setState(() {
                  _error = null;
                  v ? _selected.add(code) : _selected.remove(code);
                }),
              ),
            const SizedBox(height: Gap.lg),

            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: t.msgrModReportNoteLabel,
                hintText: t.msgrModReportNoteHint,
              ),
            ),
            const SizedBox(height: Gap.md),

            // Honest, upfront explanation of what submit does.
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: (_hasSevere ? Brand.danger : scheme.primary)
                    .withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _hasSevere
                        ? Icons.gpp_maybe_outlined
                        : Icons.shield_outlined,
                    size: 20,
                    color: _hasSevere ? Brand.danger : scheme.primary,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      _hasSevere
                          ? t.msgrModReportSevereNote
                          : t.msgrModReportReviewNote,
                      style: const TextStyle(height: 1.4, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: Gap.sm),
              Text(_error!, style: const TextStyle(color: Brand.danger)),
            ],
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              onPressed: _sending ? null : _submit,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(t.msgrModReportSubmit),
            ),
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String text;
  final bool danger;
  const _GroupLabel(this.text, {this.danger = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: danger ? Brand.danger : scheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
    );
  }
}

class _ReasonTile extends StatelessWidget {
  final String label;
  final bool severe;
  final bool selected;
  final ValueChanged<bool> onChanged;
  const _ReasonTile({
    required this.label,
    required this.severe,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => onChanged(!selected),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (v) => onChanged(v ?? false),
              ),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    height: 1.35,
                    fontWeight: severe ? FontWeight.w700 : FontWeight.w500,
                    color: severe ? Brand.danger : scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
