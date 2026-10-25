import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../state.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/pa_engine.dart';
import 'pa_meeting_brief_screen.dart';
import '../../services/error_kind.dart' show serverFailText; // qa2

/// PA Secretary — SCHEDULE control (SPEC v2.1 §14 #103, ADVANCED §21).
///
/// The PA's organized view of the OWNER's day/week: agenda of appointments &
/// meetings, add/edit/delete slots, HONEST conflict (overlap) detection, and a
/// "next up" summary. Logic mirrors core.logic.pa_schedule via pa_engine.dart.
///
/// ADVANCED states: loading skeleton, honest empty "welcome" first-use state,
/// error + retry, offline banner (keeps the last list, never strands the user),
/// a confirm gate before delete, and a clash badge that says exactly how long a
/// pair overlaps. ZERO Bangla glyphs here — every string is an AppLocalizations
/// getter; new keys are emitted to .phaseB/up_pa1_arb.json.
///
/// Persistence uses the proven generic item slot (`listItems/createItem` on the
/// `pa_schedule` path storing {'items': [...]}); the integrator may swap to a
/// real PaMeeting model/endpoint (see up_pa1_integration.md) without touching
/// this screen's shape.
class PaScheduleScreen extends StatefulWidget {
  const PaScheduleScreen({super.key});
  @override
  State<PaScheduleScreen> createState() => _PaScheduleScreenState();
}

enum _Scope { day, week }

class _PaScheduleScreenState extends State<PaScheduleScreen> {
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _offline = false;
  List<Map<String, dynamic>> _slots = [];

  _Scope _scope = _Scope.day;
  DateTime _anchor = DateTime.now();

  AppState get _app => context.read<AppState>();
  AppLocalizations get t => AppLocalizations.of(context);

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
      final rows = await _app.api.listItems('pa_schedule');
      // The PA collection serializer flattens each row to {...slot, 'id': N};
      // every slot is its own row. Older builds (pre-fix) wrote one or more
      // wrapper rows shaped {'items': [...], 'id': N}. Self-heal here: expand
      // any wrapper rows into real per-slot rows, and delete the stale wrappers
      // from the backend so they never accumulate or shadow the real slots.
      final slots = <Map<String, dynamic>>[];
      final staleWrapperIds = <int>[];
      for (final r in rows) {
        final row = (r['data'] as Map<String, dynamic>?) ?? r;
        if (row['items'] is List) {
          // Legacy wrapper row — expand its payload into standalone slots.
          for (final e in (row['items'] as List)) {
            if (e is Map) {
              final slot = Map<String, dynamic>.from(e);
              slot.remove('id'); // inner items never carried a real row id
              slots.add(slot);
            }
          }
          final wid = row['id'];
          if (wid is int) staleWrapperIds.add(wid);
        } else {
          slots.add(Map<String, dynamic>.from(row));
        }
      }
      _slots = slots;
      _offline = false;
      // Fire-and-forget cleanup of the legacy wrapper rows. If any expanded
      // slots had no id of their own, re-persist them as proper per-slot rows
      // so the self-heal is durable across reloads.
      if (staleWrapperIds.isNotEmpty) {
        await _healLegacyRows(staleWrapperIds);
      }
    } catch (e) {
      if (_slots.isNotEmpty) {
        _offline = true;
      } else {
        _error = true;
        _failCause = e;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Recovers data written by the old wrapper-row bug: persists any expanded
  /// slots that lack a row id as fresh per-slot rows, then deletes the stale
  /// wrapper rows. Best-effort — failures leave the in-memory view intact.
  Future<void> _healLegacyRows(List<int> staleWrapperIds) async {
    try {
      for (var i = 0; i < _slots.length; i++) {
        final s = _slots[i];
        if (s['id'] is int) continue;
        final created = await _app.api.createItem('pa_schedule', _payloadOf(s));
        _slots[i] = {...s, 'id': created['id']};
      }
      for (final id in staleWrapperIds) {
        await _app.api.deleteItem('pa_schedule', id);
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Leave the in-memory slots as-is; a later successful save/reload will
      // retry the heal. Never strand the user on a transient failure.
    }
  }

  /// A slot map minus the backend row id — the body we send on create/update.
  Map<String, dynamic> _payloadOf(Map<String, dynamic> s) {
    final body = Map<String, dynamic>.from(s);
    body.remove('id');
    return body;
  }

  /// Persists a single slot: PATCH when it already has a row id, POST (capturing
  /// the new id) otherwise. Returns the slot with its id populated, or null on
  /// failure (caller surfaces the offline state).
  Future<Map<String, dynamic>?> _persist(Map<String, dynamic> s) async {
    try {
      final id = s['id'];
      if (id is int) {
        await _app.api.updateItem('pa_schedule', id, _payloadOf(s));
        if (mounted && _offline) setState(() => _offline = false);
        return s;
      }
      final created = await _app.api.createItem('pa_schedule', _payloadOf(s));
      final withId = {...s, 'id': created['id']};
      if (mounted && _offline) setState(() => _offline = false);
      return withId;
    } catch (_) {
      if (mounted) {
        setState(() => _offline = true);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.paSavedOffline)));
      }
      return null;
    }
  }

  Future<void> _addOrEdit([Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SlotEditor(existing: existing, anchor: _anchor),
    );
    if (result == null) return;
    // Carry the backend row id across an edit so we PATCH the same row rather
    // than POSTing a duplicate.
    final toSave = existing != null && existing['id'] is int
        ? {...result, 'id': existing['id']}
        : result;
    setState(() {
      if (existing == null) {
        _slots = [..._slots, toSave];
      } else {
        _slots =
            _slots.map((x) => identical(x, existing) ? toSave : x).toList();
      }
    });
    final saved = await _persist(toSave);
    if (saved != null && mounted) {
      setState(() => _slots =
          _slots.map((x) => identical(x, toSave) ? saved : x).toList());
    }
  }

  Future<void> _delete(Map<String, dynamic> s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.paDeleteTitle),
        content: Text(t.paDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(ctx).cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocalizations.of(ctx).delete)),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _slots = _slots.where((x) => !identical(x, s)).toList());
    final id = s['id'];
    if (id is int) {
      try {
        await _app.api.deleteItem('pa_schedule', id);
        if (mounted && _offline) setState(() => _offline = false);
      } catch (_) {
        if (mounted) setState(() => _offline = true);
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.commonDeleted)));
    }
  }

  Future<void> _setStatus(Map<String, dynamic> s, String status) async {
    final updated = {...s, 'status': status};
    setState(() =>
        _slots = _slots.map((x) => identical(x, s) ? updated : x).toList());
    final saved = await _persist(updated);
    if (saved != null && mounted) {
      setState(() => _slots =
          _slots.map((x) => identical(x, updated) ? saved : x).toList());
    }
  }

  void _openBrief(Map<String, dynamic> s) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PaMeetingBriefScreen(
        meeting: Map<String, dynamic>.from(s),
        onSaved: (updated) async {
          // Preserve the backend row id so the brief edit PATCHes in place.
          final merged = s['id'] is int && updated['id'] == null
              ? {...updated, 'id': s['id']}
              : updated;
          setState(() => _slots =
              _slots.map((x) => identical(x, s) ? merged : x).toList());
          final saved = await _persist(merged);
          if (saved != null && mounted) {
            setState(() => _slots =
                _slots.map((x) => identical(x, merged) ? saved : x).toList());
          }
        },
      ),
    ));
  }

  void _shiftAnchor(int delta) {
    setState(() {
      _anchor = _scope == _Scope.day
          ? _anchor.add(Duration(days: delta))
          : _anchor.add(Duration(days: 7 * delta));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.paScheduleTitle)),
      floatingActionButton: (_loading || _error || _slots.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.add),
              label: Text(t.paAddSlot),
            ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const SkeletonList(count: 5);
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off,
        tint: Brand.danger,
        title: t.paLoadError,
        message: serverFailText(t, _failCause),
        action: FilledButton.tonal(onPressed: _load, child: Text(t.retry)),
      );
    }

    final scopeStr = _scope == _Scope.day ? 'day' : 'week';
    final days = agenda(_slots, scope: scopeStr, anchor: _anchor);
    final conflictIdx = conflictingIndexes(_slots);
    final nu = nextUp(_slots);
    final totalInWindow =
        days.fold<int>(0, (acc, d) => acc + d.items.length);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
        children: [
          if (_offline) ...[
            _OfflineBanner(text: t.paOffline),
            const SizedBox(height: Gap.md),
          ],
          _NextUpCard(nextUp: nu),
          const SizedBox(height: Gap.lg),
          _ScopeBar(
            scope: _scope,
            anchor: _anchor,
            onScope: (s) => setState(() => _scope = s),
            onPrev: () => _shiftAnchor(-1),
            onNext: () => _shiftAnchor(1),
            onToday: () => setState(() => _anchor = DateTime.now()),
          ),
          const SizedBox(height: Gap.md),
          if (conflictIdx.isNotEmpty) ...[
            _ConflictSummary(count: conflicts(_slots).length),
            const SizedBox(height: Gap.md),
          ],
          if (_slots.isEmpty)
            _welcomeEmpty()
          else if (totalInWindow == 0)
            _noneInWindow()
          else
            ...days.map((d) => _daySection(d, conflictIdx)),
        ],
      ),
    );
  }

  Widget _welcomeEmpty() {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xxl),
      child: StateMessage(
        icon: Icons.event_available_outlined,
        title: t.paEmptyTitle,
        message: t.paEmptyBody,
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(),
          icon: const Icon(Icons.add, size: 18),
          label: Text(t.paAddFirst),
        ),
      ),
    );
  }

  Widget _noneInWindow() {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xl),
      child: StateMessage(
        icon: Icons.free_breakfast_outlined,
        title: t.paNoneWindowTitle,
        message: _scope == _Scope.day ? t.paNoneDayBody : t.paNoneWeekBody,
      ),
    );
  }

  Widget _daySection(AgendaDay d, Set<int> conflictIdx) {
    final scheme = Theme.of(context).colorScheme;
    final date = DateTime.parse(d.date);
    final label = _dayHeading(date);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.sm),
          child: Row(children: [
            Text(label,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800, color: scheme.primary)),
            const SizedBox(width: Gap.sm),
            Text(t.paSlotCount(d.items.length),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
        ...d.items.map((it) => Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: _SlotCard(
                slot: it.slot,
                clash: conflictIdx.contains(it.index),
                onEdit: () => _addOrEdit(it.slot),
                onDelete: () => _delete(it.slot),
                onBrief: () => _openBrief(it.slot),
                onStatus: (st) => _setStatus(it.slot, st),
              ),
            )),
      ],
    );
  }

  String _dayHeading(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = that.difference(today).inDays;
    if (diff == 0) return t.paToday;
    if (diff == 1) return t.paTomorrow;
    final loc = Localizations.localeOf(context).toString();
    return DateFormat('EEE, d MMM', loc).format(d);
  }
}

// ---------------------------------------------------------------------------
// pieces
// ---------------------------------------------------------------------------

class _OfflineBanner extends StatelessWidget {
  final String text;
  const _OfflineBanner({required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        const Icon(Icons.wifi_off, size: 16, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: AType.bodySmall.copyWith(height: 1.3))),
      ]),
    );
  }
}

class _NextUpCard extends StatelessWidget {
  final NextUp nextUp;
  const _NextUpCard({required this.nextUp});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (!nextUp.hasNext) {
      return Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          Icon(Icons.check_circle_outline,
              color: Brand.success, size: 22),
          const SizedBox(width: Gap.md),
          Expanded(
              child: Text(t.paNothingNext,
                  style: TextStyle(color: scheme.onSurfaceVariant))),
        ]),
      );
    }
    final slot = nextUp.slot!;
    final start = startOf(slot);
    final loc = Localizations.localeOf(context).toString();
    final timeStr = start == null ? '' : DateFormat('d MMM, HH:mm', loc).format(start);
    final sub = nextUp.inProgress
        ? t.paInProgress
        : t.paInMinutes(nextUp.minutesUntil ?? 0);
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.upcoming, color: Colors.white, size: 18),
          const SizedBox(width: Gap.sm),
          Text(t.paNextUp,
              style: AType.bodySmall.copyWith(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
          const Spacer(),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AType.bodySmall.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Text('${slot['title'] ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AType.titleLarge.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xxs),
        Text(timeStr,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.92))),
      ]),
    );
  }
}

class _ScopeBar extends StatelessWidget {
  final _Scope scope;
  final DateTime anchor;
  final ValueChanged<_Scope> onScope;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  const _ScopeBar({
    required this.scope,
    required this.anchor,
    required this.onScope,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final loc = Localizations.localeOf(context).toString();
    final rangeLabel = scope == _Scope.day
        ? DateFormat('EEE, d MMM', loc).format(anchor)
        : _weekLabel(context);
    return Column(children: [
      SegmentedButton<_Scope>(
        segments: [
          ButtonSegment(value: _Scope.day, label: Text(t.paScopeDay)),
          ButtonSegment(value: _Scope.week, label: Text(t.paScopeWeek)),
        ],
        selected: {scope},
        onSelectionChanged: (s) => onScope(s.first),
        showSelectedIcon: false,
      ),
      const SizedBox(height: Gap.sm),
      Row(children: [
        IconButton(
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left),
            tooltip: t.paPrev),
        Expanded(
          child: GestureDetector(
            onTap: onToday,
            child: Text(rangeLabel,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
            tooltip: t.paNext),
      ]),
    ]);
  }

  String _weekLabel(BuildContext context) {
    final loc = Localizations.localeOf(context).toString();
    final mon = anchor.subtract(Duration(days: anchor.weekday - 1));
    final sun = mon.add(const Duration(days: 6));
    final f = DateFormat('d MMM', loc);
    return '${f.format(mon)} – ${f.format(sun)}';
  }
}

class _ConflictSummary extends StatelessWidget {
  final int count;
  const _ConflictSummary({required this.count});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: Brand.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: Brand.danger.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded,
            size: 18, color: Brand.danger),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(t.paConflictSummary(count),
              style: AType.bodySmall.copyWith(color: Brand.danger, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class _SlotCard extends StatelessWidget {
  final Map<String, dynamic> slot;
  final bool clash;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onBrief;
  final ValueChanged<String> onStatus;
  const _SlotCard({
    required this.slot,
    required this.clash,
    required this.onEdit,
    required this.onDelete,
    required this.onBrief,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final loc = Localizations.localeOf(context).toString();
    final start = startOf(slot);
    final end = endOf(slot);
    final status = statusOf(slot);
    final kind = cleanKind(slot['kind']);
    final done = status == kStatusDone;
    final cancelled = status == kStatusCancelled;
    final timeStr = start == null
        ? ''
        : '${DateFormat('HH:mm', loc).format(start)}'
            '${end == null ? '' : ' – ${DateFormat('HH:mm', loc).format(end)}'}';
    final people = ((slot['people'] as List?) ?? const [])
        .map((e) => '$e')
        .where((e) => e.trim().isNotEmpty)
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: clash
              ? Brand.danger.withValues(alpha: 0.6)
              : scheme.outlineVariant,
          width: clash ? 1.4 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_kindIcon(kind), size: 18, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text('${slot['title'] ?? ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800, decoration: (done || cancelled)
                          ? TextDecoration.lineThrough
                          : null, color: cancelled ? scheme.onSurfaceVariant : null)),
            ),
            _MenuButton(
              status: status,
              onEdit: onEdit,
              onDelete: onDelete,
              onStatus: onStatus,
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Row(children: [
            Icon(Icons.schedule, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Flexible(
              child: Text(timeStr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(width: Gap.sm),
            _StatusChip(status: status),
          ]),
          if ('${slot['place'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Row(children: [
              Icon(Icons.place_outlined,
                  size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text('${slot['place']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ]),
          ],
          if (people.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Row(children: [
              Icon(Icons.group_outlined,
                  size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(people.join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ]),
          ],
          if (clash) ...[
            const SizedBox(height: Gap.sm),
            Row(children: [
              const Icon(Icons.error_outline,
                  size: 14, color: Brand.danger),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(t.paClashBadge,
                    style: AType.bodySmall.copyWith(color: Brand.danger, fontWeight: FontWeight.w600)),
              ),
            ]),
          ],
          const SizedBox(height: Gap.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onBrief,
              icon: const Icon(Icons.description_outlined, size: 16),
              label: Text(t.paOpenBrief),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.md, vertical: Gap.xxs),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  IconData _kindIcon(String kind) {
    switch (kind) {
      case kKindCall:
        return Icons.call_outlined;
      case kKindTask:
        return Icons.task_alt_outlined;
      case kKindBlock:
        return Icons.block_outlined;
      case kKindAppointment:
        return Icons.event_outlined;
      case kKindMeeting:
      default:
        return Icons.groups_outlined;
    }
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Color c;
    switch (status) {
      case kStatusDone:
        c = Brand.success;
        break;
      case kStatusCancelled:
        c = Brand.danger;
        break;
      case kStatusTentative:
        c = Brand.warning;
        break;
      default:
        c = Brand.blue;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(statusLabel(t, status),
          style: AType.labelSmall.copyWith(color: c, fontWeight: FontWeight.w700)),
    );
  }
}

class _MenuButton extends StatelessWidget {
  final String status;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<String> onStatus;
  const _MenuButton({
    required this.status,
    required this.onEdit,
    required this.onDelete,
    required this.onStatus,
  });
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (v) {
        switch (v) {
          case 'edit':
            onEdit();
            break;
          case 'delete':
            onDelete();
            break;
          default:
            onStatus(v);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'edit', child: Text(t.edit)),
        if (status != kStatusConfirmed)
          PopupMenuItem(
              value: kStatusConfirmed, child: Text(t.paMarkConfirmed)),
        if (status != kStatusDone)
          PopupMenuItem(value: kStatusDone, child: Text(t.paMarkDone)),
        if (status != kStatusCancelled)
          PopupMenuItem(
              value: kStatusCancelled, child: Text(t.paMarkCancelled)),
        PopupMenuItem(value: 'delete', child: Text(t.delete)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// slot editor bottom sheet
// ---------------------------------------------------------------------------
class _SlotEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final DateTime anchor;
  const _SlotEditor({this.existing, required this.anchor});
  @override
  State<_SlotEditor> createState() => _SlotEditorState();
}

class _SlotEditorState extends State<_SlotEditor> {
  late final TextEditingController _title;
  late final TextEditingController _place;
  late final TextEditingController _people;
  late final TextEditingController _note;
  late String _kind;
  late DateTime _start;
  late int _duration;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    _title = TextEditingController(text: '${e['title'] ?? ''}');
    _place = TextEditingController(text: '${e['place'] ?? ''}');
    _people = TextEditingController(
        text: ((e['people'] as List?) ?? const []).join(', '));
    _note = TextEditingController(text: '${e['note'] ?? ''}');
    _kind = cleanKind(e['kind']);
    final parsed = parseDt(e['start']);
    _start = parsed ??
        DateTime(widget.anchor.year, widget.anchor.month, widget.anchor.day,
            DateTime.now().hour + 1);
    _duration = clampDuration(e['duration_min'] ?? kDurationDefaultMin);
  }

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _people.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() => _start =
        DateTime(d.year, d.month, d.day, _start.hour, _start.minute));
  }

  Future<void> _pickTime() async {
    final tm = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (tm == null) return;
    setState(() =>
        _start = DateTime(_start.year, _start.month, _start.day, tm.hour, tm.minute));
  }

  void _submit() {
    final t = AppLocalizations.of(context);
    final payload = <String, dynamic>{
      'title': _title.text.trim(),
      'kind': _kind,
      'start': _start.toIso8601String(),
      'duration_min': _duration,
      'place': _place.text.trim(),
      'people': _people.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      'note': _note.text.trim(),
      'status': '${(widget.existing ?? const {})['status'] ?? kStatusConfirmed}',
    };
    // keep any extra brief fields the user filled on the brief screen
    final existing = widget.existing;
    if (existing != null) {
      for (final k in ['agenda', 'prep', 'purpose', 'organiser', 'leads']) {
        if (existing[k] != null) payload[k] = existing[k];
      }
    }
    final problems = validateSlot(payload);
    if (problems.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(slotProblemLabel(t, problems.first))));
      return;
    }
    Navigator.pop(context, payload);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final loc = Localizations.localeOf(context).toString();
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, insets + Gap.lg),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.existing == null ? t.paAddSlot : t.paEditSlot,
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _title,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: t.paFieldTitle,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: InputDecoration(
                labelText: t.paFieldKind,
                border: const OutlineInputBorder()),
            items: kKinds
                .map((k) => DropdownMenuItem(
                    value: k, child: Text(kindLabel(t, k))))
                .toList(),
            onChanged: (v) => setState(() => _kind = v ?? kKindMeeting),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(DateFormat('d MMM yyyy', loc).format(_start),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickTime,
                icon: const Icon(Icons.access_time, size: 16),
                label: Text(DateFormat('HH:mm', loc).format(_start),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFeatures: AFonts.tabular)),
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          Row(children: [
            Text(t.paFieldDuration,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(t.paMinutes(_duration),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
          Slider(
            value: _duration.toDouble().clamp(
                kDurationMin.toDouble(), 240),
            min: kDurationMin.toDouble(),
            max: 240,
            divisions: (240 - kDurationMin) ~/ 5,
            label: '$_duration',
            onChanged: (v) => setState(() => _duration = (v / 5).round() * 5),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _place,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: t.paFieldPlace,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _people,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: t.paFieldPeople,
                hintText: t.paFieldPeopleHint,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(
                labelText: t.paFieldNote,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t.cancel)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(
                  onPressed: _submit, child: Text(t.save)),
            ),
          ]),
        ]),
      ),
    );
  }
}
