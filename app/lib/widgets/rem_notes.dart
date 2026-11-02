import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'bn_day_periods.dart' show appDateLocale;
import 'package:assisto/widgets/app_sheet.dart';
import 'package:share_plus/share_plus.dart';
import '../api.dart' show ApiException;
import '../screens/vault_screen.dart' show VaultScreen;
import 'reminders_nlp.dart' show RecurrenceRule, nextOccurrence;
import 'rn_bits.dart'; // remnotes
import 'voice_input.dart' show VoiceDictation, VoiceMicButton;

/// Advanced NOTES + TO-DO building blocks (#22, SPEC v2.1 §21).
///
/// Advanced depth vs Google Keep / Microsoft To Do / Samsung Notes:
///  - A note is no longer a title+body blob: it carries an ordered CHECKLIST
///    (tick items off inside the note), a PIN, free-form TAGS, a PRIORITY flag,
///    an optional DUE DATE (so it also lands on the combined calendar), and a
///    LINK to a reminder — one tap turns "buy rice, dal, oil" into a reminder
///    that will actually nag you.
///  - To-dos gain the same priority + due-date, so a task can be scheduled and
///    shown on the agenda alongside reminders.
///  - All editing lives in these reusable sheets so the two screens stay thin.
///  - Bilingual, WCAG (icon+label, 44px targets), zero Bangla glyph literals.

// ---------------------------------------------------------------- note editor
/// Full note editor: title, body, checklist, tags, priority, pin, due date, and
/// an optional "turn into a reminder" link. Reuses the reminders repo for the
/// linked reminder so the calendar and reminder list pick it up automatically.
Future<void> editNote(BuildContext context, {Map<String, dynamic>? item}) async {
  final t = AppLocalizations.of(context);
  final app = context.read<AppState>();
  final d = (item?['data'] as Map<String, dynamic>?) ?? {};
  final title = TextEditingController(text: (d['title'] ?? '').toString());
  final body = TextEditingController(text: (d['body'] ?? '').toString());
  final tags = TextEditingController(
      text: (d['tags'] is List ? (d['tags'] as List).join(', ') : '').toString());
  // checklist items: [{text, done}]
  final checklist = <Map<String, dynamic>>[
    for (final c in (d['checklist'] is List ? d['checklist'] as List : []))
      {'text': (c['text'] ?? '').toString(), 'done': c['done'] == true},
  ];
  bool pinned = d['pinned'] == true;
  bool high = (d['priority'] ?? 'none') == 'high';
  DateTime? due = d['due_at'] != null
      ? DateTime.tryParse(d['due_at'])?.toLocal()
      : null;
  // remnotes: colour + vault attachments (stored on the server now)
  String color = kNoteColors.contains(d['color']) ? d['color'] as String : '';
  final attachments = <Map<String, dynamic>>[
    for (final a in (d['attachments'] is List ? d['attachments'] as List : []))
      if (a is Map && a['doc_id'] != null)
        {'doc_id': a['doc_id'], 'title': '${a['title'] ?? ''}'},
  ];
  final voice = VoiceDictation();
  final newItem = TextEditingController();

  final saved = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      // remnotes: the "add item" field lives OUTSIDE the builder (it was
      // re-created on every tick, dropping half-typed text)
      return Padding(
        padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
            Gap.lg + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                child: Text(item == null ? t.notesNewNote : t.notesEditNote,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              IconButton(
                tooltip: pinned ? t.notesUnpin : t.notesPin,
                icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    color: pinned ? Brand.warning : null),
                onPressed: () => setS(() => pinned = !pinned),
              ),
              IconButton(
                tooltip: high ? t.remPriorityClear : t.remPrioritySet,
                icon: Icon(high ? Icons.flag_rounded : Icons.outlined_flag_rounded,
                    color: high ? Brand.warning : null),
                onPressed: () => setS(() => high = !high),
              ),
            ]),
            TextField(
                controller: title,
                autofocus: item == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: t.title)),
            const SizedBox(height: Gap.sm),
            TextField(
                controller: body,
                maxLines: 4,
                minLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: t.notesBody,
                    // remnotes: speak the note (phone's own speech-to-text;
                    // no audio is kept)
                    suffixIcon: VoiceMicButton(voice: voice, input: body))),
            const SizedBox(height: Gap.sm),
            // ---- colour ----
            Align(
              alignment: Alignment.centerLeft,
              child: Text(t.rnColor, style: Theme.of(ctx).textTheme.labelLarge),
            ),
            NoteColorPicker(value: color, onChanged: (v) => setS(() => color = v)),
            const SizedBox(height: Gap.md),
            // ---- checklist ----
            Align(
              alignment: Alignment.centerLeft,
              child: Text(t.notesChecklist,
                  style: Theme.of(ctx).textTheme.labelLarge),
            ),
            for (var i = 0; i < checklist.length; i++)
              Row(children: [
                Checkbox(
                  value: checklist[i]['done'] == true,
                  onChanged: (v) =>
                      setS(() => checklist[i]['done'] = v ?? false),
                ),
                Expanded(
                  child: Text(
                    checklist[i]['text'].toString(),
                    style: checklist[i]['done'] == true
                        ? TextStyle(
                            decoration: TextDecoration.lineThrough,
                            color: Theme.of(ctx).disabledColor)
                        : null,
                  ),
                ),
                IconButton(
                  tooltip: t.delete,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => setS(() => checklist.removeAt(i)),
                ),
              ]),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: newItem,
                  decoration: InputDecoration(
                      isDense: true, hintText: t.notesChecklistAdd),
                  onSubmitted: (v) {
                    if (v.trim().isEmpty) return;
                    setS(() {
                      checklist.add({'text': v.trim(), 'done': false});
                      newItem.clear();
                    });
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_rounded),
                onPressed: () {
                  if (newItem.text.trim().isEmpty) return;
                  setS(() {
                    checklist.add({'text': newItem.text.trim(), 'done': false});
                    newItem.clear();
                  });
                },
              ),
            ]),
            const SizedBox(height: Gap.sm),
            TextField(
                controller: tags,
                decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.label_outline_rounded, size: 18),
                    labelText: t.notesTags,
                    helperText: t.notesTagsHint)),
            const SizedBox(height: Gap.sm),
            // ---- vault papers (remnotes) ----
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                for (final a in attachments)
                  InputChip(
                    avatar: const Icon(Icons.description_rounded, size: 18),
                    label: Text(a['title'].toString()),
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => const VaultScreen())),
                    deleteButtonTooltipMessage: t.rnAttachRemove,
                    onDeleted: () => setS(() => attachments.remove(a)),
                  ),
                if (attachments.length < 10)
                  ActionChip(
                    key: const ValueKey('rn-attach'),
                    avatar: const Icon(Icons.attach_file_rounded, size: 18),
                    label: Text(t.rnAttach),
                    onPressed: () async {
                      final picked = await pickVaultDocs(ctx,
                          already: {for (final a in attachments) a['doc_id']});
                      if (picked != null) setS(() => attachments.addAll(picked));
                    },
                  ),
              ]),
            ),
            const SizedBox(height: Gap.sm),
            // ---- due date (puts the note on the calendar) ----
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event_rounded, size: 18),
                  label: Text(due == null
                      ? t.notesSetDue
                      : DateFormat('d MMM, h:mm a', appDateLocale(context)).format(due!)),
                  onPressed: () async {
                    final date = await showDatePicker(
                        context: ctx,
                        initialDate: due ?? DateTime.now(),
                        firstDate:
                            DateTime.now().subtract(const Duration(days: 1)),
                        lastDate:
                            DateTime.now().add(const Duration(days: 3650)));
                    if (date == null) return;
                    final tm = await showTimePicker(
                        context: ctx,
                        initialTime:
                            TimeOfDay.fromDateTime(due ?? DateTime.now()));
                    setS(() => due = DateTime(date.year, date.month, date.day,
                        tm?.hour ?? 9, tm?.minute ?? 0));
                  },
                ),
              ),
              if (due != null)
                IconButton(
                    tooltip: t.delete,
                    onPressed: () => setS(() => due = null),
                    icon: const Icon(Icons.clear_rounded)),
            ]),
            const SizedBox(height: Gap.md),
            Row(children: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.cancel)),
              const Spacer(),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.save)),
            ]),
          ]),
        ),
      );
    }),
  );

  try {
    voice.dispose();
  } catch (_) {}
  // a typed-but-not-added checklist line is kept, not lost
  if (newItem.text.trim().isNotEmpty) {
    checklist.add({'text': newItem.text.trim(), 'done': false});
  }
  if (saved == true &&
      (title.text.trim().isNotEmpty ||
          body.text.trim().isNotEmpty ||
          checklist.isNotEmpty)) {
    final payload = <String, dynamic>{
      'color': color,
      'attachments': attachments,
      'title': title.text.trim(),
      'body': body.text.trim(),
      'checklist': checklist,
      'tags': tags.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      'priority': high ? 'high' : 'none',
      'pinned': pinned,
      'due_at': due?.toUtc().toIso8601String(),
    };
    if (item == null) {
      await app.notes.add(payload);
    } else {
      await app.notes.update(item, payload);
    }
  }
}

/// Turn a note into a reminder: copy its title (and first open checklist line)
/// into the reminders store so it fires. Reuses the reminders repo + scheduler.
Future<void> noteToReminder(
    BuildContext context, Map<String, dynamic> note) async {
  final t = AppLocalizations.of(context);
  final app = context.read<AppState>();
  final d = note['data'] as Map<String, dynamic>;
  final title = (d['title'] ?? '').toString().isNotEmpty
      ? (d['title']).toString()
      : (d['body'] ?? '').toString();
  final due = await showDatePicker(
    context: context,
    initialDate: DateTime.now().add(const Duration(days: 1)),
    firstDate: DateTime.now(),
    lastDate: DateTime.now().add(const Duration(days: 3650)),
  );
  if (due == null || !context.mounted) return;
  final tm = await showTimePicker(
      context: context, initialTime: const TimeOfDay(hour: 9, minute: 0));
  final when = DateTime(
      due.year, due.month, due.day, tm?.hour ?? 9, tm?.minute ?? 0);
  final created = await app.reminders.add({
    'title': title,
    'notes': (d['body'] ?? '').toString(),
    'due_at': when.toUtc().toIso8601String(),
    'recurrence': 'none',
    'date_only': tm == null,
    'done': false,
    'source': 'note',
    'note_local_id': note['localId'],
  });
  // link back from the note to the reminder it spawned
  final lid = created['localId'];
  if (lid != null) {
    await app.notes.update(note, {'reminder_local_id': lid});
    // remmeter: the alarm follows the reminders repo (AppState reconcile)
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.notesLinkedToReminder)));
  }
}

// ---------------------------------------------------------------- todo editor
/// Advanced to-do editor: title, priority flag, optional due date (so the task
/// shows on the calendar and can be rescheduled there).
Future<void> editTodo(BuildContext context, {Map<String, dynamic>? item}) async {
  final t = AppLocalizations.of(context);
  final app = context.read<AppState>();
  final d = (item?['data'] as Map<String, dynamic>?) ?? {};
  final title = TextEditingController(text: (d['title'] ?? '').toString());
  bool high = (d['priority'] ?? 'none') == 'high';
  DateTime? due = d['due_at'] != null
      ? DateTime.tryParse(d['due_at'])?.toLocal()
      : null;
  // remnotes: repeating to-dos (TickTick / To Do have them)
  String freq = d['recurrence_rule'] is Map
      ? '${(d['recurrence_rule'] as Map)['freq'] ?? 'none'}'
      : 'none';
  if (!const ['daily', 'weekly', 'monthly', 'yearly'].contains(freq)) freq = 'none';

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      return AlertDialog(
        scrollable: true, // 200% text / keyboard
        title: Text(item == null ? t.notesNewTask : t.notesEditTask),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: title,
              autofocus: item == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: t.notesTaskField)),
          const SizedBox(height: Gap.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.remPriorityHigh),
            secondary: Icon(high ? Icons.flag_rounded : Icons.outlined_flag_rounded,
                color: high ? Brand.warning : null),
            value: high,
            onChanged: (v) => setS(() => high = v),
          ),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(due == null
                    ? t.notesSetDue
                    : DateFormat('d MMM, h:mm a', appDateLocale(context)).format(due!)),
                onPressed: () async {
                  final date = await showDatePicker(
                      context: ctx,
                      initialDate: due ?? DateTime.now(),
                      firstDate:
                          DateTime.now().subtract(const Duration(days: 1)),
                      lastDate: DateTime.now().add(const Duration(days: 3650)));
                  if (date == null) return;
                  final tm = await showTimePicker(
                      context: ctx,
                      initialTime:
                          TimeOfDay.fromDateTime(due ?? DateTime.now()));
                  setS(() => due = DateTime(date.year, date.month, date.day,
                      tm?.hour ?? 9, tm?.minute ?? 0));
                },
              ),
            ),
            if (due != null)
              IconButton(
                  tooltip: t.delete,
                  onPressed: () => setS(() => due = null),
                  icon: const Icon(Icons.clear_rounded)),
          ]),
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<String>(
            key: const ValueKey('rn-todo-repeat'),
            initialValue: freq,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.remRecurrence),
            items: [
              DropdownMenuItem(value: 'none', child: Text(t.remRecurNone)),
              DropdownMenuItem(value: 'daily', child: Text(t.remRecurDaily)),
              DropdownMenuItem(value: 'weekly', child: Text(t.remRecurWeekly)),
              DropdownMenuItem(value: 'monthly', child: Text(t.remRecurMonthly)),
              DropdownMenuItem(value: 'yearly', child: Text(t.remRecurYearly)),
            ],
            onChanged: (v) => setS(() => freq = v ?? 'none'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
        ],
      );
    }),
  );

  if (saved == true && title.text.trim().isNotEmpty) {
    if (freq != 'none' && due == null) {
      final n = DateTime.now();
      due = DateTime(n.year, n.month, n.day, 9);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.rnTodoRepeatNeedsDate)));
      }
    }
    final payload = <String, dynamic>{
      'title': title.text.trim(),
      'priority': high ? 'high' : 'none',
      'due_at': due?.toUtc().toIso8601String(),
      'done': d['done'] ?? false,
      'recurrence_rule': todoRule(freq, due),
    };
    if (item == null) {
      await app.todos.add(payload);
    } else {
      await app.todos.update(item, payload);
    }
  }
}

// ---------------------------------------------------------------- remnotes
/// The stored repeat rule for a to-do ({} = no repeat), in the reminders'
/// shape so one engine ([nextOccurrence]) serves both.
Map<String, dynamic> todoRule(String freq, DateTime? due) {
  if (freq == 'none' || due == null) return <String, dynamic>{};
  return RecurrenceRule(
    freq: freq,
    weekday: freq == 'weekly' ? due.weekday - 1 : null,
    dayOfMonth: freq == 'monthly' ? due.day : null,
    month: freq == 'yearly' ? due.month : null,
    time: '${due.hour.toString().padLeft(2, '0')}:'
        '${due.minute.toString().padLeft(2, '0')}',
  ).toJson();
}

/// Ticking a to-do: a repeating one moves to its next date and stays open
/// (returns that date); otherwise null (= plain done).
DateTime? todoNextDue(Map<String, dynamic> d, {DateTime? now}) {
  final raw = d['recurrence_rule'];
  if (raw is! Map || raw['freq'] == null) return null;
  final due = d['due_at'] != null ? DateTime.tryParse('${d['due_at']}')?.toLocal() : null;
  if (due == null) return null;
  int? i(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}');
  final rule = RecurrenceRule(
    freq: '${raw['freq']}',
    interval: i(raw['interval']) ?? 1,
    weekday: i(raw['weekday']),
    dayOfMonth: i(raw['day_of_month']),
    month: i(raw['month']),
    time: raw['time'] as String?,
  );
  final at = now ?? DateTime.now();
  // the next occurrence after BOTH now and the current due date
  final after = due.isAfter(at) ? due : at;
  return nextOccurrence(due, rule, after: after);
}

/// Pick papers from the Vault to attach to a note (the vault's own list;
/// the server keeps only the caller's own documents).
Future<List<Map<String, dynamic>>?> pickVaultDocs(BuildContext context,
    {Set<Object?> already = const {}}) {
  return showAppSheet<List<Map<String, dynamic>>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _VaultPick(already: already),
  );
}

class _VaultPick extends StatefulWidget {
  const _VaultPick({required this.already});
  final Set<Object?> already;
  @override
  State<_VaultPick> createState() => _VaultPickState();
}

class _VaultPickState extends State<_VaultPick> {
  List<Map<String, dynamic>>? _docs;
  bool _failed = false;
  final Set<int> _on = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final l = await context.read<AppState>().api.listDocuments();
      if (mounted) setState(() => _docs = l);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final docs = _docs;
    Widget body;
    if (_failed) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.rnLoadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
      ]);
    } else if (docs == null) {
      body = const Padding(
          padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()));
    } else if (docs.isEmpty) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.rnAttachEmpty, key: const ValueKey('rn-vault-empty'), textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          onPressed: () {
            Navigator.pop(context);
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VaultScreen()));
          },
          icon: const Icon(Icons.folder_rounded),
          label: Text(t.rnAttachOpen),
        ),
      ]);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        for (final doc in docs)
          if (doc['id'] is int && !widget.already.contains(doc['id']))
            CheckboxListTile(
              key: ValueKey('rn-vault-${doc['id']}'),
              value: _on.contains(doc['id']),
              title: Text('${doc['title'] ?? ''}'),
              secondary: const Icon(Icons.description_rounded),
              onChanged: (v) => setState(() =>
                  v == true ? _on.add(doc['id'] as int) : _on.remove(doc['id'])),
            ),
      ]);
    }
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
          key: const ValueKey('rn-vault-attach'),
          onPressed: _on.isEmpty
              ? null
              : () => Navigator.pop(context, [
                    for (final doc in docs ?? const <Map<String, dynamic>>[])
                      if (_on.contains(doc['id']))
                        {'doc_id': doc['id'], 'title': '${doc['title'] ?? ''}'},
                  ]),
          child: Text(t.rnAttach),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.rnAttach,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.md),
        body,
      ]),
    );
  }
}

/// The note as plain text (title, body, checklist with ticks, labels).
String noteAsText(Map<String, dynamic> d) {
  final b = StringBuffer();
  final title = '${d['title'] ?? ''}'.trim();
  final body = '${d['body'] ?? ''}'.trim();
  if (title.isNotEmpty) b.writeln(title);
  if (body.isNotEmpty) b.writeln(body);
  final cl = d['checklist'] is List ? d['checklist'] as List : const [];
  for (final c in cl) {
    if (c is! Map) continue;
    b.writeln('${c['done'] == true ? '☑' : '☐'} ${c['text'] ?? ''}');
  }
  return b.toString().trim();
}

/// Share a note: to one My Circle member (a copy in their notes) or out as
/// text (WhatsApp / SMS / anything).
Future<void> shareNote(BuildContext context, Map<String, dynamic> note) async {
  final t = AppLocalizations.of(context);
  final choice = await showAppSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          key: const ValueKey('rn-share-circle'),
          leading: const Icon(Icons.people_alt_rounded),
          title: Text(t.rnShareCircle),
          subtitle: Text(t.rnShareCircleSub),
          onTap: () => Navigator.pop(ctx, 'circle'),
        ),
        ListTile(
          key: const ValueKey('rn-share-text'),
          leading: const Icon(Icons.share_rounded),
          title: Text(t.rnShareOther),
          onTap: () => Navigator.pop(ctx, 'text'),
        ),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  final d = note['data'] as Map<String, dynamic>;
  if (choice == 'text') {
    try {
      await Share.share(noteAsText(d));
    } catch (_) {}
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final sid = note['serverId'];
  if (sid is! int) {
    messenger.showSnackBar(SnackBar(content: Text(t.rnShareNeedsSync)));
    return;
  }
  final m = await pickCircleMember(context,
      title: t.rnShareCircle, subtitle: t.rnShareCircleSub);
  if (m == null || !context.mounted) return;
  try {
    await context
        .read<AppState>()
        .api
        .postJson('/notes/$sid/share/', {'circle_id': m['circle_id']});
    messenger.showSnackBar(
        SnackBar(content: Text(t.rnShareSent('${m['name'] ?? ''}'))));
  } catch (e) {
    messenger.showSnackBar(SnackBar(
        content: Text(e is ApiException && e.message.isNotEmpty
            ? e.message
            : t.rnLoadFailed)));
  }
}
