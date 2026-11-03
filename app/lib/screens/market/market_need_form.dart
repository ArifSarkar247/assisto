import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import 'market_source.dart';
import 'market_widgets.dart';

/// amarket: "Post a need" — category, what, quantity + unit, optional
/// budget (private unless shown), Dhaka area, deadline, group-buy switch.
/// Every rule is re-checked by the server (core.market.clean_need).
/// Pops with the new need id.
class MarketNeedForm extends StatefulWidget {
  final MarketSource source;
  final Map<String, dynamic> catalogue;
  final bool groupDefault;
  const MarketNeedForm({super.key, required this.source, required this.catalogue, this.groupDefault = false});

  @override
  State<MarketNeedForm> createState() => _MarketNeedFormState();
}

const _kDeadlines = [6, 24, 72, 168, 336];

class _MarketNeedFormState extends State<MarketNeedForm> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _bmin = TextEditingController();
  final _bmax = TextEditingController();
  String? _cat;
  String _unit = 'piece';
  String? _area;
  int _hours = 72;
  bool _showBudget = false;
  late bool _group = widget.groupDefault;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _desc, _qty, _bmin, _bmax]) {
      c.dispose();
    }
    super.dispose();
  }

  String _deadlineLabel(AppLocalizations t, int h) =>
      h < 24 ? t.amkInHours(mkNum(context, h)) : t.amkInDays(mkNum(context, h ~/ 24));

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final qty = int.tryParse(_qty.text.trim());
    if (_cat == null || _area == null || _title.text.trim().length < 3 || qty == null || qty < 1) {
      setState(() => _error = t.amkFormMissing);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.source.createNeed({
        'category': _cat,
        'title': _title.text.trim(),
        'description': _desc.text.trim(),
        'quantity': qty,
        'unit': _unit,
        'area': _area,
        'deadline_hours': _hours,
        if (_bmin.text.trim().isNotEmpty) 'budget_min': int.tryParse(_bmin.text.trim()),
        if (_bmax.text.trim().isNotEmpty) 'budget_max': int.tryParse(_bmax.text.trim()),
        'show_budget': _showBudget,
        'group_open': _group,
      });
      final id = (r['need'] as Map?)?['id'];
      if (mounted) {
        mkSnack(context, t.amkPosted);
        Navigator.pop(context, id is int ? id : null);
      }
    } catch (e) {
      if (mounted) setState(() => _error = mkMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _dec(String label, {String? hint, String? helper}) => InputDecoration(
      labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3, border: const OutlineInputBorder());

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cats = mkList(widget.catalogue['categories']);
    final units = mkList(widget.catalogue['units']);
    final areas = mkList(widget.catalogue['areas']);
    final digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)];
    return Scaffold(
      appBar: AppBar(title: Text(t.amkPostNeed)),
      body: ListView(
        key: const Key('amk-form'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Text(t.amkFormIntro),
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<String>(
            key: const Key('amk-f-cat'),
            isExpanded: true,
            initialValue: _cat,
            decoration: _dec(t.amkCategory),
            items: [for (final c in cats) DropdownMenuItem(value: '${c['key']}', child: Text('${c['label']}'))],
            onChanged: (v) => setState(() => _cat = v),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('amk-f-title'),
            controller: _title,
            maxLength: 120, buildCounter: localCounter,
            decoration: _dec(t.amkWhat, hint: t.amkWhatHint),
          ),
          TextField(
            key: const Key('amk-f-desc'),
            controller: _desc,
            maxLines: 3,
            maxLength: 1000, buildCounter: localCounter,
            decoration: _dec(t.amkDetails, hint: t.amkDetailsHint),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                key: const Key('amk-f-qty'),
                controller: _qty,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                decoration: _dec(t.amkQuantity),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const Key('amk-f-unit'),
                isExpanded: true,
                initialValue: _unit,
                decoration: _dec(t.amkUnit),
                items: [for (final u in units) DropdownMenuItem(value: '${u['key']}', child: Text('${u['label']}'))],
                onChanged: (v) => setState(() => _unit = v ?? 'piece'),
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<String>(
            key: const Key('amk-f-area'),
            isExpanded: true,
            initialValue: _area,
            decoration: _dec(t.amkArea, helper: t.amkDhakaOnly),
            items: [for (final a in areas) DropdownMenuItem(value: '${a['key']}', child: Text('${a['label']}'))],
            onChanged: (v) => setState(() => _area = v),
          ),
          const SizedBox(height: Gap.md),
          Text(t.amkDeadline),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final h in _kDeadlines)
              ChoiceChip(
                label: Text(_deadlineLabel(t, h)),
                selected: _hours == h,
                onSelected: (_) => setState(() => _hours = h),
              ),
          ]),
          const SizedBox(height: Gap.lg),
          Text(t.amkBudgetOptional),
          const SizedBox(height: Gap.xs),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('amk-f-bmin'),
                controller: _bmin,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                decoration: _dec(t.amkBudgetMin, hint: '৳'),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: TextField(
                key: const Key('amk-f-bmax'),
                controller: _bmax,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                decoration: _dec(t.amkBudgetMax, hint: '৳'),
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.amkShowBudget),
            subtitle: Text(t.amkShowBudgetNote),
            value: _showBudget,
            onChanged: (v) => setState(() => _showBudget = v),
          ),
          SwitchListTile(
            key: const Key('amk-f-group'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.amkGroupSwitch),
            subtitle: Text(t.amkGroupSwitchNote),
            value: _group,
            onChanged: (v) => setState(() => _group = v),
          ),
          const SizedBox(height: Gap.sm),
          Text(t.amkCodNote, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          if (_error != null) ...[
            const SizedBox(height: Gap.sm),
            Text(_error!, key: const Key('amk-f-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const Key('amk-f-submit'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
            label: Text(t.amkPostNeedSend),
          ),
        ],
      ),
    );
  }
}
