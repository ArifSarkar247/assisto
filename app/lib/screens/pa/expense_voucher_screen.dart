import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA SECRETARY MODE — EXPENSE VOUCHER / claim builder (#113, §14, ADVANCED).
///
/// The PA builds a voucher entirely by hand, offline, with NO key: a header
/// (title + claimant + approval STATUS draft→submitted→approved) and LINE ITEMS
/// (date, category, ৳ amount, attach-receipt REFERENCE, note). The engine
/// auto-TOTALS the lines and shows a deterministic voucher summary.
///
/// MONEY IS INTEGER POISHA — all amounts carried as int poisha (1 taka = 100
/// poisha) so totals never drift (mirror of backend/core/logic/pa_expense.py
/// to_poisha / fmt_bdt). HOLDS NO MONEY — it only sums what the PA typed.
///
/// HONEST, KEY-GATED (NEVER FABRICATES):
///   * OCR auto-read of a receipt photo is a DOCUMENTED key-gated seam shown as
///     an honest "connect an OCR key to auto-read receipts" card (_OcrSeamCard).
///     This screen NEVER invents an amount, merchant or date from an image.
///
/// Honest states: welcome (no vouchers) · loading · error. ZERO Bangla literals
/// — every string is an AppLocalizations getter (৳ exempt).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('pa/vouchers')  → mixed rows tagged by {kind}:
///     {id, kind:'voucher', title, claimant, status, note}
///     {id, kind:'line',    voucher_id, date, category, amount, receipt_ref,
///                          note}
///   create/update/delete on 'pa/vouchers'; rows round-trip as {id, ...data}
///   through one flexible per-user JSON collection (PaCollectionItem precedent).
class ExpenseVoucherScreen extends StatefulWidget {
  const ExpenseVoucherScreen({super.key});
  @override
  State<ExpenseVoucherScreen> createState() => _ExpenseVoucherScreenState();
}

const String _path = 'pa/vouchers';

const List<String> _statuses = ['draft', 'submitted', 'approved'];
const List<String> _categories = [
  'transport',
  'lodging',
  'meals',
  'supplies',
  'communication',
  'entertainment',
  'other',
];

// -------- integer-poisha math (mirror of pa_expense.to_poisha / fmt_bdt) ----
int _toPoisha(dynamic v) {
  if (v == null || v == '') return 0;
  if (v is bool) return 0;
  var s = '$v'.trim().replaceAll(',', '');
  if (s.startsWith('-')) return 0;
  String whole, frac;
  if (s.contains('.')) {
    final parts = s.split('.');
    whole = parts[0];
    frac = parts.sublist(1).join();
  } else {
    whole = s;
    frac = '';
  }
  if (whole.isEmpty) whole = '0';
  frac = (frac + '000').substring(0, 3);
  final major = int.tryParse(whole);
  final milli = int.tryParse(frac);
  if (major == null || milli == null) return 0;
  var poisha = major * 100 + milli ~/ 10;
  if (milli % 10 >= 5) poisha += 1;
  return poisha;
}

String _fmtBdt(int poisha) {
  final neg = poisha < 0;
  var p = poisha.abs();
  final taka = p ~/ 100;
  final paisa = p % 100;
  final s = taka.toString();
  String grouped;
  if (s.length <= 3) {
    grouped = s;
  } else {
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    grouped = '${parts.join(',')},$tail';
  }
  return '${neg ? '-' : ''}৳$grouped.${paisa.toString().padLeft(2, '0')}';
}

DateTime? _parse(String s) {
  var x = s.trim();
  if (x.isEmpty) return null;
  if (x.endsWith('Z')) x = x.substring(0, x.length - 1);
  return DateTime.tryParse(x) ?? DateTime.tryParse('${x}T00:00:00');
}

String _advance(String status) {
  if (status == 'draft') return 'submitted';
  if (status == 'submitted') return 'approved';
  return 'approved';
}

class _ExpenseVoucherScreenState extends State<ExpenseVoucherScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
      _rows = await context.read<AppState>().api.listItems(_path);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _vouchers =>
      _rows.where((r) => '${r['kind']}' == 'voucher').toList();

  int _voucherTotal(int id) {
    var sum = 0;
    for (final r in _rows) {
      if ('${r['kind']}' == 'line' && r['voucher_id'] == id) {
        sum += _toPoisha(r['amount']);
      }
    }
    return sum;
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _openVoucherEditor([Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _VoucherEditor(existing: existing),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_path, existing['id'] as int, result);
      } else {
        await api.createItem(_path, {...result, 'kind': 'voucher'});
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'submitted':
        return t.paVoucherStatusSubmitted;
      case 'approved':
        return t.paVoucherStatusApproved;
      default:
        return t.paVoucherStatusDraft;
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'submitted':
        return Brand.warning;
      case 'approved':
        return Brand.success;
      default:
        return Brand.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.paVoucherTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(t.paVoucherTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: t.loadFailed,
          message: honestFailText(t, _failCause, otherwise: t.paVoucherLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry)),
        ),
      );
    }
    final vouchers = _vouchers;
    return Scaffold(
      appBar: AppBar(title: Text(t.paVoucherTitle)),
      // qa1: the empty state already has this action as its CTA — one is enough
      floatingActionButton: vouchers.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openVoucherEditor(),
              icon: const Icon(Icons.add),
              label: Text(t.paVoucherNew),
            ),
      body: vouchers.isEmpty
          ? StateMessage(
              icon: Icons.receipt_long,
              tint: Brand.blue,
              title: t.paVoucherWelcomeTitle,
              message: t.paVoucherWelcomeBody,
              action: FilledButton.icon(
                onPressed: () => _openVoucherEditor(),
                icon: const Icon(Icons.add),
                label: Text(t.paVoucherNew),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  const _OcrSeamCard(),
                  const SizedBox(height: Gap.sm),
                  for (final v in vouchers)
                    Card(
                      margin: const EdgeInsets.only(bottom: Gap.sm),
                      child: ListTile(
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _VoucherDetailScreen(voucher: v),
                          ));
                          await _load();
                        },
                        leading: CircleAvatar(
                          backgroundColor:
                              _statusColor('${v['status']}').withValues(alpha: 0.18),
                          child: Icon(Icons.description_outlined,
                              color: _statusColor('${v['status']}')),
                        ),
                        title: Text('${v['title'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          if ('${v['claimant'] ?? ''}'.trim().isNotEmpty)
                            '${v['claimant']}',
                          _statusLabel('${v['status'] ?? 'draft'}'),
                        ].join(' · ')),
                        trailing: Text(_fmtBdt(_voucherTotal(v['id'] as int)),
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

// ======================= OCR seam (key-gated) =======================
class _OcrSeamCard extends StatelessWidget {
  const _OcrSeamCard();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.document_scanner_outlined,
              size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.paVoucherOcrSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(t.paVoucherOcrSeamBody,
                  style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                      height: 1.35)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= voucher detail =======================
class _VoucherDetailScreen extends StatefulWidget {
  final Map<String, dynamic> voucher;
  const _VoucherDetailScreen({required this.voucher});
  @override
  State<_VoucherDetailScreen> createState() => _VoucherDetailScreenState();
}

class _VoucherDetailScreenState extends State<_VoucherDetailScreen> {
  List<Map<String, dynamic>> _lines = [];
  String _status = 'draft';
  bool _loading = true;

  AppLocalizations get t => AppLocalizations.of(context);
  int get _vid => widget.voucher['id'] as int;

  @override
  void initState() {
    super.initState();
    _status = '${widget.voucher['status'] ?? 'draft'}';
    if (!_statuses.contains(_status)) _status = 'draft';
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final all = await context.read<AppState>().api.listItems(_path);
      final mine = all
          .where((r) => '${r['kind']}' == 'line' && r['voucher_id'] == _vid)
          .toList();
      const far = '9999-12-31T23:59:59';
      mine.sort((a, b) {
        final ka = _parse('${a['date'] ?? ''}')?.toIso8601String() ?? far;
        final kb = _parse('${b['date'] ?? ''}')?.toIso8601String() ?? far;
        return ka.compareTo(kb);
      });
      _lines = mine;
    } catch (_) {
      _lines = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  int get _totalPoisha =>
      _lines.fold(0, (s, l) => s + _toPoisha(l['amount']));

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _addOrEditLine([Map<String, dynamic>? e]) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LineEditor(existing: e, categoryLabel: _categoryLabel),
    );
    if (r == null) return;
    final api = context.read<AppState>().api;
    try {
      if (e != null && e['id'] is int) {
        await api.updateItem(_path, e['id'] as int, {...r, 'voucher_id': _vid});
      } else {
        await api.createItem(_path, {...r, 'voucher_id': _vid});
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _deleteLine(int id) async {
    try {
      await context.read<AppState>().api.deleteItem(_path, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _setStatus(String s) async {
    try {
      await context.read<AppState>().api.updateItem(_path, _vid, {
        'kind': 'voucher',
        'title': widget.voucher['title'],
        'claimant': widget.voucher['claimant'],
        'status': s,
      });
      if (mounted) setState(() => _status = s);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  String _categoryLabel(String c) {
    switch (c) {
      case 'transport':
        return t.paVoucherCatTransport;
      case 'lodging':
        return t.paVoucherCatLodging;
      case 'meals':
        return t.paVoucherCatMeals;
      case 'supplies':
        return t.paVoucherCatSupplies;
      case 'communication':
        return t.paVoucherCatCommunication;
      case 'entertainment':
        return t.paVoucherCatEntertainment;
      default:
        return t.paVoucherCatOther;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'submitted':
        return t.paVoucherStatusSubmitted;
      case 'approved':
        return t.paVoucherStatusApproved;
      default:
        return t.paVoucherStatusDraft;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.voucher['title'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEditLine(),
        icon: const Icon(Icons.add),
        label: Text(t.paVoucherAddLine),
      ),
      body: _loading
          ? const SkeletonList()
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
              children: [
                // total + status banner
                Container(
                  padding: const EdgeInsets.all(Gap.lg),
                  decoration: BoxDecoration(
                      gradient: Brand.gradient,
                      borderRadius: BorderRadius.circular(Radii.lg)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.paVoucherTotalLabel,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                        Text(_fmtBdt(_totalPoisha),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: Gap.sm),
                        Text(t.paVoucherLineCount(_lines.length),
                            style: const TextStyle(color: Colors.white70)),
                      ]),
                ),
                const SizedBox(height: Gap.lg),

                // status flow
                Text(t.paVoucherStatusLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: Gap.xs),
                Wrap(spacing: Gap.sm, children: [
                  for (final s in _statuses)
                    ChoiceChip(
                      label: Text(_statusLabel(s)),
                      selected: _status == s,
                      onSelected: (_) => _setStatus(s),
                    ),
                ]),
                if (_status != 'approved') ...[
                  const SizedBox(height: Gap.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: Text(_status == 'draft'
                          ? t.paVoucherSubmit
                          : t.paVoucherApprove),
                      onPressed: () => _setStatus(_advance(_status)),
                    ),
                  ),
                ],
                const Divider(height: Gap.xl),

                // lines
                Text(t.paVoucherLinesHeader,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: Gap.xs),
                if (_lines.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.md),
                    child: Text(t.paVoucherNoLines,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  )
                else
                  for (final l in _lines)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.payments_outlined),
                      title: Text(_fmtBdt(_toPoisha(l['amount'])),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text([
                        _categoryLabel('${l['category'] ?? 'other'}'),
                        if ('${l['date'] ?? ''}'.trim().isNotEmpty)
                          '${l['date']}',
                        if ('${l['receipt_ref'] ?? ''}'.trim().isNotEmpty)
                          t.paVoucherReceiptLabel('${l['receipt_ref']}'),
                      ].join(' · '),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) => v == 'edit'
                            ? _addOrEditLine(l)
                            : _deleteLine(l['id'] as int),
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'edit', child: Text(t.edit)),
                          PopupMenuItem(
                              value: 'delete', child: Text(t.delete)),
                        ],
                      ),
                    ),
              ],
            ),
    );
  }
}

// ======================= editors =======================
class _VoucherEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _VoucherEditor({this.existing});
  @override
  State<_VoucherEditor> createState() => _VoucherEditorState();
}

class _VoucherEditorState extends State<_VoucherEditor> {
  late final TextEditingController _title =
      TextEditingController(text: '${widget.existing?['title'] ?? ''}');
  late final TextEditingController _claimant =
      TextEditingController(text: '${widget.existing?['claimant'] ?? ''}');

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _title.dispose();
    _claimant.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paVoucherTitleRequired)));
      return;
    }
    Navigator.pop(context, {
      'kind': 'voucher',
      'title': _title.text.trim(),
      'claimant': _claimant.text.trim(),
      'status': '${widget.existing?['status'] ?? 'draft'}',
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.existing == null ? t.paVoucherNew : t.edit,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.lg),
          TextField(
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: t.paVoucherTitleLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _claimant,
              decoration: InputDecoration(
                  labelText: t.paVoucherClaimantLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.lg),
          SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: Text(t.save))),
        ]),
      ),
    );
  }
}

class _LineEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String Function(String) categoryLabel;
  const _LineEditor({this.existing, required this.categoryLabel});
  @override
  State<_LineEditor> createState() => _LineEditorState();
}

class _LineEditorState extends State<_LineEditor> {
  late final TextEditingController _amount =
      TextEditingController(text: '${widget.existing?['amount'] ?? ''}');
  late final TextEditingController _ref =
      TextEditingController(text: '${widget.existing?['receipt_ref'] ?? ''}');
  late final TextEditingController _note =
      TextEditingController(text: '${widget.existing?['note'] ?? ''}');
  late String _category = _categories.contains('${widget.existing?['category']}')
      ? '${widget.existing!['category']}'
      : 'other';
  late String _date = '${widget.existing?['date'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (_toPoisha(_amount.text) <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paVoucherAmountRequired)));
      return;
    }
    Navigator.pop(context, {
      'kind': 'line',
      'date': _date,
      'category': _category,
      'amount': _amount.text.trim(),
      'receipt_ref': _ref.text.trim(),
      'note': _note.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.paVoucherAddLine,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _amount,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: t.paVoucherAmountLabel,
                    prefixText: '৳ ',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Text(t.paVoucherCategoryLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                for (final c in _categories)
                  ChoiceChip(
                    label: Text(widget.categoryLabel(c)),
                    selected: _category == c,
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.event, size: 18),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    alignment: Alignment.centerLeft),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_date.isEmpty
                      ? t.paVoucherDateLabel
                      : '${t.paVoucherDateLabel}: $_date'),
                ),
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _parse(_date) ?? now,
                    firstDate: DateTime(now.year - 2),
                    lastDate: DateTime(now.year + 1),
                  );
                  if (picked != null) {
                    setState(() => _date =
                        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
                  }
                },
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _ref,
                decoration: InputDecoration(
                    labelText: t.paVoucherReceiptRefLabel,
                    helperText: t.paVoucherReceiptRefHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _note,
                decoration: InputDecoration(
                    labelText: t.paVoucherLineNoteLabel,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              SizedBox(
                  width: double.infinity,
                  child:
                      FilledButton(onPressed: _save, child: Text(t.save))),
            ]),
      ),
    );
  }
}
