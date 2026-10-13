import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Business mode (feature 33): catalog + orders + a reply tester. Replies use
/// only the real catalog (never invents price/stock). Live WhatsApp send needs
/// the Meta integration (owner adds it in Integrations).
class BusinessScreen extends StatelessWidget {
  const BusinessScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String tr(String bn, String e) => en ? e : bn;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('বিজনেস', 'Business')),
          bottom: TabBar(tabs: [
            Tab(text: tr('ক্যাটালগ', 'Catalog')),
            Tab(text: tr('অর্ডার', 'Orders')),
            Tab(text: tr('রিপ্লাই টেস্ট', 'Reply test')),
          ]),
        ),
        body: TabBarView(children: [
          _CatalogTab(tr: tr),
          _SimpleList(path: 'orders', tr: tr, emptyIcon: Icons.receipt_long_outlined,
              emptyTitle: tr('কোনো অর্ডার নেই', 'No orders yet'),
              line: (o) => '#${o['id']} · ৳${o['total']} · ${o['status']}'),
          _ReplyTab(tr: tr),
        ]),
      ),
    );
  }
}

class _CatalogTab extends StatefulWidget {
  final String Function(String, String) tr;
  const _CatalogTab({required this.tr});
  @override
  State<_CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends State<_CatalogTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _items = await context.read<AppState>().api.listItems('products');
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final tr = widget.tr;
    final name = TextEditingController();
    final price = TextEditingController();
    final stock = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('পণ্য যোগ', 'Add product')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: InputDecoration(labelText: tr('নাম', 'Name'))),
          TextField(controller: price, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('দাম', 'Price'))),
          TextField(controller: stock, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('স্টক', 'Stock'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('বাতিল', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('যোগ', 'Add'))),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await context.read<AppState>().api.createItem('products', {
        'name': name.text.trim(),
        'price': price.text.trim().isEmpty ? '0' : price.text.trim(),
        'stock': int.tryParse(stock.text.trim()) ?? 0,
      });
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    if (_loading) return const SkeletonList();
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: _add, child: const Icon(Icons.add)),
      body: _items.isEmpty
          ? StateMessage(icon: Icons.inventory_2_outlined,
              title: tr('কোনো পণ্য নেই', 'No products yet'),
              message: tr('পণ্য যোগ করুন — গ্রাহকের প্রশ্নে সঠিক দাম/স্টক থেকে উত্তর দেব।',
                  'Add products — replies use the real price/stock.'))
          : ListView(padding: const EdgeInsets.all(Gap.md), children: [
              for (final p in _items)
                Card(child: ListTile(
                  title: Text(p['name'] ?? ''),
                  subtitle: Text('${tr('স্টক', 'Stock')}: ${p['stock'] ?? 0}'),
                  trailing: Text('৳${p['price'] ?? 0}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                )),
            ]),
    );
  }
}

class _SimpleList extends StatefulWidget {
  final String path;
  final String Function(String, String) tr;
  final IconData emptyIcon;
  final String emptyTitle;
  final String Function(Map<String, dynamic>) line;
  const _SimpleList({required this.path, required this.tr, required this.emptyIcon,
      required this.emptyTitle, required this.line});
  @override
  State<_SimpleList> createState() => _SimpleListState();
}

class _SimpleListState extends State<_SimpleList> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _items = await context.read<AppState>().api.listItems(widget.path);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonList();
    if (_items.isEmpty) {
      return StateMessage(icon: widget.emptyIcon, title: widget.emptyTitle);
    }
    return ListView(padding: const EdgeInsets.all(Gap.md), children: [
      for (final it in _items)
        Card(child: ListTile(title: Text(widget.line(it)))),
    ]);
  }
}

class _ReplyTab extends StatefulWidget {
  final String Function(String, String) tr;
  const _ReplyTab({required this.tr});
  @override
  State<_ReplyTab> createState() => _ReplyTabState();
}

class _ReplyTabState extends State<_ReplyTab> {
  final _msg = TextEditingController();
  String? _reply;
  bool _busy = false, _handoff = false;

  Future<void> _go() async {
    if (_msg.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.businessReply(_msg.text.trim());
      _reply = r['reply']?.toString();
      _handoff = r['needs_handoff'] == true;
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Text(tr('গ্রাহকের একটা মেসেজ লিখুন — ক্যাটালগ থেকে উত্তর দেখুন।',
          'Type a customer message — see the catalog-based reply.'),
          style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      TextField(controller: _msg, maxLines: 2,
          decoration: InputDecoration(labelText: tr('গ্রাহকের মেসেজ', 'Customer message'))),
      const SizedBox(height: Gap.md),
      FilledButton(onPressed: _busy ? null : _go, child: Text(tr('উত্তর দেখুন', 'Get reply'))),
      if (_reply != null) ...[
        const SizedBox(height: Gap.lg),
        Card(
          color: _handoff
              ? Theme.of(context).colorScheme.tertiaryContainer
              : Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_handoff)
                Text(tr('🙋 মানুষকে হ্যান্ডওভার', 'Hand off to a human'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(_reply!),
            ]),
          ),
        ),
      ],
    ]);
  }
}
