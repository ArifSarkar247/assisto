import 'package:flutter/material.dart';
import '../theme.dart';
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
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        Text(t.crmFormImportHint, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _raw,
          maxLines: 6,
          decoration: InputDecoration(
              hintText: t.crmFormPlaceholder, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _import,
          icon: const Icon(Icons.input),
          label: Text(t.crmImport),
        ),
        if (_parsed) ...[
          const Divider(height: Gap.lg),
          Text(t.crmReviewDraft, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          if (_draft.isEmpty)
            Text(t.crmFormNothingMapped,
                style: const TextStyle(color: Brand.warning)),
          for (final e in _draft.entries)
            if (e.key != 'source')
              ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle_outline, color: Brand.success, size: 18),
                title: Text(e.key),
                subtitle: Text(e.value.toString()),
              ),
          if (_unmapped.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(t.crmUnmappedFields,
                style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.warning)),
            for (final e in _unmapped.entries)
              ListTile(
                dense: true,
                leading: const Icon(Icons.help_outline, color: Brand.warning, size: 18),
                title: Text(e.key),
                subtitle: Text(e.value.toString()),
              ),
          ],
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            onPressed: (_busy || _draft.isEmpty) ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(t.crmSaveLead),
          ),
        ],
        if (_err != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_err!, style: const TextStyle(color: Brand.danger)),
        ],
      ],
    );
  }
}
