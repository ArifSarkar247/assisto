import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../api.dart';
import '../../discover_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/home_suggestions.dart' show DiscoverCardTile;
import '../../widgets/skeleton.dart';
import '../../services/action_feedback.dart'; // db1
import '../../services/error_kind.dart' show honestFailText; // qa2
import '../../messaging/date_separators.dart' show localDigits, fmtDate; // qa2

/// OWNER "Discover manager" (d1-discover) — add / edit / delete / reorder /
/// enable-disable the home Discover cards, pick an in-app route, preview what a
/// Free / Premium / Business user sees, and open the per-card sponsor report
/// (CSV / PDF export).
///
/// Owner-only: the entry tile sits behind the same operator probe as the P&L
/// dashboard, and every endpoint re-checks superuser server-side (403 ->
/// owner-only state). Visibility rules and content safety are enforced by the
/// server; this screen only shows what the server says.
class DiscoverManagerScreen extends StatefulWidget {
  const DiscoverManagerScreen({super.key});
  @override
  State<DiscoverManagerScreen> createState() => _DiscoverManagerScreenState();
}

enum _St { loading, ok, error, ownerOnly }

List<Map<String, dynamic>> _maps(Object? v) => (v is List)
    ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
    : <Map<String, dynamic>>[];

int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

String _typeLabel(AppLocalizations t, String type) => switch (type) {
      DiscoverItem.ourProduct => t.discoverMgrTypeProduct,
      DiscoverItem.sponsored => t.discoverMgrTypeSponsored,
      DiscoverItem.admob => t.discoverMgrTypeAdmob,
      _ => t.discoverMgrTypeFeature,
    };

String _audLabel(AppLocalizations t, String a) => switch (a) {
      'free' => t.discoverMgrSegFree,
      'premium' => t.discoverMgrSegPremium,
      'business' => t.discoverMgrSegBusiness,
      _ => t.discoverMgrAudienceAll,
    };

class _DiscoverManagerScreenState extends State<DiscoverManagerScreen> {
  _St _st = _St.loading;
  Object? _failCause; // qa2: honest error (5xx = our server)
  List<Map<String, dynamic>> _cards = [];
  Map<String, dynamic> _meta = const {};

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _st = _St.loading);
    try {
      final r = await _api.adminDiscoverList();
      Map<String, dynamic> meta = _meta;
      if (meta.isEmpty) meta = await _api.adminDiscoverMeta();
      if (!mounted) return;
      setState(() {
        _cards = _maps(r['cards']);
        _meta = meta;
        _st = _St.ok;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      _failCause = e;
      setState(() => _st = e.status == 403 ? _St.ownerOnly : _St.error);
    } catch (e) {
      if (!mounted) return;
      _failCause = e;
      setState(() => _st = _St.error);
    }
  }

  Future<void> _toggle(Map<String, dynamic> c, bool v) async {
    final t = AppLocalizations.of(context);
    try {
      final r = await _api.adminDiscoverUpdate(_i(c['id']), {'enabled': v});
      if (!mounted) return;
      setState(() {
        final i = _cards.indexWhere((x) => x['id'] == c['id']);
        if (i >= 0) _cards[i] = r;
      });
    } catch (_) {
      if (mounted) _snack(t.discoverMgrSaveFailed);
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final t = AppLocalizations.of(context);
    final before = List<Map<String, dynamic>>.from(_cards);
    setState(() {
      final c = _cards.removeAt(oldIndex);
      _cards.insert(newIndex, c);
    });
    try {
      await _api.adminDiscoverReorder([for (final c in _cards) _i(c['id'])]);
    } catch (_) {
      if (!mounted) return;
      setState(() => _cards = before);
      _snack(t.discoverMgrSaveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t.discoverMgrDeleteConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.adminDiscoverDelete(_i(c['id']));
      if (!mounted) return;
      setState(() => _cards.removeWhere((x) => x['id'] == c['id']));
    } catch (_) {
      if (mounted) _snack(t.discoverMgrSaveFailed);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _edit([Map<String, dynamic>? c]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => DiscoverCardEditScreen(card: c, meta: _meta)),
    );
    if (changed == true) _load();
  }

  void _openReport(Map<String, dynamic> c) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => DiscoverReportScreen(
              cardId: _i(c['id']), title: '${c['title_en'] ?? ''}')));

  void _preview() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const _PreviewSheet(),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.discoverMgrTitle),
        actions: [
          if (_st == _St.ok) ...[
            IconButton(
                tooltip: t.discoverMgrPreview,
                icon: const Icon(Icons.visibility_rounded),
                onPressed: _preview),
            IconButton(
                tooltip: t.refresh,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _load),
          ],
        ],
      ),
      floatingActionButton: _st == _St.ok
          ? FloatingActionButton.extended(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.discoverMgrAdd),
            )
          : null,
      body: switch (_st) {
        _St.loading => const SkeletonList(),
        _St.ownerOnly => StateMessage(
            icon: Icons.admin_panel_settings_rounded,
            title: t.pnlOwnerOnlyTitle,
            message: t.discoverMgrOwnerOnly,
            tint: Brand.warning,
          ),
        _St.error => StateMessage(
            icon: Icons.cloud_off_rounded,
            title: t.loadFailed,
            message:
                honestFailText(t, _failCause, otherwise: t.loadFailedBody),
            tint: Brand.danger,
            action: FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.retry)),
          ),
        _St.ok => _list(t),
      },
    );
  }

  Widget _list(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    if (_cards.isEmpty) {
      return StateMessage(
          icon: Icons.view_carousel_rounded, title: t.discoverMgrEmpty);
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
      header: Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text('${t.discoverMgrReorderHint}\n${t.qa2DiscoverPaidNote}',
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ),
      itemCount: _cards.length,
      onReorderItem: _reorder,
      itemBuilder: (ctx, i) {
        final c = _cards[i];
        final item = DiscoverItem.fromJson({
          ...c,
          'title': {'bn': c['title_bn'], 'en': c['title_en']},
          'description': {'bn': c['desc_bn'], 'en': c['desc_en']},
        });
        final lang =
            Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
        final stats = (c['stats'] as Map?)?.cast<String, dynamic>() ?? {};
        final enabled = c['enabled'] == true;
        final live = c['live'] == true;
        final title = item.isAdmob ? t.discoverMgrTypeAdmob : item.title(t, lang);
        return Card(
          key: ValueKey('dm-${c['id']}'),
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => _edit(c),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
              child: Row(children: [
                Icon(item.iconData, color: scheme.primary),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: Gap.xxs),
                      Wrap(spacing: Gap.xs, runSpacing: 2, children: [
                        _chip(_typeLabel(t, item.type), scheme.primary),
                        _chip(_audLabel(t, '${c['audience'] ?? 'all'}'),
                            scheme.tertiary),
                        _chip(
                            !enabled
                                ? t.discoverMgrOff
                                : (live ? t.discoverMgrLive : t.discoverMgrNotLive),
                            live ? Brand.success : scheme.onSurfaceVariant),
                      ]),
                      const SizedBox(height: Gap.xxs),
                      Text(
                        t.discoverMgrStats(_i(stats['impressions']),
                            _i(stats['clicks']), '${stats['ctr'] ?? 0}'),
                        maxLines: 2,
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Switch(value: enabled, onChanged: (v) => _toggle(c, v)),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'report') _openReport(c);
                    if (v == 'delete') _delete(c);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'report', child: Text(t.discoverMgrReport)),
                    PopupMenuItem(value: 'delete', child: Text(t.delete)),
                  ],
                ),
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.all(Gap.xs),
                    child: Icon(Icons.drag_handle_rounded),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
      buildDefaultDragHandles: false,
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.xs),
        ),
        child: Text(label,
            style: AType.labelSmall.copyWith(color: color, fontWeight: FontWeight.w700)),
      );
}

// ---------------------------------------------------------------- preview
class _PreviewSheet extends StatefulWidget {
  const _PreviewSheet();
  @override
  State<_PreviewSheet> createState() => _PreviewSheetState();
}

class _PreviewSheetState extends State<_PreviewSheet> {
  String _seg = 'free';
  List<DiscoverItem>? _items;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _items = null;
      _failed = false;
    });
    try {
      final r =
          await context.read<AppState>().api.adminDiscoverPreview(_seg);
      if (!mounted) return;
      setState(() => _items = _maps(r['cards'])
          .map(DiscoverItem.fromJson)
          .where((c) => !c.isAdmob)
          .toList());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final items = _items;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.discoverMgrPreviewAs,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'free', label: Text(t.discoverMgrSegFree)),
                ButtonSegment(
                    value: 'premium', label: Text(t.discoverMgrSegPremium)),
                ButtonSegment(
                    value: 'business', label: Text(t.discoverMgrSegBusiness)),
              ],
              selected: {_seg},
              onSelectionChanged: (s) {
                _seg = s.first;
                _load();
              },
            ),
            const SizedBox(height: Gap.md),
            Flexible(
              child: _failed
                  ? Text(t.loadFailedBody)
                  : items == null
                      ? const Center(child: CircularProgressIndicator())
                      : items.isEmpty
                          ? Text(t.discoverMgrPreviewEmpty)
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: Gap.sm),
                              itemBuilder: (_, i) =>
                                  DiscoverCardTile(item: items[i]),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ editor
class DiscoverCardEditScreen extends StatefulWidget {
  final Map<String, dynamic>? card;
  final Map<String, dynamic> meta;
  const DiscoverCardEditScreen({super.key, this.card, required this.meta});
  @override
  State<DiscoverCardEditScreen> createState() => _DiscoverCardEditScreenState();
}

class _DiscoverCardEditScreenState extends State<DiscoverCardEditScreen> {
  late Map<String, dynamic>? _card = widget.card;
  late String _type = '${widget.card?['type'] ?? DiscoverItem.feature}';
  late String _audience = '${widget.card?['audience'] ?? 'all'}';
  late String _icon = '${widget.card?['icon'] ?? ''}';
  late String _route = '${widget.card?['route'] ?? ''}';
  late bool _useUrl = '${widget.card?['url'] ?? ''}'.isNotEmpty;
  late bool _enabled = widget.card?['enabled'] != false;
  DateTime? _start;
  DateTime? _end;
  bool _saving = false;
  bool _changed = false;
  String? _error;

  final _titleBn = TextEditingController();
  final _titleEn = TextEditingController();
  final _descBn = TextEditingController();
  final _descEn = TextEditingController();
  final _url = TextEditingController();
  final _minBuild = TextEditingController();
  final _sponsor = TextEditingController();
  final _revenue = TextEditingController();

  List<String> get _routes =>
      (widget.meta['routes'] as List?)?.map((e) => '$e').toList() ??
      const <String>[];
  List<String> get _icons =>
      (widget.meta['icons'] as List?)?.map((e) => '$e').toList() ??
      kDiscoverIcons.keys.toList();

  @override
  void initState() {
    super.initState();
    final c = widget.card ?? const {};
    _titleBn.text = '${c['title_bn'] ?? ''}';
    _titleEn.text = '${c['title_en'] ?? ''}';
    _descBn.text = '${c['desc_bn'] ?? ''}';
    _descEn.text = '${c['desc_en'] ?? ''}';
    _url.text = '${c['url'] ?? ''}';
    _minBuild.text = c['min_build'] == null ? '' : '${c['min_build']}';
    _sponsor.text = '${c['sponsor_name'] ?? ''}';
    final rev = c['sponsor_revenue'];
    _revenue.text = (rev == null || rev == 0 || rev == 0.0) ? '' : '$rev';
    _start = DateTime.tryParse('${c['start_at'] ?? ''}')?.toLocal();
    _end = DateTime.tryParse('${c['end_at'] ?? ''}')?.toLocal();
    for (final ctl in [_titleBn, _titleEn, _descBn, _descEn]) {
      ctl.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [
      _titleBn, _titleEn, _descBn, _descEn, _url, _minBuild, _sponsor, _revenue
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isAdmob => _type == DiscoverItem.admob;
  bool get _isSponsored => _type == DiscoverItem.sponsored;

  DiscoverItem get _previewItem => DiscoverItem(
        key: 'preview',
        type: _type,
        titleBn: _titleBn.text,
        titleEn: _titleEn.text,
        descBn: _descBn.text,
        descEn: _descEn.text,
        icon: _icon,
        imageUrl: '${_card?['image_url'] ?? ''}',
        route: _useUrl ? '' : _route,
        url: _useUrl ? _url.text.trim() : '',
      );

  Map<String, dynamic> _body() => {
        'type': _type,
        'title_bn': _titleBn.text.trim(),
        'title_en': _titleEn.text.trim(),
        'desc_bn': _descBn.text.trim(),
        'desc_en': _descEn.text.trim(),
        'icon': _icon,
        'route': _isAdmob || _useUrl ? '' : _route,
        'url': _isAdmob || !_useUrl ? '' : _url.text.trim(),
        'audience': _audience,
        'enabled': _enabled,
        'start_at': _start?.toUtc().toIso8601String(),
        'end_at': _end?.toUtc().toIso8601String(),
        'min_build': _minBuild.text.trim().isEmpty ? null : _minBuild.text.trim(),
        'sponsor_name': _isSponsored ? _sponsor.text.trim() : '',
        'sponsor_revenue':
            _isSponsored && _revenue.text.trim().isNotEmpty ? _revenue.text.trim() : 0,
      };

  String _fieldLabel(AppLocalizations t, String k) => switch (k) {
        'title_bn' => t.discoverMgrTitleBn,
        'title_en' => t.discoverMgrTitleEn,
        'route' => t.discoverMgrRoute,
        'url' => t.discoverMgrUrl,
        'action' => t.discoverMgrAction,
        'icon' => t.discoverMgrIcon,
        'sponsor_name' => t.discoverMgrSponsorName,
        'sponsor_revenue' => t.discoverMgrSponsorRevenue,
        'end_at' => t.discoverMgrEnd,
        'start_at' => t.discoverMgrStart,
        'min_build' => t.discoverMgrMinBuild,
        'audience' => t.discoverMgrAudience,
        _ => t.discoverMgrType,
      };

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = _card?['id'];
      final r = id == null
          ? await api.adminDiscoverCreate(_body())
          : await api.adminDiscoverUpdate(_i(id), _body());
      if (!mounted) return;
      setState(() {
        _card = r;
        _changed = true;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.discoverMgrSaved)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.status == 400
          ? _explain400(t, e)
          : honestFailText(t, e, otherwise: t.discoverMgrSaveFailed)); // qa2
    } catch (_) {
      if (mounted) setState(() => _error = t.discoverMgrSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ApiException carries the first body value as its message: the server's
  // `errors` map or `safety` list rendered as text. Map known keys to labels.
  String _explain400(AppLocalizations t, ApiException e) {
    final m = e.message;
    if (m.contains('banned_wording') ||
        m.contains('scam_pattern') ||
        m.contains('url_') ||
        m.contains('link_in_text') ||
        m.contains('bad_url')) {
      return t.discoverMgrErrSafety;
    }
    final keys = RegExp(r'([a-z_]+):').allMatches(m).map((x) => x.group(1)!);
    final labels = {for (final k in keys) _fieldLabel(t, k)};
    return labels.isEmpty
        ? t.discoverMgrSaveFailed
        : t.discoverMgrErrFields(labels.join(', '));
  }

  Future<void> _pickImage() async {
    final t = AppLocalizations.of(context);
    final id = _card?['id'];
    if (id == null) {
      setState(() => _error = t.discoverMgrImageSaveFirst);
      return;
    }
    try {
      final x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
      if (x == null || !mounted) return;
      final r = await context
          .read<AppState>()
          .api
          .adminDiscoverUploadImage(_i(id), x.path);
      if (!mounted) return;
      setState(() {
        _card = r;
        _changed = true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = t.discoverMgrImageFailed);
    }
  }

  Future<DateTime?> _pickDate(DateTime? initial) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: initial ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    return d;
  }

  String _fmt(DateTime? d) => d == null
      ? AppLocalizations.of(context).discoverMgrNoDate
      : MaterialLocalizations.of(context).formatMediumDate(d);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isNew = _card?['id'] == null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isNew ? t.discoverMgrAdd : t.discoverMgrEdit),
          actions: [
            if (!isNew)
              IconButton(
                tooltip: t.discoverMgrReport,
                icon: const Icon(Icons.insights_rounded),
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => DiscoverReportScreen(
                            cardId: _i(_card!['id']),
                            title: _titleEn.text))),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            Text(t.discoverMgrPreview,
                style: AType.titleSmall.copyWith(color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            if (_isAdmob)
              Text(t.discoverMgrAdmobNote,
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else
              DiscoverCardTile(item: _previewItem),
            const SizedBox(height: Gap.xl),
            DropdownButtonFormField<String>(
              initialValue: _type,
              isExpanded: true,
              decoration: InputDecoration(labelText: t.discoverMgrType),
              items: [
                for (final ty in const [
                  DiscoverItem.feature,
                  DiscoverItem.ourProduct,
                  DiscoverItem.sponsored,
                  DiscoverItem.admob
                ])
                  DropdownMenuItem(value: ty, child: Text(_typeLabel(t, ty))),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            if (_isSponsored || _isAdmob)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.qa2DiscoverPaidNote,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ),
            if (!_isAdmob) ...[
              const SizedBox(height: Gap.lg + Gap.xs),
              _field(_titleBn, t.discoverMgrTitleBn, max: 80),
              _field(_titleEn, t.discoverMgrTitleEn, max: 80),
              _field(_descBn, t.discoverMgrDescBn, max: 200, lines: 2),
              _field(_descEn, t.discoverMgrDescEn, max: 200, lines: 2),
              const SizedBox(height: Gap.sm),
              Text(t.discoverMgrAction,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                      value: false,
                      icon: const Icon(Icons.apps_rounded),
                      label: Text(t.qa2DiscoverActionRoute)),
                  ButtonSegment(
                      value: true,
                      icon: const Icon(Icons.language_rounded),
                      label: Text(t.qa2DiscoverActionUrl)),
                ],
                selected: {_useUrl},
                onSelectionChanged: (s) => setState(() => _useUrl = s.first),
              ),
              const SizedBox(height: Gap.lg + Gap.xs),
              if (_useUrl)
                _field(_url, t.discoverMgrUrl,
                    keyboard: TextInputType.url, onChanged: true)
              else
                DropdownButtonFormField<String>(
                  initialValue: _routes.contains(_route) ? _route : null,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: t.discoverMgrRoute),
                  items: [
                    for (final r in _routes)
                      DropdownMenuItem(value: r, child: Text(r)),
                  ],
                  onChanged: (v) => setState(() => _route = v ?? ''),
                ),
              const SizedBox(height: Gap.lg + Gap.xs),
              DropdownButtonFormField<String>(
                initialValue: _icons.contains(_icon) ? _icon : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: t.discoverMgrIcon),
                items: [
                  for (final name in _icons)
                    DropdownMenuItem(
                      value: name,
                      // qa2: the icon is the choice — its internal name
                      // ("shopping_bag") was English text in the Bangla UI.
                      child: Semantics(
                        label: name.replaceAll('_', ' '),
                        child: Icon(
                            kDiscoverIcons[name] ?? Icons.auto_awesome_rounded,
                            size: 24),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _icon = v ?? ''),
              ),
              const SizedBox(height: Gap.sm),
              Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                OutlinedButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.image_rounded),
                  label: Text(t.discoverMgrImagePick),
                ),
                if ('${_card?['image_url'] ?? ''}'.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      try {
                        await context.read<AppState>().api.deleteJson(
                            '/admin/discover/cards/${_i(_card!['id'])}/image');
                        if (!mounted) return;
                        setState(() {
                          _card = {..._card!, 'image_url': ''};
                          _changed = true;
                        });
                      } catch (e) {
                        showActionFailed(context, 'discover.removeImage', e); // db1
                      }
                    },
                    child: Text(t.discoverMgrImageRemove),
                  ),
              ]),
            ],
            const SizedBox(height: Gap.lg + Gap.xs),
            DropdownButtonFormField<String>(
              initialValue: _audience,
              isExpanded: true,
              decoration: InputDecoration(labelText: t.discoverMgrAudience),
              items: [
                for (final a in const ['all', 'free', 'premium', 'business'])
                  DropdownMenuItem(value: a, child: Text(_audLabel(t, a))),
              ],
              onChanged: (v) => setState(() => _audience = v ?? 'all'),
            ),
            const SizedBox(height: Gap.sm),
            _dateRow(t.discoverMgrStart, _start, (d) => setState(() => _start = d),
                startOfDay: true),
            _dateRow(t.discoverMgrEnd, _end, (d) => setState(() => _end = d),
                startOfDay: false),
            _field(_minBuild, t.discoverMgrMinBuild,
                keyboard: TextInputType.number),
            if (_isSponsored) ...[
              _field(_sponsor, t.discoverMgrSponsorName, max: 80),
              _field(_revenue, t.discoverMgrSponsorRevenue,
                  keyboard: const TextInputType.numberWithOptions(decimal: true)),
              Text(t.discoverMgrSponsorNote,
                  style:
                      AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.discoverMgrEnabled),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check_rounded),
              label: Text(t.save),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      {int? max, int lines = 1, TextInputType? keyboard, bool onChanged = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg + Gap.xs), // qa2: the floated label sits on the top edge — give it room
      child: TextField(
        controller: c,
        maxLength: max,
        minLines: 1,
        maxLines: lines,
        keyboardType: keyboard,
        onChanged: onChanged ? (_) => setState(() {}) : null,
        decoration: InputDecoration(labelText: label, counterText: ''),
      ),
    );
  }

  /// Start = the chosen day's 00:00; End = the END of the chosen day (the
  /// card stops showing at the next midnight, local time).
  Widget _dateRow(String label, DateTime? value, ValueChanged<DateTime?> set,
      {required bool startOfDay}) {
    final t = AppLocalizations.of(context);
    final shown =
        (!startOfDay && value != null) ? value.subtract(const Duration(seconds: 1)) : value;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.event_rounded),
      title: Text(label),
      subtitle: Text(_fmt(shown)),
      trailing: value == null
          ? null
          : TextButton(onPressed: () => set(null), child: Text(t.discoverMgrClear)),
      onTap: () async {
        final d = await _pickDate(shown);
        if (d == null) return;
        final day = DateTime(d.year, d.month, d.day);
        set(startOfDay ? day : day.add(const Duration(days: 1)));
      },
    );
  }
}

// ------------------------------------------------------------------ report
class DiscoverReportScreen extends StatefulWidget {
  final int cardId;
  final String title;
  const DiscoverReportScreen(
      {super.key, required this.cardId, required this.title});
  @override
  State<DiscoverReportScreen> createState() => _DiscoverReportScreenState();
}

class _DiscoverReportScreenState extends State<DiscoverReportScreen> {
  int _days = 30;
  Map<String, dynamic>? _data;
  bool _failed = false;
  Object? _failCause; // qa2: a 5xx is our server, not the owner's internet
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _data = null;
      _failed = false;
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .adminDiscoverReport(widget.cardId, days: _days);
      if (mounted) setState(() => _data = r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failCause = e;
        });
      }
    }
  }

  Future<void> _export(String fmt) async {
    final t = AppLocalizations.of(context);
    setState(() => _exporting = true);
    try {
      final bytes = await context
          .read<AppState>()
          .api
          .adminDiscoverExport(widget.cardId, fmt, days: _days);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/discover-report-${widget.cardId}.$fmt');
      await f.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(f.path)], text: t.discoverMgrReportTitle);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.discoverMgrExportFailed)));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final d = _data;
    final rows = _maps(d?['rows']).reversed.toList(); // newest first
    final totals = (d?['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final card = (d?['card'] as Map?)?.cast<String, dynamic>() ?? const {};
    // qa2: Bangla digits + "23 Oct" dates in the Bangla UI (the server sends
    // ISO dates and Latin numbers; the CSV/PDF exports keep those).
    final lang = Localizations.localeOf(context).languageCode;
    String ld(Object? v) => localDigits('${v ?? 0}', lang);
    String day(Object? iso) {
      final dt = DateTime.tryParse('${iso ?? ''}');
      return dt == null ? ld(iso) : fmtDate('d MMM', dt, lang);
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.discoverMgrReportTitle)),
      body: _failed
          ? StateMessage(
              icon: Icons.cloud_off_rounded,
              title: t.loadFailed,
              message:
                  honestFailText(t, _failCause, otherwise: t.loadFailedBody),
              tint: Brand.danger,
              action: FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(t.retry)),
            )
          : d == null
              ? const SkeletonList()
              : ListView(
                  padding: const EdgeInsets.all(Gap.lg),
                  children: [
                    Text(
                        '${card['title_en'] ?? widget.title}'.isEmpty
                            ? widget.title
                            : '${card['title_en']}',
                        style: Theme.of(context).textTheme.titleMedium),
                    if ('${card['sponsor_name'] ?? ''}'.isNotEmpty)
                      Text('${t.discoverMgrSponsorName}: ${card['sponsor_name']}',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    const SizedBox(height: Gap.sm),
                    SegmentedButton<int>(
                      segments: [
                        for (final n in const [7, 30, 90])
                          ButtonSegment(
                              value: n,
                              label: Text(localDigits(t.discoverMgrDays(n), lang))),
                      ],
                      selected: {_days},
                      onSelectionChanged: (s) {
                        _days = s.first;
                        _load();
                      },
                    ),
                    const SizedBox(height: Gap.md),
                    Text(
                      localDigits(
                          t.discoverMgrStats(_i(totals['impressions']),
                              _i(totals['clicks']), '${totals['ctr'] ?? 0}'),
                          lang),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(t.discoverMgrUniqueNote,
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                    const SizedBox(height: Gap.sm),
                    Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                      OutlinedButton.icon(
                        onPressed: _exporting ? null : () => _export('csv'),
                        icon: const Icon(Icons.table_view_rounded),
                        label: Text(t.discoverMgrExportCsv),
                      ),
                      OutlinedButton.icon(
                        onPressed: _exporting ? null : () => _export('pdf'),
                        icon: const Icon(Icons.picture_as_pdf_rounded),
                        label: Text(t.discoverMgrExportPdf),
                      ),
                    ]),
                    const SizedBox(height: Gap.md),
                    // qa2: the table spans the full width (it stopped at
                    // ~80% and looked unfinished); scrolls only when wider.
                    LayoutBuilder(
                      builder: (context, box) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: box.maxWidth),
                      child: DataTable(
                        columnSpacing: Gap.lg,
                        columns: [
                          DataColumn(label: Text(t.discoverMgrColDate)),
                          DataColumn(
                              numeric: true,
                              label: Text(t.discoverMgrColViews)),
                          DataColumn(
                              numeric: true, label: Text(t.discoverMgrColTaps)),
                          DataColumn(
                              numeric: true, label: Text(t.discoverMgrColCtr)),
                        ],
                        rows: [
                          for (final r in rows)
                            DataRow(cells: [
                              DataCell(Text(day(r['date']))),
                              DataCell(Text(ld(r['impressions']))),
                              DataCell(Text(ld(r['clicks']))),
                              DataCell(Text(ld(r['ctr']))),
                            ]),
                          DataRow(cells: [
                            DataCell(Text(t.discoverMgrTotal,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800))),
                            DataCell(Text(ld(totals['impressions']))),
                            DataCell(Text(ld(totals['clicks']))),
                            DataCell(Text(ld(totals['ctr']))),
                          ]),
                        ],
                      ),
                      ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
