import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// DOCTOR APPOINTMENT / SERIAL TRACKER — ADVANCED (#187, SPEC v2.1 §20).
///
/// A personal appointment book for doctor visits. You record each appointment —
/// doctor, specialty, hospital/chamber, date & time, the SERIAL NUMBER the
/// chamber gave you, a status and notes — and the tracker splits them into
/// UPCOMING and PAST, flags which are reminder-due, and never loses a record.
///
/// It is a TRACKER, not medical advice and not a booking engine. A standing
/// note keeps that honest. LIVE serial-booking through a healthcare partner (so
/// the chamber's queue and the app stay in sync) is a DOCUMENTED, KEY-GATED
/// SEAM: the booking-partner key is absent, so the screen shows an honest
/// "connect a booking partner" card and NEVER fabricates a booking or serial —
/// serial numbers only ever come from what the user typed from their own slip.
/// Reminders are COMPUTED here (reminder-due badge) but SENDING them is a
/// documented seam wired to the existing messaging integrations, not fired here.
///
/// All logic mirrors backend/core/logic/doctor_serial.py VERBATIM (upcoming/past
/// bucketing, derived 'missed', reminder-due within a 24h window from a passed-in
/// `now`). ZERO Bangla literals — every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('doctor/appointments') → [{id, doctor, specialty, place, date,
///                                         time, serial, status, notes, created}]
/// create/update/deleteItem on the same path; one flexible per-user JSON
/// collection.
class DoctorSerialScreen extends StatefulWidget {
  const DoctorSerialScreen({super.key});
  @override
  State<DoctorSerialScreen> createState() => _DoctorSerialScreenState();
}

const String _apptsPath = 'doctor/appointments';

// Stable status keys (mirror STATUSES). 'missed' is derived, never stored.
const List<String> _statuses = ['booked', 'done', 'cancelled'];

// Common specialty keys (mirror specialty_label). 'other' lets free text stand.
const List<String> _specialties = [
  'general',
  'medicine',
  'cardiology',
  'dental',
  'gyne',
  'child',
  'ortho',
  'skin',
  'eye',
  'ent',
  'other',
];

class _DoctorSerialScreenState extends State<DoctorSerialScreen> {
  List<Map<String, dynamic>> _appts = [];
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
    final api = context.read<AppState>().api;
    try {
      _appts = await api.listItems(_apptsPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _add() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _apptSheet(context, null);
    if (res == null) return;
    try {
      await api.createItem(_apptsPath, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _apptSheet(context, row);
    if (res == null) return;
    try {
      await api.updateItem(_apptsPath, row['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok = await _confirm(context, tr.doctorDeleteTitle, tr.doctorDeleteBody);
    if (ok != true) return;
    try {
      await api.deleteItem(_apptsPath, row['id'] as int);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _setStatus(Map<String, dynamic> row, String status) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    try {
      await api.updateItem(_apptsPath, row['id'] as int, {'status': status});
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.doctorSerialTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.doctorSerialTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.doctorLoadError),
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr.retry),
          ),
        ),
      );
    }

    final now = DateTime.now(); // ONLY time input, read once per build.
    final org = _DCore.organise(_appts, now);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.doctorSerialTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: tr.doctorTabUpcoming),
              Tab(text: tr.doctorTabPast),
            ],
          ),
        ),
        floatingActionButton: org.upcoming.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: _add,
                icon: const Icon(Icons.add_rounded),
                label: Text(tr.doctorAddAppt),
              ),
        body: TabBarView(children: [
          _UpcomingTab(
            org: org,
            onAdd: _add,
            onEdit: _edit,
            onDelete: _delete,
            onStatus: _setStatus,
          ),
          _PastTab(
            org: org,
            onEdit: _edit,
            onDelete: _delete,
            onStatus: _setStatus,
          ),
        ]),
      ),
    );
  }
}

// ----------------------------------------------------------- upcoming tab
class _UpcomingTab extends StatelessWidget {
  final _DOrg org;
  final VoidCallback onAdd;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(Map<String, dynamic>) onDelete;
  final void Function(Map<String, dynamic>, String) onStatus;
  const _UpcomingTab({
    required this.org,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    if (org.upcoming.isEmpty) {
      return StateMessage(
        icon: Icons.event_available_rounded,
        title: tr.doctorUpcomingWelcomeTitle,
        message: tr.doctorUpcomingWelcomeBody,
        action: FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
          label: Text(tr.doctorAddAppt),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
      children: [
        if (org.remindersDue > 0) _reminderBanner(context, tr, org.remindersDue),
        _trackerNote(context, tr),
        const SizedBox(height: Gap.sm),
        _bookingSeamCard(context, tr),
        const SizedBox(height: Gap.md),
        ...org.upcoming.map((a) => _ApptCard(
              appt: a,
              onEdit: () => onEdit(a.raw),
              onDelete: () => onDelete(a.raw),
              onStatus: (s) => onStatus(a.raw, s),
            )),
      ],
    );
  }

  Widget _reminderBanner(BuildContext context, AppLocalizations tr, int n) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(Icons.notifications_active_rounded,
            color: scheme.onPrimaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(tr.doctorReminderDue('$n'),
              style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------------- past tab
class _PastTab extends StatelessWidget {
  final _DOrg org;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(Map<String, dynamic>) onDelete;
  final void Function(Map<String, dynamic>, String) onStatus;
  const _PastTab({
    required this.org,
    required this.onEdit,
    required this.onDelete,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    if (org.past.isEmpty) {
      return StateMessage(
        icon: Icons.history_rounded,
        title: tr.doctorPastWelcomeTitle,
        message: tr.doctorPastWelcomeBody,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
      children: [
        ...org.past.map((a) => _ApptCard(
              appt: a,
              onEdit: () => onEdit(a.raw),
              onDelete: () => onDelete(a.raw),
              onStatus: (s) => onStatus(a.raw, s),
            )),
      ],
    );
  }
}

// ----------------------------------------------------------- appointment card
class _ApptCard extends StatelessWidget {
  final _DAppt appt;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<String> onStatus;
  const _ApptCard({
    required this.appt,
    required this.onEdit,
    required this.onDelete,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = _statusColor(context, appt.derived);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(Icons.medical_services_rounded,
                    color: scheme.onPrimaryContainer, size: 20),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(appt.doctor,
                        style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                    if (appt.specialty.isNotEmpty)
                      Text(_specialtyLabel(tr, appt.specialty),
                          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') {
                    onEdit();
                  } else if (v == 'delete') {
                    onDelete();
                  } else {
                    onStatus(v);
                  }
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(value: 'done', child: Text(tr.doctorMarkDone)),
                  PopupMenuItem(
                      value: 'cancelled', child: Text(tr.doctorMarkCancelled)),
                  PopupMenuItem(value: 'booked', child: Text(tr.doctorMarkBooked)),
                  const PopupMenuDivider(),
                  PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                  PopupMenuItem(value: 'delete', child: Text(tr.delete)),
                ],
              ),
            ]),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.md,
              runSpacing: Gap.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _statusPill(context, appt.derived, color),
                if (appt.reminderDue)
                  _reminderPill(context, tr),
                if (appt.whenLabel.isNotEmpty)
                  _meta(context, Icons.schedule_rounded, appt.whenLabel),
                if (appt.place.isNotEmpty)
                  _meta(context, Icons.local_hospital_rounded, appt.place),
                if (appt.serial.isNotEmpty)
                  _meta(context, Icons.confirmation_number_rounded,
                      tr.doctorSerialNo(appt.serial)),
              ],
            ),
            if (appt.notes.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(appt.notes,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, height: 1.3)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusPill(BuildContext context, String status, Color color) {
    final tr = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(_statusLabel(tr, status),
          style: AType.labelSmall.copyWith(fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _reminderPill(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.notifications_active_rounded,
          size: 14, color: scheme.primary),
      const SizedBox(width: Gap.xs),
      Text(tr.doctorSoon,
          style: AType.labelSmall.copyWith(fontWeight: FontWeight.w700,
              color: scheme.primary)),
    ]);
  }

  Widget _meta(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: scheme.onSurfaceVariant),
      const SizedBox(width: Gap.xs),
      Flexible(
        child: Text(text,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ),
    ]);
  }
}

// ----------------------------------------------------------- shared cards
Widget _trackerNote(BuildContext context, AppLocalizations tr) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    color: scheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(tr.doctorTrackerNote,
              style:
                  AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ]),
    ),
  );
}

// Honest key-gated LIVE-booking seam. The booking-partner key is absent, so we
// show "connect a booking partner" and never fabricate a serial/booking.
Widget _bookingSeamCard(BuildContext context, AppLocalizations tr) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(Icons.link_off_rounded, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.doctorBookingSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xxs),
              Text(tr.doctorBookingSeamBody,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ]),
    ),
  );
}

// ----------------------------------------------------------- status helpers
String _statusLabel(AppLocalizations tr, String status) {
  switch (status) {
    case 'done':
      return tr.doctorStatusDone;
    case 'cancelled':
      return tr.doctorStatusCancelled;
    case 'missed':
      return tr.doctorStatusMissed;
    default:
      return tr.doctorStatusBooked;
  }
}

Color _statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  switch (status) {
    case 'done':
      return scheme.primary;
    case 'cancelled':
      return scheme.onSurfaceVariant;
    case 'missed':
      return scheme.error;
    default:
      return scheme.secondary;
  }
}

String _specialtyLabel(AppLocalizations tr, String key) {
  switch (key) {
    case 'general':
      return tr.doctorSpecGeneral;
    case 'medicine':
      return tr.doctorSpecMedicine;
    case 'cardiology':
      return tr.doctorSpecCardiology;
    case 'dental':
      return tr.doctorSpecDental;
    case 'gyne':
      return tr.doctorSpecGyne;
    case 'child':
      return tr.doctorSpecChild;
    case 'ortho':
      return tr.doctorSpecOrtho;
    case 'skin':
      return tr.doctorSpecSkin;
    case 'eye':
      return tr.doctorSpecEye;
    case 'ent':
      return tr.doctorSpecEnt;
    case 'other':
      return tr.doctorSpecOther;
    default:
      return key; // free-text specialty echoed verbatim
  }
}

// ----------------------------------------------------------- appointment sheet
Future<Map<String, dynamic>?> _apptSheet(
    BuildContext context, Map<String, dynamic>? existing) {
  final tr = AppLocalizations.of(context);
  final doctorC =
      TextEditingController(text: (existing?['doctor'] ?? '').toString());
  String specialty = (existing?['specialty'] ?? '').toString();
  final customSpecC = TextEditingController(
      text: _specialties.contains(specialty) ? '' : specialty);
  if (!_specialties.contains(specialty)) {
    specialty = specialty.isEmpty ? 'general' : 'other';
  }
  final placeC =
      TextEditingController(text: (existing?['place'] ?? '').toString());
  final serialC =
      TextEditingController(text: (existing?['serial'] ?? '').toString());
  final notesC =
      TextEditingController(text: (existing?['notes'] ?? '').toString());
  String status = (existing?['status'] ?? 'booked').toString();
  if (!_statuses.contains(status)) status = 'booked';
  DateTime? date = _DCore.asDate(existing?['date']);
  TimeOfDay? time = _DCore.asTime(existing?['time']);

  String d(DateTime x) =>
      '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
  String t(TimeOfDay x) =>
      '${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';

  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(existing == null ? tr.doctorAddAppt : tr.doctorEditAppt,
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: doctorC,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.doctorName,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              DropdownButtonFormField<String>(
                initialValue: specialty,
                isExpanded: true,
                decoration: InputDecoration(
                    labelText: tr.doctorSpecialty,
                    border: const OutlineInputBorder()),
                items: [
                  for (final s in _specialties)
                    DropdownMenuItem(
                        value: s, child: Text(_specialtyLabel(tr, s))),
                ],
                onChanged: (v) => setSheet(() => specialty = v ?? 'general'),
              ),
              if (specialty == 'other') ...[
                const SizedBox(height: Gap.md),
                TextField(
                  controller: customSpecC,
                  decoration: InputDecoration(
                      labelText: tr.doctorSpecialtyCustom,
                      border: const OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: Gap.md),
              TextField(
                controller: placeC,
                decoration: InputDecoration(
                    labelText: tr.doctorPlace,
                    helperText: tr.doctorPlaceHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Row(children: [
                Expanded(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_rounded),
                    title: Text(tr.doctorDate),
                    subtitle: Text(date == null ? tr.doctorPickDate : d(date!)),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: date ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setSheet(() => date = picked);
                    },
                  ),
                ),
              ]),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_rounded),
                title: Text(tr.doctorTime),
                subtitle: Text(time == null ? tr.doctorTimeOptional : t(time!)),
                trailing: TextButton(
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: ctx,
                      initialTime: time ?? TimeOfDay.now(),
                    );
                    if (picked != null) setSheet(() => time = picked);
                  },
                  child: Text(tr.doctorPickTime),
                ),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: serialC,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(
                    labelText: tr.doctorSerial,
                    helperText: tr.doctorSerialHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              DropdownButtonFormField<String>(
                initialValue: status,
                isExpanded: true,
                decoration: InputDecoration(
                    labelText: tr.doctorStatus,
                    border: const OutlineInputBorder()),
                items: [
                  for (final s in _statuses)
                    DropdownMenuItem(
                        value: s, child: Text(_statusLabel(tr, s))),
                ],
                onChanged: (v) => setSheet(() => status = v ?? 'booked'),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: notesC,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.doctorNotes,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (doctorC.text.trim().isEmpty) {
                      ScaffoldMessenger.of(ctx)
                        ..clearSnackBars()
                        ..showSnackBar(
                            SnackBar(content: Text(tr.doctorNameRequired)));
                      return;
                    }
                    if (date == null) {
                      ScaffoldMessenger.of(ctx)
                        ..clearSnackBars()
                        ..showSnackBar(
                            SnackBar(content: Text(tr.doctorDateRequired)));
                      return;
                    }
                    final spec = specialty == 'other'
                        ? customSpecC.text.trim()
                        : specialty;
                    Navigator.pop(ctx, {
                      'doctor': doctorC.text.trim(),
                      'specialty': spec,
                      'place': placeC.text.trim(),
                      'date': d(date!),
                      'time': time == null ? '' : t(time!),
                      'serial': serialC.text.trim(),
                      'status': status,
                      'notes': notesC.text.trim(),
                    });
                  },
                  child: Text(tr.save),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

Future<bool?> _confirm(BuildContext context, String title, String body) {
  final tr = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(tr.delete)),
      ],
    ),
  );
}

// ===========================================================================
// _DCore — VERBATIM mirror of backend/core/logic/doctor_serial.py: upcoming/
// past bucketing, derived 'missed', reminder-due within the 24h window from a
// passed-in `now`. Deterministic; the UI localises specialty/status labels.
// ===========================================================================
class _DAppt {
  final Map<String, dynamic> raw;
  final int id;
  final String doctor;
  final String specialty;
  final String place;
  final String date;
  final String time;
  final String serial;
  final String status; // stored
  final String notes;
  final String bucket; // 'upcoming' | 'past'
  final String derived; // booked|done|cancelled|missed
  final bool reminderDue;
  final double? hoursUntil;
  final String whenLabel;
  _DAppt({
    required this.raw,
    required this.id,
    required this.doctor,
    required this.specialty,
    required this.place,
    required this.date,
    required this.time,
    required this.serial,
    required this.status,
    required this.notes,
    required this.bucket,
    required this.derived,
    required this.reminderDue,
    required this.hoursUntil,
    required this.whenLabel,
  });
}

class _DOrg {
  final List<_DAppt> upcoming;
  final List<_DAppt> past;
  final int remindersDue;
  _DOrg(this.upcoming, this.past, this.remindersDue);
}

class _DCore {
  static const int reminderWindowHours = 24;

  static String _clean(dynamic v) =>
      (v ?? '').toString().trim().split(RegExp(r'\s+')).join(' ');

  static DateTime? asDate(dynamic v) {
    final s = _clean(v);
    if (s.isEmpty) return null;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
    if (m == null) return null;
    return DateTime(
        int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  }

  static TimeOfDay? asTime(dynamic v) {
    final s = _clean(v);
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s);
    if (m == null) return null;
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) return null;
    return TimeOfDay(hour: h, minute: mi);
  }

  static DateTime? _combine(String dateStr, String timeStr) {
    final d = asDate(dateStr);
    if (d == null) return null;
    final t = asTime(timeStr);
    if (t == null) return DateTime(d.year, d.month, d.day);
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  static _DAppt _classify(Map<String, dynamic> row, DateTime now) {
    final doctor = _clean(row['doctor']);
    var status = (row['status'] ?? 'booked').toString();
    if (!_statuses.contains(status)) status = 'booked';
    final dateStr = _clean(row['date']);
    final timeStr = _clean(row['time']);
    final when = _combine(dateStr, timeStr);
    double? hoursUntil;
    if (when != null) {
      hoursUntil = when.difference(now).inMinutes / 60.0;
    }

    String bucket, derived;
    if (status == 'cancelled') {
      bucket = 'past';
      derived = 'cancelled';
    } else if (when == null) {
      bucket = 'upcoming';
      derived = status;
    } else if (hoursUntil != null && hoursUntil < 0) {
      if (status == 'done') {
        bucket = 'past';
        derived = 'done';
      } else {
        bucket = 'past';
        derived = 'missed';
      }
    } else {
      bucket = 'upcoming';
      derived = status;
    }

    final reminderDue = bucket == 'upcoming' &&
        status == 'booked' &&
        hoursUntil != null &&
        hoursUntil >= 0 &&
        hoursUntil <= reminderWindowHours;

    final whenLabel = when == null
        ? ''
        : (timeStr.isEmpty
            ? dateStr
            : '$dateStr ${timeStr.length >= 5 ? timeStr.substring(0, 5) : timeStr}');

    return _DAppt(
      raw: row,
      id: (row['id'] is int) ? row['id'] as int : 0,
      doctor: doctor,
      specialty: _clean(row['specialty']),
      place: _clean(row['place']),
      date: dateStr,
      time: timeStr,
      serial: _clean(row['serial']),
      status: status,
      notes: _clean(row['notes']),
      bucket: bucket,
      derived: derived,
      reminderDue: reminderDue,
      hoursUntil: hoursUntil,
      whenLabel: whenLabel,
    );
  }

  static _DOrg organise(List<Map<String, dynamic>> rows, DateTime now) {
    final views = rows.map((r) => _classify(r, now)).toList();
    final upcoming = views.where((v) => v.bucket == 'upcoming').toList();
    final past = views.where((v) => v.bucket == 'past').toList();

    double upKey(_DAppt v) => v.hoursUntil ?? double.infinity;
    double pastKey(_DAppt v) => v.hoursUntil ?? double.negativeInfinity;

    upcoming.sort((a, b) {
      final c = upKey(a).compareTo(upKey(b));
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    past.sort((a, b) {
      final c = pastKey(b).compareTo(pastKey(a)); // most recent first
      return c != 0 ? c : b.id.compareTo(a.id);
    });

    final remindersDue = upcoming.where((v) => v.reminderDue).length;
    return _DOrg(upcoming, past, remindersDue);
  }
}
