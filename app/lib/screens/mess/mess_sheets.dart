import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../mess_v2_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import '../../widgets/permission_reason.dart' show showPermissionReason, PermKind;
import '../messenger/m3_add_to_circle_screen.dart';
import 'mess_store.dart';

// ======================================================================
// Meal day sheet (owner order D): breakfast / lunch / dinner on-off + guests
// ======================================================================

/// Returns {b,l,d,gb,gl,gd} or null.
Future<Map<String, int>?> showMealDaySheet(BuildContext context,
    {required String dateLabel, required Map<String, dynamic> day, String? forName}) {
  return showAppSheet<Map<String, int>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _MealDaySheet(dateLabel: dateLabel, day: day, forName: forName),
  );
}

class _MealDaySheet extends StatefulWidget {
  const _MealDaySheet({required this.dateLabel, required this.day, this.forName});
  final String dateLabel;
  final Map<String, dynamic> day;
  final String? forName;
  @override
  State<_MealDaySheet> createState() => _MealDaySheetState();
}

class _MealDaySheetState extends State<_MealDaySheet> {
  late final Map<String, int> _v = {
    for (final k in const ['b', 'l', 'd', 'gb', 'gl', 'gd'])
      k: (widget.day[k] as num?)?.toInt() ?? (k.startsWith('g') ? 0 : 1),
  };

  Widget _slot(String k, String label) {
    final t = AppLocalizations.of(context);
    final g = 'g$k';
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SwitchListTile(
          key: ValueKey('meal-$k'),
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          value: _v[k] == 1,
          onChanged: (on) => setState(() => _v[k] = on ? 1 : 0),
        ),
        Row(children: [
          Expanded(child: Text(t.mv2Guests)),
          IconButton(
            tooltip: t.mv2GuestLess,
            onPressed: _v[g]! > 0 ? () => setState(() => _v[g] = _v[g]! - 1) : null,
            icon: const Icon(Icons.remove_circle_outline_rounded),
          ),
          Text(messDigits(context, _v[g]), style: Theme.of(context).textTheme.titleMedium),
          IconButton(
            key: ValueKey('meal-guest-$k'),
            tooltip: t.mv2GuestMore,
            onPressed: _v[g]! < 20 ? () => setState(() => _v[g] = _v[g]! + 1) : null,
            icon: const Icon(Icons.add_circle_outline_rounded),
          ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
          key: const ValueKey('meal-save'),
          onPressed: () => Navigator.pop(context, Map<String, int>.from(_v)),
          child: Text(t.mv2Save),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.forName == null
                ? t.mv2MealsFor(widget.dateLabel)
                : t.mv2MealsForPerson(widget.forName!, widget.dateLabel),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        _slot('b', t.mv2Breakfast),
        _slot('l', t.mv2Lunch),
        _slot('d', t.mv2Dinner),
        Text(t.mv2GuestNote, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

// ======================================================================
// Several days off (owner order D)
// ======================================================================

/// Returns (from, to, on) or null.
Future<({DateTime from, DateTime to, bool on})?> showDaysOffSheet(BuildContext context) {
  return showAppSheet<({DateTime from, DateTime to, bool on})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _DaysOffSheet(),
  );
}

class _DaysOffSheet extends StatefulWidget {
  const _DaysOffSheet();
  @override
  State<_DaysOffSheet> createState() => _DaysOffSheetState();
}

class _DaysOffSheetState extends State<_DaysOffSheet> {
  DateTimeRange? _range;
  bool _on = false;

  Future<void> _pick() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day).add(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 120)),
    );
    if (r != null) setState(() => _range = r);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _range;
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
          key: const ValueKey('daysoff-save'),
          onPressed: r == null ? null : () => Navigator.pop(context, (from: r.start, to: r.end, on: _on)),
          child: Text(t.mv2Save),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.mv2DaysOffTitle,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.mv2DaysOffBody),
        const SizedBox(height: Gap.md),
        OutlinedButton.icon(
          key: const ValueKey('daysoff-pick'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _pick,
          icon: const Icon(Icons.date_range_rounded),
          label: Text(r == null
              ? t.mv2PickDays
              : '${messShortDate(context, messIsoDate(r.start))} – ${messShortDate(context, messIsoDate(r.end))}'),
        ),
        const SizedBox(height: Gap.sm),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: false, label: Text(t.mv2MealsOff)),
            ButtonSegment(value: true, label: Text(t.mv2MealsOn)),
          ],
          selected: {_on},
          onSelectionChanged: (s) => setState(() => _on = s.first),
        ),
      ]),
    );
  }
}

// ======================================================================
// Bazar / deposit / service charge / bazar turn (owner orders E, F, H)
// ======================================================================

const messChargeKinds = ['khala', 'electricity', 'gas', 'water', 'wifi', 'rent', 'other'];

String messChargeLabel(AppLocalizations t, String k) => switch (k) {
      'khala' => t.mv2ChKhala,
      'electricity' => t.mv2ChElectricity,
      'gas' => t.mv2ChGas,
      'water' => t.mv2ChWater,
      'wifi' => t.mv2ChWifi,
      'rent' => t.mv2ChRent,
      _ => t.mv2ChOther,
    };

/// Returns the POST body for mess/v2/<id>/entries (kind, date, amount
/// poisha, member_id?, data, photo_b64?) or null.
Future<Map<String, dynamic>?> showEntrySheet(BuildContext context,
    {required String kind,
    required List<Map<String, dynamic>> members,
    required int myMemberId,
    required bool staff}) {
  return showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _EntrySheet(kind: kind, members: members, myMemberId: myMemberId, staff: staff),
  );
}

class _EntrySheet extends StatefulWidget {
  const _EntrySheet(
      {required this.kind, required this.members, required this.myMemberId, required this.staff});
  final String kind;
  final List<Map<String, dynamic>> members;
  final int myMemberId;
  final bool staff;
  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  final _amount = TextEditingController();
  final _text = TextEditingController();
  late int _member = widget.myMemberId;
  DateTime _date = DateTime.now();
  String _chargeKind = 'wifi';
  bool _seat = false;
  bool _advance = false;
  List<int>? _photo;
  String? _amountErr;

  @override
  void dispose() {
    _amount.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource src) async {
    if (src == ImageSource.camera && !await showPermissionReason(context, PermKind.camera)) {
      return;
    }
    try {
      final x = await ImagePicker().pickImage(source: src, imageQuality: 60, maxWidth: 1600);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _photo = bytes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).mv2PhotoFailed)));
      }
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: 62)),
      lastDate: now.add(const Duration(days: 62)),
    );
    if (d != null) setState(() => _date = d);
  }

  void _save() {
    final t = AppLocalizations.of(context);
    int? amount;
    if (widget.kind != 'turn') {
      amount = messTakaToPoisha(_amount.text);
      if (amount == null) {
        setState(() => _amountErr = t.mv2AmountError);
        return;
      }
    }
    final data = <String, dynamic>{
      if (widget.kind == 'bazar') 'items': _text.text.trim(),
      if (widget.kind == 'deposit') ...{'advance': _advance, 'note': _text.text.trim()},
      if (widget.kind == 'charge') ...{
        'kind': _chargeKind,
        'split': _seat ? 'seat' : 'equal',
        'title': _text.text.trim(),
      },
    };
    Navigator.pop(context, {
      'kind': widget.kind,
      'date': messIsoDate(_date),
      if (amount != null) 'amount': amount,
      if (widget.kind != 'charge') 'member_id': _member,
      'data': data,
      if (_photo != null) 'photo_b64': base64Encode(_photo!),
      'client_id': MessOutbox.newClientId(),
    });
  }

  String _title(AppLocalizations t) => switch (widget.kind) {
        'bazar' => t.mv2AddBazar,
        'deposit' => t.mv2AddDeposit,
        'charge' => t.mv2AddCharge,
        _ => t.mv2AddTurn,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final active = widget.members.where((m) => m['status'] == 'active').toList();
    final canPickMember = widget.kind == 'turn' || (widget.staff && widget.kind != 'charge');
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
          key: const ValueKey('entry-save'),
          onPressed: _save,
          child: Text(t.mv2Save),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_title(t),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        if (widget.kind == 'charge') ...[
          Text(t.mv2ChargeNoteDays, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final k in messChargeKinds)
              ChoiceChip(
                key: ValueKey('charge-$k'),
                label: Text(messChargeLabel(t, k)),
                selected: _chargeKind == k,
                onSelected: (_) => setState(() {
                  _chargeKind = k;
                  _seat = k == 'rent';
                }),
              ),
          ]),
          const SizedBox(height: Gap.sm),
        ],
        if (canPickMember)
          DropdownButtonFormField<int>(
            key: const ValueKey('entry-member'),
            initialValue: active.any((m) => m['id'] == _member) ? _member : null,
            isExpanded: true,
            decoration: InputDecoration(
                labelText: widget.kind == 'turn'
                    ? t.mv2TurnWho
                    : (widget.kind == 'bazar' ? t.mv2BoughtBy : t.mv2DepositBy)),
            items: [
              for (final m in active)
                DropdownMenuItem(value: (m['id'] as num).toInt(), child: Text('${m['name']}')),
            ],
            onChanged: (v) => setState(() => _member = v ?? widget.myMemberId),
          ),
        if (widget.kind != 'turn') ...[
          const SizedBox(height: Gap.sm),
          TextField(
            key: const ValueKey('entry-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            maxLength: 12,
            buildCounter: localCounter,
            decoration: InputDecoration(
                labelText: t.mv2AmountLabel, prefixText: '৳ ', errorText: _amountErr),
            onChanged: (_) {
              if (_amountErr != null) setState(() => _amountErr = null);
            },
          ),
        ],
        if (widget.kind != 'turn') ...[
          const SizedBox(height: Gap.sm),
          TextField(
            key: const ValueKey('entry-text'),
            controller: _text,
            maxLength: widget.kind == 'bazar' ? 300 : 80,
            buildCounter: localCounter,
            decoration: InputDecoration(
                labelText: switch (widget.kind) {
              'bazar' => t.mv2ItemsLabel,
              'charge' => t.mv2ChargeTitleLabel,
              _ => t.mv2NoteLabel,
            }),
          ),
        ],
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _pickDate,
          icon: const Icon(Icons.event_rounded),
          label: Text(t.mv2DateLabel(messShortDate(context, messIsoDate(_date)))),
        ),
        if (widget.kind == 'charge')
          SwitchListTile(
            key: const ValueKey('charge-seat'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.mv2SplitBySeat),
            subtitle: Text(t.mv2SplitBySeatSub),
            value: _seat,
            onChanged: (v) => setState(() => _seat = v),
          ),
        if (widget.kind == 'deposit')
          SwitchListTile(
            key: const ValueKey('deposit-advance'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.mv2Advance),
            subtitle: Text(t.mv2AdvanceSub),
            value: _advance,
            onChanged: (v) => setState(() => _advance = v),
          ),
        if (widget.kind == 'bazar') ...[
          const SizedBox(height: Gap.sm),
          Text(t.mv2ReceiptLabel, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            OutlinedButton.icon(
              key: const ValueKey('receipt-camera'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _pickPhoto(ImageSource.camera),
              icon: const Icon(Icons.photo_camera_rounded),
              label: Text(t.mv2Camera),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _pickPhoto(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_rounded),
              label: Text(t.mv2Gallery),
            ),
          ]),
          if (_photo != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.mv2PhotoAdded, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.primary)),
            ),
        ],
      ]),
    );
  }
}

// ======================================================================
// Add member from My Circle (owner order B)
// ======================================================================

/// One-tap "add from My Circle". People not in My Circle are invited with
/// the existing My Circle invite flow; after they accept, they appear here.
/// Returns true when someone was added.
Future<bool?> showMessCirclePicker(BuildContext context, int messId) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CirclePicker(messId: messId),
  );
}

class _CirclePicker extends StatefulWidget {
  const _CirclePicker({required this.messId});
  final int messId;
  @override
  State<_CirclePicker> createState() => _CirclePickerState();
}

class _CirclePickerState extends State<_CirclePicker> {
  List<Map<String, dynamic>>? _rows;
  List<Map<String, dynamic>> _unlinked = [];
  Object? _error;
  bool _added = false;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await context.read<AppState>().api.messCirclePick(widget.messId);
      List<Map<String, dynamic>> rows(Object? v) =>
          ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      if (mounted) {
        setState(() {
          _rows = rows(r['results']);
          _unlinked = rows(r['unlinked']);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _add(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    final id = (row['circle_member_id'] as num).toInt();
    int? link;
    if (_unlinked.isNotEmpty) {
      link = await showAppSheet<int>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => AppSheetBody(
          primary: OutlinedButton(
              onPressed: () => Navigator.pop(ctx, -1), child: Text(t.mv2LinkNone)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.mv2LinkTitle(('${row['name']}')),
                style: Theme.of(ctx).textTheme.titleMedium),
            for (final u in _unlinked)
              ListTile(
                minTileHeight: 52,
                title: Text('${u['name']}'),
                onTap: () => Navigator.pop(ctx, (u['id'] as num).toInt()),
              ),
          ]),
        ),
      );
      if (link == null) return;
      if (link == -1) link = null;
    }
    if (!mounted) return;
    setState(() => _busy.add(id));
    try {
      await context.read<AppState>().api.messAddMember(widget.messId, id, linkMemberId: link);
      if (mounted) {
        setState(() {
          row['in_mess'] = true;
          _added = true;
          if (link != null) _unlinked.removeWhere((u) => u['id'] == link);
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.mv2MemberAdded('${row['name']}'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e is ApiException && e.message.isNotEmpty ? e.message : t.mv2SaveFailed)));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _invite() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const M3AddToCircleScreen()));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    if (_error != null) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.loadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.sm),
        FilledButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
      ]);
    } else if (_rows == null) {
      body = const Padding(
          padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()));
    } else if (_rows!.isEmpty) {
      body = Text(t.mv2CircleEmpty, textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant));
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        for (final r in _rows!)
          ListTile(
            key: ValueKey('mess-pick-${r['circle_member_id']}'),
            minTileHeight: 56,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
                child: Text(('${r['name'] ?? ''}'.trim().isEmpty ? '?' : '${r['name']}'.trim()[0])
                    .toUpperCase())),
            title: Text('${r['name'] ?? ''}'),
            trailing: r['in_mess'] == true
                ? Icon(Icons.check_circle_rounded, color: scheme.primary,
                    semanticLabel: t.mv2InMess)
                : _busy.contains((r['circle_member_id'] as num).toInt())
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : FilledButton.tonal(
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => _add(r),
                        child: Text(t.mv2Add)),
          ),
      ]);
    }
    return AppSheetBody(
      primary: _added
          ? FilledButton(
              key: const ValueKey('mess-pick-done'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.pop(context, true),
              child: Text(t.mv2Done))
          : OutlinedButton.icon(
              key: const ValueKey('mess-pick-invite'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _invite,
              icon: const Icon(Icons.person_add_alt_rounded),
              label: Text(t.mv2InviteToCircle, textAlign: TextAlign.center)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.mv2PickTitle,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.mv2PickSub, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        body,
        if (_added) ...[
          const SizedBox(height: Gap.sm),
          TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _invite,
              icon: const Icon(Icons.person_add_alt_rounded),
              label: Text(t.mv2InviteToCircle)),
        ],
      ]),
    );
  }
}
