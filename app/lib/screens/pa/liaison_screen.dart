import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';

/// PA Secretary Mode · Liaison & Follow-up — ADVANCED (#108, §14).
///
/// Track external contacts/tasks the PA is chasing on the owner's behalf: a
/// follow-up list with due dates, a status (waiting / replied / done), a
/// nudge-reminder cadence, and an HONEST overdue indicator. Add / edit /
/// complete freely; delete sits behind a confirm gate.
///
/// Honest states: welcome (first use) · loading · error · empty-for-filter.
/// Contact is privacy-minimised (masked hint, never a raw phone/email in the
/// list). All logic mirrors backend/core/logic/pa_liaison.py so the computed
/// overdue / urgency / next-nudge are deterministic and identical offline.
/// ZERO Bangla literals — every string is an AppLocalizations getter.
///
/// Endpoints (generic api helpers, no api.dart edit):
///   listItems('pa/followups')            → List of follow-up rows
///   createItem('pa/followups', body)     → create
///   updateItem('pa/followups', id, body) → edit / status / nudge
///   deleteItem('pa/followups', id)       → remove
class LiaisonScreen extends StatefulWidget {
  const LiaisonScreen({super.key});
  @override
  State<LiaisonScreen> createState() => _LiaisonScreenState();
}

// ---- constants (mirror pa_liaison.py) -------------------------------------
const String _stWaiting = 'waiting';
const String _stReplied = 'replied';
const String _stDone = 'done';

const int _dueSoonDays = 2;

// nudge cadences → whole days (0 = off)
const Map<String, int> _nudgeDays = {
  'off': 0,
  'daily': 1,
  'every_3_days': 3,
  'weekly': 7,
};

class _LiaisonScreenState extends State<LiaisonScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;

  String? _fStatus; // null ⇒ any
  bool _onlyOverdue = false;

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
      _rows = await context.read<AppState>().api.listItems('pa/followups');
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- deterministic mirror of pa_liaison.py -------------------------------
  DateTime get _now => DateTime.now();

  DateTime? _parse(dynamic v) {
    if (v == null) return null;
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).round(), isUtc: true);
    }
    return DateTime.tryParse(v.toString());
  }

  bool _isOpen(Map<String, dynamic> r) {
    final s = (r['status'] ?? _stWaiting).toString();
    return s == _stWaiting || s == _stReplied;
  }

  bool _isOverdue(Map<String, dynamic> r) {
    if (!_isOpen(r)) return false;
    final due = _parse(r['due_at']);
    return due != null && due.isBefore(_now);
  }

  int? _daysUntilDue(Map<String, dynamic> r) {
    final due = _parse(r['due_at']);
    if (due == null) return null;
    return (due.difference(_now).inSeconds / 86400).floor();
  }

  String _urgency(Map<String, dynamic> r) {
    if (!_isOpen(r)) return 'done';
    if (_isOverdue(r)) return 'overdue';
    final d = _daysUntilDue(r);
    if (d != null && d >= 0 && d <= _dueSoonDays) return 'due_soon';
    return 'later';
  }

  int _urgencyRank(String u) {
    switch (u) {
      case 'overdue':
        return 0;
      case 'due_soon':
        return 1;
      case 'later':
        return 2;
      default:
        return 3; // done
    }
  }

  int _statusTie(String s) {
    switch (s) {
      case _stReplied:
        return 0;
      case _stWaiting:
        return 1;
      default:
        return 2; // done
    }
  }

  DateTime? _nextNudge(Map<String, dynamic> r) {
    if (!_isOpen(r)) return null;
    final days = _nudgeDays[(r['nudge'] ?? 'off').toString()] ?? 0;
    if (days <= 0) return null;
    final now = _now;
    final anchor = _parse(r['last_nudged_at']) ?? _parse(r['due_at']) ?? now;
    final step = Duration(days: days);
    var nxt = anchor.add(step);
    if (!nxt.isAfter(now)) {
      final missed = (now.difference(anchor).inSeconds ~/ step.inSeconds) + 1;
      nxt = anchor.add(step * missed);
    }
    return nxt;
  }

  List<Map<String, dynamic>> get _ordered {
    final list = _rows.where((r) {
      if (_fStatus != null && (r['status'] ?? _stWaiting).toString() != _fStatus) {
        return false;
      }
      if (_onlyOverdue && !_isOverdue(r)) return false;
      return true;
    }).toList();
    list.sort((a, b) {
      final ua = _urgencyRank(_urgency(a));
      final ub = _urgencyRank(_urgency(b));
      if (ua != ub) return ua - ub;
      final ta = _statusTie((a['status'] ?? _stWaiting).toString());
      final tb = _statusTie((b['status'] ?? _stWaiting).toString());
      if (ta != tb) return ta - tb;
      final da = _parse(a['due_at'])?.millisecondsSinceEpoch ?? 1 << 62;
      final db = _parse(b['due_at'])?.millisecondsSinceEpoch ?? 1 << 62;
      if (da != db) return da.compareTo(db);
      return (a['title'] ?? '').toString().compareTo((b['title'] ?? '').toString());
    });
    return list;
  }

  int _countStatus(String s) =>
      _rows.where((r) => (r['status'] ?? _stWaiting).toString() == s).length;
  int get _overdueCount => _rows.where(_isOverdue).length;

  // ---- actions -------------------------------------------------------------
  Future<void> _setStatus(Map<String, dynamic> r, String to, AppLocalizations tr) async {
    final body = <String, dynamic>{'status': to};
    if (to == _stDone) {
      body['completed_at'] = _now.toUtc().toIso8601String();
    } else {
      body['completed_at'] = null;
    }
    await _apply(r, body, tr);
  }

  Future<void> _apply(Map<String, dynamic> r, Map<String, dynamic> body, AppLocalizations tr) async {
    final id = r['id'];
    try {
      if (id is int) {
        await context.read<AppState>().api.updateItem('pa/followups', id, body);
      }
      await _load();
      if (mounted) _toast(tr.paLiaSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.paLiaDeleteConfirmTitle),
        content: Text(tr.paLiaDeleteConfirmBody((r['title'] ?? '').toString())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = r['id'];
    try {
      if (id is int) await context.read<AppState>().api.deleteItem('pa/followups', id);
      await _load();
      if (mounted) _toast(tr.paLiaDeleted);
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  Future<void> _addOrEdit(AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _FollowupForm(existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context.read<AppState>().api.updateItem('pa/followups', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('pa/followups', result);
      }
      await _load();
      if (mounted) _toast(tr.paLiaSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
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
      appBar: AppBar(title: Text(tr.paLiaTitle)),
      // When the list is empty the welcome state already shows an Add CTA, so
      // suppress the FAB to avoid two identical "Add" buttons on one screen.
      floatingActionButton: (_loading || _error || _rows.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addOrEdit(tr),
              icon: const Icon(Icons.add),
              label: Text(tr.paLiaAdd),
            ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: tr.paLiaLoadError,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)),
                )
              : _rows.isEmpty
                  ? _welcome(tr, scheme)
                  : _body(tr, scheme),
    );
  }

  Widget _welcome(AppLocalizations tr, ColorScheme scheme) => StateMessage(
        icon: Icons.contact_mail_outlined,
        title: tr.paLiaWelcomeTitle,
        message: tr.paLiaWelcomeBody,
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(tr),
          icon: const Icon(Icons.add),
          label: Text(tr.paLiaAdd),
        ),
      );

  Widget _body(AppLocalizations tr, ColorScheme scheme) {
    final list = _ordered;
    return Column(children: [
      if (_overdueCount > 0) _overdueBanner(tr, scheme),
      _filterBar(tr, scheme),
      Expanded(
        child: list.isEmpty
            ? StateMessage(
                icon: Icons.filter_alt_off_outlined,
                title: tr.paLiaNoMatchTitle,
                message: tr.paLiaNoMatchBody,
                action: TextButton(
                  onPressed: () => setState(() {
                    _fStatus = null;
                    _onlyOverdue = false;
                  }),
                  child: Text(tr.paLiaClearFilters),
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

  Widget _overdueBanner(AppLocalizations tr, ColorScheme scheme) => Container(
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: Brand.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          const Icon(Icons.warning_amber_rounded, size: 20, color: Brand.warning),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.paLiaOverdueBanner('$_overdueCount'),
                style: TextStyle(color: scheme.onSurface, fontSize: 13, height: 1.3)),
          ),
          TextButton(
            onPressed: () => setState(() {
              _onlyOverdue = true;
              _fStatus = null;
            }),
            child: Text(tr.paLiaViewOverdue, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ]),
      );

  Widget _filterBar(AppLocalizations tr, ColorScheme scheme) {
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
          chip(tr.paLiaFilterAll, _fStatus == null && !_onlyOverdue, () {
            setState(() {
              _fStatus = null;
              _onlyOverdue = false;
            });
          }),
          chip(tr.paLiaFilterOverdue, _onlyOverdue,
              () => setState(() {
                    _onlyOverdue = !_onlyOverdue;
                    if (_onlyOverdue) _fStatus = null;
                  })),
          chip(_statusLabel(tr, _stWaiting), _fStatus == _stWaiting && !_onlyOverdue,
              () => setState(() {
                    _fStatus = _fStatus == _stWaiting ? null : _stWaiting;
                    _onlyOverdue = false;
                  })),
          chip(_statusLabel(tr, _stReplied), _fStatus == _stReplied && !_onlyOverdue,
              () => setState(() {
                    _fStatus = _fStatus == _stReplied ? null : _stReplied;
                    _onlyOverdue = false;
                  })),
          chip(_statusLabel(tr, _stDone), _fStatus == _stDone && !_onlyOverdue,
              () => setState(() {
                    _fStatus = _fStatus == _stDone ? null : _stDone;
                    _onlyOverdue = false;
                  })),
        ],
      ),
    );
  }

  String _statusLabel(AppLocalizations tr, String s) {
    switch (s) {
      case _stWaiting:
        return tr.paLiaStatusWaiting;
      case _stReplied:
        return tr.paLiaStatusReplied;
      case _stDone:
        return tr.paLiaStatusDone;
      default:
        return s;
    }
  }

  Color _urgencyColor(String u, ColorScheme scheme) {
    switch (u) {
      case 'overdue':
        return scheme.error;
      case 'due_soon':
        return Brand.warning;
      case 'done':
        return Brand.success;
      default:
        return scheme.primary;
    }
  }

  Widget _card(Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme) {
    final status = (r['status'] ?? _stWaiting).toString();
    final urgency = _urgency(r);
    final due = _parse(r['due_at']);
    final nudge = (r['nudge'] ?? 'off').toString();
    final raw = (r['contact'] ?? r['phone'] ?? r['email'] ?? '').toString();
    final hasContact = raw.trim().isNotEmpty;
    final nxt = _nextNudge(r);
    final overdue = urgency == 'overdue';
    final days = _daysUntilDue(r);
    final dfDate = DateFormat('EEE d MMM', tr.localeName);

    String? dueText;
    if (due != null) {
      if (overdue && days != null) {
        dueText = tr.paLiaOverdueBy('${-days}');
      } else if (urgency == 'due_soon' && days != null) {
        dueText = tr.paLiaDueInDays('$days');
      } else {
        dueText = dfDate.format(due.toLocal());
      }
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text((r['title'] ?? '').toString(),
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      decoration: status == _stDone ? TextDecoration.lineThrough : null,
                      color: status == _stDone ? scheme.onSurfaceVariant : scheme.onSurface),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            _pill(_statusLabel(tr, status), _urgencyColor(urgency, scheme)),
          ]),
          const SizedBox(height: 4),
          Text(tr.paLiaWith((r['counterpart'] ?? '').toString()),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.md, runSpacing: 4, children: [
            if (dueText != null)
              _meta(overdue ? Icons.event_busy : Icons.event, dueText,
                  overdue ? scheme.error : scheme.onSurfaceVariant),
            if (nudge != 'off' && nxt != null)
              _meta(Icons.notifications_active_outlined,
                  tr.paLiaNextNudge(DateFormat('d MMM', tr.localeName).format(nxt.toLocal())),
                  scheme.onSurfaceVariant),
            if (nudge == 'off')
              _meta(Icons.notifications_off_outlined, tr.paLiaNudgeOff, scheme.onSurfaceVariant),
            if (hasContact)
              _meta(Icons.contact_phone_outlined,
                  tr.paLiaContactHidden(_maskContact(raw)), scheme.onSurfaceVariant),
          ]),
          const Divider(height: Gap.xl),
          Row(children: [
            if (status != _stReplied && status != _stDone)
              TextButton.icon(
                onPressed: () => _setStatus(r, _stReplied, tr),
                icon: const Icon(Icons.reply, size: 18),
                label: Text(tr.paLiaMarkReplied, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            if (status == _stReplied)
              TextButton.icon(
                onPressed: () => _setStatus(r, _stWaiting, tr),
                icon: const Icon(Icons.hourglass_empty, size: 18),
                label: Text(tr.paLiaMarkWaiting, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            const Spacer(),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'edit') _addOrEdit(tr, existing: r);
                if (v == 'delete') _delete(r, tr);
                if (v == 'reopen') _setStatus(r, _stWaiting, tr);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                if (status == _stDone)
                  PopupMenuItem(value: 'reopen', child: Text(tr.paLiaReopen)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
          if (status != _stDone)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _setStatus(r, _stDone, tr),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(tr.paLiaMarkDone),
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

  Widget _meta(IconData icon, String text, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12.5, color: color)),
        ],
      );

  String _maskContact(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    final tail = s.length <= 4 ? s : s.substring(s.length - 4);
    final dots = (s.length - tail.length).clamp(0, 5);
    return '${'·' * dots}$tail';
  }
}

/// Add / edit follow-up form.
class _FollowupForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _FollowupForm({this.existing});
  @override
  State<_FollowupForm> createState() => _FollowupFormState();
}

class _FollowupFormState extends State<_FollowupForm> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?['title']?.toString() ?? '');
  late final TextEditingController _counterpart = TextEditingController(
      text: widget.existing?['counterpart']?.toString() ?? '');
  late final TextEditingController _contact = TextEditingController(
      text: (widget.existing?['contact'] ??
              widget.existing?['phone'] ??
              widget.existing?['email'] ??
              '')
          .toString());
  late String _nudge = _nudgeDays.containsKey((widget.existing?['nudge'] ?? 'off').toString())
      ? (widget.existing?['nudge'] ?? 'off').toString()
      : 'off';
  DateTime? _due;

  @override
  void initState() {
    super.initState();
    final d = widget.existing?['due_at'];
    if (d != null) _due = DateTime.tryParse(d.toString())?.toLocal();
  }

  @override
  void dispose() {
    _title.dispose();
    _counterpart.dispose();
    _contact.dispose();
    super.dispose();
  }

  String _nudgeLabel(AppLocalizations tr, String n) {
    switch (n) {
      case 'daily':
        return tr.paLiaNudgeDaily;
      case 'every_3_days':
        return tr.paLiaNudgeEvery3;
      case 'weekly':
        return tr.paLiaNudgeWeekly;
      default:
        return tr.paLiaNudgeOff;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final fmt = DateFormat('EEE d MMM', tr.localeName);
    final titleOk = _title.text.trim().isNotEmpty;
    final cpOk = _counterpart.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.existing == null ? tr.paLiaAdd : tr.paLiaEdit,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _title,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.paLiaTitleField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _counterpart,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: tr.paLiaCounterpart, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _contact,
            decoration: InputDecoration(
                labelText: tr.paLiaContactOptional,
                helperText: tr.paLiaContactPrivacyNote,
                helperMaxLines: 2,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
            onPressed: () async {
              final base = _due ?? DateTime.now().add(const Duration(days: 2));
              final d = await showDatePicker(
                context: context,
                initialDate: base,
                firstDate: DateTime.now().subtract(const Duration(days: 365)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d == null) return;
              setState(() => _due = DateTime(d.year, d.month, d.day, 9));
            },
            icon: const Icon(Icons.event),
            label: Text(_due == null ? tr.paLiaPickDue : fmt.format(_due!),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (_due != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _due = null),
                child: Text(tr.paLiaClearDue),
              ),
            ),
          const SizedBox(height: Gap.md),
          Text(tr.paLiaNudgeLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.sm,
            children: _nudgeDays.keys.map((n) {
              return ChoiceChip(
                label: Text(_nudgeLabel(tr, n)),
                selected: _nudge == n,
                onSelected: (_) => setState(() => _nudge = n),
              );
            }).toList(),
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
                onPressed: (titleOk && cpOk)
                    ? () => Navigator.pop(context, <String, dynamic>{
                          'title': _title.text.trim(),
                          'counterpart': _counterpart.text.trim(),
                          'contact': _contact.text.trim(),
                          'nudge': _nudge,
                          if (_due != null) 'due_at': _due!.toUtc().toIso8601String(),
                          if (_due == null) 'due_at': null,
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
