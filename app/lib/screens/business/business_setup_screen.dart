import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../ds/ds.dart';
import '../../business_khata_api.dart';
import 'business_common.dart';
import 'package:assisto/widgets/app_sheet.dart';

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
        return (Icons.shopping_bag_rounded, t.bizTypeOnlineSeller);
      case 'small_shop':
        return (Icons.storefront_rounded, t.bizTypeSmallShop);
      case 'service':
        return (Icons.handyman_rounded, t.bizTypeService);
      case 'food':
        return (Icons.restaurant_rounded, t.bizTypeFood);
      case 'wholesaler':
        return (Icons.warehouse_rounded, t.bizTypeWholesaler);
      case 'b2b':
        return (Icons.business_center_rounded, t.bizTypeB2b);
      default:
        return (Icons.store_rounded, t.business);
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
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          DsHeroCard(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DsAvatar(child: Icon(Icons.storefront_rounded, color: scheme.ds.primaryInk)),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.businessSetupHeroTitle,
                      style: AType.titleLarge.copyWith(
                          color: scheme.ds.text, fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  Text(t.businessSetupHeroBody,
                      style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
                ]),
              ),
            ]),
          ),

          DsSectionHeader(t.businessChooseType),
          // Two columns whose tiles GROW with the font (a fixed-ratio grid
          // cut the type names with "…" at 200%).
          LayoutBuilder(builder: (context, c) {
            final w = (c.maxWidth - Gap.md) / 2;
            return Wrap(spacing: Gap.md, runSpacing: Gap.md, children: [
              for (final type in _types)
                SizedBox(
                  width: w,
                  child: _TypeTile(
                    icon: _typeMeta(t, type).$1,
                    label: _typeMeta(t, type).$2,
                    selected: _type == type,
                    onTap: () => setState(() => _type = type),
                  ),
                ),
            ]);
          }),

          DsSectionHeader(t.businessDetails),
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: t.businessNameLabel,
                prefixIcon: const Icon(Icons.badge_rounded)),
          ),
          const SizedBox(height: Gap.md),

          if (_showDelivery) ...[
            TextField(
              controller: _delivery,
              decoration: InputDecoration(
                  labelText: t.businessDeliveryLabel,
                  helperText: t.businessDeliveryHelp,
                  prefixIcon: const Icon(Icons.local_shipping_rounded)),
            ),
            const SizedBox(height: Gap.md),
          ],

          // Owner's own bKash/Nagad number — shown in tagada pay-hints (plan §6:
          // we never hold money, only surface the owner's own merchant number).
          Builder(builder: (context) {
            final method = DropdownButtonFormField<String>(
              initialValue: _payMethod,
              decoration: InputDecoration(labelText: t.businessPayMethod),
              items: [
                DropdownMenuItem(value: 'bkash', child: Text(t.payBkash)),
                DropdownMenuItem(value: 'nagad', child: Text(t.payNagad)),
              ],
              onChanged: (v) => setState(() => _payMethod = v ?? 'bkash'),
            );
            final number = TextField(
              controller: _payNumber,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: t.businessPayNumber),
            );
            // big font: the two fields stack instead of squeezing the
            // dropdown into 128 dp
            if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                method,
                const SizedBox(height: Gap.md),
                number,
              ]);
            }
            return Row(children: [
              SizedBox(width: 128, child: method),
              const SizedBox(width: Gap.md),
              Expanded(child: number),
            ]);
          }),
          const SizedBox(height: Gap.sm),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _hasStaff,
            title: Text(t.businessHasStaff),
            subtitle: Text(t.businessHasStaffHelp,
                style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
            onChanged: (v) => setState(() => _hasStaff = v),
          ),
          const SizedBox(height: Gap.xl),

          DsButton(
            onPressed: _saving ? null : _create,
            busy: _saving,
            icon: Icons.check_rounded,
            label: t.businessCreate,
            expand: true,
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
    final ds = Theme.of(context).colorScheme.ds;
    return Semantics(
      selected: selected,
      button: true,
      child: DsSurface(
        onTap: onTap,
        color: selected ? ds.primarySoft : ds.card,
        borderColor: selected ? ds.primaryInk : null,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.md),
        child: Row(children: [
          Icon(icon, color: selected ? ds.primaryInk : ds.muted),
          const SizedBox(width: Gap.sm),
          Expanded(
            // wraps (never "…") at 200% font; the tile grows
            child: Text(label,
                style: AType.bodyMedium.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? ds.primaryInk : ds.text)),
          ),
        ]),
      ),
    );
  }
}
