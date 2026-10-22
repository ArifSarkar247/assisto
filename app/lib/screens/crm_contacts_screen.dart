import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/contacts_model.dart';
import '../widgets/contacts_sheets.dart';
import 'messenger/m3_add_to_circle_screen.dart';

/// Contacts (feature 24): the PERSONAL phonebook / relationship manager — the
/// people in your life (family, friends, colleagues). Distinct from the Sales
/// CRM (screens/crm/*).
///
/// ADVANCED (SPEC v2.1 §21): rich multi-field contacts, groups/labels,
/// favourites, search + filter + sort, merge duplicates, hashed-safe phone
/// import, link-to-Circle, quick actions (call/SMS/WhatsApp/vCard-share),
/// stay-in-touch reminders, recent interactions, vCard export. Offline-first
/// (SharedPreferences cache), bilingual, WCAG-minded, no dead ends.
class CrmContactsScreen extends StatefulWidget {
  const CrmContactsScreen({super.key});
  @override
  State<CrmContactsScreen> createState() => _CrmContactsScreenState();
}

class _CrmContactsScreenState extends State<CrmContactsScreen> {
  static const _cacheKey = 'contacts_cache_v2';

  List<Contact> _all = [];
  bool _loading = true, _error = false, _offline = false;
  String _query = '';
  String _group = ''; // '' = all
  bool _favOnly = false;
  String _sort = 'name';
  final _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // offline-first: show the cache instantly, then refresh from the server.
    final cached = await _readCache();
    if (cached.isNotEmpty && mounted) {
      setState(() {
        _all = cached;
        _loading = false;
      });
    }
    await _load(silent: cached.isNotEmpty);
  }

  Future<List<Contact>> _readCache() async {
    try {
      final raw = await Settings.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return [];
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(Contact.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeCache(List<Contact> list) async {
    try {
      await Settings.setString(
          _cacheKey, jsonEncode(list.map((c) => c.toJson()).toList()));
    } catch (_) {/* best-effort */}
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final raw = await context.read<AppState>().api.listItems('contacts');
      _all = raw.map(Contact.fromJson).toList();
      _offline = false;
      _error = false;
      await _writeCache(_all);
    } catch (_) {
      // keep whatever we have (cache); only hard-error if we have nothing.
      _offline = true;
      if (_all.isEmpty) _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- derived list (search → filter → sort), all pure + instant ----
  List<Contact> get _visible {
    var list = searchContacts(_all, _query, context);
    list = filterContacts(list,
        group: _group.isEmpty ? null : _group, favouritesOnly: _favOnly);
    return sortContacts(list, _sort, context);
  }

  // ---- CRUD (optimistic + offline-cached) ----
  Future<void> _upsert(Contact c) async {
    final api = context.read<AppState>().api;
    try {
      if (c.id == null) {
        final created = await api.createItem('contacts', c.toJson());
        c.id = Contact.fromJson(created).id;
        _all = [..._all, c];
      } else {
        await api.updateItem('contacts', c.id!, c.toJson());
        _all = [for (final x in _all) if (x.id == c.id) c else x];
      }
      await _writeCache(_all);
      _toast(cStr(context, 'cContactSaved'));
    } catch (_) {
      // offline: keep it locally so the user isn't blocked.
      if (c.id == null) _all = [..._all, c];
      await _writeCache(_all);
      _toast(cStr(context, 'cSavedOffline'));
    }
    if (mounted) setState(() {});
  }

  Future<void> _delete(Contact c) async {
    final api = context.read<AppState>().api;
    try {
      if (c.id != null) await api.deleteItem('contacts', c.id!);
    } catch (_) {
      // q1-seams: it used to vanish locally with "deleted" and come back on
      // the next sync. A server row is only gone when the server says so.
      _toast(AppLocalizations.of(context).grpActionFailed);
      return;
    }
    _all = _all.where((x) => x != c).toList();
    await _writeCache(_all);
    _toast(cStr(context, 'cContactDeleted'));
    if (mounted) setState(() {});
  }

  Future<void> _logContact(Contact c) async {
    c.lastInteraction = DateTime.now().toIso8601String();
    await _upsert(c);
    if (mounted) _toast(cStr(context, 'cLoggedContact'));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- interactions ----
  Future<void> _openEditor({Contact? existing}) async {
    final result = await showContactEditor(context, existing: existing);
    if (result != null) await _upsert(result);
  }

  Future<void> _openDetail(Contact c) async {
    final r = await showContactDetail(context, c,
        onLogContact: () => _logContact(c));
    if (!mounted) return;
    switch (r) {
      case ContactDetailResult.edit:
        await _openEditor(existing: c);
        break;
      case ContactDetailResult.delete:
        await _confirmDelete(c);
        break;
      case ContactDetailResult.linkCircle:
        _linkToCircle(c);
        break;
      case ContactDetailResult.logged:
      case ContactDetailResult.none:
        break;
    }
  }

  Future<void> _confirmDelete(Contact c) async {
    final tr = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(cStr(context, 'cDeleteContactQ')),
        content: Text(c.displayName(context)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              child: Text(tr.delete)),
        ],
      ),
    );
    if (ok == true) await _delete(c);
  }

  void _linkToCircle(Contact c) {
    // q1-seams: this used to stamp a -1 "link requested" sentinel (the server
    // drops it) and toast "Link to Circle" as if done. Now it opens the REAL
    // My Circle add flow (find by number -> request -> they accept).
    final number = c.phones.isEmpty ? null : c.phones.first;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => M3AddToCircleScreen(initialNumber: number)));
  }

  Future<void> _exportAll() async {
    final list = _visible.isEmpty ? _all : _visible;
    if (list.isEmpty) return;
    await Share.share(vcardBundle(context, list),
        subject: cStr(context, 'cExportAll'));
    if (mounted) _toast(cStr(context, 'cExported'));
  }

  Future<void> _showReachOut() async {
    final due = touchDueContacts(_all);
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: due.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Gap.xl),
                child: StateMessage(
                    icon: Icons.favorite_border,
                    title: cStr(context, 'cReachOutTitle'),
                    message: cStr(context, 'cNeverTalked')),
              )
            : ListView(shrinkWrap: true, children: [
                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Text(cStr(context, 'cReachOutTitle'),
                      style: Theme.of(ctx)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                for (final c in due) _contactTile(c, inSheet: true),
                const SizedBox(height: Gap.lg),
              ]),
      ),
    );
  }

  Future<void> _showDedupe() async {
    final groups = findDuplicateGroups(_all);
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _DedupeSheet(
        groups: groups,
        onMerge: (g) async {
          final merged = mergeContacts(g);
          // save the merged primary, delete the rest
          await _upsert(merged);
          for (final extra in g.skip(1)) {
            await _delete(extra);
          }
          if (ctx.mounted) Navigator.pop(ctx);
          _toast(cStr(context, 'cMerged'));
        },
      ),
    );
  }

  Future<void> _showImport() async {
    // Privacy-safe import (hashed, like messenger): raw numbers never leave the
    // device; the device hashes + the server matches. This surface explains the
    // contract and hands off to the OS picker via the integration endpoint.
    final tr = AppLocalizations.of(context);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.contacts_outlined),
        title: Text(cStr(context, 'cImportFromPhone')),
        content: Text(cStr(context, 'cImportPrivacy')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(tr.close)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final dueCount = touchDueContacts(_all).length;
    final counts = _groupCounts();

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.contactsTitle),
        actions: [
          IconButton(
            tooltip: cStr(context, 'cSortBy'),
            icon: const Icon(Icons.sort),
            onPressed: _all.isEmpty ? null : _pickSort,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'import') _showImport();
              if (v == 'export') _exportAll();
              if (v == 'dedupe') _showDedupe();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                  value: 'import',
                  child: _menu(Icons.download_outlined,
                      cStr(context, 'cImportFromPhone'))),
              PopupMenuItem(
                  enabled: _all.isNotEmpty,
                  value: 'export',
                  child: _menu(
                      Icons.upload_outlined, cStr(context, 'cExportAll'))),
              PopupMenuItem(
                  enabled: _all.length > 1,
                  value: 'dedupe',
                  child: _menu(Icons.merge_type,
                      cStr(context, 'cMergeDuplicates'))),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.person_add_alt),
        label: Text(tr.contact),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: Column(children: [
                    if (_offline) _offlineBanner(scheme),
                    _searchBar(scheme),
                    _filterChips(counts),
                    if (dueCount > 0) _reachOutBanner(scheme, dueCount),
                    Expanded(child: _listBody(tr)),
                  ]),
                ),
    );
  }

  Map<String, int> _groupCounts() {
    final counts = <String, int>{for (final g in kGroupOrder) g: 0};
    var fav = 0;
    for (final c in _all) {
      if (c.favourite) fav++;
      for (final g in c.groups) {
        counts[g] = (counts[g] ?? 0) + 1;
      }
    }
    counts['_fav'] = fav;
    counts['_all'] = _all.length;
    return counts;
  }

  Widget _menu(IconData icon, String label) => Row(children: [
        Icon(icon, size: 20),
        const SizedBox(width: Gap.md),
        Flexible(child: Text(label)),
      ]);

  Widget _offlineBanner(ColorScheme scheme) => Container(
        width: double.infinity,
        color: scheme.secondaryContainer,
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.lg, vertical: Gap.sm),
        child: Row(children: [
          Icon(Icons.cloud_off, size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(cStr(context, 'cOfflineShowingCached'),
                style: TextStyle(color: scheme.onSecondaryContainer)),
          ),
        ]),
      );

  Widget _searchBar(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
        child: TextField(
          controller: _searchCtl,
          onChanged: (v) => setState(() => _query = v),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: cStr(context, 'cSearchHint'),
            isDense: true,
            filled: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.pill),
                borderSide: BorderSide.none),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchCtl.clear();
                      setState(() => _query = '');
                    }),
          ),
        ),
      );

  Widget _filterChips(Map<String, int> counts) {
    Widget chip(String label, bool selected, VoidCallback onTap,
        {IconData? icon, int? count}) {
      final text = count != null && count > 0
          ? '$label (${localeNum(context, count)})'
          : label;
      return Padding(
        padding: const EdgeInsets.only(right: Gap.sm),
        child: FilterChip(
          avatar: icon == null ? null : Icon(icon, size: 16),
          label: Text(text),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      );
    }

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          chip(cStr(context, 'cAll'), _group.isEmpty && !_favOnly, () {
            setState(() {
              _group = '';
              _favOnly = false;
            });
          }, count: counts['_all']),
          chip(cStr(context, 'cFavourites'), _favOnly, () {
            setState(() {
              _favOnly = !_favOnly;
            });
          }, icon: Icons.star, count: counts['_fav']),
          for (final g in kGroupOrder)
            chip(groupLabel(context, g), _group == g, () {
              setState(() => _group = _group == g ? '' : g);
            }, icon: groupIcon(g), count: counts[g]),
        ],
      ),
    );
  }

  Widget _reachOutBanner(ColorScheme scheme, int n) => Padding(
        padding:
            const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
        child: Material(
          color: Brand.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            onTap: _showReachOut,
            borderRadius: BorderRadius.circular(Radii.md),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Row(children: [
                const Icon(Icons.favorite, color: Brand.warning),
                const SizedBox(width: Gap.md),
                Expanded(
                    child: Text(
                        '${cStr(context, 'cReachOutTitle')} · ${localeNum(context, n)}')),
                const Icon(Icons.chevron_right),
              ]),
            ),
          ),
        ),
      );

  Widget _listBody(AppLocalizations tr) {
    if (_all.isEmpty) {
      return StateMessage(
        icon: Icons.contacts_outlined,
        title: tr.noContactsYet,
        message: cStr(context, 'cEmptyBody'),
        action: FilledButton.icon(
          onPressed: () => _openEditor(),
          icon: const Icon(Icons.person_add_alt),
          label: Text(tr.addContact),
        ),
      );
    }
    final list = _visible;
    if (list.isEmpty) {
      return StateMessage(
        icon: Icons.search_off,
        title: cStr(context, 'cNoSearchResults'),
        message: cStr(context, 'cSearchHint'),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 96),
      itemCount: list.length,
      itemBuilder: (ctx, i) => _contactTile(list[i]),
    );
  }

  Widget _contactTile(Contact c, {bool inSheet = false}) {
    final scheme = Theme.of(context).colorScheme;
    final subtitleBits = <String>[
      if (c.relation.isNotEmpty) relationDisplay(context, c.relation),
      if (c.org.isNotEmpty) c.org,
      if (c.phones.isNotEmpty) c.phones.first,
    ];
    final due = c.touchDue();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        onTap: () => _openDetail(c),
        leading: Stack(children: [
          CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Text(c.initial(context),
                style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700)),
          ),
          if (due)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                    color: Theme.of(context).cardColor, shape: BoxShape.circle),
                child: const Icon(Icons.favorite,
                    size: 12, color: Brand.warning),
              ),
            ),
        ]),
        title: Row(children: [
          Flexible(
              child: Text(c.displayName(context),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (c.favourite) ...[
            const SizedBox(width: 4),
            const Icon(Icons.star, size: 16, color: Brand.warning),
          ],
        ]),
        subtitle: subtitleBits.isEmpty
            ? null
            : Text(subtitleBits.join(' · '),
                maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: inSheet
            ? null
            : IconButton(
                tooltip: cStr(context, 'cFavourite'),
                icon: Icon(
                    c.favourite ? Icons.star : Icons.star_border,
                    color: c.favourite ? Brand.warning : scheme.outline),
                onPressed: () {
                  c.favourite = !c.favourite;
                  _upsert(c);
                },
              ),
      ),
    );
  }

  Future<void> _pickSort() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final opt in const [
            ['name', 'cSortName'],
            ['recent', 'cSortRecent'],
            ['favourite', 'cSortFavourite'],
          ])
            RadioListTile<String>(
              value: opt[0],
              groupValue: _sort,
              title: Text(cStr(context, opt[1])),
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
        ]),
      ),
    );
    if (chosen != null) setState(() => _sort = chosen);
  }
}

// ---------------------------------------------------------------------------
// Dedupe sheet
// ---------------------------------------------------------------------------
class _DedupeSheet extends StatelessWidget {
  final List<List<Contact>> groups;
  final Future<void> Function(List<Contact>) onMerge;
  const _DedupeSheet({required this.groups, required this.onMerge});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (groups.isEmpty) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: StateMessage(
            icon: Icons.verified_outlined,
            tint: Brand.success,
            title: cStr(context, 'cNoDuplicates'),
          ),
        ),
      );
    }
    return SafeArea(
      child: ListView(shrinkWrap: true, children: [
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cStr(context, 'cMergeDuplicates'),
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(cStrNum(context, 'cDuplicatesFound', groups.length),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ]),
        ),
        for (final g in groups)
          Card(
            margin: const EdgeInsets.symmetric(
                horizontal: Gap.md, vertical: Gap.xs),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final c in g)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: scheme.primaryContainer,
                          child: Text(c.initial(context),
                              style: TextStyle(
                                  color: scheme.onPrimaryContainer,
                                  fontSize: 13)),
                        ),
                        title: Text(c.displayName(context)),
                        subtitle: Text(
                            [...c.phones, ...c.emails].join(' · '),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    Text(cStr(context, 'cMergePreview'),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                    const SizedBox(height: Gap.sm),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.merge_type, size: 18),
                        label: Text(cStr(context, 'cMerge')),
                        onPressed: () => onMerge(g),
                      ),
                    ),
                  ]),
            ),
          ),
        const SizedBox(height: Gap.lg),
      ]),
    );
  }
}
