// invoices — the hub: set up once, print any shop sale again, make a service
// invoice (lawyer / VAT-tax consultant / any service).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart' show withNavBarInset;
import '../../../widgets/fam_empty.dart';
import 'invoice_api.dart';
import 'invoice_doc.dart';
import 'invoice_paper.dart' show templateLabel;
import 'invoice_screen.dart';
import 'invoice_settings_screen.dart';
import 'new_invoice_screen.dart';

class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key, this.businessId});
  final int? businessId;
  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  bool _loading = true;
  Object? _error;
  bool _saved = true;
  bool _canEdit = false;
  List<Map<String, dynamic>> _sales = const [], _manual = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<AppState>().api;
    try {
      final r = await Future.wait([
        api.invoiceSettings(businessId: widget.businessId),
        api.invoiceSales(businessId: widget.businessId),
        api.manualInvoices(businessId: widget.businessId),
      ]);
      _saved = r[0]['saved'] == true;
      _canEdit = r[0]['can_edit'] == true;
      _sales = ((r[1]['items'] ?? const []) as List).cast<Map<String, dynamic>>();
      _manual = ((r[2]['items'] ?? const []) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _settings() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InvoiceSettingsScreen(businessId: widget.businessId)));
    if (mounted) _load();
  }

  Future<void> _new() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => NewInvoiceScreen(businessId: widget.businessId)));
    if (mounted) _load();
  }

  void _openManual(int id) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InvoiceScreen(
            businessId: widget.businessId,
            loader: (c) => c.read<AppState>().api.manualInvoice(id, businessId: widget.businessId))));
  }

  String _when(String iso, String lang) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})').firstMatch(iso);
    if (m == null) return '';
    return invNum('${m[3]}/${m[2]}/${m[1]} ${m[4]}:${m[5]}', lang);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.invLoadFailed, textAlign: TextAlign.center),
            const SizedBox(height: Gap.md),
            FilledButton(onPressed: _load, child: Text(t.invRetry)),
          ]),
        ),
      );
    } else if (_sales.isEmpty && _manual.isEmpty) {
      body = FamEmptyState(
        icon: Icons.receipt_long_rounded,
        title: t.invHubEmptyTitle,
        benefit: t.invHubBenefit,
        primaryLabel: t.invHubNew,
        onPrimary: _new,
        steps: [t.invHubStep1, t.invHubStep2, t.invHubStep3],
        secondaryLabel: _canEdit ? t.invSetTitle : null,
        onSecondary: _canEdit ? _settings : null,
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
          children: [
            Text(t.invHubBenefit, style: tt.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            if (!_saved && _canEdit)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.invNotSetBanner),
                    const SizedBox(height: Gap.sm),
                    FilledButton.tonal(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                        onPressed: _settings,
                        child: Text(t.invSetUpNow)),
                  ]),
                ),
              ),
            FilledButton.icon(
              key: const ValueKey('inv-new'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _new,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.invHubNew),
            ),
            const SizedBox(height: Gap.lg),
            Text(t.invHubManual, style: tt.titleMedium),
            if (_manual.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: Text(t.invHubManualEmpty, style: tt.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            for (final m in _manual)
              ListTile(
                contentPadding: EdgeInsets.zero,
                minVerticalPadding: Gap.sm,
                leading: const Icon(Icons.description_outlined),
                title: Text('${invNum(m['number'] ?? '', lang)} · ${m['buyer'] ?? ''}'),
                subtitle: Text([
                  templateLabel(t, '${m['template']}'),
                  _when('${m['issued_at'] ?? ''}', lang),
                  if (m['cancelled'] == true) t.invCancelled,
                ].where((s) => s.isNotEmpty).join(' · ')),
                trailing: Text(invMoney((m['total'] as num?)?.toInt() ?? 0, lang),
                    style: tt.titleSmall),
                onTap: () => _openManual((m['id'] as num).toInt()),
              ),
            const SizedBox(height: Gap.lg),
            Text(t.invHubRecentSales, style: tt.titleMedium),
            if (_sales.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: Text(t.invHubEmptySales, style: tt.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            for (final s in _sales)
              ListTile(
                contentPadding: EdgeInsets.zero,
                minVerticalPadding: Gap.sm,
                leading: const Icon(Icons.point_of_sale_rounded),
                title: Text([
                  _when('${s['issued_at'] ?? ''}', lang),
                  if ('${s['buyer'] ?? ''}'.isNotEmpty) '${s['buyer']}',
                ].join(' · ')),
                subtitle: s['cancelled'] == true ? Text(t.invCancelled) : null,
                trailing: Text(invMoney((s['total'] as num?)?.toInt() ?? 0, lang),
                    style: tt.titleSmall),
                onTap: () => openSaleInvoice(context, (s['id'] as num).toInt(),
                    businessId: widget.businessId),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.invHubTitle), actions: [
        if (_canEdit)
          IconButton(
              tooltip: t.invSetTitle,
              icon: const Icon(Icons.tune_rounded),
              onPressed: _settings),
      ]),
      body: body,
    );
  }
}
