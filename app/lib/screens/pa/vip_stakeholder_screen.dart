import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · CORPORATE · VIP & stakeholder tracker — ADVANCED
/// (#118, §14).
///
/// A VIP / stakeholder relationship tracker. Keep one CONTACT per stakeholder
/// (name, org, tier, last-touch, next-touch, follow-up cadence in days, private
/// notes and an interaction log). The screen deterministically works out
/// follow-up health — OVERDUE / DUE-SOON / ON-TRACK — against the DEVICE's
/// today (`now`), deriving a next-touch from last-touch + cadence when none is
/// set. Fully deterministic; works offline with NO key, and there is NO AI
/// path that could fabricate relationships.
///
/// CONSERVATIVE PRIVACY: this is sensitive data. Notes and the interaction log
/// are kept behind an explicit reveal (collapsed by default) and never surface
/// in any roll-up. Everything stays on the owner's own saved rows.
///
/// Fixed scaffolding (tier labels, status labels, "overdue by N days", cadence
/// phrasing) is localised bn/en from the .arb — this file has ZERO Bangla
/// literals. Status logic mirrors backend/core/logic/pa_vip.py exactly.
///
/// Endpoints (generic api helpers, no api.dart edit):
///   listItems('pa/vip')            → saved contacts
///   createItem('pa/vip', body)     → save
///   updateItem('pa/vip', id, body) → re-save edits
///   deleteItem('pa/vip', id)       → remove
class VipStakeholderScreen extends StatefulWidget {
  const VipStakeholderScreen({super.key});
  @override
  State<VipStakeholderScreen> createState() => _VipStakeholderScreenState();
}

// ---- constants (mirror pa_vip.py) -----------------------------------------
const String _tierStrategic = 'strategic';
const String _tierKey = 'key';
const String _tierStandard = 'standard';
const List<String> _tiers = [_tierStrategic, _tierKey, _tierStandard];

const String _stOverdue = 'overdue';
const String _stDueSoon = 'due_soon';
const String _stOnTrack = 'on_track';
const String _stNoDate = 'no_date';

const int _dueSoonDays = 7;
const int _defaultCadenceDays = 30;

const Map<String, int> _tierOrder = {
  _tierStrategic: 0,
  _tierKey: 1,
  _tierStandard: 2,
};
const Map<String, int> _statusOrder = {
  _stOverdue: 0,
  _stDueSoon: 1,
  _stOnTrack: 2,
  _stNoDate: 3,
};

String _clean(String? s) => (s ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

final RegExp _dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Parse a valid YYYY-MM-DD into a DateTime (UTC midnight) or null.
DateTime? _parseIso(String? v) {
  final s = _clean(v);
  if (!_dateRe.hasMatch(s)) return null;
  final parts = s.split('-').map(int.parse).toList();
  try {
    final d = DateTime.utc(parts[0], parts[1], parts[2]);
    // reject overflow (e.g. 2026-13-40 → rolls over)
    if (d.year != parts[0] || d.month != parts[1] || d.day != parts[2]) {
      return null;
    }
    return d;
  } catch (_) {
    return null;
  }
}

int _toInt(dynamic v) {
  if (v is int) return v < 0 ? 0 : v;
  final n = int.tryParse(_clean(v?.toString()));
  return (n == null || n < 0) ? 0 : n;
}

String _normTier(String? v) {
  final s = _clean(v).toLowerCase();
  return _tiers.contains(s) ? s : _tierStandard;
}

String _isoFromDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Follow-up status for one contact against `now`. Mirrors pa_vip.status_for.
({String status, DateTime? due, int? days}) _statusFor(
    DateTime now, Map<String, dynamic> c) {
  final explicit = _parseIso(c['next_touch']?.toString());
  DateTime? due = explicit;
  if (due == null) {
    final last = _parseIso(c['last_touch']?.toString());
    if (last != null) {
      final cadence = _toInt(c['cadence_days']);
      due =
          last.add(Duration(days: cadence > 0 ? cadence : _defaultCadenceDays));
    }
  }
  if (due == null) {
    return (status: _stNoDate, due: null, days: null);
  }
  final days = due.difference(now).inDays;
  final String st;
  if (days < 0) {
    st = _stOverdue;
  } else if (days <= _dueSoonDays) {
    st = _stDueSoon;
  } else {
    st = _stOnTrack;
  }
  return (status: st, due: due, days: days);
}

class _VipStakeholderScreenState extends State<VipStakeholderScreen> {
  List<Map<String, dynamic>> _saved = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  // `now` = device local date reduced to a UTC midnight date for pure day math.
  DateTime get _now {
    final n = DateTime.now();
    return DateTime.utc(n.year, n.month, n.day);
  }

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
      _saved = await context.read<AppState>().api.listItems('pa/vip');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open({Map<String, dynamic>? existing}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _VipEditor(existing: existing)),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.paVipDeleteTitle),
        content: Text(tr.paVipDeleteBody(_clean(r['name']?.toString()))),
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
        await context.read<AppState>().api.deleteItem('pa/vip', id);
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

  /// Sorted contacts annotated with status — mirrors pa_vip.summarise ordering.
  List<({Map<String, dynamic> row, String status, DateTime? due, int? days})>
      _annotated() {
    final now = _now;
    final out =
        _saved.where((r) => _clean(r['name']?.toString()).isNotEmpty).map((r) {
      final s = _statusFor(now, r);
      return (row: r, status: s.status, due: s.due, days: s.days);
    }).toList();
    out.sort((a, b) {
      final sa = _statusOrder[a.status]!, sb = _statusOrder[b.status]!;
      if (sa != sb) return sa.compareTo(sb);
      final ta = _tierOrder[_normTier(a.row['tier']?.toString())]!;
      final tb = _tierOrder[_normTier(b.row['tier']?.toString())]!;
      if (ta != tb) return ta.compareTo(tb);
      final da = a.days ?? 1000000000, db = b.days ?? 1000000000;
      if (da != db) return da.compareTo(db);
      return _clean(a.row['name']?.toString())
          .toLowerCase()
          .compareTo(_clean(b.row['name']?.toString()).toLowerCase());
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows = _annotated();
    final overdue = rows.where((r) => r.status == _stOverdue).length;
    final dueSoon = rows.where((r) => r.status == _stDueSoon).length;

    return Scaffold(
      appBar: AppBar(title: Text(tr.paVipTitle)),
      // When the list is empty the welcome state already shows a "New" CTA, so
      // suppress the FAB to avoid two identical buttons on one screen.
      floatingActionButton: (_loading || _error || rows.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _open(),
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(tr.paVipNew),
            ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.paVipLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)),
                )
              : rows.isEmpty
                  ? StateMessage(
                      icon: Icons.handshake_outlined,
                      title: tr.paVipWelcomeTitle,
                      message: tr.paVipWelcomeBody,
                      action: FilledButton.icon(
                        onPressed: () => _open(),
                        icon: const Icon(Icons.person_add_alt_1),
                        label: Text(tr.paVipNew),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                            Gap.md, Gap.md, Gap.md, 96),
                        children: [
                          if (overdue > 0 || dueSoon > 0)
                            _followupBanner(tr, scheme, overdue, dueSoon),
                          if (overdue > 0 || dueSoon > 0)
                            const SizedBox(height: Gap.md),
                          Row(children: [
                            Icon(Icons.lock_outline,
                                size: 14, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(tr.paVipPrivacyNote,
                                  style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 12)),
                            ),
                          ]),
                          const SizedBox(height: Gap.sm),
                          for (final r in rows) ...[
                            _contactCard(tr, scheme, r),
                            const SizedBox(height: Gap.sm),
                          ],
                        ],
                      ),
                    ),
    );
  }

  Widget _followupBanner(
      AppLocalizations tr, ColorScheme scheme, int overdue, int dueSoon) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: (overdue > 0 ? scheme.error : scheme.primary)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(
            overdue > 0
                ? Icons.notification_important_outlined
                : Icons.schedule,
            color: overdue > 0 ? scheme.error : scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            [
              if (overdue > 0) tr.paVipBannerOverdue(overdue),
              if (dueSoon > 0) tr.paVipBannerDueSoon(dueSoon),
            ].join('  ·  '),
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: overdue > 0 ? scheme.error : scheme.primary),
          ),
        ),
      ]),
    );
  }

  Widget _contactCard(AppLocalizations tr, ColorScheme scheme,
      ({Map<String, dynamic> row, String status, DateTime? due, int? days}) a) {
    final r = a.row;
    final name = _clean(r['name']?.toString());
    final org = _clean(r['org']?.toString());
    final tier = _normTier(r['tier']?.toString());
    final (Color, String) badge = switch (a.status) {
      _stOverdue => (scheme.error, _statusLabel(tr, a)),
      _stDueSoon => (scheme.tertiary, _statusLabel(tr, a)),
      _stOnTrack => (scheme.primary, _statusLabel(tr, a)),
      _ => (scheme.onSurfaceVariant, _statusLabel(tr, a)),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => _open(existing: r),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _tierDot(scheme, tier),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                          [
                            if (org.isNotEmpty) org,
                            _tierLabel(tr, tier),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: scheme.onSurfaceVariant, fontSize: 12.5)),
                    ]),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'open') _open(existing: r);
                  if (v == 'delete') _delete(r, tr);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'open', child: Text(tr.paVipOpen)),
                  PopupMenuItem(value: 'delete', child: Text(tr.delete)),
                ],
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
              decoration: BoxDecoration(
                color: badge.$1.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(badge.$2,
                  style: TextStyle(
                      color: badge.$1,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tierDot(ColorScheme scheme, String tier) {
    final c = switch (tier) {
      _tierStrategic => scheme.error,
      _tierKey => scheme.tertiary,
      _ => scheme.primary,
    };
    final filled = tier == _tierStrategic || tier == _tierKey;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(filled ? Icons.star : Icons.star_border, size: 18, color: c),
    );
  }

  String _tierLabel(AppLocalizations tr, String tier) => switch (tier) {
        _tierStrategic => tr.paVipTierStrategic,
        _tierKey => tr.paVipTierKey,
        _ => tr.paVipTierStandard,
      };

  String _statusLabel(AppLocalizations tr,
      ({Map<String, dynamic> row, String status, DateTime? due, int? days}) a) {
    switch (a.status) {
      case _stOverdue:
        return tr.paVipStatusOverdue((a.days ?? 0).abs());
      case _stDueSoon:
        return a.days == 0
            ? tr.paVipStatusDueToday
            : tr.paVipStatusDueSoon(a.days ?? 0);
      case _stOnTrack:
        return a.due != null
            ? tr.paVipStatusOnTrack(_isoFromDate(a.due!))
            : tr.paVipStatusOnTrackPlain;
      default:
        return tr.paVipStatusNoDate;
    }
  }
}

/// Editor: name, org, tier, last/next touch, cadence, notes, interaction log.
/// Notes + log are the privacy-sensitive parts and stay on this contact's row.
class _VipEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _VipEditor({this.existing});
  @override
  State<_VipEditor> createState() => _VipEditorState();
}

class _VipEditorState extends State<_VipEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?['name']?.toString() ?? '');
  late final TextEditingController _org =
      TextEditingController(text: widget.existing?['org']?.toString() ?? '');
  late final TextEditingController _lastTouch = TextEditingController(
      text: widget.existing?['last_touch']?.toString() ?? '');
  late final TextEditingController _nextTouch = TextEditingController(
      text: widget.existing?['next_touch']?.toString() ?? '');
  late final TextEditingController _cadence = TextEditingController(text: () {
    final c = widget.existing?['cadence_days'];
    return (c is int && c > 0) ? c.toString() : '';
  }());
  late final TextEditingController _notes =
      TextEditingController(text: widget.existing?['notes']?.toString() ?? '');
  late String _tier = _normTier(widget.existing?['tier']?.toString());
  late List<Map<String, dynamic>> _log = () {
    final v = widget.existing?['log'];
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _org.dispose();
    _lastTouch.dispose();
    _nextTouch.dispose();
    _cadence.dispose();
    _notes.dispose();
    super.dispose();
  }

  List<String> _validate() {
    final problems = <String>[];
    if (_clean(_name.text).isEmpty) problems.add('empty_name');
    return problems;
  }

  Future<void> _save(AppLocalizations tr) async {
    setState(() => _saving = true);
    final body = <String, dynamic>{
      'name': _clean(_name.text),
      'org': _clean(_org.text),
      'tier': _tier,
      'last_touch': _clean(_lastTouch.text),
      'next_touch': _clean(_nextTouch.text),
      'cadence_days': _toInt(_cadence.text),
      'notes': _notes.text.trim(),
      'log': _log
          .where((m) =>
              _clean(m['note']?.toString()).isNotEmpty ||
              _clean(m['date']?.toString()).isNotEmpty)
          .toList(),
    };
    try {
      final api = context.read<AppState>().api;
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem('pa/vip', id, body);
      } else {
        await api.createItem('pa/vip', body);
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

  String _tierLabel(AppLocalizations tr, String tier) => switch (tier) {
        _tierStrategic => tr.paVipTierStrategic,
        _tierKey => tr.paVipTierKey,
        _ => tr.paVipTierStandard,
      };

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final problems = _validate();
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.existing == null ? tr.paVipNew : tr.paVipEdit)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
        children: [
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.paVipNameField,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _org,
            decoration: InputDecoration(
                labelText: tr.paVipOrgField,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          Text(tr.paVipTierLabel,
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            for (final t in _tiers)
              ChoiceChip(
                label: Text(_tierLabel(tr, t)),
                selected: _tier == t,
                onSelected: (_) => setState(() => _tier = t),
              ),
          ]),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _lastTouch,
                decoration: InputDecoration(
                    labelText: tr.paVipLastTouchField,
                    helperText: tr.paVipDateHelp,
                    helperMaxLines: 2,
                    border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: TextField(
                controller: _nextTouch,
                decoration: InputDecoration(
                    labelText: tr.paVipNextTouchField,
                    helperText: tr.paVipDateHelp,
                    helperMaxLines: 2,
                    border: const OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _cadence,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: tr.paVipCadenceField,
                helperText: tr.paVipCadenceHelp,
                helperMaxLines: 2,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),
          // ---- privacy-sensitive: notes
          Row(children: [
            Icon(Icons.lock_outline, size: 16, color: scheme.primary),
            const SizedBox(width: 4),
            Text(tr.paVipPrivateSection,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: Gap.xs),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: tr.paVipNotesField,
              helperText: tr.paVipNotesHelp,
              helperMaxLines: 2,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
          // ---- interaction log
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.history_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(tr.paVipLogTitle,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ]),
              for (var i = 0; i < _log.length; i++) ...[
                const SizedBox(height: Gap.sm),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 118,
                    child: TextFormField(
                      initialValue: _log[i]['date']?.toString() ?? '',
                      onChanged: (v) => _log[i]['date'] = v,
                      decoration: InputDecoration(
                          isDense: true,
                          labelText: tr.paVipLogDateField,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: TextFormField(
                      initialValue: _log[i]['note']?.toString() ?? '',
                      minLines: 1,
                      maxLines: 3,
                      onChanged: (v) => _log[i]['note'] = v,
                      decoration: InputDecoration(
                          isDense: true,
                          labelText: tr.paVipLogNoteField,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                  IconButton(
                    icon:
                        Icon(Icons.remove_circle_outline, color: scheme.error),
                    onPressed: () => setState(() => _log.removeAt(i)),
                  ),
                ]),
              ],
              const SizedBox(height: Gap.xs),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _log.add({'date': '', 'note': ''})),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr.paVipAddLog),
                ),
              ),
            ]),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Icon(Icons.info_outline, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(tr.paVipPrivacyNote,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12.5)),
            ),
          ]),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed:
                  (problems.isEmpty && !_saving) ? () => _save(tr) : null,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(tr.save),
            ),
          ),
          if (problems.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(tr.paVipNeedName,
                style: TextStyle(color: scheme.error, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}
