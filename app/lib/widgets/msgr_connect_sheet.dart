import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// The mandatory relationship + ONE optional note form shown before a personal
/// connection request is sent. Mirrors the circle request vocabulary
/// (Family/Friend/Cousin/Husband/Wife + optional family sub) and the pre-accept
/// one-note rule. Relation is REQUIRED; the note is optional and is the single
/// message allowed before acceptance.
///
/// Returns null on cancel, else {relation, customLabel?, note?}.
class MsgrConnectResult {
  final String relation;
  final String? customLabel;
  final String? note;
  const MsgrConnectResult(this.relation, {this.customLabel, this.note});
}

Future<MsgrConnectResult?> showMsgrConnectSheet(
  BuildContext context, {
  required String peerName,
}) {
  return showAppSheet<MsgrConnectResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ConnectSheet(peerName: peerName),
  );
}

// Relation keys mirror core/logic/circle relationship vocab.
const _relations = <String>[
  'family',
  'friend',
  'cousin',
  'husband',
  'wife',
];
// Optional family sub-relations (never required, no proof).
const _familySubs = <String>[
  'father',
  'mother',
  'child',
  'sibling',
  'other',
];

class _ConnectSheet extends StatefulWidget {
  final String peerName;
  const _ConnectSheet({required this.peerName});

  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  String? _relation;
  String? _familySub;
  final _note = TextEditingController();
  bool _showError = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _relLabel(AppLocalizations t, String key) => switch (key) {
        'family' => t.msgrRelationFamily,
        'friend' => t.msgrRelationFriend,
        'cousin' => t.msgrRelationCousin,
        'husband' => t.msgrRelationHusband,
        'wife' => t.msgrRelationWife,
        'father' => t.msgrRelationFather,
        'mother' => t.msgrRelationMother,
        'child' => t.msgrRelationChild,
        'sibling' => t.msgrRelationSibling,
        _ => t.msgrRelationOther,
      };

  void _submit() {
    if (_relation == null) {
      setState(() => _showError = true);
      return;
    }
    final note = _note.text.trim();
    Navigator.of(context).pop(MsgrConnectResult(
      _relation!,
      customLabel: _relation == 'family' ? _familySub : null,
      note: note.isEmpty ? null : note,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.msgrConnectTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(widget.peerName,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            // ---- mandatory relation ----
            Text(t.msgrRelationLabel,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              children: [
                for (final r in _relations)
                  ChoiceChip(
                    label: Text(_relLabel(t, r)),
                    selected: _relation == r,
                    onSelected: (_) => setState(() {
                      _relation = r;
                      _showError = false;
                      if (r != 'family') _familySub = null;
                    }),
                  ),
              ],
            ),
            if (_showError)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.msgrRelationRequired,
                    style: TextStyle(color: scheme.error, fontSize: 12)),
              ),
            // ---- optional family sub-relation ----
            if (_relation == 'family') ...[
              const SizedBox(height: Gap.md),
              Text(t.msgrFamilySubLabel,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  for (final s in _familySubs)
                    ChoiceChip(
                      label: Text(_relLabel(t, s)),
                      selected: _familySub == s,
                      onSelected: (_) => setState(
                          () => _familySub = _familySub == s ? null : s),
                    ),
                ],
              ),
            ],
            const SizedBox(height: Gap.lg),
            // ---- ONE optional note ----
            Text(t.msgrNoteOptional,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            TextField(
              controller: _note,
              minLines: 1,
              maxLines: 3,
              maxLength: 280,
              decoration: InputDecoration(hintText: t.msgrNoteHint),
            ),
            const SizedBox(height: Gap.sm),
            FilledButton(onPressed: _submit, child: Text(t.msgrSendRequest)),
          ],
        ),
      ),
    );
  }
}
