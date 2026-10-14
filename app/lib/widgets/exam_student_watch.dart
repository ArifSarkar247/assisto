import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Multi-student result watch (SPEC v2.1 §21, ADVANCED) — for a parent or a
/// teacher tracking several students at once.
///
/// We only store a label + roll/reg/board/exam per student so the watcher is
/// labelled right and the user can jump to the OFFICIAL site for each. No
/// result is ever stored, inferred, or fabricated — the card merely says how
/// many students are being watched and reminds that results live only on the
/// official board site.
///
/// Mirrors core.logic.exam.normalise_students / watch_summary.

/// One watched student (user-entered identifiers only — never a result).
class ExamStudent {
  String label;
  String roll;
  ExamStudent({this.label = '', this.roll = ''});

  bool get isBlank => label.trim().isEmpty && roll.trim().isEmpty;

  Map<String, String> toJson() => {
        'label': label.trim(),
        'roll': roll.trim(),
      };
}

class ExamStudentWatch extends StatelessWidget {
  final List<ExamStudent> students;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;
  final void Function(int index, String label, String roll) onChanged;

  const ExamStudentWatch({
    super.key,
    required this.students,
    required this.onAdd,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final count = students.where((s) => !s.isBlank).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < students.length; i++) ...[
        _StudentRow(
          key: ValueKey(students[i]),
          student: students[i],
          onChanged: (l, r) => onChanged(i, l, r),
          onRemove: students.length > 1 ? () => onRemove(i) : null,
        ),
        const SizedBox(height: Gap.xs),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: students.length >= 25 ? null : onAdd,
          icon: const Icon(Icons.person_add_alt, size: 18),
          label: Text(t.examAddStudent),
        ),
      ),
      if (count > 0) ...[
        const SizedBox(height: Gap.xs),
        Container(
          padding: const EdgeInsets.all(Gap.sm),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.groups_2_outlined,
                size: 16, color: scheme.onSecondaryContainer),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(t.examWatchSummary(count),
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: scheme.onSecondaryContainer)),
            ),
          ]),
        ),
      ],
    ]);
  }
}

class _StudentRow extends StatelessWidget {
  final ExamStudent student;
  final void Function(String label, String roll) onChanged;
  final VoidCallback? onRemove;

  const _StudentRow({
    super.key,
    required this.student,
    required this.onChanged,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Row(children: [
      Expanded(
        flex: 3,
        child: TextFormField(
          initialValue: student.label,
          decoration: InputDecoration(labelText: t.examStudentLabel, isDense: true),
          onChanged: (v) => onChanged(v, student.roll),
        ),
      ),
      const SizedBox(width: Gap.sm),
      Expanded(
        flex: 2,
        child: TextFormField(
          initialValue: student.roll,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: t.examFieldRoll, isDense: true),
          onChanged: (v) => onChanged(student.label, v),
        ),
      ),
      if (onRemove != null)
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: onRemove,
          tooltip: t.examRemoveStudent,
        ),
    ]);
  }
}
