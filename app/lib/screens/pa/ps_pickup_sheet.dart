import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../p3/assisto_sheet.dart' show addReminderForMe;
import '../../ps/ps_circle.dart';
import '../../ps/ps_extract.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/rn_bits.dart' show pickCircleMember;

/// pssec: "Pick up a task from a message". The user pastes a WhatsApp / SMS /
/// Messenger message; [psExtract] finds the date, time and kind ON THIS PHONE
/// (the message text is never uploaded). Nothing is saved until the user
/// checks the proposal and taps "Yes, add it". Returns true when added.
Future<bool?> showPsPickupSheet(BuildContext context, {String? initialText}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => PsPickupSheet(initialText: initialText),
  );
}

class PsPickupSheet extends StatefulWidget {
  const PsPickupSheet({super.key, this.initialText, this.now});
  final String? initialText;
  final DateTime? now; // tests pin the clock
  @override
  State<PsPickupSheet> createState() => _PsPickupSheetState();
}

class _PsPickupSheetState extends State<PsPickupSheet> {
  late final TextEditingController _msg =
      TextEditingController(text: widget.initialText ?? '');
  final _title = TextEditingController();
  final _who = TextEditingController();
  PsPickup? _found;
  PsKind _kind = PsKind.reminder;
  DateTime? _when;
  bool _dateOnly = true;
  Map<String, dynamic>? _person;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // A message handed in (e.g. shared from another app) is parsed at once.
    if ((widget.initialText ?? '').trim().isNotEmpty) _applyFind();
  }

  @override
  void dispose() {
    _msg.dispose();
    _title.dispose();
    _who.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    try {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final s = d?.text ?? '';
      if (s.isNotEmpty) {
        _msg.text = s;
        _find();
      }
    } catch (_) {} // best-effort: clipboard unavailable; the user can long-press paste
  }

  void _find() => setState(_applyFind);

  void _applyFind() {
    final p = psExtract(_msg.text, now: widget.now);
    _found = p;
    if (p == null) return;
    _kind = p.kind;
    _title.text = p.title;
    _when = p.when;
    _dateOnly = p.dateOnly;
    if (p.counterpart.isNotEmpty && _who.text.isEmpty) _who.text = p.counterpart;
  }

  Future<void> _pickWhen() async {
    final now = widget.now ?? DateTime.now();
    final base = _when ?? now.add(const Duration(hours: 1));
    final d = await showDatePicker(
        context: context,
        initialDate: base,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 5));
    if (d == null || !mounted) return;
    final tm = await showTimePicker(
        context: context,
        initialTime: _dateOnly
            ? const TimeOfDay(hour: 10, minute: 0)
            : TimeOfDay.fromDateTime(base));
    if (!mounted) return;
    setState(() {
      _when = DateTime(d.year, d.month, d.day, tm?.hour ?? 10, tm?.minute ?? 0);
      _dateOnly = false;
    });
  }

  Future<void> _pickPerson() async {
    final t = AppLocalizations.of(context);
    final r = await pickCircleMember(context, title: t.mbCirclePick);
    if (r == null || !mounted) return;
    final id = r['circle_id'] is int ? r['circle_id'] as int : int.tryParse('${r['circle_id']}');
    if (id == null) return;
    setState(() {
      _person = {'id': id, 'name': '${r['name'] ?? ''}'.trim()};
      _who.text = '${_person!['name']}';
    });
  }

  /// The date/time to save: a found day with no clock defaults to 10:00.
  DateTime? get _at {
    final w = _when;
    if (w == null) return null;
    return _dateOnly ? DateTime(w.year, w.month, w.day, 10) : w;
  }

  bool get _ready {
    if (_title.text.trim().isEmpty) return false;
    switch (_kind) {
      case PsKind.meeting:
      case PsKind.reminder:
        return _at != null;
      case PsKind.followup:
        return _who.text.trim().isNotEmpty;
    }
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    var ok = false;
    final title = _title.text.trim();
    final who = _who.text.trim();
    final circle = [if (_person != null && _person!['name'] == who) _person!];
    try {
      switch (_kind) {
        case PsKind.meeting:
          await api.createItem('pa_schedule', {
            'title': title,
            'kind': 'meeting',
            'start': _at!.toIso8601String(),
            'duration_min': 60,
            'place': '',
            'people': [if (who.isNotEmpty) who],
            'circle_people': circle,
            'note': '',
            'status': 'confirmed',
          });
          ok = true;
        case PsKind.followup:
          await api.createItem('pa/followups', {
            'title': title,
            'counterpart': who,
            'contact': '',
            'status': 'waiting',
            'nudge': 'off',
            'circle_people': circle,
            'due_at': _at?.toUtc().toIso8601String(),
          });
          ok = true;
        case PsKind.reminder:
          ok = await addReminderForMe(context, title, _at!);
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(content: Text(ok ? t.psecAdded : t.saveFailed)));
    if (ok) nav.pop(true);
  }

  String _kindLabel(AppLocalizations t, PsKind k) => switch (k) {
        PsKind.meeting => t.psecKindMeeting,
        PsKind.followup => t.psecKindFollowup,
        PsKind.reminder => t.psecKindReminder,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final f = _found;
    final now = widget.now ?? DateTime.now();
    final at = _at;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.psecPickupTitle,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_rounded, size: 16, color: cs.primary),
            const SizedBox(width: Gap.xs),
            Expanded(
                child: Text(t.psecStaysOnPhone,
                    style: TextStyle(color: cs.onSurfaceVariant))),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('ps-pickup-msg'),
            controller: _msg,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
                labelText: t.psecPasteHint, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            OutlinedButton.icon(
              key: const ValueKey('ps-pickup-paste'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _paste,
              icon: const Icon(Icons.content_paste_rounded),
              label: Text(t.psecPasteBtn),
            ),
            FilledButton.icon(
              key: const ValueKey('ps-pickup-find'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _find,
              icon: const Icon(Icons.manage_search_rounded),
              label: Text(t.psecFindBtn),
            ),
          ]),
          if (f != null) ...[
            const Divider(height: Gap.xl),
            Text(t.psecFoundTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (final k in PsKind.values)
                ChoiceChip(
                  key: ValueKey('ps-kind-${k.name}'),
                  label: Text(_kindLabel(t, k)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ]),
            const SizedBox(height: Gap.md),
            TextField(
              key: const ValueKey('ps-pickup-title'),
              controller: _title,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  labelText: t.psecFieldTitle, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.sm),
            ListTile(
              key: const ValueKey('ps-pickup-when'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_rounded),
              title: Text(at == null
                  ? t.psecNoDateFound
                  : psWhen(context, at, dateOnly: false)),
              subtitle: (at != null && at.isBefore(now))
                  ? Text(t.psecPastWarn, style: TextStyle(color: cs.error))
                  : null,
              trailing: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _pickWhen,
                  child: Text(t.psecPickDate)),
              onTap: _pickWhen,
            ),
            if (_kind != PsKind.reminder) ...[
              const SizedBox(height: Gap.sm),
              TextField(
                key: const ValueKey('ps-pickup-who'),
                controller: _who,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: t.psecFieldWho, border: const OutlineInputBorder()),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('ps-pickup-circle'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _pickPerson,
                  icon: const Icon(Icons.diversity_1_rounded),
                  label: Text(t.mbCirclePick),
                ),
              ),
            ],
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              key: const ValueKey('ps-pickup-add'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: (_ready && !_busy) ? _save : null,
              icon: const Icon(Icons.check_rounded),
              label: Text(t.psecConfirmAdd),
            ),
          ],
        ]),
      ),
    );
  }
}
