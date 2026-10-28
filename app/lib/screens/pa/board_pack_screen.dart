import '../../feature_gates.dart' show kShowKeySeams;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · CORPORATE · Board-meeting pack — ADVANCED (#116, §14).
///
/// Assemble a board pack from its raw parts — AGENDA items, the DOCUMENTS
/// circulated, the ATTENDEE list (present / apology / absent) and the
/// RESOLUTIONS to vote — and get a deterministic, numbered, formatted pack
/// summary with a counted quorum/roll-up. The pack is editable, copy/share-able
/// and savable (a 'pa/board' row). Works fully offline with NO key.
///
/// Honest "AI-generated — review" marker (the STRUCTURE / numbering / counting is
/// generated, nothing is fabricated); a documented "connect an AI key for an
/// AI-written executive summary" seam (Anthropic) that never fakes prose. All
/// fixed scaffolding (section headings, Present/Apologies labels, roll-up
/// labels) is localised bn/en from the .arb — this file has ZERO Bangla
/// literals. Structure mirrors backend/core/logic/pa_board.py exactly so the
/// preview is identical offline.
///
/// Endpoints (generic api helpers, no api.dart edit):
///   listItems('pa/board')            → saved packs
///   createItem('pa/board', body)     → save
///   updateItem('pa/board', id, body) → re-save edits
///   deleteItem('pa/board', id)       → remove
class BoardPackScreen extends StatefulWidget {
  const BoardPackScreen({super.key});
  @override
  State<BoardPackScreen> createState() => _BoardPackScreenState();
}

// ---- constants (mirror pa_board.py) ---------------------------------------
const String _rTitle = 'title';
const String _rSection = 'section';
const String _rItem = 'item';
const String _rAttendee = 'attendee';
const String _rRollup = 'rollup';
const String _rNote = 'note';

const String _phPack = 'pack';
const String _phAgenda = 'agenda';
const String _phDocuments = 'documents';
const String _phAttendees = 'attendees';
const String _phResolutions = 'resolutions';
const String _phPresent = 'present';
const String _phApologies = 'apologies';
const String _phAbsent = 'absent';
const String _phQuorumMet = 'quorum_met';
const String _phQuorumShort = 'quorum_short';
const String _phTotalMinutes = 'total_minutes';
const String _phToVote = 'to_vote';
const String _phEmpty = 'empty';

const String _stPresent = 'present';
const String _stApology = 'apology';
const String _stAbsent = 'absent';
const List<String> _statuses = [_stPresent, _stApology, _stAbsent];

class _PackLine {
  final String role;
  final String text;
  final String phrase;
  final int num;
  const _PackLine(this.role, this.text, this.phrase, this.num);
}

String _clean(String? s) => (s ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

int _toInt(dynamic v) {
  if (v is int) return v < 0 ? 0 : v;
  final n = int.tryParse(_clean(v?.toString()));
  return (n == null || n < 0) ? 0 : n;
}

class _BoardPackScreenState extends State<BoardPackScreen> {
  List<Map<String, dynamic>> _saved = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
    try {
      _saved = await context.read<AppState>().api.listItems('pa/board');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open({Map<String, dynamic>? existing}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _PackEditor(existing: existing)),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.paBoardDeleteTitle),
        content: Text(tr.paBoardDeleteBody(_clean(r['title']?.toString()))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = r['id'];
    try {
      if (id is int) {
        await context.read<AppState>().api.deleteItem('pa/board', id);
      }
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(tr.deleteFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.paBoardTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.paBoardNew),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.paBoardLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : _saved.isEmpty
                  ? StateMessage(
                      icon: Icons.groups_2_rounded,
                      title: tr.paBoardWelcomeTitle,
                      message: tr.paBoardWelcomeBody,
                      action: FilledButton.icon(
                        onPressed: () => _open(),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(tr.paBoardNew),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                            Gap.md, Gap.md, Gap.md, 96),
                        itemCount: _saved.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: Gap.sm),
                        itemBuilder: (_, i) {
                          final r = _saved[i];
                          final agenda = (r['agenda'] as List?) ?? const [];
                          final res = (r['resolutions'] as List?) ?? const [];
                          final date = _clean(r['date']?.toString());
                          return Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                              leading: Icon(Icons.groups_2_rounded,
                                  color: scheme.primary),
                              title: Text(_clean(r['title']?.toString()),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  [
                                    if (date.isNotEmpty) date,
                                    tr.paBoardAgendaCount(agenda.length),
                                    tr.paBoardResCount(res.length),
                                  ].join(' · '),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              isThreeLine: false,
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'open') _open(existing: r);
                                  if (v == 'delete') _delete(r, tr);
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                      value: 'open',
                                      child: Text(tr.paBoardOpen)),
                                  PopupMenuItem(
                                      value: 'delete', child: Text(tr.delete)),
                                ],
                              ),
                              onTap: () => _open(existing: r),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

/// Editor: title/date + repeatable agenda / documents / attendees / resolutions,
/// a live preview assembled exactly like pa_board.build(), and a documented
/// AI-summary seam. Save writes a 'pa/board' row.
class _PackEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _PackEditor({this.existing});
  @override
  State<_PackEditor> createState() => _PackEditorState();
}

class _PackEditorState extends State<_PackEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?['title']?.toString() ?? '');
  late final TextEditingController _date =
      TextEditingController(text: widget.existing?['date']?.toString() ?? '');
  late final TextEditingController _quorum = TextEditingController(text: () {
    final q = widget.existing?['quorum'];
    return (q is int && q > 0) ? q.toString() : '';
  }());

  late List<Map<String, dynamic>> _agenda =
      _cloneList(widget.existing?['agenda']);
  late List<Map<String, dynamic>> _documents =
      _cloneList(widget.existing?['documents']);
  late List<Map<String, dynamic>> _attendees =
      _cloneList(widget.existing?['attendees']);
  late List<Map<String, dynamic>> _resolutions =
      _cloneList(widget.existing?['resolutions']);
  bool _saving = false;

  static List<Map<String, dynamic>> _cloneList(dynamic v) {
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return [];
  }

  @override
  void dispose() {
    _title.dispose();
    _date.dispose();
    _quorum.dispose();
    super.dispose();
  }

  // ---- deterministic mirror of pa_board.build() ---------------------------
  int _presentCount() => _attendees
      .where((a) =>
          _clean(a['name']?.toString()).isNotEmpty &&
          _normStatus(a['status']?.toString()) == _stPresent)
      .length;

  String _normStatus(String? v) {
    final s = _clean(v).toLowerCase();
    return _statuses.contains(s) ? s : _stPresent;
  }

  List<_PackLine> _assemble() {
    final title = _clean(_title.text);
    final date = _clean(_date.text);
    final quorum = _toInt(_quorum.text);
    final agenda = _agenda
        .where((r) => _clean(r['title']?.toString()).isNotEmpty)
        .toList();
    final docs = _documents
        .where((r) => _clean(r['title']?.toString()).isNotEmpty)
        .toList();
    final att = _attendees
        .where((r) => _clean(r['name']?.toString()).isNotEmpty)
        .toList();
    final res = _resolutions
        .where((r) => _clean(r['text']?.toString()).isNotEmpty)
        .toList();
    final lines = <_PackLine>[];

    if (title.isNotEmpty) {
      final cover = date.isNotEmpty ? '$title — $date' : title;
      lines.add(_PackLine(_rTitle, cover, _phPack, 0));
    }

    // agenda
    lines.add(const _PackLine(_rSection, '', _phAgenda, 0));
    if (agenda.isNotEmpty) {
      for (var i = 0; i < agenda.length; i++) {
        final r = agenda[i];
        var txt = _clean(r['title']?.toString());
        final presenter = _clean(r['presenter']?.toString());
        final minutes = _toInt(r['minutes']);
        if (presenter.isNotEmpty) txt += ' · $presenter';
        if (minutes > 0) txt += ' ($minutes)';
        lines.add(_PackLine(_rItem, txt, '', i + 1));
      }
    } else {
      lines.add(const _PackLine(_rNote, '', _phEmpty, 0));
    }

    // documents
    lines.add(const _PackLine(_rSection, '', _phDocuments, 0));
    if (docs.isNotEmpty) {
      for (var i = 0; i < docs.length; i++) {
        final r = docs[i];
        var txt = _clean(r['title']?.toString());
        final ref = _clean(r['ref']?.toString());
        if (ref.isNotEmpty) txt = '[$ref] $txt';
        lines.add(_PackLine(_rItem, txt, '', i + 1));
      }
    } else {
      lines.add(const _PackLine(_rNote, '', _phEmpty, 0));
    }

    // attendees + roll-up
    lines.add(const _PackLine(_rSection, '', _phAttendees, 0));
    if (att.isNotEmpty) {
      var present = 0, apology = 0, absent = 0;
      for (final r in att) {
        final name = _clean(r['name']?.toString());
        final role = _clean(r['role']?.toString());
        final st = _normStatus(r['status']?.toString());
        final stPhrase = st == _stPresent
            ? _phPresent
            : st == _stApology
                ? _phApologies
                : _phAbsent;
        if (st == _stPresent) {
          present++;
        } else if (st == _stApology) {
          apology++;
        } else {
          absent++;
        }
        final txt = role.isNotEmpty ? '$name — $role' : name;
        lines.add(_PackLine(_rAttendee, txt, stPhrase, 0));
      }
      lines.add(_PackLine(
          _rRollup, '$present/$apology/$absent', _phPresent, present));
      if (quorum > 0) {
        final met = present >= quorum;
        lines.add(_PackLine(_rRollup, '$present/$quorum',
            met ? _phQuorumMet : _phQuorumShort, quorum));
      }
    } else {
      lines.add(const _PackLine(_rNote, '', _phEmpty, 0));
    }

    // resolutions + to-vote roll-up
    lines.add(const _PackLine(_rSection, '', _phResolutions, 0));
    if (res.isNotEmpty) {
      for (var i = 0; i < res.length; i++) {
        final r = res[i];
        var txt = _clean(r['text']?.toString());
        final proposer = _clean(r['proposer']?.toString());
        final seconder = _clean(r['seconder']?.toString());
        final tail =
            [proposer, seconder].where((s) => s.isNotEmpty).join(' · ');
        if (tail.isNotEmpty) txt += ' ($tail)';
        lines.add(_PackLine(_rItem, txt, '', i + 1));
      }
      lines.add(
          _PackLine(_rRollup, res.length.toString(), _phToVote, res.length));
    } else {
      lines.add(const _PackLine(_rNote, '', _phEmpty, 0));
    }

    final totalMinutes =
        agenda.fold<int>(0, (s, r) => s + _toInt(r['minutes']));
    if (totalMinutes > 0) {
      lines.add(_PackLine(
          _rRollup, totalMinutes.toString(), _phTotalMinutes, totalMinutes));
    }
    return lines;
  }

  List<String> _validate() {
    final problems = <String>[];
    if (_clean(_title.text).isEmpty) problems.add('empty_title');
    final agenda = _agenda
        .where((r) => _clean(r['title']?.toString()).isNotEmpty)
        .toList();
    if (agenda.isEmpty) problems.add('empty_agenda');
    return problems;
  }

  String _sectionLabel(AppLocalizations tr, String phrase) {
    switch (phrase) {
      case _phAgenda:
        return tr.paBoardSecAgenda;
      case _phDocuments:
        return tr.paBoardSecDocuments;
      case _phAttendees:
        return tr.paBoardSecAttendees;
      case _phResolutions:
        return tr.paBoardSecResolutions;
      default:
        return '';
    }
  }

  String _statusLabel(AppLocalizations tr, String st) {
    switch (st) {
      case _stApology:
        return tr.paBoardStatusApology;
      case _stAbsent:
        return tr.paBoardStatusAbsent;
      default:
        return tr.paBoardStatusPresent;
    }
  }

  /// Render the structured lines to plain text for copy/share + preview.
  String _render(AppLocalizations tr) {
    final out = <String>[];
    for (final ln in _assemble()) {
      switch (ln.role) {
        case _rTitle:
          out.add(ln.text);
          out.add('');
          break;
        case _rSection:
          out.add('');
          out.add('${_sectionLabel(tr, ln.phrase)}:');
          break;
        case _rItem:
          out.add('  ${ln.num}. ${ln.text}');
          break;
        case _rAttendee:
          final st = ln.phrase == _phPresent
              ? tr.paBoardStatusPresent
              : ln.phrase == _phApologies
                  ? tr.paBoardStatusApology
                  : tr.paBoardStatusAbsent;
          out.add('  • ${ln.text} ($st)');
          break;
        case _rRollup:
          out.add('  — ${_rollupLabel(tr, ln)}');
          break;
        case _rNote:
          out.add('  (${tr.paBoardSectionEmpty})');
          break;
      }
    }
    return out.join('\n');
  }

  String _rollupLabel(AppLocalizations tr, _PackLine ln) {
    switch (ln.phrase) {
      case _phPresent:
        return tr.paBoardRollupAttendance(ln.text);
      case _phQuorumMet:
        return tr.paBoardQuorumMet(ln.text);
      case _phQuorumShort:
        return tr.paBoardQuorumShort(ln.text);
      case _phToVote:
        return tr.paBoardToVote(ln.num);
      case _phTotalMinutes:
        return tr.paBoardTotalMinutes(ln.num);
      default:
        return ln.text;
    }
  }

  Future<void> _save(AppLocalizations tr) async {
    setState(() => _saving = true);
    final body = <String, dynamic>{
      'title': _clean(_title.text),
      'date': _clean(_date.text),
      'quorum': _toInt(_quorum.text),
      'agenda': _agenda,
      'documents': _documents,
      'attendees': _attendees,
      'resolutions': _resolutions,
    };
    try {
      final api = context.read<AppState>().api;
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem('pa/board', id, body);
      } else {
        await api.createItem('pa/board', body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(tr.saveFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final problems = _validate();
    final rendered = _render(tr);
    return Scaffold(
      appBar: AppBar(
          title:
              Text(widget.existing == null ? tr.paBoardNew : tr.paBoardEdit)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32)),
        children: [
          TextField(
            controller: _title,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.paBoardTitleField,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _date,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: tr.paBoardDateField,
                    helperText: tr.paBoardDateHelp,
                    helperMaxLines: 2,
                    border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: Gap.md),
            SizedBox(
              width: 108,
              child: TextField(
                controller: _quorum,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr.paBoardQuorumField,
                    border: const OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: Gap.lg),

          // ---- Agenda
          _SectionEditor(
            label: tr.paBoardSecAgenda,
            icon: Icons.list_alt_rounded,
            rows: _agenda,
            addLabel: tr.paBoardAddAgenda,
            onChanged: () => setState(() {}),
            builder: (r, update) =>
                _AgendaRow(row: r, onChanged: update, tr: tr),
            newRow: () => {'title': '', 'presenter': '', 'minutes': 0},
          ),
          const SizedBox(height: Gap.lg),

          // ---- Documents
          _SectionEditor(
            label: tr.paBoardSecDocuments,
            icon: Icons.folder_rounded,
            rows: _documents,
            addLabel: tr.paBoardAddDocument,
            onChanged: () => setState(() {}),
            builder: (r, update) => _DocRow(row: r, onChanged: update, tr: tr),
            newRow: () => {'title': '', 'ref': ''},
          ),
          const SizedBox(height: Gap.lg),

          // ---- Attendees
          _SectionEditor(
            label: tr.paBoardSecAttendees,
            icon: Icons.people_alt_rounded,
            rows: _attendees,
            addLabel: tr.paBoardAddAttendee,
            onChanged: () => setState(() {}),
            builder: (r, update) => _AttendeeRow(
                row: r, onChanged: update, tr: tr, statusLabel: _statusLabel),
            newRow: () => {'name': '', 'role': '', 'status': _stPresent},
          ),
          const SizedBox(height: Gap.lg),

          // ---- Resolutions
          _SectionEditor(
            label: tr.paBoardSecResolutions,
            icon: Icons.how_to_vote_rounded,
            rows: _resolutions,
            addLabel: tr.paBoardAddResolution,
            onChanged: () => setState(() {}),
            builder: (r, update) =>
                _ResolutionRow(row: r, onChanged: update, tr: tr),
            newRow: () => {'text': '', 'proposer': '', 'seconder': ''},
          ),
          const SizedBox(height: Gap.lg),

          _aiSeamCard(tr, scheme),
          const SizedBox(height: Gap.lg),

          Row(children: [
            Icon(Icons.info_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(tr.f6BwTemplateMarker, // truth: template, not AI
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12.5)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(tr.paBoardPreviewLabel,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: SelectableText(
              rendered.trim().isEmpty ? tr.paBoardPreviewEmpty : rendered,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: rendered));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(SnackBar(content: Text(tr.copied)));
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(tr.copy),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Share.share(rendered),
                icon: const Icon(Icons.share_rounded, size: 18),
                label: Text(tr.share),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed:
                  (problems.isEmpty && !_saving) ? () => _save(tr) : null,
              icon: const Icon(Icons.save_rounded, size: 18),
              label: Text(tr.save),
            ),
          ),
          if (problems.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(
              problems.contains('empty_title')
                  ? tr.paBoardNeedTitle
                  : tr.paBoardNeedAgenda,
              style: TextStyle(color: scheme.error, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _aiSeamCard(AppLocalizations tr, ColorScheme scheme) => !kShowKeySeams
      ? const SizedBox.shrink() // truth: no key dead end
      : Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr.paBoardAiSeamTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, height: 1.4)),
              const SizedBox(height: 2),
              Text(tr.paBoardAiSeamBody,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      height: 1.4)),
            ]),
          ),
        ]),
      );
}

/// A labelled card holding a repeatable list of child rows with add/remove.
class _SectionEditor extends StatelessWidget {
  final String label;
  final IconData icon;
  final List<Map<String, dynamic>> rows;
  final String addLabel;
  final VoidCallback onChanged;
  final Widget Function(Map<String, dynamic> row, VoidCallback update) builder;
  final Map<String, dynamic> Function() newRow;
  const _SectionEditor({
    required this.label,
    required this.icon,
    required this.rows,
    required this.addLabel,
    required this.onChanged,
    required this.builder,
    required this.newRow,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          Text('${rows.length}',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
        for (var i = 0; i < rows.length; i++) ...[
          const SizedBox(height: Gap.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: builder(rows[i], onChanged)),
            IconButton(
              tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
              icon: Icon(Icons.remove_circle_outline_rounded, color: scheme.error),
              onPressed: () {
                rows.removeAt(i);
                onChanged();
              },
            ),
          ]),
        ],
        const SizedBox(height: Gap.xs),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () {
              rows.add(newRow());
              onChanged();
            },
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(addLabel),
          ),
        ),
      ]),
    );
  }
}

class _AgendaRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onChanged;
  final AppLocalizations tr;
  const _AgendaRow(
      {required this.row, required this.onChanged, required this.tr});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      TextFormField(
        initialValue: row['title']?.toString() ?? '',
        onChanged: (v) {
          row['title'] = v;
          onChanged();
        },
        decoration: InputDecoration(
            isDense: true,
            labelText: tr.paBoardAgendaItemField,
            border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.xs),
      Row(children: [
        Expanded(
          flex: 2,
          child: TextFormField(
            initialValue: row['presenter']?.toString() ?? '',
            onChanged: (v) {
              row['presenter'] = v;
              onChanged();
            },
            decoration: InputDecoration(
                isDense: true,
                labelText: tr.paBoardPresenterField,
                border: const OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: Gap.sm),
        SizedBox(
          width: 92,
          child: TextFormField(
            initialValue: (row['minutes'] is int && row['minutes'] > 0)
                ? '${row['minutes']}'
                : '',
            keyboardType: TextInputType.number,
            onChanged: (v) {
              row['minutes'] = _toInt(v);
              onChanged();
            },
            decoration: InputDecoration(
                isDense: true,
                labelText: tr.paBoardMinutesField,
                border: const OutlineInputBorder()),
          ),
        ),
      ]),
    ]);
  }
}

class _DocRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onChanged;
  final AppLocalizations tr;
  const _DocRow({required this.row, required this.onChanged, required this.tr});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
        width: 84,
        child: TextFormField(
          initialValue: row['ref']?.toString() ?? '',
          onChanged: (v) {
            row['ref'] = v;
            onChanged();
          },
          decoration: InputDecoration(
              isDense: true,
              labelText: tr.paBoardDocRefField,
              border: const OutlineInputBorder()),
        ),
      ),
      const SizedBox(width: Gap.sm),
      Expanded(
        child: TextFormField(
          initialValue: row['title']?.toString() ?? '',
          onChanged: (v) {
            row['title'] = v;
            onChanged();
          },
          decoration: InputDecoration(
              isDense: true,
              labelText: tr.paBoardDocTitleField,
              border: const OutlineInputBorder()),
        ),
      ),
    ]);
  }
}

class _AttendeeRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onChanged;
  final AppLocalizations tr;
  final String Function(AppLocalizations, String) statusLabel;
  const _AttendeeRow(
      {required this.row,
      required this.onChanged,
      required this.tr,
      required this.statusLabel});
  @override
  Widget build(BuildContext context) {
    final status = () {
      final s = _clean(row['status']?.toString()).toLowerCase();
      return _statuses.contains(s) ? s : _stPresent;
    }();
    return Column(children: [
      Row(children: [
        Expanded(
          flex: 3,
          child: TextFormField(
            initialValue: row['name']?.toString() ?? '',
            onChanged: (v) {
              row['name'] = v;
              onChanged();
            },
            decoration: InputDecoration(
                isDense: true,
                labelText: tr.paBoardAttendeeNameField,
                border: const OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          flex: 2,
          child: TextFormField(
            initialValue: row['role']?.toString() ?? '',
            onChanged: (v) {
              row['role'] = v;
              onChanged();
            },
            decoration: InputDecoration(
                isDense: true,
                labelText: tr.paBoardAttendeeRoleField,
                border: const OutlineInputBorder()),
          ),
        ),
      ]),
      const SizedBox(height: Gap.xs),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Wrap(spacing: Gap.sm, children: [
          for (final s in _statuses)
            ChoiceChip(
              label: Text(statusLabel(tr, s)),
              selected: status == s,
              onSelected: (_) {
                row['status'] = s;
                onChanged();
              },
            ),
        ]),
      ),
    ]);
  }
}

class _ResolutionRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onChanged;
  final AppLocalizations tr;
  const _ResolutionRow(
      {required this.row, required this.onChanged, required this.tr});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      TextFormField(
        initialValue: row['text']?.toString() ?? '',
        minLines: 1,
        maxLines: 3,
        onChanged: (v) {
          row['text'] = v;
          onChanged();
        },
        decoration: InputDecoration(
            isDense: true,
            labelText: tr.paBoardResolutionField,
            border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.xs),
      Row(children: [
        Expanded(
          child: TextFormField(
            initialValue: row['proposer']?.toString() ?? '',
            onChanged: (v) {
              row['proposer'] = v;
              onChanged();
            },
            decoration: InputDecoration(
                isDense: true,
                labelText: tr.paBoardProposerField,
                border: const OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: TextFormField(
            initialValue: row['seconder']?.toString() ?? '',
            onChanged: (v) {
              row['seconder'] = v;
              onChanged();
            },
            decoration: InputDecoration(
                isDense: true,
                labelText: tr.paBoardSeconderField,
                border: const OutlineInputBorder()),
          ),
        ),
      ]),
    ]);
  }
}
