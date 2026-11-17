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
  const PlansBuySection({super.key, this.preview, this.flavour});

  @override
  State<PlansBuySection> createState() => _PlansBuySectionState();
}

class _PlansBuySectionState extends State<PlansBuySection> {
  Map<String, dynamic>? _rec;
  String _text = '';

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
                    Text(t.biCctvPlanLine,
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
