import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../famcare_api.dart';
import '../l10n/app_localizations.dart';
import '../screens/vault_screen.dart';
import '../state.dart';
import '../theme.dart';
import '../vault/vault_lock.dart';
import 'app_sheet.dart';
import 'fam_empty.dart';
import 'fam_members_section.dart' show famInCircle;
import 'fam_share_section.dart';
import 'skeleton.dart';

/// famcare (owner decision 3, 28 Oct) — the Sharing tab is three things a
/// family shares: the SHOPPING LIST (anyone in the family adds and ticks),
/// DOCUMENTS from the Vault (chosen documents to chosen members, PIN first,
/// revocable, with who-opened-when), and PRIVACY (the existing per-member
/// consent grid — what of mine each member may see).
class FamSharingHub extends StatefulWidget {
  const FamSharingHub({super.key, required this.members, required this.onAddMember,
      this.vaultLock});

  final List<Map<String, dynamic>> members;
  final VoidCallback onAddMember;

  /// Test seam (default: the real vault lock).
  final VaultLock? vaultLock;

  @override
  State<FamSharingHub> createState() => _FamSharingHubState();
}

class _FamSharingHubState extends State<FamSharingHub> {
  String _pane = 'list';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
        child: SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            key: const ValueKey('fc-share-panes'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 'list', icon: const Icon(Icons.shopping_cart_rounded),
                  label: Text(t.fcShopTab, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ButtonSegment(value: 'docs', icon: const Icon(Icons.folder_shared_rounded),
                  label: Text(t.fcDocsTab, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ButtonSegment(value: 'privacy', icon: const Icon(Icons.lock_person_rounded),
                  label: Text(t.fcPrivacyTab, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            selected: {_pane},
            onSelectionChanged: (s) => setState(() => _pane = s.first),
          ),
        ),
      ),
      Expanded(
        child: switch (_pane) {
          'docs' => FamDocsPane(members: widget.members, onAddMember: widget.onAddMember,
              vaultLock: widget.vaultLock),
          'privacy' => widget.members.isEmpty
              ? FamEmptyState(
                  icon: Icons.lock_person_rounded,
                  title: t.fcPrivacyEmptyTitle,
                  benefit: t.fcPrivacyEmptyBenefit,
                  primaryLabel: t.fcAddFamilyFirst,
                  primaryIcon: Icons.group_add_rounded,
                  onPrimary: widget.onAddMember,
                  steps: [t.fcPrivacyStep1, t.fcPrivacyStep2])
              : FamShareSection(members: widget.members),
          _ => FamShopPane(members: widget.members, onAddMember: widget.onAddMember),
        },
      ),
    ]);
  }
}

// ------------------------------------------------------------ shopping list
class FamShopPane extends StatefulWidget {
  const FamShopPane({super.key, required this.members, required this.onAddMember});
  final List<Map<String, dynamic>> members;
  final VoidCallback onAddMember;
  @override
  State<FamShopPane> createState() => _FamShopPaneState();
}

class _FamShopPaneState extends State<FamShopPane> {
  List<Map<String, dynamic>>? _lists;
  bool _failed = false;
  int? _owner; // whose list is shown (null = mine)
  final _text = TextEditingController();

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onText);
    _load();
  }

  bool _hasText = false;
  void _onText() {
    final h = _text.text.trim().isNotEmpty;
    if (h != _hasText) setState(() => _hasText = h);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await _api.famShopping();
      final l = (r['lists'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (mounted) setState(() { _lists = l; _failed = false; });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Map<String, dynamic>? get _current {
    final l = _lists;
    if (l == null || l.isEmpty) return null;
    return l.firstWhere((x) => _owner == null ? x['mine'] == true : x['owner_id'] == _owner,
        orElse: () => l.first);
  }

  Future<void> _add() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final cur = _current;
    try {
      await _api.famShopAdd(text, ownerId: cur == null || cur['mine'] == true
          ? null
          : (cur['owner_id'] as num).toInt());
      _text.clear();
      await _load();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _toggle(Map<String, dynamic> it) async {
    setState(() => it['done'] = !(it['done'] == true)); // instant tick
    try {
      await _api.famShopToggle((it['id'] as num).toInt());
      await _load();
    } catch (e) {
      _fail(e);
      await _load();
    }
  }

  Future<void> _delete(Map<String, dynamic> it) async {
    try {
      await _api.famShopDelete((it['id'] as num).toInt());
      await _load();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _clearDone() async {
    final cur = _current;
    try {
      await _api.famShopClearDone(
          ownerId: cur == null || cur['mine'] == true ? null : (cur['owner_id'] as num).toInt());
      await _load();
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is ApiException && e.message.isNotEmpty ? e.message : t.grpActionFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_failed) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.loadFailed,
        tint: Brand.danger,
        action: FilledButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
      );
    }
    if (_lists == null) return const Center(child: CircularProgressIndicator());
    final cur = _current;
    final items = (cur?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final mine = cur == null || cur['mine'] == true;
    final sharedWith = (cur?['shared_with'] as num?)?.toInt() ?? 0;
    final linked = widget.members.where(famInCircle).length;
    final addRow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('fc-shop-input'),
            controller: _text,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _add(),
            decoration: InputDecoration(labelText: t.fcShopAddHint),
          ),
        ),
        const SizedBox(width: Gap.sm),
        IconButton.filled(
            key: const ValueKey('fc-shop-add'),
            tooltip: t.add,
            onPressed: _hasText ? _add : null, // nothing to add -> disabled, not dead
            icon: const Icon(Icons.add_rounded)),
      ]),
    );
    final lists = _lists!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.only(bottom: Gap.xxl)),
        children: [
          if (lists.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
              child: Wrap(spacing: Gap.sm, children: [
                for (final l in lists)
                  ChoiceChip(
                    label: Text(l['mine'] == true ? t.fcShopMine : t.fcShopOf('${l['owner_name'] ?? ''}')),
                    selected: identical(l, cur),
                    onSelected: (_) => setState(() =>
                        _owner = l['mine'] == true ? null : (l['owner_id'] as num).toInt()),
                  ),
              ]),
            ),
          addRow,
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
            child: Text(
              mine
                  ? (sharedWith > 0
                      ? t.fcShopSharedWith(famDigits(context, '$sharedWith'))
                      : (linked == 0 ? t.fcShopOnlyYou : t.fcShopOnlyYouLinked))
                  : t.fcShopTheirs,
              key: const ValueKey('fc-shop-who'),
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(children: [
                Icon(Icons.shopping_basket_rounded, size: 48, color: scheme.primary),
                const SizedBox(height: Gap.sm),
                Text(t.fcShopEmptyBenefit, textAlign: TextAlign.center,
                    key: const ValueKey('fam-empty-benefit')),
                if (mine && widget.members.isEmpty) ...[
                  const SizedBox(height: Gap.md),
                  SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                        key: const ValueKey('fam-empty-primary'),
                        onPressed: widget.onAddMember,
                        icon: const Icon(Icons.group_add_rounded),
                        label: Text(t.fcAddFamilyFirst)),
                  ),
                ],
              ]),
            )
          else ...[
            for (final it in items)
              CheckboxListTile(
                key: ValueKey('fc-shop-${it['id']}'),
                value: it['done'] == true,
                onChanged: (_) => _toggle(it),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text([it['text'], if ('${it['qty'] ?? ''}'.isNotEmpty) it['qty']].join(' · '),
                    style: it['done'] == true
                        ? const TextStyle(decoration: TextDecoration.lineThrough)
                        : null),
                subtitle: Text(it['done'] == true && '${it['done_by'] ?? ''}'.isNotEmpty
                    ? t.fcShopBoughtBy('${it['done_by']}')
                    : t.fcShopAddedBy('${it['added_by'] ?? ''}')),
                secondary: IconButton(
                    tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => _delete(it)),
              ),
            if (items.any((x) => x['done'] == true))
              Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: OutlinedButton.icon(
                    onPressed: _clearDone,
                    icon: const Icon(Icons.cleaning_services_rounded),
                    label: Text(t.fcShopClearDone)),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------- vault documents
class FamDocsPane extends StatefulWidget {
  const FamDocsPane({super.key, required this.members, required this.onAddMember, this.vaultLock});
  final List<Map<String, dynamic>> members;
  final VoidCallback onAddMember;
  final VaultLock? vaultLock;
  @override
  State<FamDocsPane> createState() => _FamDocsPaneState();
}

class _FamDocsPaneState extends State<FamDocsPane> {
  Map<String, dynamic>? _data;
  bool _failed = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.famDocs();
      if (mounted) setState(() { _data = r; _failed = false; });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  List<Map<String, dynamic>> _rows(String k) => (_data?[k] as List? ?? const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();

  /// The vault PIN gate (the PIN never leaves the phone).
  Future<bool> _unlock() async {
    final t = AppLocalizations.of(context);
    final lock = widget.vaultLock ?? VaultLock();
    if (!await lock.hasPin()) {
      if (!mounted) return false;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(t.fcDocsNeedPin),
          content: Text(t.fcDocsNeedPinBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
            FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const VaultScreen()));
                },
                child: Text(t.fcOpenVault)),
          ],
        ),
      );
      return false;
    }
    if (!mounted) return false;
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        String? err;
        return AlertDialog(
          scrollable: true,
          title: Text(t.fcDocsPinTitle),
          content: TextField(
            key: const ValueKey('fc-docs-pin'),
            controller: pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: VaultLock.maxPin,
            decoration: InputDecoration(labelText: t.fcDocsPinLabel, errorText: err),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(
                onPressed: () async {
                  final r = await lock.check(pin.text.trim());
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx, r == PinCheck.ok);
                },
                child: Text(t.ok)),
          ],
        );
      }),
    );
    if (ok != true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.fcDocsPinWrong)));
    }
    return ok == true;
  }

  Future<void> _share() async {
    final linked = widget.members.where(famInCircle).toList();
    if (linked.isEmpty) {
      widget.onAddMember();
      return;
    }
    if (!await _unlock() || !mounted) return;
    List<Map<String, dynamic>> docs;
    try {
      docs = await _api.listItems('documents');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).loadFailed)));
      return;
    }
    if (!mounted) return;
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ShareDocSheet(docs: docs, members: linked),
    );
    if (ok == true) await _load();
  }

  Future<void> _revoke(Map<String, dynamic> s) async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.fcDocsRevokeQ),
        content: Text(t.fcDocsRevokeBody('${s['title'] ?? ''}', '${s['recipient_name'] ?? ''}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fcDocsRevoke)),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await _api.famRevokeDoc((s['id'] as num).toInt());
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.grpActionFailed)));
      }
    }
  }

  Future<void> _openShared(Map<String, dynamic> s) async {
    final t = AppLocalizations.of(context);
    Map<String, dynamic> d;
    try {
      d = await _api.famOpenDoc((s['id'] as num).toInt());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.fcDocsGone)));
      }
      await _load();
      return;
    }
    if (!mounted) return;
    final details = (d['details'] as Map? ?? const {}).cast<String, dynamic>();
    final exp = DateTime.tryParse('${d['expiry_date'] ?? ''}');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text('${d['title'] ?? ''}'),
        content: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(t.fcDocsFrom('${d['owner_name'] ?? ''}')),
          if (exp != null) Text(t.fcDocsExpires(famDate(context, exp))),
          if ('${d['note'] ?? ''}'.isNotEmpty) Text('${d['note']}'),
          for (final e in details.entries)
            if ('${e.value}'.trim().isNotEmpty) Text('${e.key}: ${famDigits(context, '${e.value}')}'),
        ]),
        actions: [
          if (d['has_file'] == true)
            TextButton.icon(
                key: const ValueKey('fc-docs-open-file'),
                onPressed: () => _openFile(s),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(t.fcDocsOpenFile)),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.close)),
        ],
      ),
    );
  }

  /// The recipient opens the attached scan (server re-checks the share and
  /// the Circle on every read; counted in the owner's "opened" audit).
  Future<void> _openFile(Map<String, dynamic> s) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = AppLocalizations.of(context);
    try {
      final bytes = await _api.getBytes('/family/docs/${s['id']}/file');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto-family-doc-${s['id']}');
      await f.writeAsBytes(bytes);
      await OpenFilex.open(f.path);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.fcDocsGone)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_failed) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.loadFailed,
        tint: Brand.danger,
        action: FilledButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
      );
    }
    if (_data == null) return const Center(child: CircularProgressIndicator());
    final byMe = _rows('shared_by_me');
    final toMe = _rows('shared_with_me');
    final noLinked = !widget.members.any(famInCircle);
    if (byMe.isEmpty && toMe.isEmpty) {
      return FamEmptyState(
        icon: Icons.folder_shared_rounded,
        title: t.fcDocsEmptyTitle,
        benefit: t.fcDocsEmptyBenefit,
        primaryLabel: noLinked ? t.fcAddFamilyFirst : t.fcDocsShare,
        primaryIcon: noLinked ? Icons.group_add_rounded : Icons.ios_share_rounded,
        onPrimary: _share,
        steps: [t.fcDocsStep1, t.fcDocsStep2, t.fcDocsStep3],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xxl)),
        children: [
          SizedBox(
            height: 48,
            child: FilledButton.icon(
                key: const ValueKey('fc-docs-share'),
                onPressed: _share,
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(t.fcDocsShare)),
          ),
          if (toMe.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.fcDocsWithMe, style: AType.titleSmall),
            for (final s in toMe)
              Card(
                child: ListTile(
                  minTileHeight: 56,
                  leading: const Icon(Icons.description_rounded),
                  title: Text('${s['title'] ?? ''}'),
                  subtitle: Text(t.fcDocsFrom('${s['owner_name'] ?? ''}')),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _openShared(s),
                ),
              ),
          ],
          if (byMe.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.fcDocsByMe, style: AType.titleSmall),
            for (final s in byMe)
              Card(
                child: ListTile(
                  minTileHeight: 56,
                  leading: Icon(s['active'] == true ? Icons.lock_open_rounded : Icons.lock_rounded,
                      color: s['active'] == true ? scheme.primary : scheme.onSurfaceVariant),
                  title: Text('${s['title'] ?? ''}'),
                  subtitle: Text([
                    '${s['recipient_name'] ?? ''}',
                    s['active'] == true ? t.fcDocsActive : t.fcDocsRevoked,
                    t.fcDocsOpens(famDigits(context, '${s['opens'] ?? 0}')),
                  ].join(' · ')),
                  trailing: s['active'] == true
                      ? TextButton(onPressed: () => _revoke(s), child: Text(t.fcDocsRevoke))
                      : null,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ShareDocSheet extends StatefulWidget {
  const _ShareDocSheet({required this.docs, required this.members});
  final List<Map<String, dynamic>> docs;
  final List<Map<String, dynamic>> members;
  @override
  State<_ShareDocSheet> createState() => _ShareDocSheetState();
}

class _ShareDocSheetState extends State<_ShareDocSheet> {
  int? _doc;
  final Set<int> _to = {};
  bool _saving = false;

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (_doc == null || _to.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.famShareDoc(_doc!, _to.toList());
      if (!mounted) return;
      Navigator.pop(context, true);
      messenger.showSnackBar(SnackBar(content: Text(t.fcDocsShared)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
          content: Text(e is ApiException && e.message.isNotEmpty ? e.message : t.grpActionFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
            key: const ValueKey('fc-docs-send'),
            onPressed: (_saving || _doc == null || _to.isEmpty) ? null : _save,
            child: Text(t.fcDocsShare)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.fcDocsPickDoc, style: Theme.of(context).textTheme.titleMedium),
        if (widget.docs.isEmpty) Text(t.fcDocsNoVaultDocs),
        for (final d in widget.docs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: 48,
            leading: Icon(_doc == d['id'] ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded),
            title: Text('${d['title'] ?? ''}'),
            onTap: () => setState(() => _doc = (d['id'] as num).toInt()),
          ),
        const SizedBox(height: Gap.md),
        Text(t.fcDocsPickMembers, style: Theme.of(context).textTheme.titleMedium),
        for (final m in widget.members)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _to.contains(m['id']),
            title: Text('${m['name'] ?? ''}'),
            onChanged: (v) => setState(() {
              final id = m['id'] as int;
              v == true ? _to.add(id) : _to.remove(id);
            }),
          ),
        const SizedBox(height: Gap.sm),
        Text(t.fcDocsRevokeAnytime, style: AType.bodySmall),
      ]),
    );
  }
}
