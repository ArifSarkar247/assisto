import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../business_khata_api.dart';
import 'business_common.dart';

/// Business setup (plan §1): first-run / add-another. Pick a business type,
/// name it, configure the per-type extras, then create. Pops `true` when a
/// business was created so the hub reloads.
class BusinessSetupScreen extends StatefulWidget {
  const BusinessSetupScreen({super.key});
  @override
  State<BusinessSetupScreen> createState() => _BusinessSetupScreenState();
}

class _BusinessSetupScreenState extends State<BusinessSetupScreen> {
  String? _type;
  final _name = TextEditingController();

  // Per-type config (kept generic; the server stores it as `config`).
  final _delivery = TextEditingController(); // online_seller / food
  final _payNumber = TextEditingController(); // bKash/Nagad own number (pay_hint)
  String _payMethod = 'bkash';
  bool _hasStaff = false;
  bool _saving = false;

  static const _types = [
    'online_seller',
    'small_shop',
    'service',
    'food',
    'wholesaler',
    'b2b',
  ];

  @override
  void dispose() {
    _name.dispose();
    _delivery.dispose();
    _payNumber.dispose();
    super.dispose();
  }

  (IconData, String) _typeMeta(AppLocalizations t, String type) {
    switch (type) {
      case 'online_seller':
        return (Icons.shopping_bag_outlined, t.bizTypeOnlineSeller);
      case 'small_shop':
        return (Icons.storefront_outlined, t.bizTypeSmallShop);
      case 'service':
        return (Icons.handyman_outlined, t.bizTypeService);
      case 'food':
        return (Icons.restaurant_outlined, t.bizTypeFood);
      case 'wholesaler':
        return (Icons.warehouse_outlined, t.bizTypeWholesaler);
      case 'b2b':
        return (Icons.business_center_outlined, t.bizTypeB2b);
      default:
        return (Icons.store_outlined, t.business);
    }
  }

  bool get _showDelivery => _type == 'online_seller' || _type == 'food';

  Future<void> _create() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final name = _name.text.trim();
    if (_type == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.businessPickTypeFirst)));
      return;
    }
    if (name.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.businessNameRequired)));
      return;
    }
    final config = <String, dynamic>{
      'has_staff': _hasStaff,
      if (_payNumber.text.trim().isNotEmpty) ...{
        'pay_method': _payMethod,
        'pay_number': _payNumber.text.trim(),
      },
      if (_showDelivery && _delivery.text.trim().isNotEmpty)
        'delivery_note': _delivery.text.trim(),
    };
    setState(() => _saving = true);
    try {
      await context
          .read<AppState>()
          .api
          .businessCreate(name: name, type: _type!, config: config);
      if (!mounted) return;
      nav.pop(true);
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(t.businessCreateFailed)));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.businessSetupTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          BrandBand(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.businessSetupHeroTitle,
                  style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Text(t.businessSetupHeroBody, style: AType.bodyMedium),
            ]),
          ),
          const SizedBox(height: Gap.xl),

          Text(t.businessChooseType,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Gap.md,
            crossAxisSpacing: Gap.md,
            childAspectRatio: 2.4,
            children: [
              for (final type in _types)
                _TypeTile(
                  icon: _typeMeta(t, type).$1,
                  label: _typeMeta(t, type).$2,
                  selected: _type == type,
                  onTap: () => setState(() => _type = type),
                ),
            ],
          ),
          const SizedBox(height: Gap.xl),

          Text(t.businessDetails,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: t.businessNameLabel,
                prefixIcon: const Icon(Icons.badge_outlined)),
          ),
          const SizedBox(height: Gap.md),

          if (_showDelivery) ...[
            TextField(
              controller: _delivery,
              decoration: InputDecoration(
                  labelText: t.businessDeliveryLabel,
                  helperText: t.businessDeliveryHelp,
                  prefixIcon: const Icon(Icons.local_shipping_outlined)),
            ),
            const SizedBox(height: Gap.md),
          ],

          // Owner's own bKash/Nagad number — shown in tagada pay-hints (plan §6:
          // we never hold money, only surface the owner's own merchant number).
          Row(children: [
            SizedBox(
              width: 128,
              child: DropdownButtonFormField<String>(
                initialValue: _payMethod,
                decoration: InputDecoration(labelText: t.businessPayMethod),
                items: [
                  DropdownMenuItem(value: 'bkash', child: Text(t.payBkash)),
                  DropdownMenuItem(value: 'nagad', child: Text(t.payNagad)),
                ],
                onChanged: (v) => setState(() => _payMethod = v ?? 'bkash'),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: TextField(
                controller: _payNumber,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: t.businessPayNumber),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _hasStaff,
            title: Text(t.businessHasStaff),
            subtitle: Text(t.businessHasStaffHelp,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            onChanged: (v) => setState(() => _hasStaff = v),
          ),
          const SizedBox(height: Gap.xl),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _create,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(t.businessCreate),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TypeTile(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(children: [
          Icon(icon,
              color: selected ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color:
                        selected ? scheme.onPrimaryContainer : scheme.onSurface)),
          ),
        ]),
      ),
    );
  }
}
