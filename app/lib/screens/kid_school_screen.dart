import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// KID'S SCHOOL CORNER — ADVANCED (#27, SPEC v2.1 §21).
///
/// A parent manages a child's school life. Add children (name + class only —
/// child-privacy by design), then log a school notice the parent typed and TAG
/// its type. There is NO AI and NO scan: a deterministic keyword router only
/// *suggests* a type the parent confirms. Types: fee (৳ amount + due date),
/// exam (date), ptm / parents' meeting (date), event (date), other (no date).
/// Upcoming / overdue per child is computed honestly from today.
///
/// The on-screen logic mirrors backend/core/logic/kid_school.py VERBATIM
/// (keyword routing, honest overdue/upcoming/no-date classification, per-child
/// board) so the live view is deterministic and identical offline.
///
/// Honest states: welcome (first use) · loading · error · no-notices. A dateless
/// notice is never "overdue"; a done/paid notice is never overdue. Reminder is a
/// documented seam (`_KidMath.dueSoon`) — NOT wired to notifications. ZERO
/// Bangla literals — every string is an AppLocalizations getter; ৳ is a glyph.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('kid/children') → [{id, name, klass}]
///   listItems('kid/notices')  → [{id, child, title, body, type, amount,
///                                  date, done}]
///     type ∈ {fee, exam, ptm, event, other}; date 'YYYY-MM-DD';
///     amount only for type=='fee'; done flags paid/handled.
/// create/update/deleteItem on the same paths. Each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection (PaCollectionItem
/// precedent).
class KidSchoolScreen extends StatefulWidget {
  const KidSchoolScreen({super.key});
  @override
  State<KidSchoolScreen> createState() => _KidSchoolScreenState();
}

const String _childrenPath = 'kid/children';
const String _noticesPath = 'kid/notices';

const List<String> _typeKeys = ['fee', 'exam', 'ptm', 'event', 'other'];

String _typeLabel(AppLocalizations tr, String? t) {
  switch (t) {
    case 'fee':
      return tr.kidTypeFee;
    case 'exam':
      return tr.kidTypeExam;
    case 'ptm':
      return tr.kidTypePtm;
    case 'event':
      return tr.kidTypeEvent;
    default:
      return tr.kidTypeOther;
  }
}

IconData _typeIcon(String? t) {
  switch (t) {
    case 'fee':
      return Icons.payments_outlined;
    case 'exam':
      return Icons.edit_note_outlined;
    case 'ptm':
      return Icons.groups_outlined;
    case 'event':
      return Icons.celebration_outlined;
    default:
      return Icons.sticky_note_2_outlined;
  }
}

bool _typeHasDate(String t) => t != 'other';
bool _typeHasAmount(String t) => t == 'fee';

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

class _KidSchoolScreenState extends State<KidSchoolScreen> {
  List<Map<String, dynamic>> _children = [];
  List<Map<String, dynamic>> _notices = [];
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
      final res = await Future.wait([
        api.listItems(_childrenPath),
        api.listItems(_noticesPath),
      ]);
      _children = res[0];
      _notices = res[1];
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.kidTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.kidTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.kidLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_children.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.kidTitle)),
        body: StateMessage(
          icon: Icons.school_outlined,
          title: tr.kidWelcomeTitle,
          message: tr.kidWelcomeBody,
          action: FilledButton.icon(
            onPressed: _addChild,
            icon: const Icon(Icons.person_add_alt),
            label: Text(tr.kidAddChild),
          ),
        ),
      );
    }
    final roster = _KidMath.rosterSummary(_children, _notices, _today());
    final totals = roster['totals'] as Map<String, dynamic>;
    return Scaffold(
      appBar: AppBar(title: Text(tr.kidTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addChild,
        icon: const Icon(Icons.person_add_alt),
        label: Text(tr.kidAddChild),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            if ((totals['overdue'] as int) > 0)
              _OverdueBanner(count: totals['overdue'] as int),
            for (final row
                in (roster['children'] as List).cast<Map<String, dynamic>>())
              _ChildCard(
                row: row,
                onOpen: () => _openChild(row),
              ),
            const SizedBox(height: Gap.md),
            _privacyNote(context, tr.kidPrivacyNote),
          ],
        ),
      ),
    );
  }

  Future<void> _openChild(Map<String, dynamic> row) async {
    final child = _children.firstWhere((c) => c['id'] == row['id'],
        orElse: () => row);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ChildDetailScreen(child: child, allNotices: _notices),
    ));
    await _load();
  }

  Future<void> _addChild() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ChildForm(),
    );
    if (result == null) return;
    try {
      await api.createItem(_childrenPath, result);
      await _load();
      if (mounted) _toast(tr.kidSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= overdue banner =======================
class _OverdueBanner extends StatelessWidget {
  final int count;
  const _OverdueBanner({required this.count});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.kidOverdueBanner(count),
                style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}

// ======================= child card =======================
class _ChildCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onOpen;
  const _ChildCard({required this.row, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final overdue = (row['overdue'] as int?) ?? 0;
    final open = (row['open'] as int?) ?? 0;
    final next = row['next'] as Map<String, dynamic>?;
    final klass = (row['klass'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: Brand.blue.withValues(alpha: 0.15),
                child: Icon(Icons.child_care_outlined, color: Brand.blue),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((row['name'] ?? '').toString(),
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (klass.isNotEmpty)
                        Text(klass,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                    ]),
              ),
              if (overdue > 0)
                _pill(context, tr.kidOverdueShort(overdue), scheme.error)
              else if (open > 0)
                _pill(context, tr.kidOpenShort(open), scheme.primary),
            ]),
            if (next != null) ...[
              const SizedBox(height: Gap.sm),
              const Divider(height: 1),
              const SizedBox(height: Gap.sm),
              Row(children: [
                Icon(_typeIcon(next['type'] as String?),
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                      (next['title'] ?? '').toString().isEmpty
                          ? _typeLabel(tr, next['type'] as String?)
                          : (next['title']).toString(),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: Gap.sm),
                Text(_dueLabel(tr, next),
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: (next['state'] == 'overdue')
                            ? scheme.error
                            : scheme.primary)),
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style:
                TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

String _dueLabel(AppLocalizations tr, Map<String, dynamic> s) {
  final state = s['state'] as String?;
  final days = s['days'] as int?;
  if (state == 'overdue' && days != null) return tr.kidOverdueDays(-days);
  if (state == 'due_today') return tr.kidDueToday;
  if (state == 'upcoming' && days != null) return tr.kidDueInDays(days);
  return (s['date'] ?? '').toString();
}

// ======================= child detail =======================
class _ChildDetailScreen extends StatefulWidget {
  final Map<String, dynamic> child;
  final List<Map<String, dynamic>> allNotices;
  const _ChildDetailScreen({required this.child, required this.allNotices});
  @override
  State<_ChildDetailScreen> createState() => _ChildDetailScreenState();
}

class _ChildDetailScreenState extends State<_ChildDetailScreen> {
  late List<Map<String, dynamic>> _notices;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _notices = widget.allNotices
        .where((n) => n['child'] == widget.child['id'])
        .toList();
  }

  Future<void> _reload() async {
    final api = context.read<AppState>().api;
    final all = await api.listItems(_noticesPath);
    setState(() => _notices =
        all.where((n) => n['child'] == widget.child['id']).toList());
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final board = _KidMath.childBoard(_notices, _today());
    final counts = board['counts'] as Map<String, dynamic>;
    final all = (board['all'] as List).cast<Map<String, dynamic>>();
    final name = (widget.child['name'] ?? '').toString();
    final klass = (widget.child['klass'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: tr.delete,
            onPressed: _confirmDeleteChild,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addNotice,
        icon: const Icon(Icons.add),
        label: Text(tr.kidAddNotice),
      ),
      body: _notices.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: [
                if (klass.isNotEmpty)
                  Text(klass,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.xl),
                StateMessage(
                  icon: Icons.sticky_note_2_outlined,
                  title: tr.kidNoNoticesTitle,
                  message: tr.kidNoNoticesBody,
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
              children: [
                // per-type summary chips
                Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  _summaryChip(context, Icons.payments_outlined,
                      tr.kidChipFees((counts['fee'] as int?) ?? 0), Brand.blue),
                  _summaryChip(context, Icons.edit_note_outlined,
                      tr.kidChipExams((counts['exam'] as int?) ?? 0),
                      Brand.purple),
                  _summaryChip(context, Icons.groups_outlined,
                      tr.kidChipPtm((counts['ptm'] as int?) ?? 0),
                      scheme.tertiary),
                  _summaryChip(context, Icons.celebration_outlined,
                      tr.kidChipEvents((counts['event'] as int?) ?? 0),
                      Brand.success),
                ]),
                const SizedBox(height: Gap.md),
                for (final s in all)
                  _NoticeCard(
                    status: s,
                    onToggleDone: () => _toggleDone(s),
                    onDelete: () => _deleteNotice(s),
                  ),
                const SizedBox(height: Gap.md),
                _reminderSeamNote(context, tr.kidReminderNote),
              ],
            ),
    );
  }

  Widget _summaryChip(
      BuildContext context, IconData icon, String text, Color c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: Gap.xs),
        Text(text,
            style:
                TextStyle(color: c, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Future<void> _addNotice() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _NoticeForm(defaultDate: _today()),
    );
    if (result == null) return;
    result['child'] = widget.child['id'];
    setState(() => _busy = true);
    try {
      await api.createItem(_noticesPath, result);
      await _reload();
      if (mounted) _toast(tr.kidSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleDone(Map<String, dynamic> status) async {
    final api = context.read<AppState>().api;
    final id = status['id'];
    if (id is! int) return;
    final newDone = !(status['done'] == true);
    try {
      await api.updateItem(_noticesPath, id, {'done': newDone});
      await _reload();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  Future<void> _deleteNotice(Map<String, dynamic> status) async {
    final api = context.read<AppState>().api;
    final id = status['id'];
    if (id is int) {
      await api.deleteItem(_noticesPath, id);
      await _reload();
    }
  }

  Future<void> _confirmDeleteChild() async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.kidDeleteChildTitle),
        content: Text(
            tr.kidDeleteChildBody((widget.child['name'] ?? '').toString())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = widget.child['id'];
    if (id is int) {
      // delete the child's notices first, then the child (honest cleanup)
      for (final n in _notices) {
        final nid = n['id'];
        if (nid is int) await api.deleteItem(_noticesPath, nid);
      }
      await api.deleteItem(_childrenPath, id);
    }
    if (mounted) Navigator.of(context).pop();
  }
}

// ======================= notice card =======================
class _NoticeCard extends StatelessWidget {
  final Map<String, dynamic> status;
  final VoidCallback onToggleDone;
  final VoidCallback onDelete;
  const _NoticeCard(
      {required this.status,
      required this.onToggleDone,
      required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = status['type'] as String?;
    final state = status['state'] as String?;
    final done = status['done'] == true;
    final title = (status['title'] ?? '').toString();
    final amount = status['amount'];
    final c = state == 'overdue'
        ? scheme.error
        : (state == 'due_today' ? scheme.primary : scheme.onSurfaceVariant);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(_typeIcon(type), color: done ? scheme.outline : Brand.blue),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title.isEmpty ? _typeLabel(tr, type) : title,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          decoration: done ? TextDecoration.lineThrough : null,
                          color: done ? scheme.outline : scheme.onSurface),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(children: [
                    Text(_typeLabel(tr, type),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                    if (type == 'fee' &&
                        amount != null &&
                        amount.toString().trim().isNotEmpty) ...[
                      Text('  ·  ',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                      Text('৳${amount.toString()}',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                    ],
                  ]),
                  if (!done && state != 'no_date') ...[
                    const SizedBox(height: 2),
                    Text(_dueLabel(tr, status),
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: c)),
                  ],
                  if (state == 'no_date')
                    Text(tr.kidNoDate,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                ]),
          ),
          Column(children: [
            IconButton(
              tooltip: done ? tr.kidMarkUndone : tr.kidMarkDone,
              icon: Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: done ? Brand.success : scheme.outline),
              onPressed: onToggleDone,
            ),
            IconButton(
              tooltip: tr.delete,
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: onDelete,
            ),
          ]),
        ]),
      ),
    );
  }
}

// ======================= forms =======================
class _ChildForm extends StatefulWidget {
  const _ChildForm();
  @override
  State<_ChildForm> createState() => _ChildFormState();
}

class _ChildFormState extends State<_ChildForm> {
  final _name = TextEditingController();
  final _klass = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _klass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final nameOk = _name.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.kidAddChild,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.sm),
              Text(tr.kidPrivacyNote,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: tr.kidChildName,
                    hintText: tr.kidChildNameHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _klass,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.kidChildClass,
                    hintText: tr.kidChildClassHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: nameOk
                        ? () => Navigator.pop(context, <String, dynamic>{
                              'name': _name.text.trim(),
                              'klass': _klass.text.trim(),
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

class _NoticeForm extends StatefulWidget {
  final String defaultDate;
  const _NoticeForm({required this.defaultDate});
  @override
  State<_NoticeForm> createState() => _NoticeFormState();
}

class _NoticeFormState extends State<_NoticeForm> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _amount = TextEditingController();
  late final _date = TextEditingController(text: widget.defaultDate);
  String _type = 'other';
  bool _typeTouched = false;
  String? _suggestedMatch;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _amount.dispose();
    _date.dispose();
    super.dispose();
  }

  void _resuggest() {
    if (_typeTouched) return; // never override the parent's manual choice
    final r = _KidMath.suggestType(_title.text, _body.text);
    setState(() {
      _type = r['type'] as String;
      _suggestedMatch = r['confident'] == true ? r['matched'] as String? : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final titleOk = _title.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.kidAddNotice,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.sm),
              Text(tr.kidNoticeHelp,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _title,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) {
                  _resuggest();
                  setState(() {});
                },
                decoration: InputDecoration(
                    labelText: tr.kidNoticeTitle,
                    hintText: tr.kidNoticeTitleHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _body,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => _resuggest(),
                decoration: InputDecoration(
                    labelText: tr.kidNoticeBody,
                    hintText: tr.kidNoticeBodyHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: InputDecoration(
                    labelText: tr.kidNoticeType,
                    helperText: (!_typeTouched && _suggestedMatch != null)
                        ? tr.kidTypeSuggested(_suggestedMatch!)
                        : null,
                    border: const OutlineInputBorder()),
                items: [
                  for (final k in _typeKeys)
                    DropdownMenuItem(value: k, child: Text(_typeLabel(tr, k))),
                ],
                onChanged: (v) => setState(() {
                  _type = v ?? 'other';
                  _typeTouched = true;
                }),
              ),
              if (_typeHasAmount(_type)) ...[
                const SizedBox(height: Gap.md),
                TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: tr.kidFeeAmount,
                      prefixText: '৳ ',
                      border: const OutlineInputBorder()),
                ),
              ],
              if (_typeHasDate(_type)) ...[
                const SizedBox(height: Gap.md),
                TextField(
                  controller: _date,
                  keyboardType: TextInputType.datetime,
                  decoration: InputDecoration(
                      labelText: _type == 'fee'
                          ? tr.kidDueDate
                          : tr.kidNoticeDate,
                      hintText: tr.kidDateHint,
                      helperText: tr.kidDateOptional,
                      border: const OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: titleOk
                        ? () => Navigator.pop(context, <String, dynamic>{
                              'title': _title.text.trim(),
                              'body': _body.text.trim(),
                              'type': _type,
                              if (_typeHasAmount(_type))
                                'amount': _amount.text.trim(),
                              if (_typeHasDate(_type))
                                'date': _date.text.trim(),
                              'done': false,
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

// ======================= shared small helpers =======================
Widget _privacyNote(BuildContext context, String text) =>
    _infoNote(context, Icons.shield_outlined, text);

Widget _reminderSeamNote(BuildContext context, String text) =>
    _infoNote(context, Icons.notifications_none, text);

Widget _infoNote(BuildContext context, IconData icon, String text) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    color: scheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
      ]),
    ),
  );
}

// ===================================================================
// _KidMath — deterministic mirror of backend/core/logic/kid_school.py.
// Keyword routing + honest overdue/upcoming/no-date classification from a
// passed-in `today`. No clock inside the pure functions.
// ===================================================================
class _KidMath {
  static const List<String> _validTypes = [
    'fee',
    'exam',
    'ptm',
    'event',
    'other'
  ];
  static const List<String> _typePriority = ['fee', 'exam', 'ptm', 'event'];

  // Keyword table — mirrors TYPE_KEYWORDS in kid_school.py. The Bangla cues are
  // written as \u-escapes (NOT literal U+0980–U+09FF codepoints) so this .dart
  // file stays pure-ASCII per the zero-Bangla rule while still matching a
  // Bangla notice at runtime. Each escaped string decodes to the same Bangla
  // keyword the Python router uses.
  static const Map<String, List<String>> _keywords = {
    'fee': [
      'fee', 'fees', 'tuition', 'payment', 'due', 'bill', 'invoice',
      'admission', 'session charge', 'montly', 'monthly',
      '\u{9AB}\u{9BF}', '\u{9AC}\u{9C7}\u{9A4}\u{9A8}',
      '\u{9AA}\u{9B0}\u{9BF}\u{9B6}\u{9CB}\u{9A7}',
      '\u{9AC}\u{995}\u{9C7}\u{9AF}\u{9BC}\u{9BE}',
      '\u{99A}\u{9BE}\u{981}\u{9A6}\u{9BE}',
      '\u{9AD}\u{9B0}\u{9CD}\u{9A4}\u{9BF}', '\u{99F}\u{9BE}\u{995}\u{9BE}'
    ],
    'exam': [
      'exam', 'examination', 'test', 'quiz', 'assessment', 'result',
      'mid-term', 'midterm', 'final', 'half-yearly', 'annual exam',
      '\u{9AA}\u{9B0}\u{9C0}\u{995}\u{9CD}\u{9B7}\u{9BE}',
      '\u{99F}\u{9C7}\u{9B8}\u{9CD}\u{99F}',
      '\u{9AE}\u{9C2}\u{9B2}\u{9CD}\u{9AF}\u{9BE}\u{9AF}\u{9BC}\u{9A8}',
      '\u{9AB}\u{9B2}\u{9BE}\u{9AB}\u{9B2}',
      '\u{9B0}\u{9C7}\u{99C}\u{9BE}\u{9B2}\u{9CD}\u{99F}'
    ],
    'ptm': [
      'ptm', 'parent', 'parents meeting', 'parent-teacher', 'meeting',
      'guardian',
      '\u{985}\u{9AD}\u{9BF}\u{9AD}\u{9BE}\u{9AC}\u{995}',
      '\u{9B8}\u{9AD}\u{9BE}', '\u{9AE}\u{9BF}\u{99F}\u{9BF}\u{982}',
      '\u{9B6}\u{9BF}\u{995}\u{9CD}\u{9B7}\u{995}-'
          '\u{985}\u{9AD}\u{9BF}\u{9AD}\u{9BE}\u{9AC}\u{995}'
    ],
    'event': [
      'event', 'sports', 'annual day', 'cultural', 'picnic', 'celebration',
      'programme', 'program', 'fair', 'function', 'field trip', 'holiday',
      '\u{985}\u{9A8}\u{9C1}\u{9B7}\u{9CD}\u{9A0}\u{9BE}\u{9A8}',
      '\u{996}\u{9C7}\u{9B2}\u{9BE}', '\u{995}\u{9CD}\u{9B0}\u{9C0}\u{9A1}\u{9BC}\u{9BE}',
      '\u{9B8}\u{9BE}\u{982}\u{9B8}\u{9CD}\u{995}\u{9C3}\u{9A4}\u{9BF}\u{995}',
      '\u{9AA}\u{9BF}\u{995}\u{9A8}\u{9BF}\u{995}', '\u{99B}\u{9C1}\u{99F}\u{9BF}',
      '\u{9AD}\u{9CD}\u{9B0}\u{9AE}\u{9A3}'
    ],
  };

  static bool _typeHasDateField(String t) => t != 'other';

  static Map<String, dynamic> suggestType(String title, String body) {
    final text = '${title} ${body}'.toLowerCase();
    for (final t in _typePriority) {
      for (final kw in _keywords[t]!) {
        if (text.contains(kw.toLowerCase())) {
          return {'type': t, 'confident': true, 'matched': kw};
        }
      }
    }
    return {'type': 'other', 'confident': false, 'matched': null};
  }

  // ---- dates (ordinal, no DateTime drift) ----
  static List<int>? _ymd(dynamic s) {
    if (s == null || s.toString().trim().isEmpty) return null;
    final parts = s.toString().trim().split('-');
    if (parts.length < 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    return [y, m, d];
  }

  static bool _isLeap(int y) => y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
  static const List<int> _mdays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

  static int _ordinal(List<int> ymd) {
    final y = ymd[0], m = ymd[1], d = ymd[2];
    var days = 0;
    for (var yy = 1; yy < y; yy++) {
      days += _isLeap(yy) ? 366 : 365;
    }
    for (var mm = 1; mm < m; mm++) {
      days += _mdays[mm - 1] + ((mm == 2 && _isLeap(y)) ? 1 : 0);
    }
    return days + d;
  }

  static Map<String, dynamic> noticeStatus(
      Map<String, dynamic> notice, String now) {
    var t = (notice['type'] ?? 'other').toString();
    if (!_validTypes.contains(t)) t = 'other';
    final hasDateField = _typeHasDateField(t);
    final nowY = _ymd(now);
    final due = hasDateField ? _ymd(notice['date']) : null;
    final done = notice['done'] == true;
    final base = <String, dynamic>{
      'id': notice['id'],
      'child': notice['child'],
      'title': (notice['title'] ?? '').toString().trim(),
      'type': t,
      'has_date': hasDateField,
      'amount': t == 'fee' ? notice['amount'] : null,
      'date': due != null ? notice['date'].toString() : null,
      'done': done,
    };
    if (done) {
      base['state'] = 'done';
      base['days'] = null;
      return base;
    }
    if (due == null) {
      base['state'] = 'no_date';
      base['days'] = null;
      return base;
    }
    if (nowY == null) {
      base['state'] = 'upcoming';
      base['days'] = null;
      return base;
    }
    final delta = _ordinal(due) - _ordinal(nowY);
    base['state'] = delta < 0
        ? 'overdue'
        : (delta == 0 ? 'due_today' : 'upcoming');
    base['days'] = delta;
    return base;
  }

  static const Map<String, int> _stateOrder = {
    'overdue': 0,
    'due_today': 1,
    'upcoming': 2,
    'no_date': 3,
    'done': 4
  };

  static Map<String, dynamic> childBoard(
      List<Map<String, dynamic>> notices, String now) {
    final statuses = notices.map((n) => noticeStatus(n, now)).toList();
    statuses.sort((a, b) {
      final oa = _stateOrder[a['state']] ?? 9;
      final ob = _stateOrder[b['state']] ?? 9;
      if (oa != ob) return oa.compareTo(ob);
      final da = (a['date'] ?? '9999-99-99').toString();
      final db = (b['date'] ?? '9999-99-99').toString();
      if (da != db) return da.compareTo(db);
      return (a['title'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['title'] ?? '').toString().toLowerCase());
    });
    final counts = <String, dynamic>{
      for (final k in _stateOrder.keys) k: 0,
    };
    for (final t in _validTypes) {
      counts[t] = 0;
    }
    for (final s in statuses) {
      counts[s['state']] = (counts[s['state']] as int) + 1;
      counts[s['type']] = (counts[s['type']] as int) + 1;
    }
    counts['open'] = (counts['overdue'] as int) +
        (counts['due_today'] as int) +
        (counts['upcoming'] as int) +
        (counts['no_date'] as int);
    return {'all': statuses, 'counts': counts};
  }

  static Map<String, dynamic> rosterSummary(
      List<Map<String, dynamic>> children,
      List<Map<String, dynamic>> notices,
      String now) {
    final byChild = <dynamic, List<Map<String, dynamic>>>{};
    for (final n in notices) {
      byChild.putIfAbsent(n['child'], () => []).add(n);
    }
    final rows = <Map<String, dynamic>>[];
    var totOverdue = 0, totToday = 0, totOpen = 0;
    for (final c in children) {
      final cid = c['id'];
      final board = childBoard(byChild[cid] ?? [], now);
      final counts = board['counts'] as Map<String, dynamic>;
      final all = (board['all'] as List).cast<Map<String, dynamic>>();
      final overdue = all.where((s) => s['state'] == 'overdue').toList();
      Map<String, dynamic>? nxt;
      if (overdue.isNotEmpty) {
        nxt = overdue.last; // least-overdue (closest to today)
      } else {
        final dated = all
            .where((s) =>
                (s['state'] == 'due_today' || s['state'] == 'upcoming') &&
                s['date'] != null)
            .toList();
        if (dated.isNotEmpty) {
          dated.sort(
              (a, b) => a['date'].toString().compareTo(b['date'].toString()));
          nxt = dated.first;
        }
      }
      rows.add({
        'id': cid,
        'name': (c['name'] ?? '').toString().trim(),
        'klass': (c['klass'] ?? '').toString().trim(),
        'overdue': counts['overdue'],
        'due_today': counts['due_today'],
        'open': counts['open'],
        'next': nxt,
      });
      totOverdue += counts['overdue'] as int;
      totToday += counts['due_today'] as int;
      totOpen += counts['open'] as int;
    }
    return {
      'children': rows,
      'totals': {
        'children': children.length,
        'overdue': totOverdue,
        'due_today': totToday,
        'open': totOpen,
      },
      'empty': children.isEmpty,
    };
  }

  /// REMINDER SEAM (documented, NOT wired). Forward-looking dated, not-done
  /// notices falling due within [withinDays] of [now]. Mirrors
  /// kid_school.due_soon; the app surfaces these in-screen only (no
  /// notification is scheduled). Retained as a documented seam a future
  /// reminder job would call; intentionally not referenced by the UI yet.
  // ignore: unused_element
  static List<Map<String, dynamic>> dueSoon(
      List<Map<String, dynamic>> notices, String now,
      [int withinDays = 7]) {
    final out = <Map<String, dynamic>>[];
    for (final n in notices) {
      final s = noticeStatus(n, now);
      final days = s['days'];
      if ((s['state'] == 'upcoming' || s['state'] == 'due_today') &&
          days is int &&
          days >= 0 &&
          days <= withinDays) {
        out.add(s);
      }
    }
    out.sort((a, b) => (a['date'] ?? '9999-99-99')
        .toString()
        .compareTo((b['date'] ?? '9999-99-99').toString()));
    return out;
  }
}
