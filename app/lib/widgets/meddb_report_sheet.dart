import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// "Report wrong info" bottom sheet for a medicine-DB record. Lets the user
/// flag an incorrect/missing fact so it can be cross-checked against DGDA /
/// licensed sources. Posts to /medicine-db/report (public ApiClient.postJson —
/// no api.dart edit); degrades gracefully offline (acknowledges, user not
/// blocked). NEVER edits the drug data itself.
Future<void> showMedDbReportSheet(BuildContext context, String brand) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _MedDbReportSheet(brand: brand),
    ),
  );
}

class _MedDbReportSheet extends StatefulWidget {
  final String brand;
  const _MedDbReportSheet({required this.brand});
  @override
  State<_MedDbReportSheet> createState() => _MedDbReportSheetState();
}

class _MedDbReportSheetState extends State<_MedDbReportSheet> {
  final _issue = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _issue.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final issue = _issue.text.trim();
    if (issue.isEmpty) return;
    setState(() => _sending = true);
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().api.postJson('/medicine-db/report', {
        'brand': widget.brand,
        'issue': issue,
      });
    } catch (_) {
      // Honest: never thank the user for a report the server didn't get.
      if (!mounted) return;
      setState(() => _sending = false);
      messenger.showSnackBar(SnackBar(content: Text(t.grpActionFailed)));
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.medicineDbReportThanks)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.flag_rounded, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.medicineDbReportTitle,
                style: Theme.of(context).textTheme.titleMedium),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        Text(widget.brand, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _issue,
          minLines: 2,
          maxLines: 5,
          autofocus: true,
          decoration: InputDecoration(
            hintText: t.medicineDbReportHint,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed:
                (_sending || _issue.text.trim().isEmpty) ? null : _send,
            icon: _sending
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
            label: Text(t.medicineDbReportSend),
          ),
        ),
      ]),
    );
  }
}
