import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_report.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/subs_common.dart' show fmtInt;

/// bizbar: the hub's low-stock nudge — "3 products are running low" with one
/// tap to the filtered product list. Server counts every product whose stock
/// is at or under its own low-stock mark (`low_stock_count`). Hidden when
/// nothing is low or the count could not be loaded (never a made-up number).
class LowStockCard extends StatefulWidget {
  final int businessId;
  final VoidCallback onOpen;
  const LowStockCard(
      {super.key, required this.businessId, required this.onOpen});
  @override
  State<LowStockCard> createState() => _LowStockCardState();
}

class _LowStockCardState extends State<LowStockCard> {
  int _n = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context
          .read<AppState>()
          .api
          .getJson('/business/products?business=${widget.businessId}&low=1');
      final n = (r['low_stock_count'] as num?)?.toInt() ??
          ((r['products'] as List?)?.length ?? 0);
      if (mounted) setState(() => _n = n);
    } catch (e) {
      reportNonFatal('bizhub.lowStock', e); // best-effort: the card stays hidden
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_n <= 0) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final warn = AssistoTokens.of(context).warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Card(
        color: warn.withValues(alpha: 0.12),
        child: ListTile(
          key: const ValueKey('bb-low-stock-card'),
          minVerticalPadding: Gap.md,
          leading: Icon(Icons.warning_amber_rounded, color: warn),
          title: Text(t.bbLowStockTitle(fmtInt(context, _n)),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(t.bbLowStockSub),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: widget.onOpen,
        ),
      ),
    );
  }
}
