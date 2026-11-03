import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/skeleton.dart';

/// p2career (flag career_plus): Job Hunter "Find jobs" — LEGAL sources only.
///   * Careerjet official partner API (owner key; honest "not connected").
///   * Company Greenhouse / Lever job boards and RSS feeds the USER adds
///     (`career/sources`); plain career-page links are saved as links and
///     never read by the server.
///   * Official portals (BPSC, Teletalk, Bdjobs, …) as link-outs, each labelled
///     "link only — no open feed".
/// Every result carries its source label. Saved searches (`career/searches`)
/// re-run in one tap. Tracking a job can set deadline reminders (3 days
/// before + the day). Zero Bangla literals.
class JobFindScreen extends StatefulWidget {
  const JobFindScreen({super.key});

  @override
  State<JobFindScreen> createState() => _JobFindScreenState();
}

const _kinds = ['greenhouse', 'lever', 'rss', 'link'];

class _JobFindScreenState extends State<JobFindScreen> {
  final _q = TextEditingController();
  final _loc = TextEditingController();
  bool _loading = true, _failed = false, _searching = false;
  Object? _failCause;
  Map<String, dynamic> _status = const {};
  List<Map<String, dynamic>> _searches = [], _sources = [];
  List<Map<String, dynamic>>? _results;
  List<Map<String, dynamic>> _report = [];

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    _loc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final api = context.read<AppState>().api;
      _status = await api.getJson('/career/status');
      _searches = await api.listItems('career/searches');
      _sources = await api.listItems('career/sources');
    } catch (e) {
      _failed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    final q = _q.text.trim();
    if (q.isEmpty) {
      _toast(t.crrJobsQueryNeeded);
      return;
    }
    setState(() => _searching = true);
    try {
      final r = await context.read<AppState>().api.getJson(
          '/career/jobs/search?q=${Uri.encodeQueryComponent(q)}&loc=${Uri.encodeQueryComponent(_loc.text.trim())}');
      _results = (r['jobs'] as List? ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
      _report = (r['sources'] as List? ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (e) {
      if (mounted) _toast(honestFailText(t, e));
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _saveSearch() async {
    final q = _q.text.trim();
    if (q.isEmpty) {
      _toast(t.crrJobsQueryNeeded);
      return;
    }
    try {
      final row = await context.read<AppState>().api.createItem('career/searches', {
        'q': q,
        'loc': _loc.text.trim(),
        'saved_at': DateTime.now().toIso8601String().substring(0, 10),
      });
      setState(() => _searches = [..._searches, row]);
      _toast(t.crrJobsSearchSaved);
    } catch (_) {
      _toast(t.saveFailed);
    }
  }

  Future<void> _deleteSearch(Map<String, dynamic> s) async {
    final id = (s['id'] as num?)?.toInt();
    if (id == null) return;
    try {
      await context.read<AppState>().api.deleteItem('career/searches', id);
      setState(() => _searches = _searches.where((x) => x['id'] != s['id']).toList());
    } catch (_) {
      _toast(t.saveFailed);
    }
  }

  Future<void> _open(String url) async {
    final u = Uri.tryParse(url);
    final ok = u != null && await launchUrl(u, mode: LaunchMode.externalApplication);
    if (!ok && mounted) _toast(t.crrOpenFailed);
  }

  Future<void> _track(Map<String, dynamic> j) async {
    final api = context.read<AppState>().api;
    int? id;
    try {
      final row = await api.createItem('jobs', {
        'title': '${j['title'] ?? ''}',
        'company': '${j['company'] ?? ''}',
        'source': '${j['source'] ?? ''}'.characters.take(40).toString(),
        'jd': '${j['url'] ?? ''}',
        if ('${j['location'] ?? ''}'.isNotEmpty) 'location': '${j['location']}',
      });
      id = (row['id'] as num?)?.toInt();
      if (mounted) _toast(t.crrJobsTracked);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
      return;
    }
    if (!mounted || id == null) return;
    await _askDeadline('${j['title'] ?? ''}', 'job:$id');
  }

  Future<void> _askDeadline(String title, String ref) async {
    final now = DateTime.now();
    final want = await showAppSheet<bool>(
      context: context,
      builder: (c) => AppSheetBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.crrJobsDeadlineAsk, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(t.crrJobsDeadlineHelp),
            const SizedBox(height: 16),
            Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.crrJobsDeadlineSkip)),
              FilledButton.icon(
                  onPressed: () => Navigator.pop(c, true),
                  icon: const Icon(Icons.event_rounded),
                  label: Text(t.crrJobsDeadlinePick)),
            ]),
          ],
        ),
      ),
    );
    if (want != true || !mounted) return;
    final d = await showDatePicker(
        context: context,
        firstDate: now,
        lastDate: now.add(const Duration(days: 365)),
        initialDate: now.add(const Duration(days: 7)));
    if (d == null || !mounted) return;
    try {
      final iso = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      await context.read<AppState>().api.postJson('/career/jobs/deadline', {'title': title, 'deadline': iso, 'ref': ref});
      if (mounted) _toast(t.crrJobsDeadlineSet);
    } catch (e) {
      if (mounted) _toast(honestFailText(t, e));
    }
  }

  Future<void> _removeSource(Map<String, dynamic> s) async {
    final id = (s['id'] as num?)?.toInt();
    if (id == null) return;
    try {
      await context.read<AppState>().api.deleteItem('career/sources', id);
      setState(() => _sources = _sources.where((x) => x['id'] != s['id']).toList());
    } catch (_) {
      _toast(t.saveFailed);
    }
  }

  Future<void> _addSource() async {
    if (_sources.length >= 10) {
      _toast(t.crrCompanyLimit);
      return;
    }
    final row = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (c) => const _AddSourceSheet(),
    );
    if (row == null || !mounted) return;
    try {
      final saved = await context.read<AppState>().api.createItem('career/sources', row);
      setState(() => _sources = [..._sources, saved]);
    } catch (_) {
      _toast(t.saveFailed);
    }
  }

  String _kindLabel(String k) => switch (k) {
        'greenhouse' => t.crrKindGreenhouse,
        'lever' => t.crrKindLever,
        'rss' => t.crrKindRss,
        _ => t.crrKindLink,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.crrJobsFindTitle)),
      body: _loading
          ? const SkeletonList()
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: honestFailText(t, _failCause),
                  action: FilledButton.tonalIcon(
                      onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
                    children: [
                      TextField(
                        controller: _q,
                        maxLength: 120,
                        buildCounter: localCounter,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: InputDecoration(
                            labelText: t.crrJobsQuery, prefixIcon: const Icon(Icons.search_rounded)),
                      ),
                      TextField(
                        controller: _loc,
                        maxLength: 60,
                        buildCounter: localCounter,
                        decoration: InputDecoration(
                            labelText: t.crrJobsLocation, prefixIcon: const Icon(Icons.place_outlined)),
                      ),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton.icon(
                            onPressed: _searching ? null : _search,
                            icon: const Icon(Icons.search_rounded),
                            label: Text(t.crrJobsSearch)),
                        OutlinedButton.icon(
                            onPressed: _saveSearch,
                            icon: const Icon(Icons.bookmark_add_outlined),
                            label: Text(t.crrJobsSaveSearch)),
                      ]),
                      if (_status['careerjet_ready'] != true) ...[
                        const SizedBox(height: 12),
                        _note(context, Icons.info_outline_rounded, t.crrCareerjetOff),
                      ],
                      if (_searches.isNotEmpty) ...[
                        _header(context, t.crrJobsSavedSearches),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final s in _searches)
                            InputChip(
                              label: Text([s['q'], s['loc']]
                                  .where((x) => '${x ?? ''}'.isNotEmpty)
                                  .join(' · ')),
                              onPressed: () {
                                _q.text = '${s['q'] ?? ''}';
                                _loc.text = '${s['loc'] ?? ''}';
                                _search();
                              },
                              deleteButtonTooltipMessage: t.crrJobsDeleteSearch,
                              onDeleted: () => _deleteSearch(s),
                            ),
                        ]),
                      ],
                      if (_searching) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
                      if (_results != null) ..._resultsView(context, scheme),
                      _header(context, t.crrCompanies),
                      if (_sources.isEmpty)
                        _note(context, Icons.business_rounded, t.crrCompaniesEmpty)
                      else
                        for (final s in _sources)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(s['kind'] == 'link' ? Icons.link_rounded : Icons.rss_feed_rounded),
                            title: Text('${s['label'] ?? s['value'] ?? ''}'),
                            subtitle: Text(s['kind'] == 'link'
                                ? t.crrCompanyLinkOnly
                                : _kindLabel('${s['kind']}')),
                            onTap: s['kind'] == 'link' ? () => _open('${s['value']}') : null,
                            trailing: IconButton(
                                tooltip: t.crrCompanyRemove,
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () => _removeSource(s)),
                          ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: OutlinedButton.icon(
                            onPressed: _addSource,
                            icon: const Icon(Icons.add_business_rounded),
                            label: Text(t.crrCompanyAdd)),
                      ),
                      _header(context, t.crrPortals),
                      if ('${_status['feeds_note'] ?? ''}'.isNotEmpty)
                        Text('${_status['feeds_note']}', style: Theme.of(context).textTheme.bodySmall),
                      for (final p in (_status['portals'] as List? ?? const []).whereType<Map>())
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(p['cat'] == 'govt' ? Icons.account_balance_rounded : Icons.work_outline_rounded),
                          title: Text('${p['name'] ?? ''}'),
                          subtitle: Text(p['feed'] == true ? '${p['desc'] ?? ''}' : '${p['desc'] ?? ''}\n${t.crrLinkOnly}'),
                          isThreeLine: p['feed'] != true,
                          trailing: const Icon(Icons.open_in_new_rounded),
                          onTap: () => _open('${p['url']}'),
                        ),
                      if ('${_status['safety'] ?? ''}'.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _note(context, Icons.shield_outlined, '${_status['safety']}'),
                      ],
                    ],
                  ),
                ),
    );
  }

  List<Widget> _resultsView(BuildContext context, ColorScheme scheme) {
    final res = _results!;
    return [
      _header(context, t.crrJobsResultsCount(ld(context, res.length))),
      for (final r in _report)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Icon(r['ok'] == true ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                size: 20, color: r['ok'] == true ? AssistoTokens.of(context).success : scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${r['label'] ?? ''}: ${r['ok'] == true ? t.crrSrcOk(ld(context, r['count'] ?? 0)) : r['error'] == 'not_connected' ? t.crrSrcNotConnected : t.crrSrcFailed}'),
            ),
          ]),
        ),
      if (res.isEmpty) _note(context, Icons.search_off_rounded, t.crrJobsNoResults),
      for (final j in res)
        Card(
          margin: const EdgeInsets.only(top: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${j['title'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
              if ('${j['company'] ?? ''}'.isNotEmpty || '${j['location'] ?? ''}'.isNotEmpty)
                Text([j['company'], j['location']].where((x) => '${x ?? ''}'.isNotEmpty).join(' · ')),
              const SizedBox(height: 4),
              Text(t.crrJobsSourceLabel('${j['source'] ?? ''}'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.primary)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonalIcon(
                    onPressed: () => _track(j),
                    icon: const Icon(Icons.playlist_add_rounded),
                    label: Text(t.crrJobsTrack)),
                OutlinedButton.icon(
                    onPressed: () => _open('${j['url'] ?? ''}'),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(t.crrJobsOpen)),
              ]),
            ]),
          ),
        ),
    ];
  }

  Widget _header(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(s, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _note(BuildContext context, IconData icon, String s) => Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon),
            const SizedBox(width: 10),
            Expanded(child: Text(s)),
          ]),
        ),
      );
}

class _AddSourceSheet extends StatefulWidget {
  const _AddSourceSheet();

  @override
  State<_AddSourceSheet> createState() => _AddSourceSheetState();
}

class _AddSourceSheetState extends State<_AddSourceSheet> {
  String _kind = 'greenhouse';
  final _value = TextEditingController();
  final _label = TextEditingController();
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _value.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final r = await context.read<AppState>().api.postJsonRaw('/career/jobs/sources/test', {
        'kind': _kind,
        'value': _value.text.trim(),
        'label': _label.text.trim(),
      });
      if (!mounted) return;
      _ok = r['ok'] == true;
      _result = r['link_only'] == true
          ? t.crrCompanyLinkOnly
          : _ok
              ? t.crrCompanyTestOk(ld(context, r['count'] ?? 0))
              : '${r['detail'] ?? t.crrCompanyTestFail}';
    } catch (e) {
      _ok = false;
      if (mounted) _result = honestFailText(t, e);
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final hint = switch (_kind) {
      'greenhouse' => t.crrCompanyValueGh,
      'lever' => t.crrCompanyValueLever,
      _ => t.crrCompanyValueUrl,
    };
    return AppSheetBody(
      primary: FilledButton(
        onPressed: _ok
            ? () => Navigator.pop(context, {
                  'kind': _kind,
                  'value': _value.text.trim(),
                  'label': _label.text.trim().isEmpty ? _value.text.trim() : _label.text.trim(),
                })
            : null,
        child: Text(t.save),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t.crrCompanyAdd, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(t.crrCompanyKind, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final k in _kinds)
              ChoiceChip(
                label: Text(switch (k) {
                  'greenhouse' => t.crrKindGreenhouse,
                  'lever' => t.crrKindLever,
                  'rss' => t.crrKindRss,
                  _ => t.crrKindLink,
                }),
                selected: _kind == k,
                onSelected: (_) => setState(() {
                  _kind = k;
                  _ok = false;
                  _result = null;
                }),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            maxLength: 500,
            buildCounter: localCounter,
            keyboardType: _kind == 'rss' || _kind == 'link' ? TextInputType.url : TextInputType.text,
            onChanged: (_) => setState(() => _ok = false),
            decoration: InputDecoration(labelText: hint),
          ),
          TextField(
            controller: _label,
            maxLength: 80,
            buildCounter: localCounter,
            decoration: InputDecoration(labelText: t.crrCompanyLabel),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
                onPressed: _testing || _value.text.trim().isEmpty ? null : _test,
                icon: const Icon(Icons.wifi_tethering_rounded),
                label: Text(t.crrCompanyTest)),
          ),
          if (_testing) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_result!,
                  style: TextStyle(color: _ok ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
