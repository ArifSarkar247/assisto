import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../business_khata_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../../../widgets/rn_bits.dart' show pickCircleMember;
import '../../crm/crm_common.dart' show CrmApi;
import '../business_common.dart' show pair;

/// acctui — "who with?" in ONE tap: the khata's customers / suppliers (with
/// what they owe), a CRM contact, or someone from My Circle; or a new name.
/// Returns {party_id?, name, phone} — a CRM / Circle / new pick becomes a
/// khata party on the server (found by phone first, never duplicated).
Future<Map<String, dynamic>?> pickAcctParty(BuildContext context,
    {required int? businessId, required String book}) {
  return showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PartySheet(businessId: businessId, book: book),
  );
}

class _PartySheet extends StatefulWidget {
  final int? businessId;
  final String book;
  const _PartySheet({required this.businessId, required this.book});

  @override
  State<_PartySheet> createState() => _PartySheetState();
}

class _PartySheetState extends State<_PartySheet> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _rows; // khata (or CRM when _crm)
  bool _failed = false;
  bool _crm = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _rows = null;
      _failed = false;
    });
    final api = context.read<AppState>().api;
    try {
      List<Map<String, dynamic>> rows;
      if (_crm) {
        final crm = CrmApi(api);
        final orgs = await crm.orgs();
        rows = orgs.isEmpty ? [] : await crm.contacts(orgs.first['id'] as int);
      } else {
        final r = await api.khataParties(widget.businessId ?? 0, widget.book);
        rows = ((r['parties'] as List?) ?? const []).cast<Map>()
            .map((m) => m.cast<String, dynamic>()).toList();
      }
      if (mounted) setState(() => _rows = rows);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _circle() async {
    final t = AppLocalizations.of(context);
    final r = await pickCircleMember(context, title: t.acuPickCircle);
    if (r == null || !mounted) return;
    Navigator.pop(context, {
      'name': '${r['name'] ?? ''}'.trim(),
      'phone': '${r['phone'] ?? ''}'.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final q = _q.text.trim().toLowerCase();
    final rows = (_rows ?? const <Map<String, dynamic>>[])
        .where((r) =>
            q.isEmpty ||
            '${r['name'] ?? ''}'.toLowerCase().contains(q) ||
            '${r['phone'] ?? ''}'.contains(q))
        .toList();
    final exact = rows.any((r) => '${r['name'] ?? ''}'.toLowerCase() == q);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .85,
      maxChildSize: .95,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
        children: [
          Semantics(
            header: true,
            child: Text(widget.book == 'customer' ? t.acuPickCustomer : t.acuPickSupplier,
                style: Theme.of(context).textTheme.titleLarge),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _q,
            autofocus: false,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              labelText: t.acuPickSearch,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            ChoiceChip(
              label: Text(t.acuPickFromKhata),
              selected: !_crm,
              onSelected: (_) {
                if (_crm) {
                  setState(() => _crm = false);
                  _load();
                }
              },
            ),
            ChoiceChip(
              label: Text(t.acuPickFromCrm),
              selected: _crm,
              onSelected: (_) {
                if (!_crm) {
                  setState(() => _crm = true);
                  _load();
                }
              },
            ),
            ActionChip(
              avatar: const Icon(Icons.diversity_1_rounded, size: 18),
              label: Text(t.acuPickCircle),
              onPressed: _circle,
            ),
          ]),
          const SizedBox(height: Gap.sm),
          if (q.isNotEmpty && !exact)
            ListTile(
              key: const ValueKey('acct-party-new'),
              minVerticalPadding: Gap.sm,
              leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.person_add_alt_1_rounded, color: scheme.onPrimaryContainer)),
              title: Text(t.acuPickNew(_q.text.trim())),
              subtitle: Text(t.acuPickNewSub),
              onTap: () => Navigator.pop(context, {'name': _q.text.trim()}),
            ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.lg),
              child: Column(children: [
                Text(t.acuPickLoadFailed, textAlign: TextAlign.center),
                const SizedBox(height: Gap.sm),
                OutlinedButton(onPressed: _load, child: Text(t.retry)),
              ]),
            )
          else if (_rows == null)
            const Padding(
              padding: EdgeInsets.all(Gap.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_rows!.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.lg),
              child: Text(_crm ? t.acuPickCrmEmpty : t.acuPickKhataEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            ),
          for (final r in rows)
            ListTile(
              minVerticalPadding: Gap.sm,
              leading: CircleAvatar(child: Text(_initial('${r['name'] ?? ''}'))),
              title: Text('${r['name'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: _sub(context, r),
              onTap: () => Navigator.pop(context, {
                if (!_crm) 'party_id': r['id'],
                'name': '${r['name'] ?? ''}',
                'phone': '${r['phone'] ?? ''}',
              }),
            ),
        ],
      ),
    );
  }

  static String _initial(String s) => s.isEmpty ? '?' : s.characters.first.toUpperCase();

  Widget? _sub(BuildContext context, Map<String, dynamic> r) {
    final parts = <String>[
      if ('${r['phone'] ?? ''}'.isNotEmpty) '${r['phone']}',
      if (!_crm && r['balance_status'] != null) pair(context, r['balance_status']),
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }
}
