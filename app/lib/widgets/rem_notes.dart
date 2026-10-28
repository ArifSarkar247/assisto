import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'bn_day_periods.dart' show appDateLocale;

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

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final newItem = TextEditingController();
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
                decoration: InputDecoration(labelText: t.notesBody)),
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

  if (saved == true &&
      (title.text.trim().isNotEmpty ||
          body.text.trim().isNotEmpty ||
          checklist.isNotEmpty)) {
    final payload = <String, dynamic>{
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

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      return AlertDialog(
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
    final payload = <String, dynamic>{
      'title': title.text.trim(),
      'priority': high ? 'high' : 'none',
      'due_at': due?.toUtc().toIso8601String(),
      'done': d['done'] ?? false,
    };
    if (item == null) {
      await app.todos.add(payload);
    } else {
      await app.todos.update(item, payload);
    }
  }
}
