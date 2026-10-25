import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../api.dart';
import '../../business_selling_api.dart';
import '../../widgets/skeleton.dart';
import '../../l10n/app_localizations.dart';
import 'selling_common.dart';

/// Customers (§3): list, add/edit (name/phone/address/area/notes/VIP), purchase
/// history and open dues. Dedupe is by normalised phone — saving a known phone
/// updates the existing record (server `find_or_create_customer`/`phone_key`).
class CustomersScreen extends StatefulWidget {
  final int? businessId;
  const CustomersScreen({super.key, this.businessId});
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  Object? _error;
  String _q = '';

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
      _items = await sellApi(context)
          .customersList(businessId: widget.businessId, query: _q);
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openSheet([Map<String, dynamic>? c]) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          CustomerEditSheet(businessId: widget.businessId, customer: c),
    );
    if (changed == true) _load();
  }

  Future<void> _openHistory(Map<String, dynamic> c) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CustomerHistorySheet(customer: c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.shopQaCustomers)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openSheet(),
        icon: const Icon(Icons.person_add_alt_rounded),
        label: Text(t.shopQaAddCustomer),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
          child: TextField(
            decoration: InputDecoration(
              hintText: '${t.biz_customer_name} / ${t.biz_customer_phone}',
              prefixIcon: const Icon(Icons.search_rounded),
            ),
            onChanged: (v) {
              _q = v.trim();
              _load();
            },
          ),
        ),
        Expanded(child: _body(t, scheme)),
      ]),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: scheme.error,
        title: t.loadFailed,
        message: _error is ApiException ? (_error as ApiException).message : null,
        action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry)),
      );
    }
    if (_items.isEmpty) {
      return StateMessage(
        icon: Icons.people_outline_rounded,
        title: t.shopQaNoCustomersTitle,
        message: t.shopQaNoCustomersBody,
        action: FilledButton.icon(
            onPressed: () => _openSheet(),
            icon: const Icon(Icons.person_add_alt_rounded),
            label: Text(t.shopQaAddCustomer)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
        itemBuilder: (_, i) {
          final c = _items[i];
          final dues = poishaOf(c['dues'] ?? c['due']);
          final vip = c['vip'] == true;
          return InkWell(
            onTap: () => _openHistory(c),
            borderRadius: BorderRadius.circular(Radii.md),
            child: SellCard(
              child: Row(children: [
                CircleAvatar(
                  backgroundColor:
                      vip ? AssistoTokens.of(context).warning.withValues(alpha: 0.2) : scheme.surfaceContainerHighest,
                  child: Icon(vip ? Icons.star_rounded : Icons.person_outline_rounded,
                      color: vip ? AssistoTokens.of(context).warning : scheme.onSurfaceVariant),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Flexible(
                            child: Text(
                                (c['name'] ?? '').toString().isEmpty
                                    ? (c['phone'] ?? '').toString()
                                    : c['name'].toString(),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                                overflow: TextOverflow.ellipsis),
                          ),
                          if (vip) ...[
                            const SizedBox(width: Gap.sm),
                            _vipBadge(t),
                          ],
                        ]),
                        if ((c['phone'] ?? '').toString().isNotEmpty)
                          Text(c['phone'].toString(),
                              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                        if ((c['area'] ?? '').toString().isNotEmpty)
                          Text(c['area'].toString(),
                              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                ),
                if (dues > 0)
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(t.biz_customer_dues,
                        style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
                    Text(dues.takaIn(context),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800)),
                  ]),
                IconButton(
                  tooltip: AppLocalizations.of(context).edit,
                  icon: const Icon(Icons.edit_rounded),
                  onPressed: () => _openSheet(c),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _vipBadge(AppLocalizations t) => Builder(builder: (context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: Gap.xxs),
        decoration: BoxDecoration(
            color: AssistoTokens.of(context).warning.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(t.biz_customer_vip,
            style: AType.labelSmall.copyWith(color: Brand.onTint(context, AssistoTokens.of(context).warning),
                fontWeight: FontWeight.w700)),
      ));
}

// ============================================================ edit sheet

class CustomerEditSheet extends StatefulWidget {
  final int? businessId;
  final Map<String, dynamic>? customer;
  const CustomerEditSheet({super.key, this.businessId, this.customer});
  @override
  State<CustomerEditSheet> createState() => _CustomerEditSheetState();
}

class _CustomerEditSheetState extends State<CustomerEditSheet> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _area = TextEditingController();
  final _notes = TextEditingController();
  bool _vip = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    if (c != null) {
      _name.text = (c['name'] ?? '').toString();
      _phone.text = (c['phone'] ?? '').toString();
      _address.text = (c['address'] ?? '').toString();
      _area.text = (c['area'] ?? '').toString();
      _notes.text = (c['notes'] ?? '').toString();
      _vip = c['vip'] == true;
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _area, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await sellApi(context).customerSave({
        if (widget.businessId != null) 'business': widget.businessId,
        if (widget.customer?['id'] != null) 'id': widget.customer!['id'],
        'name': _name.text.trim(),
        'phone': _phone.text.trim(),
        'address': _address.text.trim(),
        'area': _area.text.trim(),
        'notes': _notes.text.trim(),
        'vip': _vip,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (_, scroll) => Form(
          key: _form,
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(Gap.lg),
            children: [
              Text(t.biz_customer,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextFormField(
                controller: _name,
                decoration: InputDecoration(labelText: t.biz_customer_name),
              ),
              const SizedBox(height: Gap.md),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: t.biz_customer_phone,
                  prefixIcon: const Icon(Icons.phone_rounded),
                ),
                validator: (v) {
                  // Phone or name required for a usable record; dedupe is by phone.
                  if ((v == null || v.trim().isEmpty) &&
                      _name.text.trim().isEmpty) {
                    return t.biz_customer_phone;
                  }
                  return null;
                },
              ),
              const SizedBox(height: Gap.md),
              TextFormField(
                controller: _area,
                decoration: InputDecoration(labelText: t.biz_customer_area),
              ),
              const SizedBox(height: Gap.md),
              TextFormField(
                controller: _address,
                maxLines: 2,
                decoration: InputDecoration(labelText: t.biz_customer_address),
              ),
              const SizedBox(height: Gap.md),
              TextFormField(
                controller: _notes,
                maxLines: 2,
                decoration: InputDecoration(labelText: t.biz_customer_notes),
              ),
              const SizedBox(height: Gap.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.biz_customer_vip),
                secondary: const Icon(Icons.star_outline_rounded),
                value: _vip,
                onChanged: (v) => setState(() => _vip = v),
              ),
              const SizedBox(height: Gap.lg),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(t.save),
              ),
              const SizedBox(height: Gap.lg),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================ history sheet

class CustomerHistorySheet extends StatefulWidget {
  final Map<String, dynamic> customer;
  const CustomerHistorySheet({super.key, required this.customer});
  @override
  State<CustomerHistorySheet> createState() => _CustomerHistorySheetState();
}

class _CustomerHistorySheetState extends State<CustomerHistorySheet> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final phone = (widget.customer['phone'] ?? '').toString();
      _data = await sellApi(context).customerHistory(phone);
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sales = ((_data?['sales'] ?? _data?['history'] ?? []) as List);
    final dues = poishaOf(_data?['dues'] ?? _data?['due']);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text((widget.customer['name'] ?? widget.customer['phone'] ?? '')
              .toString(),
              style: Theme.of(context).textTheme.titleLarge),
          Text(t.biz_purchase_history,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          if (dues > 0)
            SellCard(
              child: MoneyRow(t.biz_customer_dues, dues,
                  strong: true, valueColor: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: Gap.md),
          if (_loading)
            const SkeletonList(count: 4)
          else if (_error != null)
            StateMessage(
                icon: Icons.cloud_off_rounded,
                tint: scheme.error,
                title: t.loadFailed)
          else if (sales.isEmpty)
            StateMessage(
                icon: Icons.receipt_long_rounded,
                title: t.biz_purchase_history,
                message: t.biz_cart_empty)
          else
            for (final s in sales)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.receipt_rounded),
                title: Text((s['date'] ?? s['created_at'] ?? '').toString()),
                subtitle: Text(
                    '${(s['lines'] as List?)?.length ?? s['items'] ?? 0} · ${(s['payment_method'] ?? '').toString()}'),
                trailing: Text(poishaOf(s['total']).takaIn(context),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
          const SizedBox(height: Gap.lg),
        ],
      ),
    );
  }
}
