import '../../feature_gates.dart' show kShowKeySeams;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA SECRETARY MODE · MEETING MINUTES — ADVANCED, KEY-GATED TRANSCRIPTION
/// (#110, SPEC v2.1 §14 / §21).
///
/// Capture the minutes of a meeting the PA sat in on (or typed up after): a
/// meeting TITLE + DATE, ATTENDEES, AGENDA items, DECISIONS, and ACTION ITEMS
/// each with an owner and a due date. A deterministic MINUTES SUMMARY formats a
/// clean recap from exactly what was entered. It complements the meeting brief
/// (#104, which prepares the owner BEFORE a meeting); this records what happened
/// AFTER.
///
/// HONEST TRANSCRIPTION, KEY-GATED: auto-GENERATING minutes from a recording
/// (speech-to-text) is a DOCUMENTED key-gated seam. Without a transcription key
/// (Integrations → transcription) the tool works fully as a MANUAL minutes tool
/// and NEVER fabricates a transcript or minutes — the UI shows an honest
/// "connect a transcription key to auto-generate minutes from audio" card
/// (_SttSeamCard). The whole tool works with no key.
///
/// The on-screen logic mirrors backend/core/logic/pa_minutes.py VERBATIM
/// (normalise, validate, order action items, deterministic summary) so the live
/// view is deterministic and identical offline. ZERO Bangla literals — every
/// string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('pa/minutes') → [{id, title, date, attendees, agenda,
///                                decisions, actions:[{title,owner,due,status}]}]
/// create / update / delete on the same path. Each row round-trips as
/// {id, ...buildMinutes(...)}. A flat per-owner action view lives in
/// 'pa/actionitems' (see the integration note) — this screen edits actions
/// embedded in the entry and does not write the flat view itself.
class MeetingMinutesScreen extends StatefulWidget {
  const MeetingMinutesScreen({super.key});
  @override
  State<MeetingMinutesScreen> createState() => _MeetingMinutesScreenState();
}

const String _acOpen = 'open';
const String _acDoing = 'doing';
const String _acDone = 'done';
const List<String> _kActionStatuses = [_acOpen, _acDoing, _acDone];

class _MeetingMinutesScreenState extends State<MeetingMinutesScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  // Auto-minutes is key-gated (Integrations → transcription), owner-only. The
  // honest default is LOCKED; a real auto-generate routes server-side when the
  // owner connects the `transcription` key. We NEVER fabricate a transcript.
  bool get _sttReady => false;

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
      _rows = await context.read<AppState>().api.listItems('pa/minutes');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addOrEdit(AppLocalizations tr,
      {Map<String, dynamic>? existing}) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => _MinutesEditor(existing: existing, sttReady: _sttReady),
      ),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context
            .read<AppState>()
            .api
            .updateItem('pa/minutes', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('pa/minutes', result);
      }
      await _load();
      if (mounted) _toast(tr.paMinSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.paMinDeleteTitle),
        content: Text(tr.paMinDeleteBody((r['title'] ?? '').toString())),
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
        await context.read<AppState>().api.deleteItem('pa/minutes', id);
      }
      await _load();
      if (mounted) _toast(tr.paMinDeleted);
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  List<Map<String, dynamic>> get _ordered {
    final list = List<Map<String, dynamic>>.from(_rows);
    // Newest meeting date first; blank dates last; then title.
    list.sort((a, b) {
      final da = (a['date'] ?? '').toString();
      final db = (b['date'] ?? '').toString();
      if (da != db) {
        if (da.isEmpty) return 1;
        if (db.isEmpty) return -1;
        return db.compareTo(da);
      }
      return (a['title'] ?? '').toString().compareTo((b['title'] ?? '').toString());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.paMinTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : () => _addOrEdit(tr),
        icon: const Icon(Icons.note_add_rounded),
        label: Text(tr.paMinAdd),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.paMinLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : _rows.isEmpty
                  ? _welcome(tr)
                  : _list(tr, scheme),
    );
  }

  Widget _welcome(AppLocalizations tr) => ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          StateMessage(
            icon: Icons.groups_rounded,
            tint: Brand.blue,
            title: tr.paMinWelcomeTitle,
            message: tr.paMinWelcomeBody,
            action: FilledButton.icon(
              onPressed: () => _addOrEdit(tr),
              icon: const Icon(Icons.note_add_rounded),
              label: Text(tr.paMinAdd),
            ),
          ),
          const SizedBox(height: Gap.lg),
          _SttSeamCard(ready: _sttReady),
        ],
      );

  Widget _list(AppLocalizations tr, ColorScheme scheme) {
    final list = _ordered;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        itemCount: list.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
        itemBuilder: (_, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: _SttSeamCard(ready: _sttReady),
            );
          }
          return _card(list[i - 1], tr, scheme);
        },
      ),
    );
  }

  Widget _card(
      Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme) {
    final s = summariseMinutes(r);
    final actions = (s['actions'] as List).cast<Map<String, dynamic>>();
    final dateStr = (s['date'] ?? '').toString();
    final open = s['open_actions'] as int;
    final done = s['done_actions'] as int;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.groups_rounded, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text((s['title'] ?? '').toString(),
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) {
                if (v == 'edit') _addOrEdit(tr, existing: r);
                if (v == 'delete') _delete(r, tr);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (dateStr.isNotEmpty)
              _meta(Icons.event_rounded, _fmtDate(dateStr, tr), scheme),
            _meta(Icons.people_outline_rounded,
                tr.paMinAttendeeCount('${s['attendee_count']}'), scheme),
            if (actions.isNotEmpty)
              _meta(Icons.task_alt_rounded,
                  tr.paMinActionCount(/* (done, open) */ '$done', '$open'), scheme),
          ]),
          if ((s['agenda'] as List).isNotEmpty)
            _section(tr.paMinAgenda, (s['agenda'] as List).cast<String>(),
                Icons.list_alt_rounded, scheme),
          if ((s['decisions'] as List).isNotEmpty)
            _section(tr.paMinDecisions,
                (s['decisions'] as List).cast<String>(), Icons.gavel_rounded, scheme),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Row(children: [
              Icon(Icons.task_alt_rounded, size: 15, color: scheme.secondary),
              const SizedBox(width: Gap.xs),
              Text(tr.paMinActions,
                  style: AType.bodySmall.copyWith(fontWeight: FontWeight.w700, color: scheme.secondary)),
            ]),
            const SizedBox(height: Gap.xs),
            for (final a in actions) _actionRow(a, tr, scheme),
          ],
        ]),
      ),
    );
  }

  Widget _section(
      String label, List<String> items, IconData icon, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.xs),
          Text(label,
              style: AType.bodySmall.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: Gap.xxs),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(left: 19, top: 1),
            child: Text('•  $it',
                style: AType.bodyMedium.copyWith(color: scheme.onSurface, height: 1.3)),
          ),
      ]),
    );
  }

  Widget _actionRow(
      Map<String, dynamic> a, AppLocalizations tr, ColorScheme scheme) {
    final status = normaliseActionStatus(a['status']);
    final owner = (a['owner'] ?? '').toString().trim();
    final due = (a['due'] ?? '').toString().trim();
    final done = status == _acDone;
    final color = status == _acDone
        ? Brand.success
        : status == _acDoing
            ? Brand.warning
            : scheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 19, top: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
            done
                ? Icons.check_circle_rounded
                : status == _acDoing
                    ? Icons.timelapse_rounded
                    : Icons.radio_button_unchecked_rounded,
            size: 15,
            color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((a['title'] ?? '').toString(),
                style: AType.bodyMedium.copyWith(height: 1.3, decoration: done ? TextDecoration.lineThrough : null, color: done ? scheme.onSurfaceVariant : scheme.onSurface)),
            if (owner.isNotEmpty || due.isNotEmpty)
              Text(
                [
                  if (owner.isNotEmpty) tr.paMinOwnerHint(owner),
                  if (due.isNotEmpty) tr.paMinDueHint(_fmtDate(due, tr)),
                ].join('  ·  '),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
              ),
          ]),
        ),
        _statusPill(tr, status, color),
      ]),
    );
  }

  Widget _statusPill(AppLocalizations tr, String status, Color c) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(_statusLabel(tr, status),
          style: AType.labelSmall.copyWith(color: c, fontWeight: FontWeight.w700)),
    );
  }

  String _statusLabel(AppLocalizations tr, String s) {
    switch (s) {
      case _acDoing:
        return tr.paMinStatusDoing;
      case _acDone:
        return tr.paMinStatusDone;
      default:
        return tr.paMinStatusOpen;
    }
  }

  String _fmtDate(String iso, AppLocalizations tr) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return DateFormat('d MMM yyyy', tr.localeName).format(d);
  }

  Widget _meta(IconData icon, String text, ColorScheme scheme) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.xs),
          Text(text,
              style:
                  AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ],
      );
}

/// Honest key-gated transcription seam card. Shows "connect a transcription key
/// to auto-generate minutes from audio" when no key is connected. NEVER
/// fabricates a transcript or minutes.
class _SttSeamCard extends StatelessWidget {
  final bool ready;
  const _SttSeamCard({required this.ready});

  @override
  Widget build(BuildContext context) {
    if (!kShowKeySeams) return const SizedBox.shrink(); // truth: no key dead end
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ready ? Icons.auto_awesome_rounded : Icons.lock_outline_rounded,
              size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ready ? tr.paMinSttReadyTitle : tr.paMinSttSeamTitle,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xxs),
                  Text(ready ? tr.paMinSttReadyBody : tr.paMinSttSeamBody,
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
                ]),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen editor for a minutes entry (title/date/attendees/agenda/
/// decisions/actions). Returns the body map (buildMinutes shape) or null.
class _MinutesEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final bool sttReady;
  const _MinutesEditor({this.existing, required this.sttReady});
  @override
  State<_MinutesEditor> createState() => _MinutesEditorState();
}

class _MinutesEditorState extends State<_MinutesEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?['title']?.toString() ?? '');
  late final TextEditingController _attendees = TextEditingController(
      text: cleanList(widget.existing?['attendees']).join('\n'));
  late final TextEditingController _agenda = TextEditingController(
      text: cleanList(widget.existing?['agenda']).join('\n'));
  late final TextEditingController _decisions = TextEditingController(
      text: cleanList(widget.existing?['decisions']).join('\n'));
  DateTime? _date;
  late List<Map<String, dynamic>> _actions;

  @override
  void initState() {
    super.initState();
    final d = widget.existing?['date'];
    if (d != null) _date = DateTime.tryParse(d.toString());
    final raw = (widget.existing?['actions'] as List?) ?? const [];
    _actions = raw
        .map((e) => normaliseAction(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  void dispose() {
    _title.dispose();
    _attendees.dispose();
    _agenda.dispose();
    _decisions.dispose();
    super.dispose();
  }

  Future<void> _editAction([int? index]) async {
    final existing = index != null ? _actions[index] : null;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ActionForm(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (index != null) {
        _actions[index] = result;
      } else {
        _actions.add(result);
      }
    });
  }

  void _save() {
    final body = buildMinutes(
      title: _title.text,
      date: _date == null ? '' : DateFormat('yyyy-MM-dd').format(_date!),
      attendees: _attendees.text,
      agenda: _agenda.text,
      decisions: _decisions.text,
      actions: _actions,
    );
    Navigator.pop(context, body);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final fmt = DateFormat('d MMM yyyy', tr.localeName);
    final titleOk = _title.text.trim().isNotEmpty;
    final ordered = orderActions(_actions);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? tr.paMinAdd : tr.paMinEdit),
        actions: [
          TextButton(
            onPressed: titleOk ? _save : null,
            child: Text(tr.save),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          _SttSeamCard(ready: widget.sttReady),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _title,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
                labelText: tr.paMinTitleLabel,
                hintText: tr.paMinTitleHint,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
            onPressed: () async {
              final base = _date ?? DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate: base,
                firstDate: DateTime(base.year - 5),
                lastDate: DateTime(base.year + 5),
              );
              if (d != null) setState(() => _date = d);
            },
            icon: const Icon(Icons.event_rounded),
            label: Text(_date == null ? tr.paMinSetDate : fmt.format(_date!)),
          ),
          const SizedBox(height: Gap.md),
          _multiline(_attendees, tr.paMinAttendeesLabel, tr.paMinAttendeesHint),
          const SizedBox(height: Gap.md),
          _multiline(_agenda, tr.paMinAgendaLabel, tr.paMinAgendaHint),
          const SizedBox(height: Gap.md),
          _multiline(_decisions, tr.paMinDecisionsLabel, tr.paMinDecisionsHint),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: Text(tr.paMinActions,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            TextButton.icon(
              onPressed: () => _editAction(),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr.paMinAddAction),
            ),
          ]),
          if (ordered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm),
              child: Text(tr.paMinNoActions,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          for (final a in ordered)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                title: Text((a['title'] ?? '').toString()),
                subtitle: Text([
                  if ((a['owner'] ?? '').toString().trim().isNotEmpty)
                    tr.paMinOwnerHint((a['owner']).toString()),
                  if ((a['due'] ?? '').toString().trim().isNotEmpty)
                    tr.paMinDueHint((a['due']).toString()),
                  _statusLabel(tr, normaliseActionStatus(a['status'])),
                ].join('  ·  ')),
                onTap: () => _editAction(_actions.indexOf(a)),
                trailing: IconButton(
                  tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => setState(() => _actions.remove(a)),
                ),
              ),
            ),
          const SizedBox(height: Gap.xl),
        ],
      ),
    );
  }

  Widget _multiline(TextEditingController c, String label, String hint) =>
      TextField(
        controller: c,
        minLines: 2,
        maxLines: 5,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            alignLabelWithHint: true,
            border: const OutlineInputBorder()),
      );

  String _statusLabel(AppLocalizations tr, String s) {
    switch (s) {
      case _acDoing:
        return tr.paMinStatusDoing;
      case _acDone:
        return tr.paMinStatusDone;
      default:
        return tr.paMinStatusOpen;
    }
  }
}

/// Add / edit one action item.
class _ActionForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _ActionForm({this.existing});
  @override
  State<_ActionForm> createState() => _ActionFormState();
}

class _ActionFormState extends State<_ActionForm> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?['title']?.toString() ?? '');
  late final TextEditingController _owner =
      TextEditingController(text: widget.existing?['owner']?.toString() ?? '');
  DateTime? _due;
  late String _status =
      normaliseActionStatus(widget.existing?['status'] ?? _acOpen);

  @override
  void initState() {
    super.initState();
    final d = widget.existing?['due'];
    if (d != null) _due = DateTime.tryParse(d.toString());
  }

  @override
  void dispose() {
    _title.dispose();
    _owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final fmt = DateFormat('d MMM yyyy', tr.localeName);
    final titleOk = _title.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.paMinAction,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _title,
                onChanged: (_) => setState(() {}),
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.paMinActionTitleLabel,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _owner,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.paMinOwnerLabel,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                onPressed: () async {
                  final base = _due ?? DateTime.now();
                  final d = await showDatePicker(
                    context: context,
                    initialDate: base,
                    firstDate: DateTime(base.year - 1),
                    lastDate: DateTime(base.year + 5),
                  );
                  if (d != null) setState(() => _due = d);
                },
                icon: const Icon(Icons.event_rounded),
                label: Text(_due == null ? tr.paMinSetDue : fmt.format(_due!)),
              ),
              const SizedBox(height: Gap.md),
              SegmentedButton<String>(
                segments: [
                  for (final s in _kActionStatuses)
                    ButtonSegment(value: s, label: Text(_statusLabel(tr, s))),
                ],
                selected: {_status},
                onSelectionChanged: (v) => setState(() => _status = v.first),
              ),
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
                    onPressed: titleOk
                        ? () => Navigator.pop(
                            context,
                            normaliseAction({
                              'title': _title.text,
                              'owner': _owner.text,
                              'due': _due == null
                                  ? ''
                                  : DateFormat('yyyy-MM-dd').format(_due!),
                              'status': _status,
                            }))
                        : null,
                    child: Text(tr.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }

  String _statusLabel(AppLocalizations tr, String s) {
    switch (s) {
      case _acDoing:
        return tr.paMinStatusDoing;
      case _acDone:
        return tr.paMinStatusDone;
      default:
        return tr.paMinStatusOpen;
    }
  }
}

// ======================================================================
// On-device Dart mirror of backend/core/logic/pa_minutes.py.
// DETERMINISTIC formatter — normalise, validate, order action items, and build
// a summary from the ENTERED fields only. PURE: no transcription, no AI, no
// clock. NEVER fabricates a transcript or minutes. The transcription seam is
// key-gated (Integrations `transcription`) and routed elsewhere.
// ======================================================================

const String _noDueM = '9999-12-31';

String _cleanM(dynamic s) => (s?.toString() ?? '')
    .trim()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .join(' ');

/// Coerce a List or newline/comma string into a clean list of non-empty
/// trimmed strings (order preserved). Mirrors pa_minutes.py::_clean_list.
List<String> cleanList(dynamic items) {
  final raw = <String>[];
  if (items is String) {
    raw.addAll(items.replaceAll('\r', '\n').split('\n'));
  } else if (items is List) {
    raw.addAll(items.map((e) => e.toString()));
  }
  return raw.map(_cleanM).where((c) => c.isNotEmpty).toList();
}

String normaliseActionStatus(dynamic status) {
  final s = _cleanM(status).toLowerCase();
  return _kActionStatuses.contains(s) ? s : _acOpen;
}

/// Normalise one action item to {title, owner, due, status}. Mirrors
/// pa_minutes.py::normalise_action.
Map<String, dynamic> normaliseAction(Map<String, dynamic> action) => {
      'title': _cleanM(action['title']),
      'owner': _cleanM(action['owner']),
      'due': _cleanM(action['due']),
      'status': normaliseActionStatus(action['status']),
    };

/// Order action items: not-done first, then soonest due, then title. No clock —
/// ordering is by the entered due string only. Mirrors order_actions.
List<Map<String, dynamic>> orderActions(List<dynamic> actions) {
  final normed = actions
      .map((a) => normaliseAction(Map<String, dynamic>.from(a as Map)))
      .toList();
  normed.sort((a, b) {
    final doneA = a['status'] == _acDone ? 1 : 0;
    final doneB = b['status'] == _acDone ? 1 : 0;
    if (doneA != doneB) return doneA - doneB;
    final dueA = (a['due'] as String).isEmpty ? _noDueM : a['due'] as String;
    final dueB = (b['due'] as String).isEmpty ? _noDueM : b['due'] as String;
    final c = dueA.compareTo(dueB);
    if (c != 0) return c;
    return (a['title'] as String)
        .toLowerCase()
        .compareTo((b['title'] as String).toLowerCase());
  });
  return normed;
}

/// Problem keys for a minutes entry (empty ⇒ valid). Mirrors validate.
List<String> validateMinutes(String title, {List<dynamic> actions = const []}) {
  final out = <String>[];
  if (_cleanM(title).isEmpty) out.add('title_required');
  for (final a in actions) {
    final m = Map<String, dynamic>.from(a as Map);
    if (_cleanM(m['title']).isEmpty) {
      out.add('bad_action');
      break;
    }
  }
  return out;
}

/// Normalise a meeting into the stored row shape. NEVER fabricates a transcript.
/// Mirrors pa_minutes.py::build_minutes.
Map<String, dynamic> buildMinutes({
  required String title,
  String date = '',
  dynamic attendees,
  dynamic agenda,
  dynamic decisions,
  List<dynamic> actions = const [],
}) {
  return {
    'title': _cleanM(title),
    'date': _cleanM(date),
    'attendees': cleanList(attendees),
    'agenda': cleanList(agenda),
    'decisions': cleanList(decisions),
    'actions': orderActions(actions),
    'stt_state': 'stt_locked',
    'ai_required': false,
    'mock': true,
    'problems': validateMinutes(title, actions: actions),
  };
}

/// Deterministic minutes summary from the ENTERED fields only. Never pads with
/// invented content. Mirrors pa_minutes.py::summarise.
Map<String, dynamic> summariseMinutes(Map<String, dynamic> entry) {
  final e = buildMinutes(
    title: (entry['title'] ?? '').toString(),
    date: (entry['date'] ?? '').toString(),
    attendees: entry['attendees'],
    agenda: entry['agenda'],
    decisions: entry['decisions'],
    actions: (entry['actions'] as List?) ?? const [],
  );
  final actions = (e['actions'] as List).cast<Map<String, dynamic>>();
  final openN = actions.where((a) => a['status'] != _acDone).length;
  final doneN = actions.where((a) => a['status'] == _acDone).length;
  final sections = <String>[];
  if ((e['attendees'] as List).isNotEmpty) sections.add('attendees');
  if ((e['agenda'] as List).isNotEmpty) sections.add('agenda');
  if ((e['decisions'] as List).isNotEmpty) sections.add('decisions');
  if (actions.isNotEmpty) sections.add('actions');
  return {
    'title': e['title'],
    'date': e['date'],
    'attendee_count': (e['attendees'] as List).length,
    'attendees': e['attendees'],
    'agenda': e['agenda'],
    'decisions': e['decisions'],
    'actions': actions,
    'open_actions': openN,
    'done_actions': doneN,
    'sections': sections,
    'mock': true,
    'ai_required': false,
  };
}
