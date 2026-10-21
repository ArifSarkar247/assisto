import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../business_selling_api.dart';
import '../../l10n/app_localizations.dart';

/// Shared scaffolding for the Business v2 SELLING screens (§3). Keeps role
/// redaction, money formatting and the common chrome in one place so every
/// selling screen looks and behaves identically.
///
/// ROLE: the backend tags each product/report/sale response with the caller's
/// business role. We treat a role of `staff` — OR the simple absence of any
/// cost/min/profit field on a response — as "redacted": cost, minimum and
/// profit UI is hidden. Owners see everything.
class SellRole {
  final String value; // 'owner' | 'staff' | ''
  const SellRole(this.value);

  bool get isStaff => value == 'staff';
  bool get canSeeCost => value != 'staff';

  static SellRole fromMap(Map<String, dynamic> m) =>
      SellRole((m['role'] ?? m['business_role'] ?? '').toString());
}

/// A product/variant cost or minimum value is considered redacted (hidden for
/// staff) when the key is simply absent from the server payload.
bool isRedacted(Map<String, dynamic> m, String key) => !m.containsKey(key);

/// The selling API, resolved from app state (same pattern as CrmApi.of).
ApiClient sellApi(BuildContext ctx) => ctx.read<AppState>().api;

/// A thin banner shown to staff on screens that hide owner-only numbers, so the
/// redaction is explicit rather than a silent gap. Uses `biz_staff_restricted`.
class StaffRedactedNote extends StatelessWidget {
  const StaffRedactedNote({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(t.biz_staff_restricted,
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.3)),
        ),
      ]),
    );
  }
}

/// A rounded "section" surface used across the add/edit sheets and detail cards.
class SellCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const SellCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(Gap.lg)});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: child,
    );
  }
}

/// A label → value money row (value formatted from poisha).
class MoneyRow extends StatelessWidget {
  final String label;
  final int poisha;
  final bool strong;
  final Color? valueColor;
  const MoneyRow(this.label, this.poisha,
      {super.key, this.strong = false, this.valueColor});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontWeight: strong ? FontWeight.w800 : FontWeight.w500,
      fontSize: strong ? 16 : 14,
      color: valueColor ?? scheme.onSurface,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Flexible(
          child: Text(label,
              style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w500)),
        ),
        const SizedBox(width: Gap.md),
        Text(poisha.fmtTaka, style: style),
      ]),
    );
  }
}

/// A money text field that returns a taka `num` (parsed client-side). Shared by
/// the product sheet and the quick-sell price override.
class MoneyField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? helper;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  const MoneyField({
    super.key,
    required this.controller,
    required this.label,
    this.helper,
    this.enabled = true,
    this.onChanged,
    this.validator,
  });
  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: onChanged,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        prefixText: '৳ ',
      ),
    );
  }
}

/// Parse a user-typed taka string to a non-negative taka num, or null if blank.
num? parseTaka(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  final v = num.tryParse(t);
  if (v == null || v < 0) return null;
  return v;
}

/// Taka (num) → poisha (int), rounding to the nearest poisha.
int takaToPoisha(num taka) => (taka * 100).round();

/// Payment-method option codes paired with their localised labels.
List<({String code, String label, IconData icon})> paymentMethods(
        AppLocalizations t) =>
    [
      (code: 'cash', label: t.biz_pay_cash, icon: Icons.payments_outlined),
      (code: 'bkash', label: t.biz_pay_bkash, icon: Icons.phone_android),
      (code: 'nagad', label: t.biz_pay_nagad, icon: Icons.phone_android),
      (code: 'due', label: t.biz_pay_due, icon: Icons.schedule_outlined),
    ];

/// A pill-style brand gradient header used atop each selling screen body — keeps
/// the chat-first/drawer app consistent (no bottom nav bar).
class SellHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  const SellHeader(
      {super.key, required this.icon, required this.title, this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Row(children: [
        Icon(icon, color: Colors.white, size: 28),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13, height: 1.3)),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Show the bilingual below-min message on a 422 `below_min`. Central so the
/// hard gate is surfaced identically wherever a sale/price is attempted.
void showBelowMin(BuildContext context) {
  final t = AppLocalizations.of(context);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(t.biz_below_min),
    backgroundColor: Brand.danger,
  ));
}

/// Show a generic API error (keeps messaging consistent).
void showApiError(BuildContext context, Object e) {
  final msg = e is ApiException ? e.message : e.toString();
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));
}
