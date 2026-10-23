import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/legal_widgets.dart';

/// Legal / policy centre (launch gap C → ADVANCED, SPEC v2.1 §21/§22).
///
/// A proper in-app legal centre: Privacy, Terms, Health Disclaimer, Community
/// Guidelines, Content Policy, Play Data-safety summary, an 18+ note, a
/// data-rights (export/delete) page and a "what admins can see" transparency
/// page. The index is searchable (across page titles + section text); every
/// page shows the §22 DRAFT stamp, last-updated date, contact line, and clear
/// expandable sections. All copy is backend DATA (bilingual via
/// Accept-Language); chrome is ARB. Zero Bangla literals in .dart.
class LegalScreen extends StatefulWidget {
  const LegalScreen({super.key});
  @override
  State<LegalScreen> createState() => _LegalScreenState();
}

class _LegalScreenState extends State<LegalScreen> {
  List<Map<String, dynamic>> _index = [];
  // Full page data, loaded lazily per key, so index search can also match
  // section text once a page has been opened; the index always matches titles.
  final Map<String, LegalPageData> _cache = {};
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _index = await context.read<AppState>().api.legalIndex();
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _filtered {
    if (_query.isEmpty) return _index;
    final needle = _query.toLowerCase();
    return _index.where((p) {
      final title = (p['title'] as String? ?? '').toLowerCase();
      if (title.contains(needle)) return true;
      final cached = _cache[p['key']];
      return cached != null && cached.matches(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(title: Text(t.legalTitle)),
      body: _loading
          ? const LegalLoading()
          : _error
              ? LegalErrorState(error: _failCause, onRetry: _load)
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Gap.md, Gap.md, Gap.md, Gap.sm),
                    child: LegalSearchField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  if (filtered.isEmpty)
                    Expanded(child: LegalEmptySearch(query: _query))
                  else
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                            Gap.md, 0, Gap.md, Gap.md),
                        children: [
                          for (final p in filtered)
                            Card(
                              child: ListTile(
                                leading:
                                    const Icon(Icons.description_outlined),
                                title: Text(p['title'] as String? ?? ''),
                                subtitle: Text(
                                  p['stamp'] as String? ?? '',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _open(p['key'] as String),
                              ),
                            ),
                        ],
                      ),
                    ),
                ]),
    );
  }

  Future<void> _open(String key) async {
    final data = await Navigator.of(context).push<LegalPageData>(
      MaterialPageRoute(builder: (_) => _LegalPage(pageKey: key)),
    );
    // Cache the loaded page so later index searches can match section text.
    if (data != null && mounted) setState(() => _cache[key] = data);
  }
}

class _LegalPage extends StatefulWidget {
  final String pageKey;
  const _LegalPage({required this.pageKey});
  @override
  State<_LegalPage> createState() => _LegalPageState();
}

class _LegalPageState extends State<_LegalPage> {
  LegalPageData? _page;
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final json =
          await context.read<AppState>().api.legalPage(widget.pageKey);
      _page = LegalPageData.fromJson(json);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final page = _page;
    final sections = page == null
        ? const <LegalSection>[]
        : (_query.isEmpty
            ? page.sections
            : page.sections
                .where((s) => s.matches(_query.toLowerCase()))
                .toList());
    return Scaffold(
      appBar: AppBar(title: Text(page?.title ?? t.legalTitle)),
      body: _loading
          ? const LegalLoading()
          : _error
              ? LegalErrorState(error: _failCause, onRetry: _load)
              : PopScope(
                  canPop: false,
                  onPopInvokedWithResult: (didPop, _) {
                    if (didPop) return;
                    // Return the loaded page so the index can cache it.
                    Navigator.of(context).pop(_page);
                  },
                  child: ListView(
                    padding: const EdgeInsets.all(Gap.lg),
                    children: [
                      LegalDraftBanner(stamp: page!.stamp),
                      const SizedBox(height: Gap.md),
                      if (page.sections.length > 3) ...[
                        LegalSearchField(
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() => _query = v),
                        ),
                        const SizedBox(height: Gap.md),
                      ],
                      if (sections.isEmpty)
                        LegalEmptySearch(query: _query)
                      else
                        LegalSectionList(sections: sections, query: _query),
                      const SizedBox(height: Gap.md),
                      LegalPageFooter(page: page),
                    ],
                  ),
                ),
    );
  }
}
