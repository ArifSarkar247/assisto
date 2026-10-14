import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/guide_data.dart';
import '../widgets/guide_service_card.dart';
import '../widgets/guide_need_sheet.dart';

/// ADVANCED Government / Service Guide (feature 30, SPEC v2.1 §21).
///
/// Step-by-step how-to guides for real Bangladesh public services (NID,
/// e-passport, birth registration, driving licence, TIN/e-return, land records
/// / porcha, trade licence, utility connections, police clearance, BRTA
/// vehicle registration). Each card carries: process steps, a required-documents
/// checklist, fee, where/office, official link, processing time, common
/// mistakes, a source note and a "verify on the official portal" disclaimer —
/// fees are NEVER invented, always marked verify-on-portal.
///
/// Features: search, category filter, bookmark/save (persisted), offline cache
/// (the whole guide works with no network), and a "what do I need for X" flow.
/// Honest Section-21 states: loading skeleton, empty, error-with-retry, an
/// offline/cached banner, bilingual (all copy via AppLocalizations), WCAG
/// contrast via the theme, and a realistic use scenario (open offline → search
/// "passport" → tap "what do I need" → open official site).
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key});
  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  static const _cacheKey = 'guide_cache_v21';
  static const _bookmarkKey = 'guide_bookmarks';

  GuideData? _data;
  bool _loading = true;
  bool _error = false;
  bool _fromCache = false; // served from cache / fallback (not a fresh fetch)
  String _query = '';
  String? _category; // null = all
  bool _onlySaved = false;
  Set<String> _saved = {};

  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBookmarks() async {
    final raw = await Settings.getString(_bookmarkKey);
    if (raw != null && raw.isNotEmpty) {
      _saved = raw.split(',').where((e) => e.isNotEmpty).toSet();
      if (mounted) setState(() {});
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final json = await context.read<AppState>().api.guides();
      final data = GuideData.fromJson(json);
      _data = data;
      _fromCache = false;
      // persist for offline use
      await Settings.setString(_cacheKey, jsonEncode(data.toJson()));
    } catch (_) {
      // Offline-first: fall back to the last good cache, then the bundled
      // sample. Only a true error if neither exists.
      final cached = await _readCache();
      if (cached != null && !cached.isEmpty) {
        _data = cached;
        _fromCache = true;
      } else {
        _data = kGuideFallback;
        _fromCache = true;
        if (kGuideFallback.isEmpty) _error = true;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<GuideData?> _readCache() async {
    final raw = await Settings.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return GuideData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _toggleBookmark(String key) async {
    setState(() {
      if (!_saved.remove(key)) _saved.add(key);
    });
    await Settings.setString(_bookmarkKey, _saved.join(','));
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      final tr = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr.guideCouldNotOpen)));
    }
  }

  List<GuideService> get _filtered {
    final d = _data;
    if (d == null) return const [];
    final q = _query.trim().toLowerCase();
    return d.services.where((s) {
      if (_onlySaved && !_saved.contains(s.key)) return false;
      if (_category != null && s.category != _category) return false;
      if (q.isEmpty) return true;
      final hay = [
        s.name,
        s.portal,
        ...s.steps,
        ...s.docs,
        ...s.mistakes,
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.serviceGuide)),
      body: _loading
          ? const SkeletonList()
          : (_error || _data == null)
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: tr.guideErrorBody,
                  action: FilledButton.tonalIcon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: Text(tr.retry),
                  ),
                )
              : _buildBody(tr, scheme),
    );
  }

  Widget _buildBody(AppLocalizations tr, ColorScheme scheme) {
    final d = _data!;
    final results = _filtered;
    return Column(children: [
      // ---- search ----
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
        child: TextField(
          controller: _searchCtrl,
          textInputAction: TextInputAction.search,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: tr.guideSearchHint,
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: tr.guideClear,
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
        ),
      ),
      // ---- category chips ----
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          children: [
            _chip(
              label: tr.guideAll,
              selected: _category == null && !_onlySaved,
              onTap: () => setState(() {
                _category = null;
                _onlySaved = false;
              }),
              scheme: scheme,
            ),
            _chip(
              label: tr.guideSaved,
              icon: Icons.bookmark,
              selected: _onlySaved,
              onTap: () => setState(() {
                _onlySaved = !_onlySaved;
                if (_onlySaved) _category = null;
              }),
              scheme: scheme,
            ),
            for (final c in d.categories)
              _chip(
                label: c.name,
                icon: guideCatMeta(c.key).icon,
                selected: _category == c.key,
                onTap: () => setState(() {
                  _onlySaved = false;
                  _category = _category == c.key ? null : c.key;
                }),
                scheme: scheme,
              ),
          ],
        ),
      ),
      // ---- offline / cache banner (honest) ----
      if (_fromCache)
        _Banner(
          icon: Icons.offline_bolt_outlined,
          text: tr.guideOfflineBanner,
          action: context.watch<AppState>().online ? tr.retry : null,
          onAction: _load,
          scheme: scheme,
        ),
      // ---- results ----
      Expanded(
        child: results.isEmpty
            ? _emptyState(tr, scheme)
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
                  children: [
                    // top-level verify disclaimer, always visible
                    _DisclaimerStrip(
                      text: d.disclaimer.isEmpty ? tr.guideDisclaimer : d.disclaimer,
                      scheme: scheme,
                    ),
                    const SizedBox(height: Gap.sm),
                    for (final s in results)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gap.sm),
                        child: GuideServiceCard(
                          service: s,
                          bookmarked: _saved.contains(s.key),
                          onToggleBookmark: () => _toggleBookmark(s.key),
                          onOpenLink: _open,
                          onWhatDoINeed: () =>
                              showGuideNeedSheet(context, s, onOpenLink: _open),
                          initiallyExpanded:
                              results.length == 1 && _query.isNotEmpty,
                        ),
                      ),
                  ],
                ),
              ),
      ),
    ]);
  }

  Widget _emptyState(AppLocalizations tr, ColorScheme scheme) {
    final searching = _query.isNotEmpty || _category != null || _onlySaved;
    return LayoutBuilder(
      builder: (_, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: StateMessage(
            icon: _onlySaved
                ? Icons.bookmark_border
                : (searching ? Icons.search_off : Icons.description_outlined),
            title: _onlySaved
                ? tr.guideNoSavedTitle
                : (searching ? tr.guideNoResultsTitle : tr.guideWelcomeTitle),
            message: _onlySaved
                ? tr.guideNoSavedBody
                : (searching ? tr.guideNoResultsBody : tr.guideWelcomeBody),
            action: searching
                ? FilledButton.tonalIcon(
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() {
                        _query = '';
                        _category = null;
                        _onlySaved = false;
                      });
                    },
                    icon: const Icon(Icons.clear_all),
                    label: Text(tr.guideClearFilters),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required ColorScheme scheme,
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: Gap.sm),
      child: ChoiceChip(
        selected: selected,
        onSelected: (_) => onTap(),
        avatar: icon == null
            ? null
            : Icon(icon,
                size: 17,
                color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
        label: Text(label),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback onAction;
  final ColorScheme scheme;
  const _Banner({
    required this.icon,
    required this.text,
    required this.onAction,
    required this.scheme,
    this.action,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface, height: 1.3)),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ]),
    );
  }
}

class _DisclaimerStrip extends StatelessWidget {
  final String text;
  final ColorScheme scheme;
  const _DisclaimerStrip({required this.text, required this.scheme});
  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.verified_outlined, size: 15, color: scheme.tertiary),
      const SizedBox(width: 6),
      Expanded(
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                height: 1.35,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant)),
      ),
    ]);
  }
}
