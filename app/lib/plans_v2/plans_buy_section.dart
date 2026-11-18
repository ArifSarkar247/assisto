import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../billing/cctv_plan_screen.dart';
import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import '../payments/checkout_sheet.dart';
import '../payments/payments_api.dart';
import '../payments/play_restore.dart' show PlayStatusCard, playManageUri;
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt; // plans-credits
import 'buy_inside.dart' show BuyOrigin;

/// buyinside — the central Plans page additions (owner order 10 Nov):
///  * a recommendation from REAL usage, shown only when it truly saves
///    money (server: GET /plans/recommend, core.logic.plan_book.recommend —
///    30 days of real credit use and real pack payments, saving >= ৳50);
///  * the CCTV plan in the plans list (one tap to its own plan screen);
///  * "Manage or cancel subscription" — Google Play's own page (Play build).
/// Restore purchase stays where it was (RestorePurchasesButton).
class PlansBuySection extends StatefulWidget {
  /// Tests: the recommendation payload (null = ask the server).
  final Map<String, dynamic>? preview;
  final String? flavour;

  /// Tests: the GET /shop/cctv-plan payload (null = ask the server).
  final Map<String, dynamic>? cctvPreview;
  const PlansBuySection({super.key, this.preview, this.flavour, this.cctvPreview});

  @override
  State<PlansBuySection> createState() => _PlansBuySectionState();
}

class _PlansBuySectionState extends State<PlansBuySection> {
  Map<String, dynamic>? _rec;
  String _text = '';
  // plans-credits: the CCTV plan's price line comes from the server's CCTV
  // plan (the same numbers the CCTV plan screen and the website show).
  Map<String, dynamic>? _cctv;

  String get _flavour => widget.flavour ?? payFlavour();

  @override
  void initState() {
    super.initState();
    final p = widget.preview;
    if (p != null) {
      _apply(p);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    _cctv = widget.cctvPreview;
    if (_cctv == null && widget.preview == null &&
        FeatureFlags.instance.isOn('cctv_watchman')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadCctv());
    }
  }

  void _apply(Map<String, dynamic> j) {
    final r = j['recommend'];
    _rec = r is Map ? r.cast<String, dynamic>() : null;
    _text = '${j['text'] ?? ''}';
  }

  Future<void> _load() async {
    try {
      final j = await context.read<AppState>().api.getJson('/plans/recommend');
      if (mounted) setState(() => _apply(j));
    } catch (_) {
      // no recommendation offline — never a guess
    }
  }

  Future<void> _loadCctv() async {
    try {
      final j = await context.read<AppState>().api.getJson('/shop/cctv-plan');
      if (mounted) setState(() => _cctv = j);
    } catch (_) {
      // offline: the line says "open to see prices" — never a typed price
    }
  }

  /// "From ৳N a month for C cameras · D days free" from the server's numbers.
  String _cctvLine(AppLocalizations t) {
    final c = _cctv;
    if (c == null) return t.pcCctvSeePrices;
    final cams = (c['base_cameras'] as num?)?.toInt();
    int? price;
    for (final m in (c['tiers'] as List? ?? const []).whereType<Map>()) {
      if (m['cameras'] == cams) price = (m['monthly'] as num?)?.toInt();
    }
    price ??= (c['base_price'] as num?)?.toInt();
    if (cams == null || price == null || price <= 0) return t.pcCctvSeePrices;
    final taka = '৳${fmtInt(context, price)}';
    final days = (c['trial_days'] as num?)?.toInt() ?? 0;
    return days > 0 && c['trial_available'] == true
        ? t.pcCctvFromLine(taka, fmtInt(context, cams), fmtInt(context, days))
        : t.pcCctvFromLineNoTrial(taka, fmtInt(context, cams));
  }

  Future<void> _switch() async {
    final plan = '${_rec?['plan'] ?? ''}';
    if (plan.isEmpty) return;
    BuyOrigin.current = 'plans_recommend';
    final ok = await CheckoutSheet.show(context, '${plan}_monthly', flavour: _flavour);
    if (ok == true && mounted) setState(() => _rec = null);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rec = _rec;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (rec != null && _text.isNotEmpty) ...[
        const SizedBox(height: Gap.md),
        Container(
          key: const Key('bi-recommend'),
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.savings_rounded, color: scheme.onSecondaryContainer),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.biRecommendTitle,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: scheme.onSecondaryContainer)),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(_text,
                style: TextStyle(color: scheme.onSecondaryContainer, height: 1.4)),
            const SizedBox(height: Gap.sm),
            FilledButton.tonal(
              key: const Key('bi-recommend-switch'),
              onPressed: _switch,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(t.biRecommendSwitch),
            ),
          ]),
        ),
      ],
      if (FeatureFlags.instance.isOn('cctv_watchman')) ...[
        const SizedBox(height: Gap.md),
        Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            key: const Key('bi-plans-cctv'),
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const CctvPlanScreen())),
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(children: [
                Icon(Icons.videocam_rounded, color: scheme.primary),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.biCctvPlanTitle,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(_cctvLine(t),
                        key: const Key('bi-plans-cctv-line'),
                        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded),
              ]),
            ),
          ),
        ),
      ],
      if (_flavour == 'play') ...[
        const SizedBox(height: Gap.sm),
        TextButton.icon(
          key: const Key('bi-manage-sub'),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () =>
              PlayStatusCard.launcher(playManageUri('', 'com.assisto.assisto')),
          icon: const Icon(Icons.manage_accounts_rounded),
          label: Text(t.biManageCancel),
        ),
      ],
    ]);
  }
}
