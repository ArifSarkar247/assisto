import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// "In progress" — everything still open: upcoming reminders and
/// unfinished to-dos, in one calm list.
class InProgressScreen extends StatelessWidget {
  const InProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final fmt = DateFormat('d MMM, h:mm a');

    Map<String, dynamic> data(Map<String, dynamic> m) =>
        (m['data'] as Map<String, dynamic>?) ?? const {};
    bool open(Map<String, dynamic> m) => data(m)['done'] != true;
    final reminders = app.reminders.items.where(open).toList();
    final todos = app.todos.items.where(open).toList();
    final empty = reminders.isEmpty && todos.isEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(t.inProgress)),
      body: empty
          ? _Empty(t: t)
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
              children: [
                if (reminders.isNotEmpty) ...[
                  _section(context, Icons.alarm_outlined, t.navReminders),
                  for (final r in reminders)
                    _tile(
                      context,
                      data(r)['title'] ?? '',
                      data(r)['due_at'] != null
                          ? fmt.format(
                              DateTime.tryParse(data(r)['due_at'])?.toLocal() ??
                                  DateTime.now())
                          : null,
                    ),
                ],
                if (todos.isNotEmpty) ...[
                  const SizedBox(height: Gap.md),
                  _section(context, Icons.checklist_outlined, t.navNotesTasks),
                  for (final td in todos)
                    _tile(context, data(td)['title'] ?? '',
                        data(td)['due_at'] != null
                            ? fmt.format(DateTime.tryParse(data(td)['due_at'])?.toLocal() ??
                                DateTime.now())
                            : null),
                ],
              ],
            ),
    );
  }

  Widget _section(BuildContext context, IconData icon, String label) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm, top: Gap.xs),
        child: Row(children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: Gap.sm),
          Text(label,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ]),
      );

  Widget _tile(BuildContext context, String title, String? sub) => Card(
        margin: const EdgeInsets.only(bottom: Gap.sm),
        child: ListTile(
          leading: const Icon(Icons.radio_button_unchecked, size: 20),
          title: Text(title),
          subtitle: sub == null ? null : Text(sub),
          visualDensity: VisualDensity.compact,
        ),
      );
}

class _Empty extends StatelessWidget {
  final AppLocalizations t;
  const _Empty({required this.t});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_outline, size: 56, color: scheme.primary),
          const SizedBox(height: Gap.md),
          Text(AppLocalizations.of(context).inprogAllClear,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(AppLocalizations.of(context).inprogNothingInProgress,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
