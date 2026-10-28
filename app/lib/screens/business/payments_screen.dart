import '../../feature_gates.dart' show kShowKeySeams;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../business_ai_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/business_ui.dart';
import '../../widgets/skeleton.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Payments (FREE).
///
/// Shows the owner's OWN bKash / Nagad MERCHANT descriptor (a QR placeholder +
/// merchant number) and a payment-link option via a LICENSED partner
/// (key-gated mock).
///
/// Explicit, bilingual: Assisto NEVER holds money and is NOT a wallet. We store
/// a pointer to the owner's merchant only. Any payment link is issued by a
/// licensed custodian partner, never by us.
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});
  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _qr;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<AppState>().api;
    try {
      _qr = await api.paymentsQr();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.bizPaymentsTitle)),
      body: _body(tr),
    );
  }

  Widget _body(AppLocalizations tr) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: tr.bizLoadFailed,
        message: _error,
        action: FilledButton(onPressed: _load, child: Text(tr.bizRetry)),
      );
    }
    final hasMerchant = _qr != null &&
        (_qr!['merchant_number'] ?? '').toString().isNotEmpty;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        // The non-negotiable money note, up top, bilingual via ARB.
        BizNote(text: tr.bizNeverHoldMoney, icon: Icons.account_balance_rounded),
        const SizedBox(height: Gap.md),
        if (hasMerchant) _merchantCard(tr) else _setupCard(tr),
        // truth: online payment links are not built (no partner checkout is
        // wired), so the card is hidden instead of promising them.
        if (kShowKeySeams) ...[
          const SizedBox(height: Gap.md),
          _linkCard(tr),
        ],
      ]),
    );
  }

  Widget _merchantCard(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    final provider = (_qr!['provider'] ?? '').toString();
    final number = (_qr!['merchant_number'] ?? '').toString();
    final name = (_qr!['merchant_name'] ?? '').toString();
    return BizCard(
      title: tr.bizYourMerchant,
      icon: Icons.qr_code_2_rounded,
      trailing: TextButton(onPressed: () => _editMerchant(tr), child: Text(tr.bizEdit)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr.payMerchantLabel(_providerName(provider)), style: const TextStyle(height: 1.4)),
        const SizedBox(height: Gap.md),
        // QR placeholder — the owner's own merchant QR renders here when the
        // descriptor is available from the merchant account.
        Center(
          child: Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.qr_code_2_rounded, size: 72, color: scheme.onSurfaceVariant),
              const SizedBox(height: Gap.sm),
              Text(_providerName(provider),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        _kv(tr.bizMerchantNumber, number),
        if (name.isNotEmpty) _kv(tr.bizMerchantName, name),
      ]),
    );
  }

  Widget _setupCard(AppLocalizations tr) {
    return BizCard(
      title: tr.bizYourMerchant,
      icon: Icons.qr_code_2_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr.bizAddMerchantBody, style: const TextStyle(height: 1.4)),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          onPressed: () => _editMerchant(tr),
          icon: const Icon(Icons.add_rounded),
          label: Text(tr.bizAddMerchant),
        ),
      ]),
    );
  }

  Widget _linkCard(AppLocalizations tr) {
    return BizCard(
      title: tr.bizPaymentLink,
      icon: Icons.link_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr.payLinkLabel, style: const TextStyle(height: 1.4)),
        const SizedBox(height: Gap.md),
        // truth: no partner checkout is wired -> honest banner, never a link.
        BizMockBanner(text: tr.bizPaymentLinkNeedKey),
      ]),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Row(children: [
          Text('$k: ',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );

  String _providerName(String p) {
    switch (p) {
      case 'bkash':
        return 'bKash';
      case 'nagad':
        return 'Nagad';
      default:
        return p.isEmpty ? 'bKash / Nagad' : p;
    }
  }

  Future<void> _editMerchant(AppLocalizations tr) async {
    String provider = (_qr?['provider'] ?? 'bkash').toString();
    final number = TextEditingController(text: (_qr?['merchant_number'] ?? '').toString());
    final name = TextEditingController(text: (_qr?['merchant_name'] ?? '').toString());
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: Gap.lg,
            right: Gap.lg,
            top: Gap.lg,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr.bizAddMerchant,
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.md),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'bkash', label: Text('bKash')),
                ButtonSegment(value: 'nagad', label: Text('Nagad')),
              ],
              selected: {provider},
              onSelectionChanged: (s) => setSheet(() => provider = s.first),
            ),
            const SizedBox(height: Gap.md),
            TextField(controller: number, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: tr.bizMerchantNumber)),
            const SizedBox(height: Gap.sm),
            TextField(controller: name, decoration: InputDecoration(labelText: tr.bizMerchantName)),
            const SizedBox(height: Gap.md),
            BizNote(text: tr.bizNeverHoldMoney, icon: Icons.account_balance_rounded),
            const SizedBox(height: Gap.lg),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.bizSave)),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<AppState>().api;
    try {
      await api.paymentsQrSave({
        'provider': provider,
        'merchant_number': number.text.trim(),
        'merchant_name': name.text.trim(),
      });
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }
}
