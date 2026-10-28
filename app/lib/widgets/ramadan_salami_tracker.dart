import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Eid salami (eidi) tracker — a local log of amounts GIVEN / RECEIVED. Every
/// entry is user-entered; we never move money. Totals mirror
/// `core.logic.ramadan.salami_tracker_total` (given / received / net).
/// Entries persist locally (SharedPreferences).
class RamadanSalamiTracker extends StatefulWidget {
  const RamadanSalamiTracker({super.key});
  @override
  State<RamadanSalamiTracker> createState() => _RamadanSalamiTrackerState();
}

class _Entry {
  final String name;
  final double amount;
  final String direction; // 'given' | 'received'
  _Entry(this.name, this.amount, this.direction);
  Map<String, dynamic> toJson() =>
      {'name': name, 'amount': amount, 'direction': direction};
  static _Entry? fromJson(Map<String, dynamic> j) {
    final a = (j['amount'] is num)
        ? (j['amount'] as num).toDouble()
        : double.tryParse('${j['amount']}');
    if (a == null) return null;
    return _Entry('${j['name'] ?? ''}', a,
        j['direction'] == 'received' ? 'received' : 'given');
  }
}

class _RamadanSalamiTrackerState extends State<RamadanSalamiTracker> {
  static const _prefsKey = 'ramadan_salami_log';
  final List<_Entry> _entries = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        _entries
          ..clear()
          ..addAll(list.map(_Entry.fromJson).whereType<_Entry>());
      } catch (_) {}
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(_entries.map((e) => e.toJson()).toList()));
  }

  double get _given => _entries
      .where((e) => e.direction == 'given')
      .fold(0.0, (s, e) => s + e.amount);
  double get _received => _entries
      .where((e) => e.direction == 'received')
      .fold(0.0, (s, e) => s + e.amount);

  Future<void> _add() async {
    final nameC = TextEditingController();
    final amtC = TextEditingController();
    String dir = 'given';
    final t = AppLocalizations.of(context);
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true, // insets: 200% text / keyboard
          title: Text(t.ramadanSalamiAdd),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameC,
              decoration:
                  InputDecoration(labelText: t.ramadanSalamiName, isDense: true),
            ),
            const SizedBox(height: Gap.xs),
            TextField(
              controller: amtC,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t.ramadanSalamiAmount, isDense: true),
            ),
            const SizedBox(height: Gap.sm),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'given', label: Text(t.ramadanSalamiGiven)),
                ButtonSegment(
                    value: 'received', label: Text(t.ramadanSalamiReceived)),
              ],
              selected: {dir},
              onSelectionChanged: (s) => setD(() => dir = s.first),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.ramadanCancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.ramadanSalamiSave)),
          ],
        ),
      ),
    );
    if (added == true) {
      final amt = double.tryParse(amtC.text.trim().replaceAll(',', ''));
      if (amt != null && amt > 0) {
        setState(() => _entries.add(_Entry(nameC.text.trim(), amt, dir)));
        await _save();
      }
    }
    nameC.dispose();
    amtC.dispose();
  }

  Future<void> _remove(int i) async {
    setState(() => _entries.removeAt(i));
    await _save();
  }

  String _money(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.card_giftcard_rounded, color: Brand.warning),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.ramadanSalamiTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            IconButton(
              tooltip: t.ramadanSalamiAdd,
              icon: const Icon(Icons.add_circle_outline_rounded),
              onPressed: _add,
            ),
          ]),
          Row(children: [
            Expanded(
                child: _stat(t.ramadanSalamiGiven, _money(_given), Brand.warning)),
            Expanded(
                child:
                    _stat(t.ramadanSalamiReceived, _money(_received), Brand.blue)),
            Expanded(
                child: _stat(t.ramadanSalamiNet, _money(_received - _given),
                    Brand.purple)),
          ]),
          if (_entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(t.ramadanSalamiEmpty,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            )
          else
            ..._entries.asMap().entries.map((e) {
              final it = e.value;
              final recv = it.direction == 'received';
              return ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                    recv ? Icons.south_west_rounded : Icons.north_east_rounded,
                    color: recv ? Brand.blue : Brand.warning,
                    size: 18),
                title: Text(it.name.isEmpty ? '—' : it.name),
                subtitle: Text(recv
                    ? t.ramadanSalamiReceived
                    : t.ramadanSalamiGiven),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_money(it.amount),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    onPressed: () => _remove(e.key),
                  ),
                ]),
              );
            }),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Column(children: [
      Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      Text(value,
          style: TextStyle(fontWeight: FontWeight.bold, color: color)),
    ]);
  }
}
