import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · Call & Email handling — ADVANCED (#106, §14).
///
/// A PA inbox / work-log for CALLS to make/return and EMAILS to handle. Each is
/// a task (channel, contact, subject, priority, status todo/done, notes). The
/// inbox is ordered open-first → priority → subject and shows honest counts.
///
/// For any task the PA can generate a SUGGESTED reply draft from a DETERMINISTIC
/// template bank by category (acknowledge / decline / schedule / follow-up),
/// filled from the task's own fields. Every draft carries an honest
/// "AI-generated — review" marker; a "connect an AI key for a full AI-drafted
/// reply" seam is shown, never fabricated. NOTHING here ever sends or dials.
///
/// All logic mirrors backend/core/logic/pa_callemail.py so previews are
/// identical offline. ZERO Bangla literals — every string is an
/// AppLocalizations getter.
///
/// Endpoints (generic api helpers, no api.dart edit):
///   listItems('pa/callemail')            → rows
///   createItem('pa/callemail', body)     → create
///   updateItem('pa/callemail', id, body) → edit / status
///   deleteItem('pa/callemail', id)       → remove
class CallEmailScreen extends StatefulWidget {
  const CallEmailScreen({super.key});
  @override
  State<CallEmailScreen> createState() => _CallEmailScreenState();
}

// ---- constants (mirror pa_callemail.py) -----------------------------------
const String _chCall = 'call';
const String _chEmail = 'email';
const List<String> _channels = [_chCall, _chEmail];

const String _prHigh = 'high';
const String _prNormal = 'normal';
const String _prLow = 'low';
const List<String> _priorities = [_prHigh, _prNormal, _prLow];

const String _stTodo = 'todo';
const String _stDone = 'done';

const String _catAck = 'acknowledge';
const String _catDecline = 'decline';
const String _catSchedule = 'schedule';
const String _catFollowup = 'followup';
const List<String> _categories = [_catAck, _catDecline, _catSchedule, _catFollowup];

const Map<String, int> _priorityRank = {_prHigh: 0, _prNormal: 1, _prLow: 2};

class _CallEmailScreenState extends State<CallEmailScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  String? _fChannel; // null ⇒ any
  bool _hideDone = false;

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
      _rows = await context.read<AppState>().api.listItems('pa/callemail');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- deterministic mirror of pa_callemail.py -----------------------------
  String _channel(Map<String, dynamic> r) {
    final v = (r['channel'] ?? '').toString().toLowerCase();
    return _channels.contains(v) ? v : _chCall;
  }

  String _priority(Map<String, dynamic> r) {
    final v = (r['priority'] ?? '').toString().toLowerCase();
    return _priorities.contains(v) ? v : _prNormal;
  }

  String _status(Map<String, dynamic> r) =>
      (r['status'] ?? _stTodo).toString().toLowerCase() == _stDone
          ? _stDone
          : _stTodo;

  List<Map<String, dynamic>> get _ordered {
    final list = _rows.where((r) {
      if (_fChannel != null && _channel(r) != _fChannel) return false;
      if (_hideDone && _status(r) == _stDone) return false;
      return true;
    }).toList();
    list.sort((a, b) {
      final sa = _status(a) == _stDone ? 1 : 0;
      final sb = _status(b) == _stDone ? 1 : 0;
      if (sa != sb) return sa - sb;
      final pa = _priorityRank[_priority(a)] ?? 1;
      final pb = _priorityRank[_priority(b)] ?? 1;
      if (pa != pb) return pa - pb;
      final subA = (a['subject'] ?? '').toString().toLowerCase();
      final subB = (b['subject'] ?? '').toString().toLowerCase();
      final c = subA.compareTo(subB);
      if (c != 0) return c;
      return (a['contact'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['contact'] ?? '').toString().toLowerCase());
    });
    return list;
  }

  int get _openCalls => _rows
      .where((r) => _status(r) != _stDone && _channel(r) == _chCall)
      .length;
  int get _openEmails => _rows
      .where((r) => _status(r) != _stDone && _channel(r) == _chEmail)
      .length;
  int get _doneCount => _rows.where((r) => _status(r) == _stDone).length;

  // ---- deterministic template reply (mirror _TEMPLATES) --------------------
  String _draftBody(AppLocalizations tr, Map<String, dynamic> r, String cat) {
    final contact = (r['contact'] ?? '').toString().trim();
    final subject = (r['subject'] ?? '').toString().trim();
    final sender = context.read<AppState>().user?.name.trim() ?? '';
    final c = contact.isEmpty ? '—' : contact;
    final s = subject.isEmpty ? '—' : subject;
    final who = sender.isEmpty ? '—' : sender;
    switch (cat) {
      case _catDecline:
        return tr.paCeTplDecline(/* (contact, sender, subject) */ c, who, s);
      case _catSchedule:
        return tr.paCeTplSchedule(/* (contact, sender, subject) */ c, who, s);
      case _catFollowup:
        return tr.paCeTplFollowup(/* (contact, sender, subject) */ c, who, s);
      default:
        return tr.paCeTplAcknowledge(/* (contact, sender, subject) */ c, who, s);
    }
  }

  // ---- actions -------------------------------------------------------------
  Future<void> _toggleDone(Map<String, dynamic> r, AppLocalizations tr) async {
    final to = _status(r) == _stDone ? _stTodo : _stDone;
    final id = r['id'];
    try {
      if (id is int) {
        await context.read<AppState>().api.updateItem('pa/callemail', id, {'status': to});
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.paCeDeleteTitle),
        content: Text(tr.paCeDeleteBody((r['subject'] ?? r['contact'] ?? '').toString())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
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
      if (id is int) await context.read<AppState>().api.deleteItem('pa/callemail', id);
      await _load();
      if (mounted) _toast(tr.paCeDeleted);
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  Future<void> _addOrEdit(AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _TaskForm(existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context.read<AppState>().api.updateItem('pa/callemail', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('pa/callemail', result);
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _openDraft(Map<String, dynamic> r, AppLocalizations tr) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _DraftSheet(
        channel: _channel(r),
        draftFor: (cat) => _draftBody(tr, r, cat),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- build ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.paCeTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : () => _addOrEdit(tr),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.paCeAdd),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.paCeLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : _rows.isEmpty
                  ? _welcome(tr)
                  : _bodyView(tr, scheme),
    );
  }

  Widget _welcome(AppLocalizations tr) => StateMessage(
        icon: Icons.contact_phone_rounded,
        title: tr.paCeWelcomeTitle,
        message: tr.paCeWelcomeBody,
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(tr),
          icon: const Icon(Icons.add_rounded),
          label: Text(tr.paCeAdd),
        ),
      );

  Widget _bodyView(AppLocalizations tr, ColorScheme scheme) {
    final list = _ordered;
    return Column(children: [
      _countsBar(tr, scheme),
      _filterBar(tr),
      Expanded(
        child: list.isEmpty
            ? StateMessage(
                icon: Icons.filter_alt_off_rounded,
                title: tr.paCeNoMatchTitle,
                message: tr.paCeNoMatchBody,
                action: TextButton(
                  onPressed: () => setState(() {
                    _fChannel = null;
                    _hideDone = false;
                  }),
                  child: Text(tr.paCeClearFilters),
                ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                  itemBuilder: (_, i) => _card(list[i], tr, scheme),
                ),
              ),
      ),
    ]);
  }

  Widget _countsBar(AppLocalizations tr, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
        child: Row(children: [
          _stat(Icons.call_rounded, tr.paCeStatCalls('$_openCalls'), scheme),
          const SizedBox(width: Gap.sm),
          _stat(Icons.mail_outline_rounded, tr.paCeStatEmails('$_openEmails'), scheme),
          const SizedBox(width: Gap.sm),
          _stat(Icons.check_circle_outline_rounded, tr.paCeStatDone('$_doneCount'), scheme),
        ]),
      );

  Widget _stat(IconData icon, String text, ColorScheme scheme) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.sm),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
            ),
          ]),
        ),
      );

  Widget _filterBar(AppLocalizations tr) {
    Widget chip(String label, bool selected, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: Gap.sm),
          child: FilterChip(
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            selected: selected,
            onSelected: (_) => onTap(),
          ),
        );
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        children: [
          chip(tr.paCeFilterAll, _fChannel == null,
              () => setState(() => _fChannel = null)),
          chip(tr.paCeFilterCalls, _fChannel == _chCall,
              () => setState(() => _fChannel = _fChannel == _chCall ? null : _chCall)),
          chip(tr.paCeFilterEmails, _fChannel == _chEmail,
              () => setState(() => _fChannel = _fChannel == _chEmail ? null : _chEmail)),
          chip(tr.paCeHideDone, _hideDone,
              () => setState(() => _hideDone = !_hideDone)),
        ],
      ),
    );
  }

  Color _priorityColor(String p, ColorScheme scheme) {
    switch (p) {
      case _prHigh:
        return scheme.error;
      case _prLow:
        return scheme.onSurfaceVariant;
      default:
        return scheme.primary;
    }
  }

  String _priorityLabel(AppLocalizations tr, String p) {
    switch (p) {
      case _prHigh:
        return tr.paCePriorityHigh;
      case _prLow:
        return tr.paCePriorityLow;
      default:
        return tr.paCePriorityNormal;
    }
  }

  Widget _card(Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme) {
    final channel = _channel(r);
    final priority = _priority(r);
    final done = _status(r) == _stDone;
    final contact = (r['contact'] ?? '').toString();
    final subject = (r['subject'] ?? '').toString();
    final notes = (r['notes'] ?? '').toString().trim();

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(channel == _chCall ? Icons.call_rounded : Icons.mail_outline_rounded,
                size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(subject.isEmpty ? contact : subject,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      decoration: done ? TextDecoration.lineThrough : null,
                      color: done ? scheme.onSurfaceVariant : scheme.onSurface),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            _pill(_priorityLabel(tr, priority), _priorityColor(priority, scheme)),
          ]),
          if (contact.isNotEmpty && subject.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(tr.paCeWith(contact),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(notes,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.3),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ],
          const Divider(height: Gap.xl),
          Row(children: [
            TextButton.icon(
              onPressed: () => _openDraft(r, tr),
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text(tr.paCeDraftReply,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Spacer(),
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
          SizedBox(
            width: double.infinity,
            child: done
                ? OutlinedButton.icon(
                    onPressed: () => _toggleDone(r, tr),
                    icon: const Icon(Icons.undo_rounded, size: 18),
                    label: Text(tr.paCeMarkTodo),
                  )
                : FilledButton.icon(
                    onPressed: () => _toggleDone(r, tr),
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                    label: Text(tr.paCeMarkDone),
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _pill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );
}

/// Suggested-reply sheet: pick a category → see a DETERMINISTIC template draft,
/// editable + copy/share. Shows the honest "AI-generated — review" marker and a
/// "connect an AI key for a full AI reply" seam. Never sends.
class _DraftSheet extends StatefulWidget {
  final String channel;
  final String Function(String category) draftFor;
  const _DraftSheet({required this.channel, required this.draftFor});
  @override
  State<_DraftSheet> createState() => _DraftSheetState();
}

class _DraftSheetState extends State<_DraftSheet> {
  String _cat = _catAck;
  late final TextEditingController _body =
      TextEditingController(text: widget.draftFor(_catAck));

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  void _pick(String cat) {
    setState(() {
      _cat = cat;
      _body.text = widget.draftFor(cat);
    });
  }

  String _catLabel(AppLocalizations tr, String c) {
    switch (c) {
      case _catDecline:
        return tr.paCeCatDecline;
      case _catSchedule:
        return tr.paCeCatSchedule;
      case _catFollowup:
        return tr.paCeCatFollowup;
      default:
        return tr.paCeCatAcknowledge;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.paCeDraftTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          _marker(tr, scheme),
          const SizedBox(height: Gap.md),
          Text(tr.paCeChooseCategory, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.sm,
            children: _categories
                .map((c) => ChoiceChip(
                      label: Text(_catLabel(tr, c)),
                      selected: _cat == c,
                      onSelected: (_) => _pick(c),
                    ))
                .toList(),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _body,
            maxLines: 8,
            minLines: 5,
            decoration: InputDecoration(
              labelText: tr.paCeDraftEditable,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: Gap.md),
          _aiSeamCard(tr, scheme),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _body.text));
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
              child: FilledButton.icon(
                onPressed: () => Share.share(_body.text),
                icon: const Icon(Icons.share_rounded, size: 18),
                label: Text(tr.share),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(tr.paCeNeverSends,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, height: 1.3)),
        ]),
      ),
    );
  }

  Widget _marker(AppLocalizations tr, ColorScheme scheme) => Row(children: [
        Icon(Icons.info_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Expanded(
          child: Text(tr.paAiReviewMarker,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
        ),
      ]);

  Widget _aiSeamCard(AppLocalizations tr, ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr.paCeAiSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
              const SizedBox(height: 2),
              Text(tr.paCeAiSeamBody,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4)),
            ]),
          ),
        ]),
      );
}

/// Add / edit a call-or-email task.
class _TaskForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _TaskForm({this.existing});
  @override
  State<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<_TaskForm> {
  late final TextEditingController _contact =
      TextEditingController(text: widget.existing?['contact']?.toString() ?? '');
  late final TextEditingController _subject =
      TextEditingController(text: widget.existing?['subject']?.toString() ?? '');
  late final TextEditingController _notes =
      TextEditingController(text: widget.existing?['notes']?.toString() ?? '');
  late String _channel = _channels.contains((widget.existing?['channel'] ?? '').toString())
      ? widget.existing!['channel'].toString()
      : _chCall;
  late String _priority = _priorities.contains((widget.existing?['priority'] ?? '').toString())
      ? widget.existing!['priority'].toString()
      : _prNormal;

  @override
  void dispose() {
    _contact.dispose();
    _subject.dispose();
    _notes.dispose();
    super.dispose();
  }

  String _channelLabel(AppLocalizations tr, String c) =>
      c == _chEmail ? tr.paCeChannelEmail : tr.paCeChannelCall;

  String _priorityLabel(AppLocalizations tr, String p) {
    switch (p) {
      case _prHigh:
        return tr.paCePriorityHigh;
      case _prLow:
        return tr.paCePriorityLow;
      default:
        return tr.paCePriorityNormal;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final valid = _contact.text.trim().isNotEmpty || _subject.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.existing == null ? tr.paCeAdd : tr.paCeEdit,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          Text(tr.paCeChannelLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            for (final c in _channels)
              ChoiceChip(
                label: Text(_channelLabel(tr, c)),
                selected: _channel == c,
                onSelected: (_) => setState(() => _channel = c),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _contact,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: tr.paCeContactField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _subject,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.paCeSubjectField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          Text(tr.paCePriorityLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            for (final p in _priorities)
              ChoiceChip(
                label: Text(_priorityLabel(tr, p)),
                selected: _priority == p,
                onSelected: (_) => setState(() => _priority = p),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _notes,
            maxLines: 3,
            decoration: InputDecoration(
                labelText: tr.paCeNotesField,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true),
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
                onPressed: valid
                    ? () => Navigator.pop(context, <String, dynamic>{
                          'channel': _channel,
                          'contact': _contact.text.trim(),
                          'subject': _subject.text.trim(),
                          'priority': _priority,
                          'notes': _notes.text.trim(),
                          'status': (widget.existing?['status'] ?? _stTodo).toString(),
                        })
                    : null,
                child: Text(tr.save),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
