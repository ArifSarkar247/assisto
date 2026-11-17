import 'package:flutter/material.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../screens/crm/crm_common.dart';
import '../screens/crm/crm_advanced_api.dart';

/// Website lead-FORM import (CRM spec #1). The owner pastes a web-form
/// submission as key:value lines (e.g. "Full Name: Karim"); the server
/// normalises it (logic_capture.form_intake) into a lead draft and flags any
/// fields it did not recognise (shown, never silently dropped). The user
/// reviews, then saves (duplicate-checked server-side).
class CrmFormImport extends StatefulWidget {
  final int org;
  const CrmFormImport({super.key, required this.org});
  @override
  State<CrmFormImport> createState() => _CrmFormImportState();
}

class _CrmFormImportState extends State<CrmFormImport> {
  final _raw = TextEditingController();
  Map<String, dynamic> _draft = {};
  Map<String, dynamic> _unmapped = {};
  bool _busy = false;
  bool _parsed = false;
  String? _err;

  @override
  void dispose() {
    _raw.dispose();
    super.dispose();
  }

  Map<String, dynamic> _parsePayload() {
    final out = <String, dynamic>{};
    for (final line in _raw.text.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final k = line.substring(0, idx).trim();
      final v = line.substring(idx + 1).trim();
      if (k.isNotEmpty) out[k] = v;
    }
    return out;
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await CrmAdvApi.of(context).formIntake(widget.org, _parsePayload());
      _draft = (r['draft'] as Map?)?.cast<String, dynamic>() ?? {};
      _unmapped = (r['unmapped'] as Map?)?.cast<String, dynamic>() ?? {};
      _parsed = true;
    } catch (e) {
      _err = CrmError.from(e).textFor(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await CrmApi.of(context).createLead({'org': widget.org, ..._draft});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).crmLeadSaved)));
        setState(() {
          _parsed = false;
          _draft = {};
          _unmapped = {};
          _raw.clear();
        });
      }
    } catch (e) {
      _err = CrmError.from(e).textFor(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = Theme.of(context).colorScheme.ds;
    final warnInk = Brand.onTint(context, AssistoTokens.of(context).warning);
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        // step 1: paste the form answers — one alive card with its button
        DsCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.crmFormImportHint, style: AType.bodyMedium.copyWith(color: ds.muted)),
            const SizedBox(height: Gap.sm),
            TextField(
              controller: _raw,
              maxLines: 6,
              decoration: InputDecoration(hintText: t.crmFormPlaceholder),
            ),
            const SizedBox(height: Gap.md),
            DsButton(
              onPressed: _busy ? null : _import,
              busy: _busy && !_parsed,
              icon: Icons.input_rounded,
              label: t.crmImport,
              expand: true,
            ),
          ]),
        ),
        if (_parsed) ...[
          // step 2: what was understood (green ticks) and what was not
          DsSectionHeader(t.crmReviewDraft),
          DsCard(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_draft.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
                  child: Text(t.crmFormNothingMapped,
                      style: AType.bodyMedium.copyWith(color: warnInk)),
                ),
              for (final e in _draft.entries)
                if (e.key != 'source')
                  DsListRow(
                    leading: Icon(Icons.check_circle_rounded, color: ds.successInk, size: 20),
                    title: e.key,
                    subtitle: e.value.toString(),
                  ),
              if (_unmapped.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
                  child: Text(t.crmUnmappedFields,
                      style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: warnInk)),
                ),
                for (final e in _unmapped.entries)
                  DsListRow(
                    leading: Icon(Icons.help_outline_rounded, color: warnInk, size: 20),
                    title: e.key,
                    subtitle: e.value.toString(),
                  ),
              ],
            ]),
          ),
          const SizedBox(height: Gap.md),
          DsButton(
            onPressed: (_busy || _draft.isEmpty) ? null : _save,
            busy: _busy && _parsed,
            icon: Icons.check_rounded,
            label: t.crmSaveLead,
            expand: true,
          ),
        ],
        if (_err != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_err!, style: AType.bodyMedium.copyWith(color: ds.dangerInk)),
        ],
      ],
    );
  }
}
