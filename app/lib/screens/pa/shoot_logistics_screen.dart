import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · CELEBRITY tier — Shooting / concert logistics call-sheet
/// (#124, §14).
///
/// An event-day call-sheet builder for a performer's PA: a call-sheet header
/// (title, date, call-time, location), an ordered SCHEDULE of time-blocks, a
/// WARDROBE/EQUIPMENT/prep CHECKLIST (grouped by kind, with progress), and a
/// crew/cast CONTACTS list. Deterministic; nothing is fetched or invented.
///
/// Mirrors backend/core/logic/pa_shoot.py. ZERO Bangla literals.
/// Endpoints: listItems('star/callsheets') / createItem / updateItem / delete.
/// Rows tagged {kind: 'sheet' | 'block' | 'contact' | 'check'}; children carry
/// {sheet_id}. This screen manages one sheet at a time (the newest, or picked).
class ShootLogisticsScreen extends StatefulWidget {
  const ShootLogisticsScreen({super.key});
  @override
  State<ShootLogisticsScreen> createState() => _ShootLogisticsScreenState();
}

// ---- constants (mirror pa_shoot.py) ---------------------------------------
const String _kSheet = 'sheet';
const String _kBlock = 'block';
const String _kContact = 'contact';
const String _kCheck = 'check';

const List<String> _blockKinds = [
  'scene', 'soundcheck', 'set', 'break', 'travel', 'other'
];
const List<String> _checkKinds = ['wardrobe', 'equipment', 'prep'];

class _ShootLogisticsScreenState extends State<ShootLogisticsScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  int? _activeSheetId;

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
      _rows = await context.read<AppState>().api.listItems('star/callsheets');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) {
      // default active sheet = first sheet if none chosen or chosen gone
      final sheets = _sheets;
      if (_activeSheetId == null ||
          !sheets.any((s) => s['id'] == _activeSheetId)) {
        _activeSheetId = sheets.isNotEmpty ? sheets.first['id'] as int? : null;
      }
      setState(() => _loading = false);
    }
  }

  // ---- mirror helpers ------------------------------------------------------
  String _kind(Map<String, dynamic> r) => (r['kind'] ?? _kSheet).toString();

  List<Map<String, dynamic>> get _sheets =>
      _rows.where((r) => _kind(r) == _kSheet).toList();

  List<Map<String, dynamic>> _childrenOf(String kind, int sheetId) => _rows
      .where((r) => _kind(r) == kind && (r['sheet_id'] == sheetId))
      .toList();

  int? _minutes(String? hhmm) {
    if (hhmm == null || hhmm.trim().isEmpty) return null;
    final parts = hhmm.trim().split(':');
    final h = int.tryParse(parts[0]);
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    if (h == null || h < 0 || h >= 24 || m < 0 || m >= 60) return null;
    return h * 60 + m;
  }

  List<Map<String, dynamic>> _orderedBlocks(int sheetId) {
    final list = _childrenOf(_kBlock, sheetId);
    list.sort((a, b) {
      final ma = _minutes(a['start']?.toString());
      final mb = _minutes(b['start']?.toString());
      if (ma == null && mb == null) return 0;
      if (ma == null) return 1;
      if (mb == null) return -1;
      return ma - mb;
    });
    return list;
  }

  // ---- actions -------------------------------------------------------------
  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _create(Map<String, dynamic> body, AppLocalizations tr) async {
    try {
      final created = await context.read<AppState>().api.createItem('star/callsheets', body);
      if (body['kind'] == _kSheet && created['id'] is int) {
        _activeSheetId = created['id'] as int;
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _update(int id, Map<String, dynamic> body) async {
    try {
      await context.read<AppState>().api.updateItem('star/callsheets', id, body);
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  Future<void> _delete(int id) async {
    try {
      await context.read<AppState>().api.deleteItem('star/callsheets', id);
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).deleteFailed);
    }
  }

  Future<void> _newSheet(AppLocalizations tr) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _SheetForm(),
    );
    if (result == null) return;
    await _create({'kind': _kSheet, ...result}, tr);
  }

  Future<void> _editSheet(Map<String, dynamic> sheet, AppLocalizations tr) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _SheetForm(existing: sheet),
    );
    if (result == null) return;
    if (sheet['id'] is int) await _update(sheet['id'] as int, result);
  }

  Future<void> _addBlock(int sheetId, AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _BlockForm(existing: existing),
    );
    if (result == null) return;
    if (existing != null && existing['id'] is int) {
      await _update(existing['id'] as int, result);
    } else {
      await _create({'kind': _kBlock, 'sheet_id': sheetId, ...result}, tr);
    }
  }

  Future<void> _addContact(int sheetId, AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ContactForm(existing: existing),
    );
    if (result == null) return;
    if (existing != null && existing['id'] is int) {
      await _update(existing['id'] as int, result);
    } else {
      await _create({'kind': _kContact, 'sheet_id': sheetId, ...result}, tr);
    }
  }

  Future<void> _addCheck(int sheetId, AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _CheckForm(existing: existing),
    );
    if (result == null) return;
    if (existing != null && existing['id'] is int) {
      await _update(existing['id'] as int, result);
    } else {
      await _create({'kind': _kCheck, 'sheet_id': sheetId, ...result}, tr);
    }
  }

  // ---- build ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.shootTitle), actions: [
        if (!_loading && !_error && _sheets.isNotEmpty)
          IconButton(
            tooltip: tr.shootNewSheet,
            icon: const Icon(Icons.add),
            onPressed: () => _newSheet(tr),
          ),
      ]),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.shootLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)),
                )
              : _sheets.isEmpty
                  ? _welcome(tr)
                  : _sheetView(tr, scheme),
    );
  }

  Widget _welcome(AppLocalizations tr) => StateMessage(
        icon: Icons.video_camera_front_outlined,
        title: tr.shootWelcomeTitle,
        message: tr.shootWelcomeBody,
        action: FilledButton.icon(
          onPressed: () => _newSheet(tr),
          icon: const Icon(Icons.add),
          label: Text(tr.shootNewSheet),
        ),
      );

  Widget _sheetView(AppLocalizations tr, ColorScheme scheme) {
    final sheets = _sheets;
    final active = sheets.firstWhere((s) => s['id'] == _activeSheetId,
        orElse: () => sheets.first);
    final sheetId = active['id'] as int;
    final blocks = _orderedBlocks(sheetId);
    final contacts = _childrenOf(_kContact, sheetId);
    final checks = _childrenOf(_kCheck, sheetId);
    final checked = checks.where((c) => c['checked'] == true).length;
    final pct = checks.isEmpty ? 0 : (checked * 100 ~/ checks.length);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl),
        children: [
          if (sheets.length > 1) _sheetPicker(sheets, scheme),
          _headerCard(active, tr, scheme),
          const SizedBox(height: Gap.md),
          // schedule
          _sectionHeader(tr.shootSchedule, Icons.schedule,
              () => _addBlock(sheetId, tr), scheme),
          if (blocks.isEmpty)
            _empty(tr.shootNoBlocks, scheme)
          else
            for (final b in blocks) _blockTile(b, tr, scheme),
          const SizedBox(height: Gap.md),
          // checklist
          _sectionHeader(
              tr.shootChecklistProgress(/* (checked, pct, total) */
                  '$checked', '$pct', '${checks.length}'),
              Icons.checklist, () => _addCheck(sheetId, tr), scheme),
          if (checks.isEmpty)
            _empty(tr.shootNoChecks, scheme)
          else ...[
            for (final kind in _checkKinds)
              if (checks.any((c) => (c['check_kind'] ?? 'equipment').toString() == kind)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.sm, 0, Gap.xxs),
                  child: Text(_checkKindLabel(tr, kind),
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
                ),
                for (final c in checks.where((c) => (c['check_kind'] ?? 'equipment').toString() == kind))
                  _checkTile(c, tr, scheme),
              ],
          ],
          const SizedBox(height: Gap.md),
          // contacts
          _sectionHeader(tr.shootContacts, Icons.contacts_outlined,
              () => _addContact(sheetId, tr), scheme),
          if (contacts.isEmpty)
            _empty(tr.shootNoContacts, scheme)
          else
            for (final c in contacts) _contactTile(c, tr, scheme),
        ],
      ),
    );
  }

  Widget _sheetPicker(List<Map<String, dynamic>> sheets, ColorScheme scheme) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final s in sheets)
                Padding(
                  padding: const EdgeInsets.only(right: Gap.sm),
                  child: ChoiceChip(
                    label: Text((s['title'] ?? '').toString(),
                        overflow: TextOverflow.ellipsis),
                    selected: s['id'] == _activeSheetId,
                    onSelected: (_) => setState(() => _activeSheetId = s['id'] as int?),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _headerCard(Map<String, dynamic> s, AppLocalizations tr, ColorScheme scheme) {
    final title = (s['title'] ?? '').toString();
    final date = (s['date'] ?? '').toString().trim();
    final callTime = (s['call_time'] ?? '').toString().trim();
    final location = (s['location'] ?? '').toString().trim();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(title,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'edit') _editSheet(s, tr);
                if (v == 'delete' && s['id'] is int) _delete(s['id'] as int);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
            if (callTime.isNotEmpty)
              _meta(Icons.alarm, tr.shootCallTimeValue(callTime), scheme),
            if (date.isNotEmpty) _meta(Icons.event, date, scheme),
            if (location.isNotEmpty) _meta(Icons.place_outlined, location, scheme),
          ]),
        ]),
      ),
    );
  }

  Widget _meta(IconData icon, String text, ColorScheme scheme) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(text, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]);

  Widget _sectionHeader(String title, IconData icon, VoidCallback onAdd, ColorScheme scheme) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.xxs, top: Gap.xs),
        child: Row(children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(title,
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context).add,
            icon: const Icon(Icons.add_circle_outline),
            color: scheme.primary,
            onPressed: onAdd,
          ),
        ]),
      );

  Widget _empty(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm, horizontal: Gap.xs),
        child: Text(text,
            style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
      );

  Widget _blockTile(Map<String, dynamic> b, AppLocalizations tr, ColorScheme scheme) {
    final label = (b['label'] ?? '').toString();
    final start = (b['start'] ?? '').toString().trim();
    final end = (b['end'] ?? '').toString().trim();
    final kind = (b['block_kind'] ?? 'other').toString();
    final time = [start, end].where((e) => e.isNotEmpty).join(' – ');
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.xs),
      child: ListTile(
        dense: true,
        leading: Text(start.isEmpty ? '—' : start,
            style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            [_blockKindLabel(tr, kind), if (time.isNotEmpty) time].join(' · '),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (v) {
            if (v == 'edit') _addBlock(b['sheet_id'] as int, tr, existing: b);
            if (v == 'delete' && b['id'] is int) _delete(b['id'] as int);
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(tr.edit)),
            PopupMenuItem(value: 'delete', child: Text(tr.delete)),
          ],
        ),
      ),
    );
  }

  Widget _checkTile(Map<String, dynamic> c, AppLocalizations tr, ColorScheme scheme) {
    final label = (c['label'] ?? '').toString();
    final checked = c['checked'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.xs),
      child: CheckboxListTile(
        dense: true,
        value: checked,
        onChanged: (v) {
          if (c['id'] is int) _update(c['id'] as int, {'checked': v == true});
        },
        title: Text(label,
            style: TextStyle(
                decoration: checked ? TextDecoration.lineThrough : null,
                color: checked ? scheme.onSurfaceVariant : scheme.onSurface),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        secondary: IconButton(
          tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
          icon: const Icon(Icons.delete_outline),
          onPressed: () {
            if (c['id'] is int) _delete(c['id'] as int);
          },
        ),
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }

  Widget _contactTile(Map<String, dynamic> c, AppLocalizations tr, ColorScheme scheme) {
    final name = (c['name'] ?? '').toString();
    final role = (c['role'] ?? '').toString().trim();
    final phone = (c['phone'] ?? '').toString().trim();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.xs),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.person_outline),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([role, phone].where((e) => e.isNotEmpty).join(' · '),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (v) {
            if (v == 'edit') _addContact(c['sheet_id'] as int, tr, existing: c);
            if (v == 'delete' && c['id'] is int) _delete(c['id'] as int);
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(tr.edit)),
            PopupMenuItem(value: 'delete', child: Text(tr.delete)),
          ],
        ),
      ),
    );
  }

  String _blockKindLabel(AppLocalizations tr, String k) {
    switch (k) {
      case 'scene':
        return tr.shootBlockScene;
      case 'soundcheck':
        return tr.shootBlockSoundcheck;
      case 'set':
        return tr.shootBlockSet;
      case 'break':
        return tr.shootBlockBreak;
      case 'travel':
        return tr.shootBlockTravel;
      default:
        return tr.shootBlockOther;
    }
  }

  String _checkKindLabel(AppLocalizations tr, String k) {
    switch (k) {
      case 'wardrobe':
        return tr.shootCheckWardrobe;
      case 'prep':
        return tr.shootCheckPrep;
      default:
        return tr.shootCheckEquipment;
    }
  }
}

// ---- forms ----------------------------------------------------------------
class _SheetForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _SheetForm({this.existing});
  @override
  State<_SheetForm> createState() => _SheetFormState();
}

class _SheetFormState extends State<_SheetForm> {
  late final _title = TextEditingController(text: widget.existing?['title']?.toString() ?? '');
  late final _date = TextEditingController(text: widget.existing?['date']?.toString() ?? '');
  late final _callTime = TextEditingController(text: widget.existing?['call_time']?.toString() ?? '');
  late final _location = TextEditingController(text: widget.existing?['location']?.toString() ?? '');

  @override
  void dispose() {
    _title.dispose();
    _date.dispose();
    _callTime.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final valid = _title.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.existing == null ? tr.shootNewSheet : tr.shootEditSheet,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _title,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr.shootTitleField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _date,
            decoration: InputDecoration(labelText: tr.shootDateField, hintText: 'YYYY-MM-DD', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _callTime,
            decoration: InputDecoration(labelText: tr.shootCallTimeField, hintText: 'HH:MM', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _location,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr.shootLocationField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),
          _formButtons(context, tr, valid, () => <String, dynamic>{
                'title': _title.text.trim(),
                'date': _date.text.trim(),
                'call_time': _callTime.text.trim(),
                'location': _location.text.trim(),
              }),
        ]),
      ),
    );
  }
}

class _BlockForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _BlockForm({this.existing});
  @override
  State<_BlockForm> createState() => _BlockFormState();
}

class _BlockFormState extends State<_BlockForm> {
  late final _label = TextEditingController(text: widget.existing?['label']?.toString() ?? '');
  late final _start = TextEditingController(text: widget.existing?['start']?.toString() ?? '');
  late final _end = TextEditingController(text: widget.existing?['end']?.toString() ?? '');
  late String _kind = _blockKinds.contains((widget.existing?['block_kind'] ?? '').toString())
      ? widget.existing!['block_kind'].toString()
      : 'scene';

  @override
  void dispose() {
    _label.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  String _kindLabel(AppLocalizations tr, String k) {
    switch (k) {
      case 'scene':
        return tr.shootBlockScene;
      case 'soundcheck':
        return tr.shootBlockSoundcheck;
      case 'set':
        return tr.shootBlockSet;
      case 'break':
        return tr.shootBlockBreak;
      case 'travel':
        return tr.shootBlockTravel;
      default:
        return tr.shootBlockOther;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final valid = _label.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.shootBlockFormTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _label,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: tr.shootBlockLabelField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          Text(tr.shootBlockKindLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            for (final k in _blockKinds)
              ChoiceChip(
                label: Text(_kindLabel(tr, k)),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ]),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _start,
                decoration: InputDecoration(labelText: tr.shootStartField, hintText: 'HH:MM', border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: TextField(
                controller: _end,
                decoration: InputDecoration(labelText: tr.shootEndField, hintText: 'HH:MM', border: const OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: Gap.lg),
          _formButtons(context, tr, valid, () => <String, dynamic>{
                'label': _label.text.trim(),
                'block_kind': _kind,
                'start': _start.text.trim(),
                'end': _end.text.trim(),
              }),
        ]),
      ),
    );
  }
}

class _ContactForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _ContactForm({this.existing});
  @override
  State<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<_ContactForm> {
  late final _name = TextEditingController(text: widget.existing?['name']?.toString() ?? '');
  late final _role = TextEditingController(text: widget.existing?['role']?.toString() ?? '');
  late final _phone = TextEditingController(text: widget.existing?['phone']?.toString() ?? '');

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final valid = _name.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.shootContactFormTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr.shootContactNameField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _role,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr.shootContactRoleField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: tr.shootContactPhoneField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),
          _formButtons(context, tr, valid, () => <String, dynamic>{
                'name': _name.text.trim(),
                'role': _role.text.trim(),
                'phone': _phone.text.trim(),
              }),
        ]),
      ),
    );
  }
}

class _CheckForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _CheckForm({this.existing});
  @override
  State<_CheckForm> createState() => _CheckFormState();
}

class _CheckFormState extends State<_CheckForm> {
  late final _label = TextEditingController(text: widget.existing?['label']?.toString() ?? '');
  late String _kind = _checkKinds.contains((widget.existing?['check_kind'] ?? '').toString())
      ? widget.existing!['check_kind'].toString()
      : 'equipment';

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  String _kindLabel(AppLocalizations tr, String k) {
    switch (k) {
      case 'wardrobe':
        return tr.shootCheckWardrobe;
      case 'prep':
        return tr.shootCheckPrep;
      default:
        return tr.shootCheckEquipment;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final valid = _label.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.shootCheckFormTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          Text(tr.shootCheckKindLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            for (final k in _checkKinds)
              ChoiceChip(
                label: Text(_kindLabel(tr, k)),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _label,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: tr.shootCheckLabelField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),
          _formButtons(context, tr, valid, () => <String, dynamic>{
                'check_kind': _kind,
                'label': _label.text.trim(),
                'checked': widget.existing?['checked'] == true,
              }),
        ]),
      ),
    );
  }
}

Widget _formButtons(BuildContext context, AppLocalizations tr, bool valid,
    Map<String, dynamic> Function() payload) {
  return Row(children: [
    Expanded(
      child: OutlinedButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr.cancel),
      ),
    ),
    const SizedBox(width: Gap.md),
    Expanded(
      child: FilledButton(
        onPressed: valid ? () => Navigator.pop(context, payload()) : null,
        child: Text(tr.save),
      ),
    ),
  ]);
}
