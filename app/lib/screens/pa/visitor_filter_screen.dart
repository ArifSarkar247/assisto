import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';

/// PA Secretary Mode · Visitor / Appointment Filter — ADVANCED (#105, §14).
///
/// The PA screens incoming visit/appointment requests in a queue the owner
/// triages: approve / decline / reschedule-suggest. Each request carries a
/// VIP/normal priority tag, and the queue filters by status and priority.
///
/// Honest states: welcome (first use) · loading · error · empty-for-filter.
/// Approve and decline sit behind a confirm gate. Visitor contact is
/// privacy-minimised — the list never shows a raw phone/email, only a masked
/// hint. All logic mirrors backend/core/logic/pa_visitor.py so the preview is
/// deterministic and identical offline. ZERO Bangla literals — every string is
/// an AppLocalizations getter.
///
/// Endpoints (generic api helpers, no api.dart edit):
///   listItems('pa/visitors')            → List of request rows
///   createItem('pa/visitors', body)     → create a request
///   updateItem('pa/visitors', id, body) → triage / priority / edit
///   deleteItem('pa/visitors', id)       → remove a request
class VisitorFilterScreen extends StatefulWidget {
  const VisitorFilterScreen({super.key});
  @override
  State<VisitorFilterScreen> createState() => _VisitorFilterScreenState();
}

// ---- status / priority constants (mirror pa_visitor.py) -------------------
const String _stPending = 'pending';
const String _stApproved = 'approved';
const String _stDeclined = 'declined';
const String _stSuggested = 'suggested';
const String _stExpired = 'expired';

const String _prVip = 'vip';
const String _prNormal = 'normal';

class _VisitorFilterScreenState extends State<VisitorFilterScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;

  // active filters (null ⇒ any). Status is the *effective* status.
  String? _fStatus;
  String? _fPriority;

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
      _rows = await context.read<AppState>().api.listItems('pa/visitors');
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- deterministic mirror of pa_visitor.py -------------------------------
  DateTime get _now => DateTime.now();

  DateTime? _parse(dynamic v) {
    if (v == null) return null;
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).round(),
          isUtc: true);
    }
    return DateTime.tryParse(v.toString());
  }

  String _effectiveStatus(Map<String, dynamic> r) {
    final stored = (r['status'] ?? _stPending).toString();
    if (stored != _stPending) return stored;
    final when = _parse(r['requested_at']);
    if (when != null && when.isBefore(_now)) return _stExpired;
    return _stPending;
  }

  int _priorityRank(String p) => p == _prVip ? 0 : 1;
  int _statusRank(String s) {
    switch (s) {
      case _stPending:
        return 0;
      case _stSuggested:
        return 1;
      case _stExpired:
        return 2;
      case _stApproved:
        return 3;
      default:
        return 4; // declined
    }
  }

  List<Map<String, dynamic>> get _ordered {
    final list = _rows.where((r) {
      if (_fStatus != null && _effectiveStatus(r) != _fStatus) return false;
      if (_fPriority != null &&
          (r['priority'] ?? _prNormal).toString() != _fPriority) {
        return false;
      }
      return true;
    }).toList();
    list.sort((a, b) {
      final pa = _priorityRank((a['priority'] ?? _prNormal).toString());
      final pb = _priorityRank((b['priority'] ?? _prNormal).toString());
      if (pa != pb) return pa - pb;
      final sa = _statusRank(_effectiveStatus(a));
      final sb = _statusRank(_effectiveStatus(b));
      if (sa != sb) return sa - sb;
      final ta = _parse(a['requested_at']);
      final tb = _parse(b['requested_at']);
      final ea = ta?.millisecondsSinceEpoch ?? 1 << 62;
      final eb = tb?.millisecondsSinceEpoch ?? 1 << 62;
      if (ea != eb) return ea.compareTo(eb);
      return (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString());
    });
    return list;
  }

  int _countFor(String status) =>
      _rows.where((r) => _effectiveStatus(r) == status).length;
  int get _needsAttention =>
      _countFor(_stPending) + _countFor(_stSuggested) + _countFor(_stExpired);

  // ---- actions -------------------------------------------------------------
  Future<void> _triage(
      Map<String, dynamic> r, String event, AppLocalizations tr) async {
    // approve / decline gated behind confirm; suggest opens a time picker.
    if (event == 'approve' || event == 'decline') {
      final confirmed = await _confirm(
        tr,
        title: event == 'approve' ? tr.paVisApproveConfirmTitle : tr.paVisDeclineConfirmTitle,
        body: event == 'approve'
            ? tr.paVisApproveConfirmBody((r['name'] ?? '').toString())
            : tr.paVisDeclineConfirmBody((r['name'] ?? '').toString()),
        confirmLabel: event == 'approve' ? tr.paVisApprove : tr.paVisDecline,
        danger: event == 'decline',
      );
      if (confirmed != true) return;
      await _apply(r, {
        'status': event == 'approve' ? _stApproved : _stDeclined,
      }, tr);
      return;
    }
    if (event == 'suggest') {
      final picked = await _pickDateTime(context, _parse(r['requested_at']));
      if (picked == null) return;
      await _apply(r, {
        'status': _stSuggested,
        'requested_at': picked.toUtc().toIso8601String(),
        'suggested_at': picked.toUtc().toIso8601String(),
      }, tr);
    }
  }

  Future<void> _setPriority(
      Map<String, dynamic> r, String priority, AppLocalizations tr) async {
    await _apply(r, {'priority': priority}, tr);
  }

  Future<void> _apply(
      Map<String, dynamic> r, Map<String, dynamic> body, AppLocalizations tr) async {
    final id = r['id'];
    try {
      if (id is int) {
        await context.read<AppState>().api.updateItem('pa/visitors', id, body);
      }
      await _load();
      if (mounted) _toast(tr.paVisSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final ok = await _confirm(
      tr,
      title: tr.paVisDeleteConfirmTitle,
      body: tr.paVisDeleteConfirmBody((r['name'] ?? '').toString()),
      confirmLabel: tr.delete,
      danger: true,
    );
    if (ok != true) return;
    final id = r['id'];
    try {
      if (id is int) await context.read<AppState>().api.deleteItem('pa/visitors', id);
      await _load();
      if (mounted) _toast(tr.paVisDeleted);
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  Future<void> _addOrEdit(AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _VisitorForm(existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context.read<AppState>().api.updateItem('pa/visitors', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('pa/visitors', result);
      }
      await _load();
      if (mounted) _toast(tr.paVisSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  // ---- small helpers -------------------------------------------------------
  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool?> _confirm(AppLocalizations tr,
      {required String title,
      required String body,
      required String confirmLabel,
      bool danger = false}) {
    final scheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<DateTime?> _pickDateTime(BuildContext ctx, DateTime? seed) async {
    final base = seed ?? DateTime.now().add(const Duration(days: 1));
    final d = await showDatePicker(
      context: ctx,
      initialDate: base,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return null;
    final t = await showTimePicker(
      context: ctx,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  // ---- build ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.paVisTitle)),
      floatingActionButton: _rows.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _loading ? null : () => _addOrEdit(tr),
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(tr.paVisAddRequest),
            ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: tr.paVisLoadError,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)),
                )
              : _rows.isEmpty
                  ? _welcome(tr, scheme)
                  : _queue(tr, scheme),
    );
  }

  // First-use welcome state — explains the feature honestly before any data.
  Widget _welcome(AppLocalizations tr, ColorScheme scheme) => StateMessage(
        icon: Icons.how_to_reg_outlined,
        title: tr.paVisWelcomeTitle,
        message: tr.paVisWelcomeBody,
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(tr),
          icon: const Icon(Icons.person_add_alt_1),
          label: Text(tr.paVisAddRequest),
        ),
      );

  Widget _queue(AppLocalizations tr, ColorScheme scheme) {
    final list = _ordered;
    return Column(children: [
      _summaryBar(tr, scheme),
      _filterBar(tr, scheme),
      Expanded(
        child: list.isEmpty
            ? StateMessage(
                icon: Icons.filter_alt_off_outlined,
                title: tr.paVisNoMatchTitle,
                message: tr.paVisNoMatchBody,
                action: TextButton(
                  onPressed: () => setState(() {
                    _fStatus = null;
                    _fPriority = null;
                  }),
                  child: Text(tr.paVisClearFilters),
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

  Widget _summaryBar(AppLocalizations tr, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
        child: Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(children: [
            Icon(Icons.inbox_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                tr.paVisSummary('$_needsAttention', '${_countFor(_stPending)}',
                    '${_countFor(_stExpired)}'),
                style: TextStyle(color: scheme.onSurface, fontSize: 13, height: 1.3),
              ),
            ),
          ]),
        ),
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
          chip(tr.paVisFilterAll, _fStatus == null && _fPriority == null, () {
            setState(() {
              _fStatus = null;
              _fPriority = null;
            });
          }),
          chip(tr.paVisPriorityVip, _fPriority == _prVip,
              () => setState(() => _fPriority = _fPriority == _prVip ? null : _prVip)),
          chip(_statusLabel(tr, _stPending), _fStatus == _stPending,
              () => setState(() => _fStatus = _fStatus == _stPending ? null : _stPending)),
          chip(_statusLabel(tr, _stSuggested), _fStatus == _stSuggested,
              () => setState(() => _fStatus = _fStatus == _stSuggested ? null : _stSuggested)),
          chip(_statusLabel(tr, _stApproved), _fStatus == _stApproved,
              () => setState(() => _fStatus = _fStatus == _stApproved ? null : _stApproved)),
          chip(_statusLabel(tr, _stDeclined), _fStatus == _stDeclined,
              () => setState(() => _fStatus = _fStatus == _stDeclined ? null : _stDeclined)),
          chip(_statusLabel(tr, _stExpired), _fStatus == _stExpired,
              () => setState(() => _fStatus = _fStatus == _stExpired ? null : _stExpired)),
        ],
      ),
    );
  }

  String _statusLabel(AppLocalizations tr, String s) {
    switch (s) {
      case _stPending:
        return tr.paVisStatusPending;
      case _stApproved:
        return tr.paVisStatusApproved;
      case _stDeclined:
        return tr.paVisStatusDeclined;
      case _stSuggested:
        return tr.paVisStatusSuggested;
      case _stExpired:
        return tr.paVisStatusExpired;
      default:
        return s;
    }
  }

  Color _statusColor(String s, ColorScheme scheme) {
    switch (s) {
      case _stApproved:
        return Brand.success;
      case _stDeclined:
        return scheme.error;
      case _stExpired:
        return Brand.warning;
      case _stSuggested:
        return Brand.purple;
      default:
        return scheme.primary; // pending
    }
  }

  Widget _card(Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme) {
    final status = _effectiveStatus(r);
    final isVip = (r['priority'] ?? _prNormal).toString() == _prVip;
    final when = _parse(r['requested_at']);
    final raw = (r['contact'] ?? r['phone'] ?? r['email'] ?? '').toString();
    final hasContact = raw.trim().isNotEmpty;
    final hint = _maskContact(raw);
    final actionable = status == _stPending || status == _stExpired;
    final fmt = DateFormat('EEE d MMM, h:mm a', tr.localeName);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (isVip) ...[
              Icon(Icons.star, size: 18, color: Brand.warning),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text((r['name'] ?? '').toString(),
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            _statusPill(status, tr, scheme),
          ]),
          if ((r['reason'] ?? '').toString().trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text((r['reason']).toString(),
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.md, runSpacing: 4, children: [
            if (when != null)
              _meta(Icons.event, fmt.format(when.toLocal()), scheme),
            if (hasContact)
              _meta(Icons.contact_phone_outlined,
                  tr.paVisContactHidden(hint), scheme),
          ]),
          const Divider(height: Gap.xl),
          // Priority toggle + triage / manage actions.
          Row(children: [
            TextButton.icon(
              onPressed: () => _setPriority(r, isVip ? _prNormal : _prVip, tr),
              icon: Icon(isVip ? Icons.star : Icons.star_border, size: 18),
              label: Text(isVip ? tr.paVisPriorityNormal : tr.paVisMarkVip,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Spacer(),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
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
          if (actionable)
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _triage(r, 'decline', tr),
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(tr.paVisDecline, maxLines: 1, overflow: TextOverflow.ellipsis),
                  style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _triage(r, 'suggest', tr),
                  icon: const Icon(Icons.schedule, size: 18),
                  label: Text(tr.paVisSuggest, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _triage(r, 'approve', tr),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(tr.paVisApprove, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ]),
        ]),
      ),
    );
  }

  Widget _statusPill(String status, AppLocalizations tr, ColorScheme scheme) {
    final c = _statusColor(status, scheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(_statusLabel(tr, status),
          style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }

  Widget _meta(IconData icon, String text, ColorScheme scheme) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
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

/// Add / edit form — bottom sheet. Returns the body map or null on cancel.
class _VisitorForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _VisitorForm({this.existing});
  @override
  State<_VisitorForm> createState() => _VisitorFormState();
}

class _VisitorFormState extends State<_VisitorForm> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?['name']?.toString() ?? '');
  late final TextEditingController _reason =
      TextEditingController(text: widget.existing?['reason']?.toString() ?? '');
  late final TextEditingController _contact = TextEditingController(
      text: (widget.existing?['contact'] ??
              widget.existing?['phone'] ??
              widget.existing?['email'] ??
              '')
          .toString());
  late String _priority =
      (widget.existing?['priority'] ?? _prNormal).toString() == _prVip ? _prVip : _prNormal;
  DateTime? _when;

  @override
  void initState() {
    super.initState();
    final w = widget.existing?['requested_at'];
    if (w != null) _when = DateTime.tryParse(w.toString())?.toLocal();
  }

  @override
  void dispose() {
    _name.dispose();
    _reason.dispose();
    _contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final fmt = DateFormat('EEE d MMM, h:mm a', tr.localeName);
    final nameOk = _name.text.trim().isNotEmpty;
    final reasonOk = _reason.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.existing == null ? tr.paVisAddRequest : tr.paVisEditRequest,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: tr.paVisVisitorName, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _reason,
            onChanged: (_) => setState(() {}),
            maxLines: 3,
            decoration: InputDecoration(
                labelText: tr.paVisReason, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _contact,
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
                labelText: tr.paVisContactOptional,
                helperText: tr.paVisContactPrivacyNote,
                helperMaxLines: 2,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
            onPressed: () async {
              final base = _when ?? DateTime.now().add(const Duration(days: 1));
              final d = await showDatePicker(
                context: context,
                initialDate: base,
                firstDate: DateTime.now().subtract(const Duration(days: 1)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d == null || !context.mounted) return;
              final t = await showTimePicker(
                  context: context, initialTime: TimeOfDay.fromDateTime(base));
              if (t == null) return;
              setState(() => _when = DateTime(d.year, d.month, d.day, t.hour, t.minute));
            },
            icon: const Icon(Icons.event),
            label: Text(_when == null ? tr.paVisPickTime : fmt.format(_when!),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: Gap.md),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: _prNormal, label: Text(tr.paVisPriorityNormal)),
              ButtonSegment(value: _prVip, label: Text(tr.paVisPriorityVip), icon: const Icon(Icons.star, size: 16)),
            ],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
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
                onPressed: (nameOk && reasonOk)
                    ? () => Navigator.pop(context, <String, dynamic>{
                          'name': _name.text.trim(),
                          'reason': _reason.text.trim(),
                          'contact': _contact.text.trim(),
                          'priority': _priority,
                          if (_when != null)
                            'requested_at': _when!.toUtc().toIso8601String(),
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
