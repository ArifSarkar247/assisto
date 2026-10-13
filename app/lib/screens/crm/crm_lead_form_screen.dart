import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';

/// Lead create/edit form (CRM_SPEC RICH MANUAL ENTRY — works WITHOUT AI).
///
/// Three ways in: a full manual form (every field), a quick-add (name + phone +
/// one line) and a paste box (chat / LinkedIn text / business-card OCR) that is
/// run through the rule-based backend extractor to pre-fill fields. When an AI
/// key exists the backend reports it and the UI offers the richer auto-fill;
/// without a key it stays honest with a clear needs-key note.
class CrmLeadFormScreen extends StatefulWidget {
  final int org;
  final Map<String, dynamic>? existing;
  const CrmLeadFormScreen({super.key, required this.org, this.existing});
  @override
  State<CrmLeadFormScreen> createState() => _CrmLeadFormScreenState();
}

class _CrmLeadFormScreenState extends State<CrmLeadFormScreen> {
  final _name = TextEditingController();
  final _company = TextEditingController();
  final _phone = TextEditingController();
  final _whatsapp = TextEditingController();
  final _email = TextEditingController();
  final _designation = TextEditingController();
  final _budget = TextEditingController();
  final _timeline = TextEditingController();
  final _decisionMaker = TextEditingController();
  final _notes = TextEditingController();

  String _industry = 'other';
  String _source = 'manual';
  int _size = 0;
  final Set<String> _modules = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e['name'] ?? '';
      _company.text = e['company'] ?? '';
      _phone.text = e['phone'] ?? '';
      _whatsapp.text = e['whatsapp'] ?? '';
      _email.text = e['email'] ?? '';
      _designation.text = e['designation'] ?? '';
      _budget.text = e['budget_range'] ?? '';
      _timeline.text = e['timeline'] ?? '';
      _decisionMaker.text = e['decision_maker'] ?? '';
      _notes.text = e['notes'] ?? '';
      _industry = e['industry'] ?? 'other';
      _source = e['source'] ?? 'manual';
      _size = (e['company_size'] as num?)?.toInt() ?? 0;
      _modules.addAll(((e['required_modules'] as List?) ?? []).map((x) => x.toString()));
    }
  }

  Future<void> _save(AppLocalizations t) async {
    if (_name.text.trim().isEmpty && _phone.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.crmNeedNameOrPhone)));
      return;
    }
    setState(() => _saving = true);
    final body = {
      'org': widget.org,
      'name': _name.text.trim(),
      'company': _company.text.trim(),
      'phone': _phone.text.trim(),
      'whatsapp': _whatsapp.text.trim(),
      'email': _email.text.trim(),
      'designation': _designation.text.trim(),
      'industry': _industry,
      'source': _source,
      'company_size': _size,
      'required_modules': _modules.toList(),
      'budget_range': _budget.text.trim(),
      'timeline': _timeline.text.trim(),
      'decision_maker': _decisionMaker.text.trim(),
      'notes': _notes.text.trim(),
    };
    try {
      final api = CrmApi.of(context);
      if (widget.existing != null) {
        await api.updateLead((widget.existing!['id'] as num).toInt(), body);
      } else {
        await api.createLead(body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _quickAdd(AppLocalizations t) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final line = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.crmQuickAdd),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: InputDecoration(labelText: t.name)),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: t.phone)),
          TextField(controller: line, decoration: InputDecoration(labelText: t.crmOneLine)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.add)),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _name.text = name.text.trim();
        _phone.text = phone.text.trim();
        _notes.text = line.text.trim();
      });
    }
  }

  Future<void> _paste(AppLocalizations t) async {
    final box = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.crmPasteTitle),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.crmPasteHint, style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            TextField(controller: box, maxLines: 6, decoration: const InputDecoration(border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.crmExtract)),
        ],
      ),
    );
    if (go != true || box.text.trim().isEmpty) return;
    try {
      final r = await CrmApi.of(context).extract(box.text.trim());
      setState(() {
        if ((r['name'] ?? '').toString().isNotEmpty) _name.text = r['name'];
        if ((r['phone'] ?? '').toString().isNotEmpty) _phone.text = r['phone'];
        if ((r['whatsapp'] ?? '').toString().isNotEmpty) _whatsapp.text = r['whatsapp'];
        if ((r['email'] ?? '').toString().isNotEmpty) _email.text = r['email'];
        if ((r['company'] ?? '').toString().isNotEmpty) _company.text = r['company'];
      });
      if (mounted) {
        final aiMsg = (r['ai_available'] == true) ? t.crmExtractDone : t.crmExtractNoKey;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(aiMsg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? t.crmEditLead : t.crmAddLead),
        actions: [
          if (!editing)
            IconButton(onPressed: () => _quickAdd(t), icon: const Icon(Icons.bolt_outlined), tooltip: t.crmQuickAdd),
          if (!editing)
            IconButton(onPressed: () => _paste(t), icon: const Icon(Icons.content_paste_outlined), tooltip: t.crmPasteTitle),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        _field(_name, t.name),
        _field(_phone, t.phone, keyboard: TextInputType.phone),
        _field(_whatsapp, t.crmWhatsApp, keyboard: TextInputType.phone),
        _field(_email, t.email, keyboard: TextInputType.emailAddress),
        _field(_company, t.company),
        _field(_designation, t.crmDesignation),
        const SizedBox(height: Gap.sm),
        _dropdown(t.industry, _industry, {
          'rmg': t.crmIndRmg,
          'pharma': t.crmIndPharma,
          'retail': t.crmIndRetail,
          'other': t.crmIndOther,
        }, (v) => setState(() => _industry = v)),
        _dropdown(t.source, _source, {
          'manual': t.crmSrcManual,
          'whatsapp': 'WhatsApp',
          'messenger': 'Messenger',
          'linkedin': 'LinkedIn',
          'email': t.email,
        }, (v) => setState(() => _source = v)),
        const SizedBox(height: Gap.sm),
        Text(t.crmHeadcount, style: const TextStyle(fontWeight: FontWeight.w700)),
        Slider(
          value: _size.clamp(0, 1000).toDouble(),
          min: 0,
          max: 1000,
          divisions: 20,
          label: _size == 0 ? '—' : '$_size',
          onChanged: (v) => setState(() => _size = v.round()),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.crmRequiredModules, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
          for (final m in moduleOptions(t))
            FilterChip(
              label: Text(m.label),
              selected: _modules.contains(m.code),
              onSelected: (on) => setState(() => on ? _modules.add(m.code) : _modules.remove(m.code)),
            ),
        ]),
        const SizedBox(height: Gap.md),
        _field(_budget, t.crmBudgetRange),
        _field(_timeline, t.crmTimeline),
        _field(_decisionMaker, t.crmDecisionMaker),
        _field(_notes, t.note, lines: 3),
        const SizedBox(height: Gap.lg),
        FilledButton.icon(
          onPressed: _saving ? null : () => _save(t),
          icon: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: Text(t.save),
        ),
      ]),
    );
  }

  Widget _field(TextEditingController c, String label,
          {TextInputType? keyboard, int lines = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: TextField(
          controller: c,
          keyboardType: keyboard,
          maxLines: lines,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  Widget _dropdown(String label, String value, Map<String, String> opts,
          ValueChanged<String> onChanged) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: DropdownButtonFormField<String>(
          initialValue: value,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: [for (final e in opts.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      );
}
