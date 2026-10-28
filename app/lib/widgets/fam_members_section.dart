import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../famcare_api.dart';
import '../l10n/app_localizations.dart';
import '../m3_circle_api.dart';
import '../state.dart';
import '../theme.dart';
import 'app_sheet.dart';
import 'circle_relation.dart';
import 'fam_empty.dart';

/// famcare (owner real-phone review 28 Oct) — the Family tab.
///
/// * The family alerts entry + notifications-off banner arrive as [header]
///   and render ONLY here (they used to sit above every tab).
/// * Members come from My Circle in ONE tap ([showFamCirclePicker]); nobody
///   is typed twice (the server links a hand-typed twin and refuses a
///   duplicate). Someone not in the Circle can still be added by hand —
///   saving also sends them a My Circle request so they get SOS.
/// * Each card says honestly whether that person receives the family SOS
///   (only accepted My Circle members do).
/// * Give a task: a reminder in the member's own list (shared reminders).
class FamMembersSection extends StatefulWidget {
  const FamMembersSection({
    super.key,
    required this.members,
    required this.onChanged,
    this.header,
  });

  final List<Map<String, dynamic>> members;
  final Future<void> Function() onChanged;
  final Widget? header;

  @override
  State<FamMembersSection> createState() => _FamMembersSectionState();
}

/// Family relation codes offered when adding by hand (Circle vocabulary).
const List<String> kFamRelationCodes = [
  'mother', 'father', 'wife', 'husband', 'child', 'sister', 'brother',
  'relative', 'custom',
];

/// A stored relation may be a Circle code ('mother') or old free text.
String famRelationLabel(AppLocalizations t, String rel) {
  final r = rel.trim();
  if (r.isEmpty) return '';
  final known = CircleRelation.catalog.any((c) => c.code == r);
  return known ? CircleRelation.labelFor(t, r) : r;
}

bool famInCircle(Map<String, dynamic> m) =>
    m['in_circle'] == true || (m['circle_member'] != null && m['in_circle'] == null);

class _FamMembersSectionState extends State<FamMembersSection> {
  List<Map<String, dynamic>> _tasks = const [];
  bool _tasksFailed = false;
  int? _limit;

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _loadExtras();
  }

  Future<void> _loadExtras() async {
    try {
      final r = await _api.famTasks();
      final rows = (r['assigned_by_me'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (mounted) setState(() { _tasks = rows; _tasksFailed = false; });
    } catch (_) {
      if (mounted) setState(() => _tasksFailed = true);
    }
    try {
      final l = await _api.famLimits();
      if (mounted) setState(() => _limit = (l['limit'] as num?)?.toInt());
    } catch (_) {} // best-effort: only the "x of 5" line
  }

  Future<void> _refresh() async {
    await widget.onChanged();
    await _loadExtras();
  }

  Future<void> _pick() async {
    final changed = await showFamCirclePicker(context, onAddByHand: _addByHand);
    if (changed == true) await _refresh();
  }

  Future<void> _addByHand() async {
    final ok = await showFamMemberForm(context);
    if (ok == true) await _refresh();
  }

  Future<void> _edit(Map<String, dynamic> m) async {
    final ok = await showFamMemberForm(context, existing: m);
    if (ok == true) await _refresh();
  }

  Future<void> _remove(Map<String, dynamic> m) async {
    final t = _t;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.fcRemoveTitle),
        content: Text(t.fcRemoveBody('${m['name'] ?? ''}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fcRemove)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await _api.deleteItem('family', m['id'] as int);
      await _refresh();
    } catch (e) {
      if (mounted) _snack(e is ApiException ? e.message : t.grpActionFailed);
    }
  }

  Future<void> _giveTask([Map<String, dynamic>? m]) async {
    final ok = await showFamTaskForm(context, members: widget.members, member: m);
    if (ok == true) await _loadExtras();
  }

  Future<void> _cancelTask(Map<String, dynamic> task) async {
    try {
      await _api.famCancelTask(task['id'] as int);
      await _loadExtras();
    } catch (_) {
      if (mounted) _snack(_t.grpActionFailed);
    }
  }

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:$phone');
    try {
      await launchUrl(uri);
    } catch (_) {
      if (mounted) _snack(_t.grpActionFailed);
    }
  }

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (widget.members.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: FamEmptyState(
          header: widget.header,
          icon: Icons.family_restroom_rounded,
          title: t.fcFamilyEmptyTitle,
          benefit: t.fcFamilyEmptyBenefit,
          primaryLabel: t.fcPickFromCircle,
          primaryIcon: Icons.group_add_rounded,
          onPrimary: _pick,
          secondaryLabel: t.fcAddByHand,
          onSecondary: _addByHand,
          steps: [t.fcFamilyStep1, t.fcFamilyStep2, t.fcFamilyStep3],
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final n = widget.members.length;
    final pending = _tasks.where((x) => x['done'] != true).toList();
    final done = _tasks.where((x) => x['done'] == true).take(5).toList();
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: withNavBarInset(
            context, const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xxl)),
        children: [
          if (widget.header != null) widget.header!,
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: FilledButton.icon(
                  key: const ValueKey('fc-pick-btn'),
                  onPressed: _pick,
                  icon: const Icon(Icons.group_add_rounded),
                  label: Text(t.fcPickFromCircle, maxLines: 2, textAlign: TextAlign.center),
                ),
              ),
            ),
            const SizedBox(width: Gap.sm),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                key: const ValueKey('fc-hand-btn'),
                onPressed: _addByHand,
                child: Text(t.fcAddByHandShort),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(
            _limit == null
                ? t.fcSafetyFree
                : '${t.fcMembersOf(famDigits(context, '$n'), famDigits(context, '$_limit'))} · ${t.fcSafetyFree}',
            key: const ValueKey('fc-limit-line'),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Gap.sm),
          for (final m in widget.members) _memberCard(m, scheme),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: Text(t.fcTasksTitle,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              key: const ValueKey('fc-task-btn'),
              onPressed: () => _giveTask(),
              icon: const Icon(Icons.add_task_rounded),
              label: Text(t.fcGiveTask),
            ),
          ]),
          Text(t.fcTasksSub, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          if (_tasksFailed)
            Card(
              color: scheme.errorContainer,
              child: ListTile(
                leading: Icon(Icons.cloud_off_rounded, color: scheme.onErrorContainer),
                title: Text(t.loadFailed, style: TextStyle(color: scheme.onErrorContainer)),
                trailing: IconButton(
                  tooltip: t.retry,
                  icon: Icon(Icons.refresh_rounded, color: scheme.onErrorContainer),
                  onPressed: _loadExtras,
                ),
              ),
            )
          else if (_tasks.isEmpty)
            Text(t.fcTasksEmpty, style: TextStyle(color: scheme.onSurfaceVariant))
          else ...[
            for (final x in pending) _taskTile(x, scheme),
            for (final x in done) _taskTile(x, scheme),
          ],
        ],
      ),
    );
  }

  Widget _memberCard(Map<String, dynamic> m, ColorScheme scheme) {
    final t = _t;
    final inCircle = famInCircle(m);
    final rel = famRelationLabel(t, '${m['relation'] ?? ''}');
    final phone = '${m['phone'] ?? ''}'.trim();
    final sub = [rel, if (phone.isNotEmpty) famDigits(context, phone)]
        .where((s) => s.isNotEmpty)
        .join(' · ');
    return Card(
      key: ValueKey('fc-member-${m['id']}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              backgroundColor: scheme.secondaryContainer,
              child: Text(
                  ('${m['name'] ?? ''}'.trim().isEmpty ? '?' : '${m['name']}'.trim()[0])
                      .toUpperCase(),
                  style: TextStyle(color: scheme.onSecondaryContainer)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${m['name'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
                if (sub.isNotEmpty)
                  Text(sub, style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
            ),
            if (phone.isNotEmpty)
              IconButton(
                  tooltip: t.call,
                  icon: const Icon(Icons.call_rounded),
                  onPressed: () => _call(phone)),
            PopupMenuButton<String>(
              tooltip: t.fcMore,
              onSelected: (v) {
                if (v == 'edit') _edit(m);
                if (v == 'task') _giveTask(m);
                if (v == 'remove') _remove(m);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'task', enabled: inCircle, child: Text(t.fcGiveTask)),
                PopupMenuItem(value: 'edit', child: Text(t.edit)),
                PopupMenuItem(value: 'remove', child: Text(t.fcRemove)),
              ],
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Chip(
              key: ValueKey(inCircle ? 'fc-sos-yes' : 'fc-sos-no'),
              visualDensity: VisualDensity.compact,
              avatar: Icon(inCircle ? Icons.verified_user_rounded : Icons.info_outline_rounded,
                  size: 18, color: inCircle ? Brand.success : Brand.warning),
              label: Text(inCircle ? t.fcGetsSos : t.fcNoSos),
            ),
            if (!inCircle && phone.isNotEmpty)
              TextButton(
                onPressed: () => _invite(m),
                child: Text(t.fcInviteToCircle),
              ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _invite(Map<String, dynamic> m) async {
    final t = _t;
    final rel = '${m['relation'] ?? ''}';
    final code = kFamRelationCodes.contains(rel) ? rel : 'relative';
    try {
      await _api.m3SendRequest(phone: '${m['phone']}', relation: code);
      if (mounted) _snack(t.fcInviteSent);
    } catch (e) {
      if (mounted) _snack(e is ApiException && e.message.isNotEmpty ? e.message : t.grpActionFailed);
    }
  }

  Widget _taskTile(Map<String, dynamic> x, ColorScheme scheme) {
    final t = _t;
    final done = x['done'] == true;
    final due = DateTime.tryParse('${x['due_at'] ?? ''}')?.toLocal();
    final who = '${x['to_name'] ?? ''}';
    final when = due == null
        ? ''
        : '${famDate(context, due)} ${famDigits(context, TimeOfDay.fromDateTime(due).format(context))}';
    return Card(
      child: ListTile(
        minTileHeight: 56,
        leading: Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: done ? Brand.success : scheme.onSurfaceVariant),
        title: Text('${x['title'] ?? ''}',
            style: done ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
        subtitle: Text([
          who,
          if (when.isNotEmpty) when,
          done ? t.fcTaskDone : t.fcTaskWaiting,
        ].where((s) => s.trim().isNotEmpty).join(' · ')),
        trailing: done
            ? null
            : IconButton(
                tooltip: t.fcTaskCancel,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => _cancelTask(x)),
      ),
    );
  }
}

// --------------------------------------------------------------- picker
/// The one-tap "pick from My Circle" sheet. Returns true when something was
/// added. Rows already in the family list show a tick and cannot be added
/// twice; an empty Circle offers "add someone by phone" instead.
Future<bool?> showFamCirclePicker(BuildContext context,
    {required Future<void> Function() onAddByHand}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _FamCirclePicker(onAddByHand: onAddByHand),
  );
}

class _FamCirclePicker extends StatefulWidget {
  const _FamCirclePicker({required this.onAddByHand});
  final Future<void> Function() onAddByHand;
  @override
  State<_FamCirclePicker> createState() => _FamCirclePickerState();
}

class _FamCirclePickerState extends State<_FamCirclePicker> {
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;
  bool _added = false;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final r = await context.read<AppState>().api.famCirclePick();
      if (mounted) setState(() => _rows = famPickRows(r));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _add(Map<String, dynamic> row) async {
    final id = (row['circle_id'] as num).toInt();
    setState(() => _busy.add(id));
    try {
      final r = await context.read<AppState>().api.famFromCircle(id);
      final fid = (r['member'] as Map?)?['id'];
      if (mounted) {
        setState(() {
          row['family_id'] = fid;
          _added = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e is ApiException && e.message.isNotEmpty
                ? e.message
                : AppLocalizations.of(context).grpActionFailed)));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    if (_failed) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.loadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
      ]);
    } else if (_rows == null) {
      body = const Padding(
          padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()));
    } else if (_rows!.isEmpty) {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.fcCircleEmpty, textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        Text(t.fcCircleEmptySub, textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant)),
      ]);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        for (final r in _rows!) _row(r, t, scheme),
      ]);
    }
    return AppSheetBody(
      primary: SizedBox(
        height: 48,
        child: _added
            ? FilledButton(
                key: const ValueKey('fc-pick-done'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(t.fcDone))
            : OutlinedButton.icon(
                key: const ValueKey('fc-pick-hand'),
                onPressed: () async {
                  Navigator.pop(context, false);
                  await widget.onAddByHand();
                },
                icon: const Icon(Icons.person_add_alt_rounded),
                label: Text(t.fcAddByHand)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.fcPickFromCircle,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.fcPickSub, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        body,
      ]),
    );
  }

  Widget _row(Map<String, dynamic> r, AppLocalizations t, ColorScheme scheme) {
    final id = (r['circle_id'] as num).toInt();
    final added = r['family_id'] != null;
    final busy = _busy.contains(id);
    final rel = CircleRelation.labelFor(t, '${r['relation'] ?? ''}',
        custom: '${r['custom_label'] ?? ''}');
    return ListTile(
      key: ValueKey('fc-pick-$id'),
      minTileHeight: 56,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(child: Text(
          ('${r['name'] ?? ''}'.trim().isEmpty ? '?' : '${r['name']}'.trim()[0]).toUpperCase())),
      title: Text('${r['name'] ?? ''}'),
      subtitle: Text(rel),
      trailing: added
          ? Semantics(
              label: t.fcAlreadyAdded,
              child: const Icon(Icons.check_circle_rounded, color: Brand.success))
          : busy
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_circle_outline_rounded),
      onTap: added || busy ? null : () => _add(r),
    );
  }
}

// ------------------------------------------------------- add / edit by hand
/// Add (or edit) a family member who is NOT in My Circle. Saving a new one
/// with a phone also sends a My Circle request, so they can get the SOS.
Future<bool?> showFamMemberForm(BuildContext context, {Map<String, dynamic>? existing}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _FamMemberForm(existing: existing),
  );
}

class _FamMemberForm extends StatefulWidget {
  const _FamMemberForm({this.existing});
  final Map<String, dynamic>? existing;
  @override
  State<_FamMemberForm> createState() => _FamMemberFormState();
}

class _FamMemberFormState extends State<_FamMemberForm> {
  late final _name = TextEditingController(text: '${widget.existing?['name'] ?? ''}');
  late final _phone = TextEditingController(text: '${widget.existing?['phone'] ?? ''}');
  late final _custom = TextEditingController();
  String? _rel;
  bool _invite = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final r = '${widget.existing?['relation'] ?? ''}';
    if (kFamRelationCodes.contains(r)) {
      _rel = r;
    } else if (r.isNotEmpty) {
      _rel = 'custom';
      _custom.text = r;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _custom.dispose();
    super.dispose();
  }

  bool get _editing => widget.existing != null;
  bool get _linked => _editing && famInCircle(widget.existing!);

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final rel = _rel == 'custom' ? _custom.text.trim() : (_rel ?? '');
    final phone = _phone.text.trim();
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final body = {'name': name, 'relation': rel, 'phone': phone};
      if (_editing) {
        await api.updateItem('family', widget.existing!['id'] as int, body);
      } else {
        await api.createItem('family', body);
      }
      String msg = t.fcSaved;
      if (!_linked && _invite && phone.isNotEmpty) {
        try {
          await api.m3SendRequest(
              phone: phone,
              relation: (_rel == null || _rel == 'custom') ? 'relative' : _rel!);
          msg = t.fcSavedInvited;
        } catch (e) {
          msg = t.fcSavedInviteFailed;
        }
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
          content: Text(e is ApiException && e.message.isNotEmpty ? e.message : t.grpActionFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
          key: const ValueKey('fc-form-save'),
          onPressed: _saving ? null : _save,
          child: Text(t.save),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_editing ? t.medEditMember : t.fcAddByHand,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        if (!_editing) ...[
          const SizedBox(height: Gap.xs),
          Text(t.fcAddByHandSub, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: Gap.md),
        TextField(
            key: const ValueKey('fc-form-name'),
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: t.name)),
        const SizedBox(height: Gap.md),
        Text(t.familyRelationLabel, style: AType.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final code in kFamRelationCodes)
            ChoiceChip(
              label: Text(CircleRelation.labelFor(t, code)),
              selected: _rel == code,
              onSelected: (_) => setState(() => _rel = code),
            ),
        ]),
        if (_rel == 'custom') ...[
          const SizedBox(height: Gap.sm),
          TextField(controller: _custom, decoration: InputDecoration(labelText: t.familyRelationLabel)),
        ],
        const SizedBox(height: Gap.md),
        TextField(
            key: const ValueKey('fc-form-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: t.phoneOptional)),
        if (!_linked)
          CheckboxListTile(
            key: const ValueKey('fc-form-invite'),
            contentPadding: EdgeInsets.zero,
            value: _invite && _phone.text.trim().isNotEmpty,
            onChanged: _phone.text.trim().isEmpty ? null : (v) => setState(() => _invite = v ?? false),
            title: Text(t.fcAlsoInvite),
            subtitle: Text(t.fcAlsoInviteSub),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------ give a task
/// Assign a reminder to a family member: it lands in THEIR reminder list
/// (with a push unless their quiet hours); you see when they finish it.
Future<bool?> showFamTaskForm(BuildContext context,
    {required List<Map<String, dynamic>> members, Map<String, dynamic>? member}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _FamTaskForm(members: members, member: member),
  );
}

class _FamTaskForm extends StatefulWidget {
  const _FamTaskForm({required this.members, this.member});
  final List<Map<String, dynamic>> members;
  final Map<String, dynamic>? member;
  @override
  State<_FamTaskForm> createState() => _FamTaskFormState();
}

class _FamTaskFormState extends State<_FamTaskForm> {
  final _title = TextEditingController();
  int? _mid;
  DateTime? _due;
  bool _saving = false;

  List<Map<String, dynamic>> get _linked =>
      widget.members.where(famInCircle).toList();

  @override
  void initState() {
    super.initState();
    final m = widget.member;
    if (m != null && famInCircle(m)) {
      _mid = m['id'] as int?;
    } else if (_linked.length == 1) {
      _mid = _linked.first['id'] as int?;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context,
        initialDate: _due ?? now,
        firstDate: DateTime(now.year, now.month, now.day),
        lastDate: now.add(const Duration(days: 365)));
    if (d == null || !mounted) return;
    final tm = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_due ?? now.add(const Duration(hours: 1))));
    if (!mounted) return;
    setState(() => _due = DateTime(d.year, d.month, d.day, tm?.hour ?? 9, tm?.minute ?? 0));
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final title = _title.text.trim();
    if (title.isEmpty || _mid == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.famAssignTask(memberId: _mid!, title: title, due: _due);
      if (!mounted) return;
      Navigator.pop(context, true);
      messenger.showSnackBar(SnackBar(content: Text(t.fcTaskSent)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
          content: Text(e is ApiException && e.message.isNotEmpty ? e.message : t.grpActionFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final linked = _linked;
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
          key: const ValueKey('fc-task-save'),
          onPressed: (_saving || linked.isEmpty) ? null : _save,
          child: Text(t.fcGiveTask),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.fcGiveTask,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.fcTasksSub, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        if (linked.isEmpty)
          Text(t.fcTaskNeedsCircle, key: const ValueKey('fc-task-needs-circle'))
        else ...[
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final m in linked)
              ChoiceChip(
                label: Text('${m['name'] ?? ''}'),
                selected: _mid == m['id'],
                onSelected: (_) => setState(() => _mid = m['id'] as int?),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
              key: const ValueKey('fc-task-title'),
              controller: _title,
              decoration: InputDecoration(labelText: t.fcTaskWhat)),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: _pickDue,
            icon: const Icon(Icons.event_rounded),
            label: Text(_due == null
                ? t.fcTaskPickTime
                : '${famDate(context, _due)} ${famDigits(context, TimeOfDay.fromDateTime(_due!).format(context))}'),
          ),
        ],
      ]),
    );
  }
}
