// cctvact (CCTV GUARD V3 E, F, G + D automations) — the shop's "manager"
// screens, Bangla first:
//   CctvActHubScreen        one entry from the site card
//   CctvClosingReportScreen the day at closing (people counted with no
//                           identity, peak hours, empty counter, events,
//                           vehicles, DVR health, tables) + settings
//   CctvAskScreen           "who went to the cash between 2 and 3 pm" ->
//                           answer + clips (no face recognition)
//   CctvSalesMatchScreen    review-only cash clips + link a POS (signed
//                           webhook key shown once) + CSV import
//   CctvAutomationsScreen   Smart Life lights / plugs / sirens; locks only
//                           after the owner's Yes
// Empty states = benefit line + big button + how-to. No dead buttons.
import 'package:flutter/material.dart';
import '../../widgets/skeleton.dart';
import '../../ds/ds.dart';
import '../../theme.dart' show AType;
import 'package:flutter/services.dart';

import '../../cctvact/cctvact_source.dart';
import '../../cctvx/cctvx_source.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/local_counter.dart';
import 'cctv_act_tiles.dart' show cv3AutoStateLabel; // gap-cctv
import 'cctvx_actions.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

// ======================================================================= hub
class CctvActHubScreen extends StatelessWidget {
  final CctvActSource source;
  final int siteId;
  final String siteName;
  final bool owner;

  /// Opens an alert's clip + actions from a result (null in tests).
  final CctvxSource? events;
  const CctvActHubScreen(
      {super.key,
      required this.source,
      required this.siteId,
      required this.siteName,
      required this.owner,
      this.events});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    void go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    Widget tile(Key key, IconData icon, String title, String sub, VoidCallback onTap) => Padding(key: key, padding: const EdgeInsets.only(bottom: 10), child: DsCard(
        padding: EdgeInsets.zero,
        child: ListTile(
            minTileHeight: 64,
            leading: Icon(icon, size: 28),
            title: Text(title),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: onTap,
          ),
      ));
    return Scaffold(
      appBar: AppBar(title: Text(t.cv3HubTitle)),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(siteName, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(t.cv3HubIntro, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          tile(const ValueKey('cv3-hub-report'), Icons.summarize_rounded, t.cv3ReportTitle,
              t.cv3ReportSub,
              () => go(CctvClosingReportScreen(source: source, siteId: siteId, owner: owner))),
          tile(const ValueKey('cv3-hub-ask'), Icons.manage_search_rounded, t.cv3AskTitle,
              t.cv3AskSub, () => go(CctvAskScreen(source: source, siteId: siteId, events: events))),
          if (owner) ...[
            tile(const ValueKey('cv3-hub-sales'), Icons.point_of_sale_rounded, t.cv3SalesTitle,
                t.cv3SalesSub,
                () => go(CctvSalesMatchScreen(source: source, siteId: siteId, events: events))),
            tile(const ValueKey('cv3-hub-auto'), Icons.lightbulb_outline_rounded, t.cv3AutoTitle,
                t.cv3AutoSub, () => go(CctvAutomationsScreen(source: source, siteId: siteId))),
          ],
          const SizedBox(height: 8),
          Text(t.cv3Privacy, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------ shared bits
Widget _loadingOr(BuildContext context, bool loading, String? error, VoidCallback retry,
    Widget Function() body) {
  final t = AppLocalizations.of(context);
  if (loading) return const SkeletonList();
  if (error != null) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(error.isEmpty ? t.wmLoadErrorBody : error, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
              onPressed: retry,
              child: Text(t.wmRetry)),
        ]),
      ),
    );
  }
  return body();
}

void _say(BuildContext context, String s) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

String _hm(String lang, int? m) {
  if (m == null) return '';
  final h = (m ~/ 60) % 24, mi = m % 60;
  return wmDigits(lang, '${h.toString().padLeft(2, '0')}:${mi.toString().padLeft(2, '0')}');
}

/// One result row (time, camera, what) that opens the alert sheet (clip,
/// evidence, actions) when an events source is there.
Widget _eventRow(BuildContext context, Map<String, dynamic> r, CctvxSource? events,
    {String? text}) {
  final t = AppLocalizations.of(context);
  final lang = wmLang(context);
  final id = (r['event_id'] as num?)?.toInt();
  final line = text ??
      [
        wmDigits(lang, r['hhmm'] ?? r['time'] ?? ''),
        (r['camera_name'] ?? r['camera'] ?? '').toString(),
        (r['what'] ?? '').toString(),
      ].where((x) => x.isNotEmpty).join(' · ');
  return Padding(padding: const EdgeInsets.only(bottom: 8), child: DsCard(
      padding: EdgeInsets.zero,
      child: ListTile(
      minTileHeight: 56,
      leading: Icon(r['has_clip'] == true ? Icons.play_circle_outline_rounded : Icons.photo_outlined),
      title: Text(line),
      subtitle: Text(r['has_clip'] == true ? t.cv3HasClip : t.cv3PhotoOnly),
      onTap: (id == null || events == null) ? null : () => AlertActionsSheet.show(context, events, id),
    ),
    ));
}

// ======================================================================= E
class CctvClosingReportScreen extends StatefulWidget {
  final CctvActSource source;
  final int siteId;
  final bool owner;
  final Map<String, dynamic>? preview;
  const CctvClosingReportScreen(
      {super.key, required this.source, required this.siteId, required this.owner, this.preview});

  @override
  State<CctvClosingReportScreen> createState() => _ClosingState();
}

class _ClosingState extends State<CctvClosingReportScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _error;
  int _daysBack = 0; // gap-cctv: 0 = today, 1 = yesterday

  /// The day asked for, as YYYY-MM-DD in the phone's local date (null = today).
  String? _dayArg() {
    if (_daysBack == 0) return null;
    final d = DateTime.now().subtract(Duration(days: _daysBack));
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _d = widget.preview;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _d = await widget.source.closingReport(widget.siteId, date: _dayArg());
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _cfg(Map<String, dynamic> body) async {
    try {
      final c = await widget.source.saveReportCfg(widget.siteId, body);
      if (mounted) setState(() => _d = {...?_d, 'cfg': c});
    } catch (e) {
      if (mounted) _say(context, wmError(e) ?? AppLocalizations.of(context).wmGenericError);
    }
  }

  String _useLabel(AppLocalizations t, String u) => switch (u) {
        'cafe' => t.cv3UseCafe,
        'parking' => t.cv3UseParking,
        'office' => t.cv3UseOffice,
        'warehouse' => t.cv3UseWarehouse,
        'home' => t.cv3UseHome,
        'gate' => t.cv3UseGate,
        _ => t.cv3UseShop,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.cv3ReportTitle)),
      body: SafeArea(
        child: _loadingOr(context, _loading, _error, _load, () {
          final d = _d!;
          final lines = (d['lines'] as List? ?? const []).map((e) => e.toString()).toList();
          final s = wmMap(d['sections']);
          final people = wmMap(s['people']);
          final hourly = (people['hourly'] as List? ?? const []).map((e) => (e as num).toInt()).toList();
          final measured = wmMap(d['measured']);
          final cfg = wmMap(d['cfg']);
          final ok = d['all_ok'] == true;
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              // gap-cctv: yesterday's closing report too (the server keeps the date)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SegmentedButton<int>(
                  key: const ValueKey('gcv-report-day'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: 0, label: Text(t.gcvReportToday)),
                    ButtonSegment(value: 1, label: Text(t.gcvReportYesterday)),
                  ],
                  selected: {_daysBack},
                  onSelectionChanged: (v) {
                    setState(() => _daysBack = v.first);
                    if (widget.preview == null) _load();
                  },
                ),
              ),
              DsSurface(color: ok
                    ? Theme.of(context).colorScheme.ds.primarySoft
                    : Theme.of(context).colorScheme.ds.cardHighest,
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text((d['title'] ?? '').toString(),
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('•  '),
                          Expanded(child: Text(l)),
                        ]),
                      ),
                  ]),
              ),
              if (hourly.any((v) => v > 0)) ...[
                const SizedBox(height: 12),
                Text(t.cv3ReportHourly, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                _HourBars(values: hourly, lang: lang),
              ],
              const SizedBox(height: 12),
              if (measured['counter'] != true || measured['vehicles'] != true || measured['tables'] != true)
                Text(t.cv3ReportNotMeasured, style: Theme.of(context).textTheme.bodySmall),
              if (widget.owner) ...[
                const Divider(height: 32),
                Text(t.cv3ReportPlace, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final u in (cfg['uses'] as List? ?? const ['shop']).map((e) => e.toString()))
                    ChoiceChip(
                      key: ValueKey('cv3-use-$u'),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      label: Text(_useLabel(t, u)),
                      selected: cfg['use'] == u,
                      onSelected: (_) => _cfg({'use': u}).then((_) => _load()),
                    ),
                ]),
                SwitchListTile(
                  key: const ValueKey('cv3-report-push'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.cv3ReportPush),
                  subtitle: Text(t.cv3ReportPushSub),
                  value: cfg['push'] != false,
                  onChanged: (v) => _cfg({'push': v}),
                ),
              ],
              const SizedBox(height: 8),
              Text((d['privacy'] ?? '').toString(), style: Theme.of(context).textTheme.bodySmall),
            ]),
          );
        }),
      ),
    );
  }
}

class _HourBars extends StatelessWidget {
  final List<int> values;
  final String lang;
  const _HourBars({required this.values, required this.lang});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    final max = values.fold<int>(1, (m, v) => v > m ? v : m);
    final scheme = Theme.of(context).colorScheme;
    for (var h = 0; h < values.length; h++) {
      if (values[h] == 0) continue;
      rows.add(Semantics(
        label: '${wmDigits(lang, '$h:00')} — ${wmDigits(lang, values[h])}',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            SizedBox(width: 56, child: Text(wmDigits(lang, '${h.toString().padLeft(2, '0')}:00'))),
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, c) => Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 14,
                    width: c.maxWidth * values[h] / max,
                    decoration: BoxDecoration(
                        color: scheme.primary, borderRadius: BorderRadius.circular(4)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 40, child: Text(wmDigits(lang, values[h]), textAlign: TextAlign.end)),
          ]),
        ),
      ));
    }
    return Column(children: rows);
  }
}

// ======================================================================= G
class CctvAskScreen extends StatefulWidget {
  final CctvActSource source;
  final int siteId;
  final CctvxSource? events;
  final Map<String, dynamic>? preview;
  const CctvAskScreen(
      {super.key, required this.source, required this.siteId, this.events, this.preview});

  @override
  State<CctvAskScreen> createState() => _AskState();
}

class _AskState extends State<CctvAskScreen> {
  final _q = TextEditingController();
  Map<String, dynamic>? _a;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _a = widget.preview;
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _ask([String? text]) async {
    final q = (text ?? _q.text).trim();
    if (q.isEmpty) return;
    if (text != null) _q.text = text;
    final fallback = AppLocalizations.of(context).wmGenericError;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _a = await widget.source.ask(widget.siteId, q);
    } catch (e) {
      _error = wmError(e) ?? fallback;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final a = _a;
    final examples = [t.cv3AskEx1, t.cv3AskEx2, t.cv3AskEx3];
    return Scaffold(
      appBar: AppBar(title: Text(t.cv3AskTitle)),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            key: const ValueKey('cv3-ask-field'),
            controller: _q,
            maxLength: 200,
            buildCounter: localCounter,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _ask(),
            decoration: InputDecoration(
              labelText: t.cv3AskHint,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: t.cv3AskGo,
                icon: const Icon(Icons.search_rounded),
                onPressed: _busy ? null : _ask,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (a == null && !_busy) ...[
            Text(t.cv3AskEmpty, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            for (final ex in examples)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48), alignment: Alignment.centerLeft),
                  onPressed: () => _ask(ex),
                  child: Text(ex),
                ),
              ),
          ],
          if (_busy) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (_error != null) Text(_error!, style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.error)),
          if (a != null && !_busy) ...[
            DsCard(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final l in (a['answer'] as List? ?? const []))
                    Padding(
                        padding: const EdgeInsets.only(bottom: 6), child: Text(l.toString())),
                  if (wmMap(a['filter'])['from_min'] != null)
                    Text(
                        t.cv3AskRange(_hm(lang, (wmMap(a['filter'])['from_min'] as num).toInt()),
                            _hm(lang, (wmMap(a['filter'])['to_min'] as num?)?.toInt())),
                        style: Theme.of(context).textTheme.bodySmall),
                ]),
            ),
            const SizedBox(height: 8),
            for (final r in wmList(a['results'])) _eventRow(context, r, widget.events),
            if ((a['total'] as num? ?? 0) > wmList(a['results']).length)
              Text(t.cv3AskMore(wmDigits(lang, a['total'])), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text((a['privacy'] ?? '').toString(), style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
      ),
    );
  }
}

// ======================================================================= F
class CctvSalesMatchScreen extends StatefulWidget {
  final CctvActSource source;
  final int siteId;
  final CctvxSource? events;
  final Map<String, dynamic>? preview;
  final Map<String, dynamic>? previewKey;
  const CctvSalesMatchScreen(
      {super.key,
      required this.source,
      required this.siteId,
      this.events,
      this.preview,
      this.previewKey});

  @override
  State<CctvSalesMatchScreen> createState() => _SalesState();
}

class _SalesState extends State<CctvSalesMatchScreen> {
  Map<String, dynamic>? _d;
  Map<String, dynamic>? _key;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _d = widget.preview;
      _key = widget.previewKey ?? const {'has_key': false};
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _d = await widget.source.salesMatch(widget.siteId);
      _key = await widget.source.posKey(widget.siteId);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _linkPos() async {
    final t = AppLocalizations.of(context);
    final partner = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(title: Text(t.cv3PosWhich), children: [
        SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'asalify'),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(t.cv3PosAsalify))),
        SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'pos'),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(t.cv3PosOther))),
      ]),
    );
    if (partner == null) return;
    try {
      final k = await widget.source.createPosKey(widget.siteId, partner);
      if (!mounted) return;
      setState(() => _key = k);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(t.cv3PosKeyTitle),
          content: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(t.cv3PosKeyOnce),
            const SizedBox(height: 12),
            // gap-cctv: labels in the user's language (the values stay as-is)
            SelectableText('${t.gcvPosUrl}: ${k['url'] ?? ''}'),
            SelectableText('${t.gcvPosKeyId}: ${k['key_id'] ?? ''}'),
            SelectableText('${t.gcvPosSecret}: ${k['secret'] ?? ''}'),
            const SizedBox(height: 8),
            Text((k['note'] ?? '').toString(), style: Theme.of(ctx).textTheme.bodySmall),
          ]),
          actions: [
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(
                        text: 'URL: ${k['url']}\nKey ID: ${k['key_id']}\nSecret: ${k['secret']}'))
                    .then((_) {
                  if (mounted) _say(context, t.cv3Copied);
                }, onError: (Object _) {
                  // best-effort: no clipboard on this phone; the key was shown selectable
                });
              },
              child: Text(t.cv3Copy),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _say(context, wmError(e) ?? t.wmGenericError);
    }
  }

  Future<void> _revoke() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cv3PosRevokeTitle),
        content: Text(t.cv3PosRevokeBody),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cxCancel)),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.cv3PosRevoke)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final k = await widget.source.revokePosKey(widget.siteId);
      if (mounted) setState(() => _key = k);
    } catch (e) {
      if (mounted) _say(context, wmError(e) ?? t.wmGenericError);
    }
  }

  Future<void> _csv() async {
    final t = AppLocalizations.of(context);
    // dialog-local controller: not disposed here — the dialog route is still
    // animating out when showDialog returns (disposing it then throws)
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.cv3CsvTitle),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cv3CsvHow, style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('cv3-csv-field'),
            controller: c,
            minLines: 4,
            maxLines: 8,
            maxLength: 100000,
            buildCounter: localCounter,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), hintText: 'time,type,amount,id'),
          ),
        ]),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.cxCancel)),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, c.text),
              child: Text(t.cv3CsvImport)),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      final r = await widget.source.importCsv(widget.siteId, text);
      if (!mounted) return;
      final lang = wmLang(context);
      _say(context, t.cv3CsvDone(wmDigits(lang, r['accepted'] ?? 0),
          wmDigits(lang, r['duplicates'] ?? 0), wmDigits(lang, r['error_count'] ?? 0)));
      await _load();
    } catch (e) {
      if (mounted) _say(context, wmError(e) ?? t.wmGenericError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.cv3SalesTitle)),
      body: SafeArea(
        child: _loadingOr(context, _loading, _error, _load, () {
          final d = _d ?? const {};
          final items = wmList(d['items']);
          final k = _key ?? const {};
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text((d['note'] ?? t.cv3SalesNote).toString(),
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              if (items.isEmpty)
                DsCard(
                  padding: const EdgeInsets.all(16),
                  child: Text(t.cv3SalesNone),
                )
              else
                for (final it in items)
                  _eventRow(context, {...it, 'event_id': it['event_id']}, widget.events,
                      text: (it['text'] ?? '').toString()),
              const Divider(height: 32),
              Text(t.cv3PosTitle, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(k['has_key'] == true
                  ? t.gcvPlPosLinked((k['events'] as num?)?.toInt() ?? 0,
                      (k['partner'] == 'asalify' ? t.cv3PosAsalify : t.cv3PosOther),
                      wmDigits(lang, k['events'] ?? 0))
                  : t.cv3PosBenefit),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('cv3-pos-link'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                icon: const Icon(Icons.link_rounded),
                label: Text(k['has_key'] == true ? t.cv3PosRotate : t.cv3PosLink),
                onPressed: _linkPos,
              ),
              if (k['has_key'] == true)
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _revoke,
                  child: Text(t.cv3PosRevoke),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('cv3-csv'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                icon: const Icon(Icons.upload_file_rounded),
                label: Text(t.cv3CsvTitle),
                onPressed: _csv,
              ),
              const SizedBox(height: 8),
              Text(t.cv3PosNever, style: Theme.of(context).textTheme.bodySmall),
            ]),
          );
        }),
      ),
    );
  }
}

// ======================================================================= D
class CctvAutomationsScreen extends StatefulWidget {
  final CctvActSource source;
  final int siteId;
  final Map<String, dynamic>? preview;
  const CctvAutomationsScreen({super.key, required this.source, required this.siteId, this.preview});

  @override
  State<CctvAutomationsScreen> createState() => _AutoState();
}

class _AutoState extends State<CctvAutomationsScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _d = widget.preview;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _d = await widget.source.automations(widget.siteId, refresh: refresh);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _rules => wmList(_d?['rules']);

  Map<String, dynamic> _rule(String trigger) => _rules.firstWhere((r) => r['trigger'] == trigger,
      orElse: () => {
            'trigger': trigger,
            'on': true,
            'window': trigger == 'night_intrusion'
                ? {'start': '22:00', 'end': '06:00'}
                : {'start': '00:00', 'end': '23:59'},
            'actions': <Map<String, dynamic>>[],
            'warn': false,
            'siren_box': false,
          });

  Future<void> _save(Map<String, dynamic> rule) async {
    final rules = [
      for (final r in _rules)
        if (r['trigger'] != rule['trigger']) r,
      rule,
    ];
    try {
      final d = await widget.source.saveRules(widget.siteId, rules);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) _say(context, wmError(e) ?? AppLocalizations.of(context).wmGenericError);
    }
  }

  void _toggleDevice(String trigger, Map<String, dynamic> dev, bool on) {
    final r = Map<String, dynamic>.from(_rule(trigger));
    final acts = wmList(r['actions']).where((a) => a['device_id'] != dev['id']).toList();
    if (on) acts.add({'device_id': dev['id'], 'seconds': 120});
    r['actions'] = acts;
    _save(r);
  }

  Future<void> _link() async {
    final t = AppLocalizations.of(context);
    final uid = TextEditingController();
    final aid = TextEditingController();
    final sec = TextEditingController();
    var own = _d?['service_on'] != true;
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text(t.cv3LinkTitle),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.cv3LinkHow, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('cv3-link-uid'),
              controller: uid,
              maxLength: 40,
              buildCounter: localCounter,
              decoration: InputDecoration(labelText: t.cv3LinkUid, border: const OutlineInputBorder()),
            ),
            if (_d?['service_on'] == true)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.cv3LinkOwn),
                value: own,
                onChanged: (v) => setD(() => own = v),
              ),
            if (own) ...[
              TextField(
                controller: aid,
                maxLength: 64,
                buildCounter: localCounter,
                decoration: InputDecoration(labelText: t.gcvTuyaAccessId, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: sec,
                maxLength: 64,
                buildCounter: localCounter,
                obscureText: true,
                decoration: InputDecoration(labelText: t.gcvTuyaAccessSecret, border: const OutlineInputBorder()),
              ),
            ],
          ]),
          actions: [
            TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.cxCancel)),
            FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                onPressed: () => Navigator.pop(ctx, {
                      'mode': own ? 'own' : 'assisto',
                      'uid': uid.text.trim(),
                      if (own) 'access_id': aid.text.trim(),
                      if (own) 'access_secret': sec.text.trim(),
                    }),
                child: Text(t.cv3LinkGo)),
          ],
        ),
      ),
    );
    if (body == null) return;
    try {
      final d = await widget.source.link(widget.siteId, body);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) _say(context, wmError(e) ?? t.wmGenericError);
    }
  }

  Future<void> _test(Map<String, dynamic> dev) async {
    final t = AppLocalizations.of(context);
    try {
      await widget.source.testDevice(widget.siteId, dev['id'].toString());
      if (mounted) _say(context, t.cv3TestOn((dev['name'] ?? '').toString()));
    } catch (e) {
      if (mounted) _say(context, wmError(e) ?? t.wmGenericError);
    }
  }

  String _kind(AppLocalizations t, String k) => switch (k) {
        'light' => t.cv3KindLight,
        'plug' || 'switch' => t.cv3KindPlug,
        'siren' => t.cv3KindSiren,
        'lock' => t.cv3KindLock,
        _ => k,
      };

  Widget _ruleCard(AppLocalizations t, String trigger, String title, String sub) {
    final r = _rule(trigger);
    final devs = wmList(_d?['devices']);
    final chosen = {for (final a in wmList(r['actions'])) a['device_id']};
    return Padding(key: ValueKey('cv3-rule-$trigger'), padding: const EdgeInsets.only(bottom: 12), child: DsCard(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(title),
            subtitle: Text(sub),
            value: r['on'] != false && (chosen.isNotEmpty || r['warn'] == true || r['siren_box'] == true),
            onChanged: (v) => _save({...r, 'on': v}),
          ),
          for (final d in devs)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: chosen.contains(d['id']),
              title: Text((d['name'] ?? '').toString()),
              subtitle: Text(d['kind'] == 'lock' ? t.cv3LockAsk : _kind(t, (d['kind'] ?? '').toString())),
              onChanged: (v) => _toggleDevice(trigger, d, v == true),
            ),
          if (_d?['play_targets'] != null && (_d!['play_targets'] as num) > 0) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: r['warn'] == true,
              title: Text(t.cv3RuleWarn),
              subtitle: Text(_d?['has_warn'] == true ? t.cv3RuleWarnSub : t.cv3RuleWarnNeedClip),
              onChanged: _d?['has_warn'] == true ? (v) => _save({...r, 'warn': v == true}) : null,
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: r['siren_box'] == true,
              title: Text(t.cv3RuleBoxSiren),
              onChanged: (v) => _save({...r, 'siren_box': v == true}),
            ),
          ],
        ]),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.cv3AutoTitle)),
      body: SafeArea(
        child: _loadingOr(context, _loading, _error, _load, () {
          final d = _d ?? const {};
          if (d['linked'] != true) {
            return ListView(padding: const EdgeInsets.all(24), children: [
              const Icon(Icons.lightbulb_circle_outlined, size: 72),
              const SizedBox(height: 12),
              Text(t.cv3AutoEmptyTitle, textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(t.cv3AutoEmptyBody, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('cv3-auto-link'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: const Icon(Icons.link_rounded),
                label: Text(t.cv3LinkTitle),
                onPressed: _link,
              ),
              const SizedBox(height: 12),
              Text(t.cv3AutoHow, style: Theme.of(context).textTheme.bodySmall),
            ]);
          }
          final devs = wmList(d['devices']);
          final logs = wmList(d['log']);
          return RefreshIndicator(
            onRefresh: () => _load(refresh: true),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text(t.gcvPlAutoLinked(devs.length, wmDigits(lang, devs.length)),
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text((d['lock_note'] ?? '').toString(), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              _ruleCard(t, 'night_intrusion', t.cv3RuleNight, t.cv3RuleNightSub),
              _ruleCard(t, 'fire_smoke', t.cv3RuleFire, t.cv3RuleFireSub),
              Text(t.cv3Devices, style: Theme.of(context).textTheme.titleSmall),
              for (final dv in devs)
                ListTile(
                  minTileHeight: 56,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(dv['online'] == true ? Icons.wifi_rounded : Icons.wifi_off_rounded),
                  title: Text((dv['name'] ?? '').toString()),
                  subtitle: Text(_kind(t, (dv['kind'] ?? '').toString())),
                  trailing: dv['kind'] == 'lock'
                      ? null
                      : TextButton(
                          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                          onPressed: () => _test(dv),
                          child: Text(t.cv3Test)),
                ),
              if (logs.isNotEmpty) ...[
                const Divider(height: 24),
                Text(t.cv3AutoLog, style: Theme.of(context).textTheme.titleSmall),
                for (final l in logs.take(5))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    // gap-cctv: local time + plain state words (was raw ISO / 'on')
                    child: Text('${gcvLocalStamp(lang, (l['at'] ?? '').toString())} — '
                        '${wmList(l['ran']).map((x) => '${x['device']}: ${cv3AutoStateLabel(t, (x['state'] ?? '').toString())}').join(', ')}'),
                  ),
              ],
              const SizedBox(height: 12),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () async {
                  // gap-cctv: unlinking the smart plugs / lights asks first
                  final sure = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(t.gcvUnlinkAsk),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false), child: Text(t.wmCancel)),
                        FilledButton(
                            key: const ValueKey('gcv-unlink-yes'),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(t.cv3Unlink)),
                      ],
                    ),
                  );
                  if (sure != true) return;
                  try {
                    final x = await widget.source.unlink(widget.siteId);
                    if (mounted) setState(() => _d = x);
                  } catch (e) {
                    if (context.mounted) _say(context, wmError(e) ?? t.wmGenericError);
                  }
                },
                child: Text(t.cv3Unlink),
              ),
            ]),
          );
        }),
      ),
    );
  }
}

/// gap-cctv: a server ISO time as the phone's local "dd/MM HH:mm" in the
/// UI's digits; the raw text if it is not a time.
String gcvLocalStamp(String lang, String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return wmDigits(lang, iso);
  String two(int v) => v.toString().padLeft(2, '0');
  return wmDigits(lang, '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}');
}
