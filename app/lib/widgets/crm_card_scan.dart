import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/crm/crm_common.dart';
import '../screens/crm/crm_advanced_api.dart';

/// Business-card SCAN (CRM spec #1). OCR is KEY-GATED and MOCK: without an OCR
/// key the server returns needs_key and the user TYPES/pastes the card text,
/// which is parsed (logic_capture.card_parse) into an editable DRAFT. A review
/// step is mandatory — the lead is created only after the user confirms the
/// parsed fields. Before saving, the server checks for duplicates.
class CrmCardScan extends StatefulWidget {
  final int org;
  const CrmCardScan({super.key, required this.org});
  @override
  State<CrmCardScan> createState() => _CrmCardScanState();
}

class _CrmCardScanState extends State<CrmCardScan> {
  final _raw = TextEditingController();
  final _name = TextEditingController();
  final _company = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  bool _needsKey = true;
  bool _hasDraft = false;
  bool _busy = false;
  List<int> _dupeHits = [];
  String? _err;

  @override
  void dispose() {
    _raw.dispose();
    _name.dispose();
    _company.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await CrmAdvApi.of(context)
          .cardParse(widget.org, text: _raw.text.trim());
      _needsKey = r['needs_key'] == true;
      final d = (r['draft'] as Map?)?.cast<String, dynamic>() ?? {};
      _name.text = d['name']?.toString() ?? '';
      _company.text = d['company']?.toString() ?? '';
      _phone.text = d['phone']?.toString() ?? '';
      _email.text = d['email']?.toString() ?? '';
      _dupeHits = ((r['duplicate_of'] as List?) ?? []).map((e) => (e as num).toInt()).toList();
      _hasDraft = d.isNotEmpty;
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
      // Reuse the standard lead-create path via CrmApi (already duplicate-safe
      // server-side). We pass the reviewed draft.
      await CrmApi.of(context).createLead({
        'org': widget.org,
        'name': _name.text.trim(),
        'company': _company.text.trim(),
        'phone': _phone.text.trim(),
        'email': _email.text.trim(),
        'source': 'manual',
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).crmLeadSaved)));
        _reset();
      }
    } catch (e) {
      _err = CrmError.from(e).textFor(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reset() {
    _raw.clear();
    _name.clear();
    _company.clear();
    _phone.clear();
    _email.clear();
    setState(() {
      _hasDraft = false;
      _dupeHits = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        if (_needsKey)
          NeedsKeyBanner(t.crmCardOcrNeedsKey, icon: Icons.document_scanner_outlined),
        Text(t.crmCardPasteHint,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _raw,
          maxLines: 5,
          decoration: InputDecoration(
              hintText: t.crmCardPastePlaceholder, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _parse,
          icon: const Icon(Icons.auto_fix_high_outlined),
          label: Text(t.crmCardParse),
        ),
        if (_hasDraft) ...[
          const Divider(height: Gap.lg),
          Text(t.crmReviewDraft, style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(t.crmReviewDraftHint,
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          _field(t.crmName, _name),
          _field(t.crmCompany, _company),
          _field(t.crmPhone, _phone),
          _field(t.crmEmail, _email),
          if (_dupeHits.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Container(
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: Brand.warning.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(children: [
                const Icon(Icons.warning_amber_outlined, size: 18, color: Brand.warning),
                const SizedBox(width: Gap.xs),
                Expanded(child: Text(t.crmPossibleDuplicate)),
              ]),
            ),
          ],
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
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

  Widget _field(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        ),
      );
}
