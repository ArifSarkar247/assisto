import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · CELEBRITY tier — PR & press tracker (#122, §14).
///
/// A media tracker for a public figure's PA: COVERAGE items (outlet, type, date,
/// sentiment, link), upcoming INTERVIEWS (outlet, topic, date/time, place) and
/// free TALKING-POINTS notes. Deterministic roll-ups (counts by type & sentiment,
/// net sentiment) + upcoming/past split. Nothing is fetched and no sentiment is
/// auto-detected — the PA types it; we never fabricate a quote, link or verdict.
///
/// Mirrors backend/core/logic/pa_pr.py. ZERO Bangla literals.
///
/// Endpoints: listItems('star/press') / createItem / updateItem / deleteItem.
/// Rows are tagged {kind: 'coverage' | 'interview' | 'talkingpoint'}.
class PrPressScreen extends StatefulWidget {
  const PrPressScreen({super.key});
  @override
  State<PrPressScreen> createState() => _PrPressScreenState();
}

// ---- constants (mirror pa_pr.py) ------------------------------------------
const String _kCoverage = 'coverage';
const String _kInterview = 'interview';
const String _kTalkingPoint = 'talkingpoint';

const List<String> _types = ['print', 'online', 'tv', 'radio', 'social'];
const List<String> _sentiments = ['positive', 'neutral', 'negative'];

class _PrPressScreenState extends State<PrPressScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _rows = await context.read<AppState>().api.listItems('star/press');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- mirror helpers ------------------------------------------------------
  String _kind(Map<String, dynamic> r) {
    final v = (r['kind'] ?? _kCoverage).toString();
    return [_kCoverage, _kInterview, _kTalkingPoint].contains(v) ? v : _kCoverage;
  }

  String _type(Map<String, dynamic> r) {
    final v = (r['type'] ?? '').toString().toLowerCase();
    return _types.contains(v) ? v : 'online';
  }

  String _sentiment(Map<String, dynamic> r) {
    final v = (r['sentiment'] ?? '').toString().toLowerCase();
    return _sentiments.contains(v) ? v : 'neutral';
  }

  DateTime? _parseDate(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    final t = s.trim();
    return DateTime.tryParse(t.endsWith('Z') ? t.substring(0, t.length - 1) : t);
  }

  List<Map<String, dynamic>> get _coverage =>
      _rows.where((r) => _kind(r) == _kCoverage).toList()
        ..sort((a, b) {
          final da = _parseDate(a['date']?.toString());
          final db = _parseDate(b['date']?.toString());
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da); // newest first
        });

  List<Map<String, dynamic>> get _interviews {
    final list = _rows.where((r) => _kind(r) == _kInterview).toList();
    list.sort((a, b) {
      final da = _parseDate(a['at']?.toString());
      final db = _parseDate(b['at']?.toString());
      final ka = da?.toIso8601String() ?? '9999';
      final kb = db?.toIso8601String() ?? '9999';
      return ka.compareTo(kb);
    });
    return list;
  }

  List<Map<String, dynamic>> get _talkingPoints =>
      _rows.where((r) => _kind(r) == _kTalkingPoint).toList();

  int _countType(String t) => _coverage.where((r) => _type(r) == t).length;
  int _countSent(String s) => _coverage.where((r) => _sentiment(r) == s).length;
  int get _netSentiment => _countSent('positive') - _countSent('negative');

  // ---- actions -------------------------------------------------------------
  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addOrEdit(AppLocalizations tr, String kind,
      {Map<String, dynamic>? existing}) async {
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _PressForm(kind: kind, existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context.read<AppState>().api.updateItem('star/press', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('star/press', result);
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final id = r['id'];
    try {
      if (id is int) await context.read<AppState>().api.deleteItem('star/press', id);
      await _load();
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  // ---- build ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.prPressTitle),
        bottom: TabBar(controller: _tabs, isScrollable: true, tabs: [
          Tab(text: tr.prPressTabCoverage),
          Tab(text: tr.prPressTabInterviews),
          Tab(text: tr.prPressTabTalkingPoints),
        ]),
      ),
      floatingActionButton: _loading || _error
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addOrEdit(
                  tr, [_kCoverage, _kInterview, _kTalkingPoint][_tabs.index]),
              icon: const Icon(Icons.add_rounded),
              label: Text(tr.prPressAdd),
            ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.prPressLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : TabBarView(controller: _tabs, children: [
                  _coverageTab(tr, scheme),
                  _interviewsTab(tr, scheme),
                  _talkingTab(tr, scheme),
                ]),
    );
  }

  // ---- coverage tab --------------------------------------------------------
  Widget _coverageTab(AppLocalizations tr, ColorScheme scheme) {
    final list = _coverage;
    if (list.isEmpty) {
      return StateMessage(
        icon: Icons.newspaper_rounded,
        title: tr.prPressWelcomeTitle,
        message: tr.prPressWelcomeBody,
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(tr, _kCoverage),
          icon: const Icon(Icons.add_rounded),
          label: Text(tr.prPressAdd),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          _rollupCard(tr, scheme),
          const SizedBox(height: Gap.md),
          for (final r in list) ...[
            _coverageCard(r, tr, scheme),
            const SizedBox(height: Gap.sm),
          ],
        ],
      ),
    );
  }

  Widget _rollupCard(AppLocalizations tr, ColorScheme scheme) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr.prPressRollup,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              _chip(tr.prPressSentPositive('${_countSent('positive')}'), Brand.success),
              _chip(tr.prPressSentNeutral('${_countSent('neutral')}'), scheme.onSurfaceVariant),
              _chip(tr.prPressSentNegative('${_countSent('negative')}'), scheme.error),
            ]),
            const SizedBox(height: Gap.sm),
            Text(
                _netSentiment >= 0
                    ? tr.prPressNetPositive('$_netSentiment')
                    : tr.prPressNetNegative('${-_netSentiment}'),
                style: AType.bodyMedium.copyWith(color: _netSentiment >= 0 ? Brand.success : scheme.error, fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final t in _types)
                if (_countType(t) > 0)
                  _chip('${_typeLabel(tr, t)} ${_countType(t)}', scheme.primary),
            ]),
          ]),
        ),
      );

  Widget _coverageCard(Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme) {
    final outlet = (r['outlet'] ?? '').toString();
    final link = (r['link'] ?? '').toString().trim();
    final date = (r['date'] ?? '').toString().trim();
    final note = (r['note'] ?? '').toString().trim();
    final sent = _sentiment(r);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(outlet,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            _dot(_sentColor(sent, scheme)),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            Text(_typeLabel(tr, _type(r)),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            if (date.isNotEmpty)
              Text('· $date',
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ]),
          if (link.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(link,
                style: AType.bodySmall.copyWith(color: scheme.primary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          if (note.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(note,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.3),
                maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: _rowMenu(r, tr, _kCoverage),
          ),
        ]),
      ),
    );
  }

  // ---- interviews tab ------------------------------------------------------
  Widget _interviewsTab(AppLocalizations tr, ColorScheme scheme) {
    final list = _interviews;
    if (list.isEmpty) {
      return StateMessage(
        icon: Icons.mic_none_rounded,
        title: tr.prPressNoInterviewsTitle,
        message: tr.prPressNoInterviewsBody,
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(tr, _kInterview),
          icon: const Icon(Icons.add_rounded),
          label: Text(tr.prPressAdd),
        ),
      );
    }
    final now = DateTime.now();
    final upcoming = list.where((r) {
      final at = _parseDate(r['at']?.toString());
      return at == null || !at.isBefore(now);
    }).toList();
    final past = list.where((r) {
      final at = _parseDate(r['at']?.toString());
      return at != null && at.isBefore(now);
    }).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          if (upcoming.isNotEmpty) ...[
            _sectionLabel(tr.prPressUpcoming('${upcoming.length}'), scheme),
            for (final r in upcoming) ...[
              _interviewCard(r, tr, scheme, false),
              const SizedBox(height: Gap.sm),
            ],
          ],
          if (past.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _sectionLabel(tr.prPressPast('${past.length}'), scheme),
            for (final r in past) ...[
              _interviewCard(r, tr, scheme, true),
              const SizedBox(height: Gap.sm),
            ],
          ],
        ],
      ),
    );
  }

  Widget _interviewCard(Map<String, dynamic> r, AppLocalizations tr,
      ColorScheme scheme, bool past) {
    final outlet = (r['outlet'] ?? '').toString();
    final topic = (r['topic'] ?? '').toString().trim();
    final at = (r['at'] ?? '').toString().trim();
    final place = (r['place'] ?? '').toString().trim();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(outlet,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700, color: past ? scheme.onSurfaceVariant : scheme.onSurface),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            _rowMenu(r, tr, _kInterview),
          ]),
          if (topic.isNotEmpty)
            Text(topic,
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            if (at.isNotEmpty)
              _iconText(Icons.schedule_rounded, at, scheme),
            if (place.isNotEmpty)
              _iconText(Icons.place_rounded, place, scheme),
          ]),
        ]),
      ),
    );
  }

  // ---- talking points tab --------------------------------------------------
  Widget _talkingTab(AppLocalizations tr, ColorScheme scheme) {
    final list = _talkingPoints;
    if (list.isEmpty) {
      return StateMessage(
        icon: Icons.sticky_note_2_rounded,
        title: tr.prPressNoPointsTitle,
        message: tr.prPressNoPointsBody,
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(tr, _kTalkingPoint),
          icon: const Icon(Icons.add_rounded),
          label: Text(tr.prPressAdd),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
        itemBuilder: (_, i) {
          final r = list[i];
          final topic = (r['topic'] ?? '').toString().trim();
          final text = (r['note'] ?? '').toString().trim();
          return Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(topic.isEmpty ? tr.prPressTabTalkingPoints : topic,
                        style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  _rowMenu(r, tr, _kTalkingPoint),
                ]),
                if (text.isNotEmpty)
                  Text(text,
                      style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
              ]),
            ),
          );
        },
      ),
    );
  }

  // ---- shared widgets ------------------------------------------------------
  Widget _rowMenu(Map<String, dynamic> r, AppLocalizations tr, String kind) =>
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (v) {
          if (v == 'edit') _addOrEdit(tr, kind, existing: r);
          if (v == 'delete') _delete(r, tr);
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', child: Text(tr.edit)),
          PopupMenuItem(value: 'delete', child: Text(tr.delete)),
        ],
      );

  Widget _sectionLabel(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm, top: Gap.xxs),
        child: Text(text,
            style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
      );

  Widget _iconText(IconData icon, String text, ColorScheme scheme) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(text, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]);

  Widget _chip(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style: AType.bodySmall.copyWith(color: c, fontWeight: FontWeight.w700)),
      );

  Widget _dot(Color c) =>
      Container(width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle));

  Color _sentColor(String s, ColorScheme scheme) {
    switch (s) {
      case 'positive':
        return Brand.success;
      case 'negative':
        return scheme.error;
      default:
        return scheme.onSurfaceVariant;
    }
  }

  String _typeLabel(AppLocalizations tr, String t) {
    switch (t) {
      case 'print':
        return tr.prPressTypePrint;
      case 'tv':
        return tr.prPressTypeTv;
      case 'radio':
        return tr.prPressTypeRadio;
      case 'social':
        return tr.prPressTypeSocial;
      default:
        return tr.prPressTypeOnline;
    }
  }
}

/// Add / edit a coverage item, interview, or talking-point note.
class _PressForm extends StatefulWidget {
  final String kind;
  final Map<String, dynamic>? existing;
  const _PressForm({required this.kind, this.existing});
  @override
  State<_PressForm> createState() => _PressFormState();
}

class _PressFormState extends State<_PressForm> {
  late final Map<String, TextEditingController> _c = {
    'outlet': TextEditingController(text: widget.existing?['outlet']?.toString() ?? ''),
    'date': TextEditingController(text: widget.existing?['date']?.toString() ?? ''),
    'link': TextEditingController(text: widget.existing?['link']?.toString() ?? ''),
    'topic': TextEditingController(text: widget.existing?['topic']?.toString() ?? ''),
    'at': TextEditingController(text: widget.existing?['at']?.toString() ?? ''),
    'place': TextEditingController(text: widget.existing?['place']?.toString() ?? ''),
    'note': TextEditingController(text: widget.existing?['note']?.toString() ?? ''),
  };
  late String _type = _types.contains((widget.existing?['type'] ?? '').toString())
      ? widget.existing!['type'].toString()
      : 'online';
  late String _sentiment =
      _sentiments.contains((widget.existing?['sentiment'] ?? '').toString())
          ? widget.existing!['sentiment'].toString()
          : 'neutral';

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _typeLabel(AppLocalizations tr, String t) {
    switch (t) {
      case 'print':
        return tr.prPressTypePrint;
      case 'tv':
        return tr.prPressTypeTv;
      case 'radio':
        return tr.prPressTypeRadio;
      case 'social':
        return tr.prPressTypeSocial;
      default:
        return tr.prPressTypeOnline;
    }
  }

  String _sentLabel(AppLocalizations tr, String s) {
    switch (s) {
      case 'positive':
        return tr.prPressSentimentPositive;
      case 'negative':
        return tr.prPressSentimentNegative;
      default:
        return tr.prPressSentimentNeutral;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final isCoverage = widget.kind == _kCoverage;
    final isInterview = widget.kind == _kInterview;
    final isPoint = widget.kind == _kTalkingPoint;
    final valid = isPoint
        ? _c['note']!.text.trim().isNotEmpty
        : _c['outlet']!.text.trim().isNotEmpty;

    String title() {
      if (widget.existing != null) return tr.prPressEdit;
      if (isCoverage) return tr.prPressAddCoverage;
      if (isInterview) return tr.prPressAddInterview;
      return tr.prPressAddPoint;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title(), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          if (isPoint) ...[
            TextField(
              controller: _c['topic'],
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                  labelText: tr.prPressTopicField, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['note'],
              maxLines: 5,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  labelText: tr.prPressPointField,
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true),
            ),
          ] else ...[
            TextField(
              controller: _c['outlet'],
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: tr.prPressOutletField, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            if (isCoverage) ...[
              Text(tr.prPressTypeLabel, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final t in _types)
                  ChoiceChip(
                    label: Text(_typeLabel(tr, t)),
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              Text(tr.prPressSentimentLabel, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final s in _sentiments)
                  ChoiceChip(
                    label: Text(_sentLabel(tr, s)),
                    selected: _sentiment == s,
                    onSelected: (_) => setState(() => _sentiment = s),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _c['date'],
                decoration: InputDecoration(
                    labelText: tr.prPressDateField,
                    hintText: 'YYYY-MM-DD',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _c['link'],
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                    labelText: tr.prPressLinkField, border: const OutlineInputBorder()),
              ),
            ] else ...[
              TextField(
                controller: _c['topic'],
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.prPressTopicField, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _c['at'],
                decoration: InputDecoration(
                    labelText: tr.prPressAtField,
                    hintText: 'YYYY-MM-DD HH:MM',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _c['place'],
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.prPressPlaceField, border: const OutlineInputBorder()),
              ),
            ],
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['note'],
              maxLines: 2,
              decoration: InputDecoration(
                  labelText: tr.prPressNoteField,
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true),
            ),
          ],
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.cancel),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(
                onPressed: valid ? () => Navigator.pop(context, _payload()) : null,
                child: Text(tr.save),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Map<String, dynamic> _payload() {
    final base = <String, dynamic>{'kind': widget.kind};
    if (widget.kind == _kCoverage) {
      base.addAll({
        'outlet': _c['outlet']!.text.trim(),
        'type': _type,
        'sentiment': _sentiment,
        'date': _c['date']!.text.trim(),
        'link': _c['link']!.text.trim(),
        'note': _c['note']!.text.trim(),
      });
    } else if (widget.kind == _kInterview) {
      base.addAll({
        'outlet': _c['outlet']!.text.trim(),
        'topic': _c['topic']!.text.trim(),
        'at': _c['at']!.text.trim(),
        'place': _c['place']!.text.trim(),
        'note': _c['note']!.text.trim(),
      });
    } else {
      base.addAll({
        'topic': _c['topic']!.text.trim(),
        'note': _c['note']!.text.trim(),
      });
    }
    return base;
  }
}
