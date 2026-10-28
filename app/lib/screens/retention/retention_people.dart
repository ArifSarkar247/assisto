import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'retention_source.dart';
import 'retention_widgets.dart';
import '../../widgets/app_sheet.dart';

/// retention1 — the owner's two small lists the automations read:
/// customer birthdays (only when the customer told the shop) and
/// "who asked for what" (back-in-stock requests).

class RetentionBirthdaysScreen extends StatefulWidget {
  final RetentionSource source;
  const RetentionBirthdaysScreen({super.key, required this.source});

  @override
  State<RetentionBirthdaysScreen> createState() => _RetentionBirthdaysScreenState();
}

class _RetentionBirthdaysScreenState extends State<RetentionBirthdaysScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.source.customers(_q.text.trim());
      _rows = rtList(d['customers']);
    } catch (e) {
      _error = rtError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _set(Map<String, dynamic> c) async {
    final t = AppLocalizations.of(context);
    final cur = DateTime.tryParse((c['birthday'] ?? '').toString());
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: cur ?? DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: t.rtSetBirthday,
    );
    if (picked == null) return;
    final iso = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    await _save(c, iso);
  }

  Future<void> _save(Map<String, dynamic> c, String? iso) async {
    final t = AppLocalizations.of(context);
    try {
      await widget.source.setBirthday(rtInt(c['id']), iso);
      if (mounted) rtSnack(context, t.rtSaved);
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final loc = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.rtBirthdaysTitle)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(t.rtBirthdaysHelp),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _q,
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 350), _load);
            },
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              labelText: t.rtSearchCustomers,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(child: _list(t, loc)),
      ]),
    );
  }

  Widget _list(AppLocalizations t, MaterialLocalizations loc) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return RtMessage(
        icon: Icons.cloud_off_rounded,
        title: t.rtLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.rtLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.rtRetry)),
      );
    }
    if (_rows.isEmpty) {
      return RtMessage(icon: Icons.people_outline_rounded, title: t.rtBirthdaysTitle, body: t.rtNoCustomers);
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final c = _rows[i];
        final bd = DateTime.tryParse((c['birthday'] ?? '').toString());
        return ListTile(
          minVerticalPadding: 12,
          leading: const Icon(Icons.person_outline_rounded),
          title: Text((c['name'] ?? '').toString().isEmpty
              ? rtDigits(rtLang(context), c['phone'] ?? '')
              : c['name'].toString()),
          subtitle: Text(bd == null ? t.rtBirthdayNone : loc.formatMediumDate(bd)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: t.rtSetBirthday,
              icon: const Icon(Icons.edit_calendar_outlined),
              onPressed: () => _set(c),
            ),
            if (bd != null)
              IconButton(
                tooltip: t.rtRemoveBirthday,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => _save(c, null),
              ),
          ]),
          onTap: () => _set(c),
        );
      },
    );
  }
}

class RetentionStockAsksScreen extends StatefulWidget {
  final RetentionSource source;
  const RetentionStockAsksScreen({super.key, required this.source});

  @override
  State<RetentionStockAsksScreen> createState() => _RetentionStockAsksScreenState();
}

class _RetentionStockAsksScreenState extends State<RetentionStockAsksScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = const {};

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
    try {
      _data = await widget.source.stockAsks();
    } catch (e) {
      _error = rtError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final t = AppLocalizations.of(context);
    final products = rtList(_data['products']);
    if (products.isEmpty) {
      rtSnack(context, t.rtNoProducts);
      return;
    }
    final res = await showAppSheet<(int, int)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddAskSheet(source: widget.source, products: products),
    );
    if (res == null) return;
    try {
      await widget.source.addStockAsk(res.$1, res.$2);
      if (mounted) rtSnack(context, t.rtSaved);
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    await _load();
  }

  Future<void> _remove(Map<String, dynamic> a) async {
    final t = AppLocalizations.of(context);
    try {
      await widget.source.removeStockAsk(rtInt(a['id']));
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.rtAsksTitle)),
      floatingActionButton: (_loading || _error != null)
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.rtAddAsk),
            ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return RtMessage(
        icon: Icons.cloud_off_rounded,
        title: t.rtLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.rtLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.rtRetry)),
      );
    }
    final asks = rtList(_data['asks']);
    return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: Text(t.rtAsksHelp)),
      if (asks.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Text(t.rtNoAsks, textAlign: TextAlign.center),
        ),
      for (final a in asks)
        ListTile(
          minVerticalPadding: 12,
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text((a['product'] ?? '').toString()),
          subtitle: Text('${(a['customer'] ?? '').toString()} · '
              '${a['notified'] == true ? t.rtAskNotified : (a['in_stock'] == true ? t.rtAskInStock : t.rtAskWaiting)}'),
          trailing: IconButton(
            tooltip: t.rtRemove,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => _remove(a),
          ),
        ),
    ]);
  }
}

class _AddAskSheet extends StatefulWidget {
  final RetentionSource source;
  final List<Map<String, dynamic>> products;
  const _AddAskSheet({required this.source, required this.products});

  @override
  State<_AddAskSheet> createState() => _AddAskSheetState();
}

class _AddAskSheetState extends State<_AddAskSheet> {
  int? _product;
  int? _customer;
  final _q = TextEditingController();
  List<Map<String, dynamic>> _custs = const [];
  bool _busy = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _busy = true);
    try {
      final d = await widget.source.customers(_q.text.trim());
      _custs = rtList(d['customers']);
    } catch (_) {
      _custs = const [];
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = rtLang(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(t.rtAddAsk, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _product,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.rtPickProduct, border: const OutlineInputBorder()),
            items: [
              for (final p in widget.products)
                DropdownMenuItem(value: rtInt(p['id']), child: Text((p['name'] ?? '').toString())),
            ],
            onChanged: (v) => setState(() => _product = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _q,
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 350), _search);
            },
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              labelText: t.rtSearchCustomers,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          if (_busy) const LinearProgressIndicator(),
          if (!_busy && _custs.isEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(t.rtNoCustomers)),
          RadioGroup<int>(
            groupValue: _customer,
            onChanged: (v) => setState(() => _customer = v),
            child: Column(children: [
              for (final c in _custs.take(8))
                RadioListTile<int>(
                  value: rtInt(c['id']),
                  title: Text((c['name'] ?? '').toString().isEmpty
                      ? rtDigits(lang, c['phone'] ?? '')
                      : c['name'].toString()),
                  subtitle: Text(rtDigits(lang, c['phone'] ?? '')),
                  contentPadding: EdgeInsets.zero,
                ),
            ]),
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: (_product != null && _customer != null)
                ? () => Navigator.of(context).pop((_product!, _customer!))
                : null,
            child: Text(t.rtSave),
          ),
        ]),
      ),
    );
  }
}
