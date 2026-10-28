import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../business_khata_api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../payments/checkout_sheet.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../services/error_report.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';

/// tagada2 — the shop's Assisto SMS balance, said plainly:
///   plan SMS this month (Business plan allowance, resets monthly) +
///   SMS-pack parts (never expire) = what can be sent. Assisto never sends
///   an SMS without balance. Free routes first (Assisto in-app, WhatsApp,
///   own SIM). Packs are bought through Google Play only once the server
///   says they are on sale (Play product verified ACTIVE); until then an
///   honest "coming soon". No ads on this screen.
class SmsBalanceScreen extends StatefulWidget {
  final int businessId;
  const SmsBalanceScreen({super.key, required this.businessId});

  @override
  State<SmsBalanceScreen> createState() => _SmsBalanceScreenState();
}

class _SmsBalanceScreenState extends State<SmsBalanceScreen> {
  Map<String, dynamic>? _b;
  bool _loading = true;
  Object? _fail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _b == null;
      _fail = null;
    });
    try {
      _b = await context.read<AppState>().api.smsBalance(widget.businessId);
    } catch (e) {
      _fail = e;
      reportNonFatal('khata.smsBalance', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  String _d(Object v) =>
      localDigits('$v', Localizations.localeOf(context).languageCode);

  int _i(String k) => (_b?[k] as num?)?.toInt() ?? 0;

  Future<void> _buy(String sku) async {
    final bought = await CheckoutSheet.show(context, sku);
    if (bought == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text(t.tg2BalTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_fail != null || _b == null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.tg2BalTitle,
        message: honestFailText(t, _fail),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final total = _i('allowance_total');
    final left = _i('allowance_left');
    final pack = _i('pack_left');
    final all = _b!.containsKey('parts_left') ? _i('parts_left') : left + pack;
    final low = _b!['low'] == true;
    final packs = ((_b!['packs'] ?? const []) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final onSale = _b!['packs_on_sale'] == true &&
        packs.any((p) => p['on_sale'] == true);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(t.tg2BalTotal(_d(all)),
                          key: const ValueKey('tg2-bal-total'),
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontFeatures: AFonts.tabular)),
                    ),
                    const SizedBox(height: Gap.md),
                    _line(Icons.event_repeat_rounded,
                        total > 0
                            ? t.tg2BalAllowance(_d(left), _d(total))
                            : t.tg2BalAllowanceNone),
                    if (total > 0) ...[
                      const SizedBox(height: Gap.xs),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        child: LinearProgressIndicator(
                          value: total == 0 ? 0 : left / total,
                          minHeight: 8,
                          semanticsLabel: t.tg2BalAllowance(_d(left), _d(total)),
                        ),
                      ),
                    ],
                    const SizedBox(height: Gap.sm),
                    _line(Icons.inventory_2_rounded, t.tg2BalPack(_d(pack))),
                    const SizedBox(height: Gap.sm),
                    Text(t.tg2BalNoExpiry,
                        style: AType.bodySmall
                            .copyWith(color: scheme.onSurfaceVariant)),
                  ]),
            ),
          ),
          const SizedBox(height: Gap.md),
          if (all <= 0)
            _banner(Icons.block_rounded, t.tg2BalEmpty, scheme.errorContainer,
                scheme.onErrorContainer,
                key: const ValueKey('tg2-bal-empty'))
          else if (low)
            _banner(Icons.warning_amber_rounded, t.tg2BalLow,
                scheme.tertiaryContainer, scheme.onTertiaryContainer,
                key: const ValueKey('tg2-bal-low')),
          if (_b!['ready'] == false) ...[
            const SizedBox(height: Gap.sm),
            _banner(Icons.sms_failed_outlined, t.tg2BalNotReady,
                scheme.surfaceContainerHighest, scheme.onSurface),
          ],
          const SizedBox(height: Gap.md),
          _banner(Icons.volunteer_activism_rounded, t.tg2BalFreeFirst,
              scheme.surfaceContainerHighest, scheme.onSurface),
          const SizedBox(height: Gap.lg),
          Semantics(
            header: true,
            child: Text(t.tg2BalPacksTitle,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: Gap.sm),
          if (!onSale)
            Text(t.tg2BalSoon,
                key: const ValueKey('tg2-bal-soon'), style: AType.bodyMedium),
          for (final p in packs) _packRow(t, p),
          const SizedBox(height: Gap.lg),
          Text(t.tg2BalParts,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(text, style: AType.bodyMedium)),
          ]);

  Widget _banner(IconData icon, String text, Color bg, Color fg, {Key? key}) =>
      Semantics(
        key: key,
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
              color: bg, borderRadius: BorderRadius.circular(Radii.md)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(text, style: AType.bodyMedium.copyWith(color: fg))),
          ]),
        ),
      );

  Widget _packRow(AppLocalizations t, Map<String, dynamic> p) {
    final parts = (p['parts'] as num?)?.toInt() ?? 0;
    final price = (p['price_bdt'] as num?)?.toInt() ?? 0;
    final sku = '${p['sku'] ?? ''}';
    final sale = p['on_sale'] == true && sku.isNotEmpty;
    return Card(
      margin: const EdgeInsets.only(top: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Gap.md,
          runSpacing: Gap.sm,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.tg2BalPackRow(_d(parts)),
                  style: Theme.of(context).textTheme.titleSmall),
              if (price > 0)
                Text('৳${_d(price)}',
                    style: AType.bodyMedium
                        .copyWith(fontFeatures: AFonts.tabular)),
            ]),
            if (sale)
              FilledButton(
                key: ValueKey('tg2-buy-$sku'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => _buy(sku),
                child: Text(t.tg2BalBuy),
              )
            else
              Text(t.tg2BalSoonShort,
                  style: AType.bodySmall.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
