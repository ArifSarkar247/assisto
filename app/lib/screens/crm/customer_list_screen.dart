import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../services/error_kind.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'crm100_api.dart';
import 'crm_bulk_send_screen.dart';
import 'crm_common.dart';
import 'customer_history_screen.dart';
import 'shop_quote_screens.dart';

/// crm100 — every customer once: khata customers, shop-till customers,
/// online-order customers, AI-chat customers and CRM leads, merged by phone.
/// Search by name or number (Bangla digits too), "has a due" filter, paged
/// 50 at a time (fast with 500+). Tap → the one history page. Select → one
/// message card per customer (never one blast).
class CustomerListScreen extends StatefulWidget {
  final int? business;

  /// Inside the CRM tabs (no own Scaffold / app bar).
  final bool embedded;
  const CustomerListScreen({super.key, this.business, this.embedded = false});

  @override
  State<CustomerListScreen> createState() => _CustomerListScreenState();
}

class _CustomerListScreenState extends State<CustomerListScreen> {
  final _search = TextEditingController();
  Timer? _deb;
  List<Map<String, dynamic>> _rows = [];
  int _total = 0;
  int? _nextOffset;
  bool _loading = true;
  bool _more = false;
  Object? _fail;
  String? _only;
  bool _hasBusiness = true;
  final _picked = <String, Map<String, dynamic>>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _deb?.cancel();
    _search.dispose();
    super.dispose();
  }

  String _d(Object v) =>
      localDigits('$v', Localizations.localeOf(context).languageCode);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    try {
      final r = await Crm100Api.of(context)
          .customers(business: widget.business, q: _search.text.trim(), only: _only)
          .timeout(const Duration(seconds: 20));
      _rows = ((r['results'] ?? []) as List).cast<Map<String, dynamic>>();
      _total = (r['total'] as num?)?.toInt() ?? _rows.length;
      _nextOffset = (r['next_offset'] as num?)?.toInt();
      _hasBusiness = r['has_business'] != false;
    } catch (e) {
      _fail = e;
      reportNonFatal('crm100.customers', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMore() async {
    if (_nextOffset == null || _more) return;
    setState(() => _more = true);
    try {
      final r = await Crm100Api.of(context).customers(
          business: widget.business,
          q: _search.text.trim(),
          only: _only,
          offset: _nextOffset!);
      _rows = [..._rows, ...((r['results'] ?? []) as List).cast<Map<String, dynamic>>()];
      _nextOffset = (r['next_offset'] as num?)?.toInt();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(honestFailText(AppLocalizations.of(context), e))));
      }
    }
    if (mounted) setState(() => _more = false);
  }

  void _onSearch(String _) {
    _deb?.cancel();
    _deb = Timer(const Duration(milliseconds: 350), _load);
  }

  void _open(Map<String, dynamic> r) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CustomerHistoryScreen(
            target: CustomerTarget.fromRow(r),
            name: '${r['name'] ?? ''}',
            business: widget.business)));
  }

  void _togglePick(Map<String, dynamic> r) {
    final k = '${r['key']}';
    setState(() => _picked.containsKey(k) ? _picked.remove(k) : _picked[k] = r);
  }

  Future<void> _bulk() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CrmBulkSendScreen(
            business: widget.business,
            customers: _picked.values.toList())));
    if (mounted) setState(_picked.clear);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final body = _body(t);
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.c100CustomersTitle),
        actions: [
          if (_hasBusiness)
            IconButton(
              tooltip: t.c100QuotesTitle,
              icon: const Icon(Icons.request_quote_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ShopQuoteListScreen(business: widget.business))),
            ),
        ],
      ),
      body: body,
    );
  }

  Widget _body(AppLocalizations t) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
        child: TextField(
          controller: _search,
          onChanged: _onSearch,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: t.c100SearchHint,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Row(children: [
          for (final e in {
            null: t.c100FAll,
            'due': t.c100OnlyDue,
            'order': t.c100FOrders,
            'chat': t.c100FChats,
            'crm': t.c100FCrm,
          }.entries)
            Padding(
              padding: const EdgeInsets.only(right: Gap.xs),
              child: ChoiceChip(
                label: Text(e.value),
                selected: _only == e.key,
                onSelected: (_) {
                  setState(() => _only = e.key);
                  _load();
                },
              ),
            ),
        ]),
      ),
      if (_picked.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, 0),
          child: Row(children: [
            Expanded(child: Text(t.c100Picked(_d(_picked.length)))),
            TextButton(onPressed: () => setState(_picked.clear), child: Text(t.cancel)),
            FilledButton.icon(
                onPressed: _bulk,
                icon: const Icon(Icons.send_rounded),
                label: Text(t.c100MessageEach)),
          ]),
        ),
      Expanded(child: _list(t)),
    ]);
  }

  Widget _list(AppLocalizations t) {
    if (_loading && _rows.isEmpty) return const SkeletonList();
    if (_fail != null) {
      final net = failKindOf(_fail!) == FailKind.network;
      return StateMessage(
        icon: net ? Icons.wifi_off_rounded : Icons.cloud_off_rounded,
        title: net ? t.c100OfflineTitle : t.loadFailed,
        message: net ? t.c100OfflineList : honestFailText(t, _fail),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_rows.isEmpty) {
      final searching = _search.text.trim().isNotEmpty || _only != null;
      return StateMessage(
        icon: searching ? Icons.search_off_rounded : Icons.people_outline_rounded,
        title: searching ? t.c100NoMatch : t.c100NoCustomersTitle,
        message: searching ? null : t.c100NoCustomersBody,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: Gap.xxl),
        itemCount: _rows.length + 2,
        itemBuilder: (_, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
              child: Text(t.c100CountLine(_d(_total)),
                  style: AType.bodySmall
                      .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            );
          }
          if (i == _rows.length + 1) {
            if (_nextOffset == null) return const SizedBox(height: Gap.lg);
            return Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: OutlinedButton(
                  onPressed: _more ? null : _loadMore, child: Text(t.c100LoadMore)),
            );
          }
          return _tile(t, _rows[i - 1]);
        },
      ),
    );
  }

  Widget _tile(AppLocalizations t, Map<String, dynamic> r) {
    final scheme = Theme.of(context).colorScheme;
    final name = '${r['name'] ?? ''}'.trim();
    final phone = '${r['phone'] ?? ''}';
    final due = (r['due_poisha'] as num?)?.toInt() ?? 0;
    final orders = (r['orders'] as num?)?.toInt() ?? 0;
    final picked = _picked.containsKey('${r['key']}');
    final sources = ((r['sources'] ?? const []) as List).map((e) => '$e').toList();
    final sub = [
      if (phone.isNotEmpty) _d(phone),
      if (orders > 0) t.c100OrdersN(_d(orders)),
      if (sources.contains('chat')) t.c100SrcChat,
      if (sources.contains('crm')) t.c100SrcCrm,
    ].join(' · ');
    return ListTile(
      minVerticalPadding: Gap.sm,
      leading: Checkbox(
        value: picked,
        semanticLabel: t.c100PickA11y(name.isEmpty ? _d(phone) : name),
        onChanged: (_) => _togglePick(r),
      ),
      title: Text(name.isEmpty ? t.c100NoName : name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: due > 0
          ? Text(bdt(context, due / 100),
              style: AType.titleSmall.copyWith(color: scheme.error, fontWeight: FontWeight.w800))
          : const Icon(Icons.chevron_right_rounded),
      onTap: () => _open(r),
      onLongPress: () => _togglePick(r),
    );
  }
}
