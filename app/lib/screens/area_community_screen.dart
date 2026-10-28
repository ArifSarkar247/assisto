import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// AREA / NEIGHBOURHOOD BOARD — ADVANCED (#194, SPEC v2.1 §20).
///
/// A small, focused LOCAL-AREA notice board: residents of one AREA post short
/// notices — an announcement, a local service, a lost-&-found, a community
/// event or a neighbourhood alert — and browse what others in the SAME area
/// posted, with category filters and honest empty states.
///
/// This is NOT the Messenger community system (which is threaded group chat).
/// It is a READ-mostly bulletin board scoped to a geographic AREA LABEL the
/// user sets (e.g. "Dhanmondi, Dhaka"). Conservative privacy: a post is scoped
/// to an AREA, never an exact address or GPS — the compose sheet never asks for
/// a house number, and the backend mirror (`_ACore`) drops any precise-location
/// field defensively.
///
/// All logic mirrors backend/core/logic/area_community.py VERBATIM so filtering/
/// ordering is identical offline. ZERO Bangla literals — every string is an
/// AppLocalizations getter; the ৳ sign (a listed service price) is gate-exempt.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('area/posts') → [{id, category, title, body, area, contact?,
///                               price?, created}]
/// create/update/deleteItem on the same path; one flexible per-user JSON
/// collection. "Area scope" is a deterministic FILTER over the rows returned —
/// we never fabricate a cross-user feed.
class AreaCommunityScreen extends StatefulWidget {
  const AreaCommunityScreen({super.key});
  @override
  State<AreaCommunityScreen> createState() => _AreaCommunityScreenState();
}

const String _postsPath = 'area/posts';

// Stable category keys (mirror CATEGORIES). 'all' is a filter-only pseudo-key.
const List<String> _categories = [
  'announcement',
  'service',
  'lost_found',
  'event',
  'alert',
];

class _AreaCommunityScreenState extends State<AreaCommunityScreen> {
  List<Map<String, dynamic>> _posts = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  // The area the user is browsing. Lives for the session; blank = show all.
  String _area = '';
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      _posts = await api.listItems(_postsPath);
      // default the browse-area to the most recent post's area, once
      if (_area.isEmpty) {
        for (final p in _posts.reversed) {
          final a = (p['area'] ?? '').toString().trim();
          if (a.isNotEmpty) {
            _area = a;
            break;
          }
        }
      }
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _add() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _postSheet(context, null, _area);
    if (res == null) return;
    try {
      await api.createItem(_postsPath, res);
      if (mounted) {
        setState(() => _area = (res['area'] ?? _area).toString());
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _postSheet(context, row, _area);
    if (res == null) return;
    try {
      await api.updateItem(_postsPath, row['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok = await _confirm(
        context, tr.areaDeleteTitle, tr.areaDeleteBody);
    if (ok != true) return;
    try {
      await api.deleteItem(_postsPath, row['id'] as int);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _changeArea() async {
    final tr = AppLocalizations.of(context);
    final picked = await _areaSheet(context, _area, _posts);
    if (picked != null && mounted) {
      setState(() => _area = picked == '*' ? '' : picked);
    }
    // '*' means "all areas"; a blank result keeps the current area.
    if (picked == '*') _toast(tr.areaShowingAll);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.areaCommunityTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.areaCommunityTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.areaLoadError),
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr.retry),
          ),
        ),
      );
    }

    final feed = _ACore.feed(_posts, area: _area, category: _filter);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.areaCommunityTitle),
        actions: [
          IconButton(
            tooltip: tr.areaChangeArea,
            onPressed: _changeArea,
            icon: const Icon(Icons.place_rounded),
          ),
        ],
      ),
      // empty board has its own "Post a notice" CTA: no duplicate FAB
      floatingActionButton: _posts.isEmpty ? null : FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.campaign_rounded),
        label: Text(tr.areaPostNotice),
      ),
      body: Column(
        children: [
          _AreaBar(
            area: _area,
            onChange: _changeArea,
          ),
          _FilterRow(
            filter: _filter,
            counts: Map<String, int>.from(feed.counts),
            areaTotal: feed.areaTotal,
            onPick: (c) => setState(() => _filter = c),
          ),
          Expanded(
            child: feed.posts.isEmpty
                ? _emptyState(context, tr, feed.areaTotal)
                : ListView(
                    padding:
                        const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 96),
                    children: [
                      _privacyNote(context, tr),
                      const SizedBox(height: Gap.sm),
                      ...feed.posts.map((p) => _PostCard(
                            post: p,
                            onEdit: () => _edit(p.raw),
                            onDelete: () => _delete(p.raw),
                          )),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, AppLocalizations tr, int areaTotal) {
    // Honest states: distinguish "no posts at all in this area" from
    // "posts exist but the active filter hides them all".
    if (areaTotal > 0 && _filter != 'all') {
      return StateMessage(
        icon: Icons.filter_alt_off_rounded,
        title: tr.areaNoneInFilterTitle,
        message: tr.areaNoneInFilterBody(_categoryLabel(tr, _filter)),
        action: FilledButton.tonalIcon(
          onPressed: () => setState(() => _filter = 'all'),
          icon: const Icon(Icons.clear_all_rounded),
          label: Text(tr.areaShowAll),
        ),
      );
    }
    return StateMessage(
      icon: Icons.holiday_village_rounded,
      title: _area.isEmpty ? tr.areaWelcomeTitle : tr.areaEmptyAreaTitle(_area),
      message: _area.isEmpty ? tr.areaWelcomeBody : tr.areaEmptyAreaBody,
      action: FilledButton.icon(
        onPressed: _add,
        icon: const Icon(Icons.campaign_rounded),
        label: Text(tr.areaPostNotice),
      ),
    );
  }

  Widget _privacyNote(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.shield_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.areaPrivacyNote,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

// ----------------------------------------------------------- area bar
class _AreaBar extends StatelessWidget {
  final String area;
  final VoidCallback onChange;
  const _AreaBar({required this.area, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.sm),
      child: Row(children: [
        Icon(Icons.place_rounded, size: 18, color: scheme.onPrimaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            area.isEmpty ? tr.areaAllAreas : area,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700),
          ),
        ),
        TextButton(
            onPressed: onChange,
            // a11y1: on primaryContainer, the container's own ink is AA.
            style: TextButton.styleFrom(foregroundColor: scheme.onPrimaryContainer),
            child: Text(tr.areaChangeArea)),
      ]),
    );
  }
}

// ----------------------------------------------------------- filter row
class _FilterRow extends StatelessWidget {
  final String filter;
  final Map<String, int> counts;
  final int areaTotal;
  final ValueChanged<String> onPick;
  const _FilterRow({
    required this.filter,
    required this.counts,
    required this.areaTotal,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final chips = <Widget>[
      _chip(context, 'all', tr.areaCatAll, areaTotal),
      for (final c in _categories)
        _chip(context, c, _categoryLabel(tr, c), counts[c] ?? 0),
    ];
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          for (final c in chips) ...[
            c,
            const SizedBox(width: Gap.sm),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String key, String label, int n) {
    final selected = filter == key;
    return Center(
      child: FilterChip(
        selected: selected,
        label: Text(n > 0 ? '$label ($n)' : label),
        onSelected: (_) => onPick(key),
      ),
    );
  }
}

// ----------------------------------------------------------- post card
class _PostCard extends StatelessWidget {
  final _APost post;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _PostCard(
      {required this.post, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _CategoryPill(category: post.category),
              const Spacer(),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') onEdit();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                  PopupMenuItem(value: 'delete', child: Text(tr.delete)),
                ],
              ),
            ]),
            Text(post.title,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
            if (post.body.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(post.body,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, height: 1.35)),
            ],
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.md,
              runSpacing: Gap.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (post.area.isNotEmpty)
                  _meta(context, Icons.place_rounded, post.area),
                if (post.price.isNotEmpty)
                  _meta(context, Icons.sell_rounded, '৳ ${post.price}'),
                if (post.contact.isNotEmpty)
                  _meta(context, Icons.call_rounded, post.contact),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _meta(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: scheme.onSurfaceVariant),
      const SizedBox(width: Gap.xs),
      Text(text,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
    ]);
  }
}

class _CategoryPill extends StatelessWidget {
  final String category;
  const _CategoryPill({required this.category});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final c = _categoryColor(context, category);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_categoryIcon(category), size: 14, color: c),
        const SizedBox(width: Gap.xs),
        Text(_categoryLabel(tr, category),
            style: AType.labelSmall.copyWith(fontWeight: FontWeight.w700, color: c)),
      ]),
    );
  }
}

// ----------------------------------------------------------- category helpers
String _categoryLabel(AppLocalizations tr, String cat) {
  switch (cat) {
    case 'announcement':
      return tr.areaCatAnnouncement;
    case 'service':
      return tr.areaCatService;
    case 'lost_found':
      return tr.areaCatLostFound;
    case 'event':
      return tr.areaCatEvent;
    case 'alert':
      return tr.areaCatAlert;
    default:
      return tr.areaCatAll;
  }
}

IconData _categoryIcon(String cat) {
  switch (cat) {
    case 'announcement':
      return Icons.campaign_rounded;
    case 'service':
      return Icons.handyman_rounded;
    case 'lost_found':
      return Icons.search_rounded;
    case 'event':
      return Icons.event_rounded;
    case 'alert':
      return Icons.warning_amber_rounded;
    default:
      return Icons.grid_view_rounded;
  }
}

Color _categoryColor(BuildContext context, String cat) {
  final scheme = Theme.of(context).colorScheme;
  switch (cat) {
    case 'alert':
      return scheme.error;
    case 'lost_found':
      return Brand.warning;
    case 'event':
      return scheme.tertiary;
    case 'service':
      return scheme.secondary;
    default:
      return scheme.primary;
  }
}

// ----------------------------------------------------------- compose sheet
Future<Map<String, dynamic>?> _postSheet(
    BuildContext context, Map<String, dynamic>? existing, String defaultArea) {
  final tr = AppLocalizations.of(context);
  String category = (existing?['category'] ?? 'announcement').toString();
  if (!_categories.contains(category)) category = 'announcement';
  final titleC =
      TextEditingController(text: (existing?['title'] ?? '').toString());
  final bodyC =
      TextEditingController(text: (existing?['body'] ?? '').toString());
  final areaC = TextEditingController(
      text: (existing?['area'] ?? defaultArea).toString());
  final contactC =
      TextEditingController(text: (existing?['contact'] ?? '').toString());
  final priceC =
      TextEditingController(text: (existing?['price'] ?? '').toString());

  return showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        final showPrice = category == 'service';
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(existing == null ? tr.areaPostNotice : tr.areaEditNotice,
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              DropdownButtonFormField<String>(
                initialValue: category,
                isExpanded: true,
                decoration: InputDecoration(
                    labelText: tr.areaCategory,
                    border: const OutlineInputBorder()),
                items: [
                  for (final c in _categories)
                    DropdownMenuItem(
                        value: c, child: Text(_categoryLabel(tr, c))),
                ],
                onChanged: (v) =>
                    setSheet(() => category = v ?? 'announcement'),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: titleC,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.areaTitle,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: bodyC,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.areaDetails,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: areaC,
                decoration: InputDecoration(
                    labelText: tr.areaFieldArea,
                    helperText: tr.areaFieldAreaHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: contactC,
                decoration: InputDecoration(
                    labelText: tr.areaContact,
                    helperText: tr.areaContactHelper,
                    border: const OutlineInputBorder()),
              ),
              if (showPrice) ...[
                const SizedBox(height: Gap.md),
                TextField(
                  controller: priceC,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: tr.areaPrice,
                      prefixText: '৳ ',
                      border: const OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (titleC.text.trim().isEmpty) {
                      ScaffoldMessenger.of(ctx)
                        ..clearSnackBars()
                        ..showSnackBar(
                            SnackBar(content: Text(tr.areaTitleRequired)));
                      return;
                    }
                    if (areaC.text.trim().isEmpty) {
                      ScaffoldMessenger.of(ctx)
                        ..clearSnackBars()
                        ..showSnackBar(
                            SnackBar(content: Text(tr.areaAreaRequired)));
                      return;
                    }
                    Navigator.pop(ctx, {
                      'category': category,
                      'title': titleC.text.trim(),
                      'body': bodyC.text.trim(),
                      'area': areaC.text.trim(),
                      'contact': contactC.text.trim(),
                      'price': showPrice ? priceC.text.trim() : '',
                    });
                  },
                  child: Text(tr.save),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

// Area picker — distinct areas found in the user's posts + "all areas".
Future<String?> _areaSheet(
    BuildContext context, String current, List<Map<String, dynamic>> posts) {
  final tr = AppLocalizations.of(context);
  final seen = <String>{};
  final areas = <String>[];
  for (final p in posts) {
    final a = (p['area'] ?? '').toString().trim();
    if (a.isNotEmpty && seen.add(a.toLowerCase())) areas.add(a);
  }
  areas.sort();
  return showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(tr.areaChooseArea,
                style: Theme.of(ctx).textTheme.titleLarge),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                RadioListTile<String>(
                  value: '*',
                  groupValue: current.isEmpty ? '*' : current,
                  title: Text(tr.areaAllAreas),
                  onChanged: (v) => Navigator.pop(ctx, v),
                ),
                for (final a in areas)
                  RadioListTile<String>(
                    value: a,
                    groupValue: current.isEmpty ? '*' : current,
                    title: Text(a),
                    onChanged: (v) => Navigator.pop(ctx, v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Gap.sm),
        ]),
      );
    },
  );
}

Future<bool?> _confirm(BuildContext context, String title, String body) {
  final tr = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true, // insets: 200% text / keyboard
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(tr.delete)),
      ],
    ),
  );
}

// ===========================================================================
// _ACore — VERBATIM mirror of backend/core/logic/area_community.py: the
// area-scoped, category-filtered, newest-first feed with conservative privacy.
// ===========================================================================
class _APost {
  final Map<String, dynamic> raw;
  final int id;
  final String category;
  final String title;
  final String body;
  final String area;
  final String contact;
  final String price;
  final String created;
  _APost(this.raw, this.id, this.category, this.title, this.body, this.area,
      this.contact, this.price, this.created);
}

class _AFeed {
  final List<_APost> posts;
  final int count;
  final Map<String, int> counts;
  final int areaTotal;
  _AFeed(this.posts, this.count, this.counts, this.areaTotal);
}

class _ACore {
  static String _clean(dynamic v) =>
      (v ?? '').toString().trim().split(RegExp(r'\s+')).join(' ');

  static String normArea(String area) {
    final s = _clean(area).toLowerCase();
    return s.split(',').map((p) => p.trim()).join(',');
  }

  static bool _known(String c) => _categories.contains(c);

  static _APost _display(Map<String, dynamic> row) {
    final cat = (row['category'] ?? '').toString();
    return _APost(
      row,
      (row['id'] is int) ? row['id'] as int : 0,
      _known(cat) ? cat : 'announcement',
      _clean(row['title']),
      _clean(row['body']),
      _clean(row['area']),
      _clean(row['contact']),
      _clean(row['price']),
      _clean(row['created']),
    );
  }

  static _AFeed feed(List<Map<String, dynamic>> posts,
      {String area = '', String category = 'all'}) {
    final wantArea = area.trim().isEmpty ? null : normArea(area);
    final scoped = <_APost>[];
    for (final raw in posts) {
      final p = _display(raw);
      if (p.title.isEmpty) continue;
      if (wantArea != null && normArea(p.area) != wantArea) continue;
      scoped.add(p);
    }
    final counts = {for (final c in _categories) c: 0};
    for (final p in scoped) {
      counts[p.category] = (counts[p.category] ?? 0) + 1;
    }
    List<_APost> shown;
    if (category != 'all' && _known(category)) {
      shown = scoped.where((p) => p.category == category).toList();
    } else {
      shown = List.of(scoped);
    }
    shown.sort((a, b) {
      final byCreated = b.created.compareTo(a.created);
      if (byCreated != 0) return byCreated;
      return b.id.compareTo(a.id);
    });
    return _AFeed(shown, shown.length, counts, scoped.length);
  }
}
