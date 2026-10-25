import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/crm/crm_common.dart';
import '../screens/crm/crm_advanced_api.dart';

/// OWNER-REVIEW COMMISSION configuration (CRM spec #8).
///
/// CRITICAL: this widget has NO hard-coded rate, tier or bonus. Every number is
/// an OWNER input. Until the owner picks a plan and enters a rate, the screen
/// shows a prominent "YOU must set this" banner and the computed preview reads
/// zero with a clear placeholder — the CRM never invents a commission.
///
/// Plans mirror logic_team.commission: flat % · tiered (marginal) · none.
class CrmCommissionConfig extends StatefulWidget {
  final int org;
  final Map<String, dynamic> data; // {config:{...}, preview:[{member_name,payout,config_set}]}
  final VoidCallback onSaved;
  const CrmCommissionConfig(
      {super.key, required this.org, required this.data, required this.onSaved});
  @override
  State<CrmCommissionConfig> createState() => _CrmCommissionConfigState();
}

class _CrmCommissionConfigState extends State<CrmCommissionConfig> {
  late String _kind; // none | flat | tiered
  late final TextEditingController _flatPct;
  late final TextEditingController _bonus;
  List<_Tier> _tiers = [];
  bool _saving = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    final cfg = (widget.data['config'] as Map?)?.cast<String, dynamic>() ?? {};
    _kind = (cfg['kind'] ?? 'none').toString();
    _flatPct = TextEditingController(
        text: cfg['flat_pct'] != null ? '${cfg['flat_pct']}' : '');
    _bonus = TextEditingController(
        text: cfg['per_deal_bonus'] != null ? '${cfg['per_deal_bonus']}' : '');
    for (final tRaw in (cfg['tiers'] as List?) ?? []) {
      final tm = (tRaw as Map).cast<String, dynamic>();
      _tiers.add(_Tier(
        upto: TextEditingController(
            text: tm['upto'] != null ? '${tm['upto']}' : ''),
        pct: TextEditingController(text: tm['pct'] != null ? '${tm['pct']}' : ''),
      ));
    }
    if (_tiers.isEmpty) _tiers = [_Tier(), _Tier()];
  }

  @override
  void dispose() {
    _flatPct.dispose();
    _bonus.dispose();
    for (final x in _tiers) {
      x.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _buildConfig() {
    final cfg = <String, dynamic>{'kind': _kind};
    if (_kind == 'flat') {
      cfg['flat_pct'] = double.tryParse(_flatPct.text.trim()) ?? 0;
    } else if (_kind == 'tiered') {
      cfg['tiers'] = [
        for (final tr in _tiers)
          if (tr.pct.text.trim().isNotEmpty)
            {
              'upto': tr.upto.text.trim().isEmpty
                  ? null
                  : double.tryParse(tr.upto.text.trim()),
              'pct': double.tryParse(tr.pct.text.trim()) ?? 0,
            }
      ];
    }
    final bonus = double.tryParse(_bonus.text.trim()) ?? 0;
    if (bonus > 0) cfg['per_deal_bonus'] = bonus;
    return cfg;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _err = null;
    });
    try {
      await CrmAdvApi.of(context).saveCommissionConfig(widget.org, _buildConfig());
      widget.onSaved();
    } catch (e) {
      setState(() => _err = CrmError.from(e).textFor(context));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final preview = ((widget.data['preview'] as List?) ?? []).cast<Map<String, dynamic>>();
    final isSet = _kind != 'none';
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        // Loud, honest "owner must set" banner — never a guessed rate.
        NeedsKeyBanner(t.crmCommissionOwnerNote, icon: Icons.verified_user_rounded),
        const SizedBox(height: Gap.sm),
        Text(t.crmCommissionPlan, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'none', label: Text(t.crmCommNone)),
            ButtonSegment(value: 'flat', label: Text(t.crmCommFlat)),
            ButtonSegment(value: 'tiered', label: Text(t.crmCommTiered)),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: Gap.md),
        if (_kind == 'flat')
          TextField(
            controller: _flatPct,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: t.crmCommRate,
                helperText: t.crmCommRateHint,
                suffixText: '%',
                border: const OutlineInputBorder()),
          ),
        if (_kind == 'tiered') ...[
          Text(t.crmCommTieredHint,
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          for (int i = 0; i < _tiers.length; i++) _tierRow(t, i),
          TextButton.icon(
              onPressed: () => setState(() => _tiers.add(_Tier())),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.crmAddTier)),
        ],
        if (isSet) ...[
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _bonus,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: t.crmCommBonus,
                helperText: t.crmCommBonusHint,
                prefixText: '৳ ',
                border: const OutlineInputBorder()),
          ),
        ],
        if (_err != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_err!, style: const TextStyle(color: Brand.danger)),
        ],
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_rounded),
          label: Text(t.crmSaveCommission),
        ),
        const SizedBox(height: Gap.lg),
        if (preview.isNotEmpty) ...[
          Text(t.crmCommissionPreview, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          for (final p in preview) _previewRow(context, t, p),
        ],
      ],
    );
  }

  Widget _tierRow(AppLocalizations t, int i) {
    final tr = _tiers[i];
    final isLast = i == _tiers.length - 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: tr.upto,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: isLast ? t.crmTierAndAbove : t.crmTierUpto,
                prefixText: '৳ ',
                isDense: true,
                border: const OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: Gap.sm),
        SizedBox(
          width: 90,
          child: TextField(
            controller: tr.pct,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                suffixText: '%', isDense: true, border: OutlineInputBorder()),
          ),
        ),
        IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: _tiers.length <= 1
                ? null
                : () => setState(() => _tiers.removeAt(i))),
      ]),
    );
  }

  Widget _previewRow(
      BuildContext context, AppLocalizations t, Map<String, dynamic> p) {
    final set = p['config_set'] == true;
    return Card(
      child: ListTile(
        title: Text(p['member_name']?.toString() ?? ''),
        subtitle: Text('${t.crmWon}: ${bdt(context, p['won_amount'] as num?)}'),
        trailing: set
            ? Text(bdt(context, p['payout'] as num?),
                style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.success))
            : Text(t.crmOwnerMustSet,
                style: const TextStyle(fontSize: 11, color: Brand.warning)),
      ),
    );
  }
}

class _Tier {
  final TextEditingController upto;
  final TextEditingController pct;
  _Tier({TextEditingController? upto, TextEditingController? pct})
      : upto = upto ?? TextEditingController(),
        pct = pct ?? TextEditingController();
  void dispose() {
    upto.dispose();
    pct.dispose();
  }
}
