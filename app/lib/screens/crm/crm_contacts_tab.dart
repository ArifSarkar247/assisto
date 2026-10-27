import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../plans_v2/plans_v2.dart';
import '../../plans_v2/upgrade_sheet.dart';
import '../../state.dart';
import '../../theme.dart';
import 'crm_common.dart';

/// plans-v2 — the CRM "Contacts" tab: the people a shop keeps in its CRM.
/// On Free this is the part you can ADD to (up to the owner's limit, 20 by
/// default); leads, deals, pipeline and tasks are view only. The header shows
/// the usage ("18/20 contacts"); when the list is full the add button opens
/// the honest upgrade sheet. The SERVER enforces the same limit (and counts
/// leads + contacts over every CRM the owner has). Existing contacts always
/// stay readable, editable and removable — nothing is ever deleted by a plan.
class CrmContactsTab extends StatefulWidget {
  final int org;
  const CrmContactsTab({super.key, required this.org});
  @override
  State<CrmContactsTab> createState() => _CrmContactsTabState();
}

class _CrmContactsTabState extends State<CrmContactsTab> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  CrmError? _error;
  PlansV2State _v2 = PlansV2State.off;

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
      _list = await CrmApi.of(context).contacts(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) {
      _v2 = await loadPlansV2(context.read<AppState>().api, org: widget.org);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final lock = _v2.contactLock();
    if (lock != null) {
      final up = await UpgradeSheet.show(context, lock);
      if (up == true) _load();
      return;
    }
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _AddContactSheet(org: widget.org),
    );
    if (added == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final locked = _v2.contactLock() != null;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('crm-add-contact'),
        onPressed: _loading ? null : _add,
        icon: Icon(locked ? Icons.lock_rounded : Icons.person_add_alt_1_rounded),
        label: Text(t.pv2AddContact),
      ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    final banner = _v2.on && _v2.contacts != null
        ? Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
            child: CrmUsageBanner(usage: _v2.contacts!, viewOnly: !_v2.crmAllows('crm_write')),
          )
        : null;
    if (_list.isEmpty) {
      return ListView(children: [
        if (banner != null) banner,
        CrmStateView.empty(
          icon: Icons.contacts_rounded,
          title: t.pv2NoContacts,
          message: t.pv2NoContactsHint,
          action: FilledButton.tonalIcon(
              onPressed: _add,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(t.pv2AddContact)),
        ),
      ]);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: _list.length + (banner != null ? 1 : 0),
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (c, i) {
          if (banner != null && i == 0) return banner;
          final ct = _list[i - (banner != null ? 1 : 0)];
          final sub = [ct['title'], ct['phone'], ct['email']]
              .where((x) => (x ?? '').toString().isNotEmpty)
              .join(' · ');
          return ListTile(
            minVerticalPadding: Gap.sm,
            leading: CircleAvatar(
              child: Text(_initial('${ct['name'] ?? ''}')),
            ),
            title: Text('${ct['name'] ?? ''}',
                maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: sub.isEmpty ? null : Text(sub),
          );
        },
      ),
    );
  }
}

String _initial(String name) {
  final n = name.trim();
  return n.isEmpty ? '?' : String.fromCharCode(n.runes.first).toUpperCase();
}

/// "18/20 contacts" + a bar, and (Free) the honest "view only" line.
class CrmUsageBanner extends StatelessWidget {
  final ContactUsage usage;
  final bool viewOnly;
  const CrmUsageBanner({super.key, required this.usage, this.viewOnly = false});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final label = contactUsageText(context, usage);
    final frac = usage.unlimited || usage.limit <= 0
        ? 0.0
        : (usage.used / usage.limit).clamp(0.0, 1.0).toDouble();
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
          label: label,
          child: ExcludeSemantics(
            child: Row(children: [
              Icon(Icons.contacts_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(label,
                      key: const Key('pv2-contact-usage'),
                      style: const TextStyle(fontWeight: FontWeight.w700))),
            ]),
          ),
        ),
        if (!usage.unlimited) ...[
          const SizedBox(height: Gap.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
              color: frac >= 1 ? scheme.error : scheme.primary,
            ),
          ),
        ],
        if (viewOnly) ...[
          const SizedBox(height: Gap.xs),
          Text(t.pv2CrmViewOnlyNote,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

class _AddContactSheet extends StatefulWidget {
  final int org;
  const _AddContactSheet({required this.org});
  @override
  State<_AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<_AddContactSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _title = TextEditingController();
  bool _saving = false;
  String? _err;

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _title]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      setState(() => _err = t.pv2ContactNameNeeded);
      return;
    }
    setState(() {
      _saving = true;
      _err = null;
    });
    try {
      await CrmApi.of(context).createContact({
        'org': widget.org,
        'name': _name.text.trim(),
        'phone': _phone.text.trim(),
        'email': _email.text.trim(),
        'title': _title.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final r = UpgradeReason.fromError(e);
      if (r != null) {
        final nav = Navigator.of(context);
        nav.pop(false);
        await UpgradeSheet.show(nav.context, r);
        return;
      }
      setState(() => _err = CrmError.from(e).textFor(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    InputDecoration dec(String l) =>
        InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.pv2AddContact, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            TextField(
                key: const Key('pv2-contact-name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: dec(t.pv2ContactName)),
            const SizedBox(height: Gap.sm),
            TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: dec(t.pv2ContactPhone)),
            const SizedBox(height: Gap.sm),
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: dec(t.pv2ContactEmail)),
            const SizedBox(height: Gap.sm),
            TextField(controller: _title, decoration: dec(t.pv2ContactTitle)),
            if (_err != null) ...[
              const SizedBox(height: Gap.sm),
              Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: Gap.md),
            FilledButton(
              key: const Key('pv2-contact-save'),
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: Text(t.save),
            ),
          ],
        ),
      ),
    );
  }
}
