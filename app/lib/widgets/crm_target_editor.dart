import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/crm/crm_common.dart';
import '../screens/crm/crm_advanced_api.dart';

/// Bottom-sheet editor for a monthly TARGET (CRM spec #8). The owner sets the
/// amount + deal-count target for a member & period. Amounts are OWNER inputs —
/// there is NO default/suggested quota; the field starts empty with a clear
/// "you set this" hint. Returns true on save.
class CrmTargetEditor extends StatefulWidget {
  final int org;
  final List<Map<String, dynamic>> members;
  final Map<String, dynamic>? existing;
  const CrmTargetEditor(
      {super.key, required this.org, required this.members, this.existing});
  @override
  State<CrmTargetEditor> createState() => _CrmTargetEditorState();
}

class _CrmTargetEditorState extends State<CrmTargetEditor> {
  int? _memberId;
  late final TextEditingController _amount;
  late final TextEditingController _deals;
  late final TextEditingController _period;
  bool _saving = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _memberId = (e?['member'] as num?)?.toInt();
    _amount = TextEditingController(
        text: e?['target_amount'] != null ? '${e!['target_amount']}' : '');
    _deals = TextEditingController(
        text: e?['deals_target'] != null ? '${e!['deals_target']}' : '');
    _period = TextEditingController(text: e?['period']?.toString() ?? _thisMonth());
  }

  String _thisMonth() {
    final n = DateTime.now();
    final mm = n.month.toString().padLeft(2, '0');
    return '${n.year}-$mm';
  }

  @override
  void dispose() {
    _amount.dispose();
    _deals.dispose();
    _period.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _err = null;
    });
    try {
      await CrmAdvApi.of(context).saveTarget({
        'org': widget.org,
        if (_memberId != null) 'member': _memberId,
        'period': _period.text.trim(),
        'amount': double.tryParse(_amount.text.trim()) ?? 0,
        'deals_target': int.tryParse(_deals.text.trim()) ?? 0,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _err = CrmError.from(e).message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.md,
          right: Gap.md,
          top: Gap.md,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.md),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.crmSetTarget, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<int?>(
          initialValue: _memberId,
          decoration: InputDecoration(labelText: t.crmTeamMember, border: const OutlineInputBorder()),
          items: [
            DropdownMenuItem<int?>(value: null, child: Text(t.crmWholeTeam)),
            for (final m in widget.members)
              DropdownMenuItem<int?>(
                  value: (m['id'] as num).toInt(),
                  child: Text(m['user_name']?.toString() ?? '')),
          ],
          onChanged: (v) => setState(() => _memberId = v),
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _period,
          decoration: InputDecoration(
              labelText: t.crmPeriod,
              hintText: 'YYYY-MM',
              border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: t.crmTargetAmount,
              helperText: t.crmTargetAmountHint,
              prefixText: '৳ ',
              border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _deals,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: t.crmDealsTarget, border: const OutlineInputBorder()),
        ),
        if (_err != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_err!, style: const TextStyle(color: Brand.danger)),
        ],
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
              child: OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context, false),
                  child: Text(t.cancel))),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.save))),
        ]),
      ]),
    );
  }
}
