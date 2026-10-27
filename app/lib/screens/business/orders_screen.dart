import 'package:flutter/material.dart';
import 'selling_common.dart' show MoneyUiX;
import 'package:provider/provider.dart';
import '../../business_ai_api.dart';
import '../../business_selling_api.dart' show MoneyX;
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/business_ui.dart';
import '../../widgets/skeleton.dart';

/// Orders (FREE for status; courier booking is key-gated mock).
///
/// State machine: new → confirmed → packed → shipped (Pathao / Steadfast /
/// RedX — key-gated mock) → delivered / returned. COD tracking + a
/// "where is my parcel?" status read.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

/// Ordered status machine. `returned` is a terminal branch off `shipped`.
const _statusFlow = ['new', 'confirmed', 'packed', 'shipped', 'delivered'];

String statusLabel(AppLocalizations tr, String s) {
  switch (s) {
    case 'new':
      return tr.parcelNew;
    case 'confirmed':
      return tr.parcelConfirmed;
    case 'packed':
      return tr.parcelPacked;
    case 'shipped':
      return tr.parcelShipped;
    case 'delivered':
      return tr.parcelDelivered;
    case 'returned':
      return tr.parcelReturned;
    case 'cancelled':
      return tr.parcelCancelled;
    default:
      return s;
  }
}

/// [statusLabel] for a stand-alone chip: first letter upper-cased (a no-op
/// for Bangla).
String statusChipLabel(AppLocalizations tr, String s) {
  final l = statusLabel(tr, s);
  return l.isEmpty ? l : l[0].toUpperCase() + l.substring(1);
}

Color statusColor(String s) {
  switch (s) {
    case 'delivered':
      return Brand.success;
    case 'returned':
    case 'cancelled':
      return Brand.danger;
    case 'shipped':
      return Brand.blue;
    case 'new':
      return Brand.warning;
    default:
      return Brand.purple;
  }
}

class _OrdersScreenState extends State<OrdersScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _orders = const [];

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
      _orders = await api.ordersList();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.orders)),
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
    if (_orders.isEmpty) {
      return StateMessage(
          icon: Icons.receipt_long_rounded, title: tr.noOrdersYet);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _orders.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
        itemBuilder: (_, i) => _orderTile(tr, _orders[i]),
      ),
    );
  }

  Widget _orderTile(AppLocalizations tr, Map<String, dynamic> o) {
    final status = (o['status'] ?? 'new').toString();
    final cod = o['payment'] == 'cod';
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
        // name gets the full width; status/amount/COD wrap below it so a
        // long Bangla status never squeezes the customer's name to "…".
        title: Text('#${o['id']} · ${o['customer_name'] ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
            Text(_takaFmt(context, o['total']), style: const TextStyle(fontWeight: FontWeight.w600)),
            BizStatusChip(label: statusChipLabel(tr, status), color: statusColor(status)),
            if (cod) BizStatusChip(label: tr.bizCod, color: AssistoTokens.of(context).warning),
          ]),
        ),
        onTap: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
                builder: (_) => OrderDetailScreen(orderId: (o['id'] as num).toInt())),
          );
          if (changed == true) _load();
        },
      ),
    );
  }
}

/// Order detail: items + state machine actions + parcel status + COD.
class OrderDetailScreen extends StatefulWidget {
  final int orderId;
  const OrderDetailScreen({super.key, required this.orderId});
  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  String? _error;
  Map<String, dynamic> _order = const {};
  Map<String, dynamic>? _parcel;

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
      _order = await api.order(widget.orderId);
      _parcel = await api.orderParcel(widget.orderId);
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  String get _status => (_order['status'] ?? 'new').toString();

  String? get _nextStatus {
    final i = _statusFlow.indexOf(_status);
    if (i < 0 || i >= _statusFlow.length - 1) return null;
    return _statusFlow[i + 1];
  }

  Future<void> _advance(String target, {String? courier}) async {
    setState(() => _busy = true);
    final api = context.read<AppState>().api;
    final tr = AppLocalizations.of(context);
    try {
      final r = await api.orderAdvance(widget.orderId, target, courier: courier);
      _dirty = true;
      if (r['courier_live'] == false && target == 'shipped') {
        _snack(tr.truthCourierManualNote);
      }
      await _load();
    } catch (e) {
      _snack(e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Advancing to `shipped` needs a courier choice (key-gated mock booking).
  Future<void> _ship() async {
    final tr = AppLocalizations.of(context);
    final courier = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: Gap.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(tr.bizChooseCourier,
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
          for (final c in const ['pathao', 'steadfast', 'redx'])
            ListTile(
              leading: const Icon(Icons.local_shipping_rounded),
              title: Text(_courierName(c)),
              onTap: () => Navigator.pop(ctx, c),
            ),
          Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: BizMockBanner(text: tr.truthCourierManualNote),
          ),
        ]),
      ),
    );
    if (courier != null) await _advance('shipped', courier: courier);
  }

  String _courierName(String c) {
    switch (c) {
      case 'pathao':
        return 'Pathao';
      case 'steadfast':
        return 'Steadfast';
      case 'redx':
        return 'RedX';
      default:
        return c;
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_dirty);
      },
      child: Scaffold(
        appBar: AppBar(title: Text('#${widget.orderId}')),
        body: _loading
            ? const SkeletonList()
            : _error != null
                ? StateMessage(
                    icon: Icons.cloud_off_rounded,
                    title: tr.bizLoadFailed,
                    message: _error,
                    action: FilledButton(onPressed: _load, child: Text(tr.bizRetry)),
                  )
                : _content(tr),
      ),
    );
  }

  Widget _content(AppLocalizations tr) {
    // list rows carry an item COUNT; only the detail carries the item list
    final rawItems = _order['items'];
    final items = rawItems is List
        ? rawItems.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const <Map<String, dynamic>>[];
    final cod = _order['payment'] == 'cod';
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      // Parcel status line ("where is my parcel?").
      BizCard(
        title: tr.bizParcelStatus,
        icon: Icons.local_shipping_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            BizStatusChip(label: statusChipLabel(tr, _status), color: statusColor(_status)),
          ]),
          if (_parcel?['line'] != null) ...[
            const SizedBox(height: Gap.sm),
            Text((_parcel!['line']).toString(), style: const TextStyle(height: 1.4)),
          ],
          if (_order['tracking'] != null && (_order['tracking']).toString().isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(
              tr.parcelTracking(
                  _courierName((_order['courier'] ?? '').toString()),
                  (_order['tracking']).toString()),
              style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
          if (_order['courier_live'] == false && _status == 'shipped') ...[
            const SizedBox(height: Gap.sm),
            BizMockBanner(text: tr.truthCourierManualNote),
          ],
        ]),
      ),
      const SizedBox(height: Gap.md),
      // Items.
      BizCard(
        title: tr.bizItems,
        icon: Icons.inventory_2_rounded,
        child: Column(children: [
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(children: [
                Expanded(child: Text((it['name'] ?? '').toString())),
                Text('×${it['qty'] ?? 1}'),
                const SizedBox(width: Gap.md),
                Text(_takaFmt(context, it['price']), style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
          const Divider(),
          Row(children: [
            Expanded(child: Text(tr.bizTotal, style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(_takaFmt(context, _order['total']), style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          if (cod) ...[
            const SizedBox(height: Gap.sm),
            BizNote(text: tr.bizCodCollect(_takaFmt(context, _order['cod_amount'] ?? _order['total'])), icon: Icons.payments_rounded, tint: AssistoTokens.of(context).warning),
          ],
        ]),
      ),
      const SizedBox(height: Gap.md),
      _actions(tr),
    ]);
  }

  Widget _actions(AppLocalizations tr) {
    final next = _nextStatus;
    final isTerminal = _status == 'delivered' || _status == 'returned' || _status == 'cancelled';
    return BizCard(
      title: tr.bizUpdateStatus,
      icon: Icons.sync_alt_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (next != null)
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => next == 'shipped' ? _ship() : _advance(next),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(tr.bizAdvanceTo(statusLabel(tr, next))),
          ),
        if (_status == 'shipped') ...[
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _advance('returned'),
            icon: const Icon(Icons.undo_rounded),
            label: Text(tr.bizMarkReturned),
          ),
        ],
        if (isTerminal)
          Text(tr.bizOrderClosed,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// Order totals arrive as TAKA decimals ("2400.00") -> "৳2,400".
String _takaFmt(BuildContext context, Object? v) =>
    ((double.tryParse('${v ?? 0}') ?? 0) * 100).round().takaIn(context);
