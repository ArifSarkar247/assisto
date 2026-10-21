import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// PROBASHI CORNER — ADVANCED (#191, SPEC v2.1 §20) for Bangladeshis abroad.
///
/// Three deterministic tools, NO money held, NO live clock crept into the math:
///
///   1. REMITTANCE LOG — each time you send money home you record the amount you
///      SENT (foreign currency), the exchange RATE, and the date. The screen
///      computes the BDT RECEIVED per row and the running totals (total sent,
///      total BDT, honest effective rate). The app sends and holds NO money.
///   2. TIME-ZONE PAIR — your abroad UTC offset vs Bangladesh (+6:00). From ONE
///      instant (`DateTime.now().toUtc()`, read once per build) both local clocks
///      are rendered side by side with the ahead/behind difference.
///   3. DOCUMENTS CHECKLIST — passport / visa / ticket etc. with an expiry date;
///      days-until-expiry and a status (valid / expiring-soon / expired) are
///      computed from today. Automatic reminders are a documented seam only.
///
/// All MONEY is INTEGER POISHA (BDT) / integer minor units (foreign); `_PMath`
/// mirrors backend/core/logic/probashi.py VERBATIM so every number is identical
/// offline. ZERO Bangla literals — every string is an AppLocalizations getter;
/// the ৳ sign is a currency glyph (gate-exempt).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('probashi/remittances') → [{id, amount, rate, date, currency?,
///                                          note?}]
///   listItems('probashi/docs')        → [{id, kind, label?, number?, expiry?}]
/// create/update/deleteItem on the same paths; each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection.
class ProbashiScreen extends StatefulWidget {
  const ProbashiScreen({super.key});
  @override
  State<ProbashiScreen> createState() => _ProbashiScreenState();
}

const String _remitPath = 'probashi/remittances';
const String _docsPath = 'probashi/docs';

// Known document kinds — stable keys, labels localised (mirror DOC_KINDS).
const List<String> _docKinds = [
  'passport',
  'visa',
  'ticket',
  'nid',
  'work_permit',
  'insurance',
  'other',
];

class _ProbashiScreenState extends State<ProbashiScreen> {
  List<Map<String, dynamic>> _remits = [];
  List<Map<String, dynamic>> _docs = [];
  bool _loading = true, _error = false;
  // abroad UTC offset in minutes; default Gulf (+4:00) — editable, persisted
  // in a tiny local preference-less field (lives for the session).
  int _abroadOffsetMin = 4 * 60;

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
        api.listItems(_remitPath),
        api.listItems(_docsPath),
      ]);
      _remits = res[0];
      _docs = res[1];
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.probashiTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.probashiTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.probashiLoadError,
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.probashiTitle),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: tr.probashiTabRemit),
              Tab(text: tr.probashiTabClock),
              Tab(text: tr.probashiTabDocs),
            ],
          ),
        ),
        body: TabBarView(children: [
          _RemitTab(
            remits: _remits,
            onAdd: _addRemit,
            onEdit: _editRemit,
            onDelete: _deleteRemit,
          ),
          _ClockTab(
            abroadOffsetMin: _abroadOffsetMin,
            onPickOffset: _pickAbroadOffset,
          ),
          _DocsTab(
            docs: _docs,
            onAdd: _addDoc,
            onEdit: _editDoc,
            onDelete: _deleteDoc,
          ),
        ]),
      ),
    );
  }

  // ---- remittance CRUD ------------------------------------------------------
  Future<void> _addRemit() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _remitSheet(context, null);
    if (res == null) return;
    try {
      await api.createItem(_remitPath, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _editRemit(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _remitSheet(context, row);
    if (res == null) return;
    try {
      await api.updateItem(_remitPath, row['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _deleteRemit(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok = await _confirm(
        context, tr.probashiDeleteRemitTitle, tr.probashiDeleteRemitBody);
    if (ok != true) return;
    try {
      await api.deleteItem(_remitPath, row['id'] as int);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  // ---- documents CRUD -------------------------------------------------------
  Future<void> _addDoc() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _docSheet(context, null);
    if (res == null) return;
    try {
      await api.createItem(_docsPath, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _editDoc(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _docSheet(context, row);
    if (res == null) return;
    try {
      await api.updateItem(_docsPath, row['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _deleteDoc(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok = await _confirm(
        context, tr.probashiDeleteDocTitle, tr.probashiDeleteDocBody);
    if (ok != true) return;
    try {
      await api.deleteItem(_docsPath, row['id'] as int);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _pickAbroadOffset() async {
    final picked = await _offsetSheet(context, _abroadOffsetMin);
    if (picked != null && mounted) {
      setState(() => _abroadOffsetMin = picked);
    }
  }
}

String _docKindLabel(AppLocalizations tr, String? kind) {
  switch (kind) {
    case 'passport':
      return tr.probashiDocPassport;
    case 'visa':
      return tr.probashiDocVisa;
    case 'ticket':
      return tr.probashiDocTicket;
    case 'nid':
      return tr.probashiDocNid;
    case 'work_permit':
      return tr.probashiDocWorkPermit;
    case 'insurance':
      return tr.probashiDocInsurance;
    default:
      return tr.probashiDocOther;
  }
}

// ======================= REMITTANCE TAB =======================
class _RemitTab extends StatelessWidget {
  final List<Map<String, dynamic>> remits;
  final VoidCallback onAdd;
  final Future<void> Function(Map<String, dynamic>) onEdit;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  const _RemitTab({
    required this.remits,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final summary = _PMath.remittanceSummary(remits);
    return Scaffold(
      floatingActionButton: remits.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: Text(tr.probashiLogSend),
            ),
      body: remits.isEmpty
          ? StateMessage(
              icon: Icons.send_outlined,
              title: tr.probashiRemitWelcomeTitle,
              message: tr.probashiRemitWelcomeBody,
              action: FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: Text(tr.probashiLogSend),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
              children: [
                // totals card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr.probashiTotals,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: Gap.sm),
                        _kv(context, tr.probashiTotalSent,
                            summary.totalSentDisplay),
                        _kv(context, tr.probashiTotalReceived,
                            summary.totalBdtDisplay),
                        _kv(context, tr.probashiEffectiveRate,
                            summary.avgRateDisplay),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.sm),
                // honest "never a wallet" note
                _noteCard(context, tr.probashiNeverHolds),
                const SizedBox(height: Gap.md),
                Text(tr.probashiHistory,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.sm),
                ...summary.rows.map((r) => Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: scheme.primaryContainer,
                          child: Icon(Icons.arrow_upward,
                              color: scheme.onPrimaryContainer),
                        ),
                        title: Text(
                          tr.probashiSentReceived(
                              r.amountDisplay, r.bdtDisplay),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(tr.probashiRateOnDate(/* (date, rate) */
                            r.dateDisplay, r.rateDisplay)),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') onEdit(r.raw);
                            if (v == 'delete') onDelete(r.raw);
                          },
                          itemBuilder: (ctx) => [
                            PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                            PopupMenuItem(
                                value: 'delete', child: Text(tr.delete)),
                          ],
                        ),
                      ),
                    )),
              ],
            ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
              child: Text(k, style: TextStyle(color: scheme.onSurfaceVariant))),
          const SizedBox(width: Gap.sm),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ======================= CLOCK / TIMEZONE TAB =======================
class _ClockTab extends StatelessWidget {
  final int abroadOffsetMin;
  final VoidCallback onPickOffset;
  const _ClockTab(
      {required this.abroadOffsetMin, required this.onPickOffset});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final nowUtc = DateTime.now().toUtc(); // ONLY time input, read once.
    final pair = _PMath.timezonePair(nowUtc, abroadOffsetMin);
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(children: [
              Row(children: [
                Expanded(
                    child: _clock(context, tr.probashiAbroad,
                        pair.abroadTime, pair.abroadOffsetDisplay)),
                Container(
                    width: 1, height: 64, color: scheme.outlineVariant),
                Expanded(
                    child: _clock(context, tr.probashiHome, pair.homeTime,
                        pair.homeOffsetDisplay)),
              ]),
              const SizedBox(height: Gap.md),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.md, vertical: Gap.sm),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(
                  _diffLabel(tr, pair),
                  style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        Card(
          child: ListTile(
            leading: const Icon(Icons.public),
            title: Text(tr.probashiAbroadZone),
            subtitle: Text(pair.abroadOffsetDisplay),
            trailing: FilledButton.tonal(
              onPressed: onPickOffset,
              child: Text(tr.probashiChangeZone),
            ),
          ),
        ),
        const SizedBox(height: Gap.sm),
        _noteCard(context, tr.probashiClockNote),
      ],
    );
  }

  String _diffLabel(AppLocalizations tr, _PPair pair) {
    if (pair.ahead == 'same') return tr.probashiSameTime;
    if (pair.ahead == 'home') return tr.probashiHomeAhead(pair.diffDisplay);
    return tr.probashiHomeBehind(pair.diffDisplay);
  }

  Widget _clock(
      BuildContext context, String label, String time, String offset) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Text(label,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.xs),
      Text(time,
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.xs),
      Text(offset,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }
}

// ======================= DOCUMENTS TAB =======================
class _DocsTab extends StatelessWidget {
  final List<Map<String, dynamic>> docs;
  final VoidCallback onAdd;
  final Future<void> Function(Map<String, dynamic>) onEdit;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  const _DocsTab({
    required this.docs,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    final overview = _PMath.docsOverview(docs, today);
    return Scaffold(
      floatingActionButton: docs.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: Text(tr.probashiAddDoc),
            ),
      body: docs.isEmpty
          ? StateMessage(
              icon: Icons.badge_outlined,
              title: tr.probashiDocsWelcomeTitle,
              message: tr.probashiDocsWelcomeBody,
              action: FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: Text(tr.probashiAddDoc),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _count(context, tr.probashiStatExpired,
                            overview.expired, scheme.error),
                        _count(context, tr.probashiStatExpiring,
                            overview.expiring, Brand.warning),
                        _count(context, tr.probashiStatValid, overview.valid,
                            scheme.primary),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.sm),
                _noteCard(context, tr.probashiDocsNote),
                const SizedBox(height: Gap.md),
                ...overview.rows.map((d) => Card(
                      child: ListTile(
                        leading: Icon(_statusIcon(d.status),
                            color: _statusColor(context, d.status)),
                        title: Text(
                          d.label.isEmpty
                              ? _docKindLabel(tr, d.kind)
                              : d.label,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(_statusLabel(tr, d)),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') onEdit(d.raw);
                            if (v == 'delete') onDelete(d.raw);
                          },
                          itemBuilder: (ctx) => [
                            PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                            PopupMenuItem(
                                value: 'delete', child: Text(tr.delete)),
                          ],
                        ),
                      ),
                    )),
              ],
            ),
    );
  }

  Widget _count(BuildContext context, String label, int n, Color color) {
    return Column(children: [
      Text('$n',
          style: TextStyle(
              fontSize: 26, fontWeight: FontWeight.w700, color: color)),
      const SizedBox(height: Gap.xs),
      Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'expired':
        return Icons.error_outline;
      case 'expiring':
        return Icons.warning_amber_outlined;
      case 'valid':
        return Icons.check_circle_outline;
      default:
        return Icons.help_outline;
    }
  }

  Color _statusColor(BuildContext context, String status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case 'expired':
        return scheme.error;
      case 'expiring':
        return Brand.warning;
      case 'valid':
        return scheme.primary;
      default:
        return scheme.onSurfaceVariant;
    }
  }

  String _statusLabel(AppLocalizations tr, _PDoc d) {
    switch (d.status) {
      case 'expired':
        return tr.probashiExpiredAgo('${-d.daysLeft}');
      case 'expiring':
        return tr.probashiExpiresIn('${d.daysLeft}');
      case 'valid':
        return tr.probashiValidDays('${d.daysLeft}');
      default:
        return tr.probashiNoExpiry;
    }
  }
}

// shared card helpers ---------------------------------------------------------
Widget _noteCard(BuildContext context, String text) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    color: scheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(Icons.info_outline, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant))),
      ]),
    ),
  );
}

// ===========================================================================
// _PMath — VERBATIM mirror of backend/core/logic/probashi.py (integer minor
// units / integer poisha, deterministic time from a passed-in instant).
// ===========================================================================
class _PRemit {
  final Map<String, dynamic> raw;
  final String amountDisplay;
  final String rateDisplay;
  final String dateDisplay;
  final String bdtDisplay;
  _PRemit(this.raw, this.amountDisplay, this.rateDisplay, this.dateDisplay,
      this.bdtDisplay);
}

class _PRemitSummary {
  final List<_PRemit> rows;
  final int count;
  final String totalSentDisplay;
  final String totalBdtDisplay;
  final String avgRateDisplay;
  _PRemitSummary(this.rows, this.count, this.totalSentDisplay,
      this.totalBdtDisplay, this.avgRateDisplay);
}

class _PPair {
  final String homeTime;
  final String abroadTime;
  final String homeOffsetDisplay;
  final String abroadOffsetDisplay;
  final String ahead; // 'home' | 'abroad' | 'same'
  final String diffDisplay; // e.g. "2" or "5:30"
  _PPair(this.homeTime, this.abroadTime, this.homeOffsetDisplay,
      this.abroadOffsetDisplay, this.ahead, this.diffDisplay);
}

class _PDoc {
  final Map<String, dynamic> raw;
  final String kind;
  final String label;
  final int daysLeft; // 0 when no date; `status` disambiguates
  final String status; // 'expired' | 'expiring' | 'valid' | 'no_date'
  _PDoc(this.raw, this.kind, this.label, this.daysLeft, this.status);
}

class _PDocsOverview {
  final List<_PDoc> rows;
  final int expired, expiring, valid, noDate;
  _PDocsOverview(
      this.rows, this.expired, this.expiring, this.valid, this.noDate);
}

class _PMath {
  static const int homeOffsetMin = 6 * 60; // Bangladesh UTC+6:00, no DST.
  static const int defaultWarnDays = 90;

  // --- money: integer minor units, no float drift (mirror to_minor) ---
  static int toMinor(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) return (v * 100).round();
    var s = v.toString().trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final parts = s.split('.');
      whole = parts[0];
      frac = parts.length > 1 ? parts[1] : '';
    } else {
      whole = s;
      frac = '';
    }
    whole = whole.isEmpty ? '0' : whole;
    frac = (frac + '00').substring(0, 3);
    final major = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (major == null || milli == null) return 0;
    var minor = major * 100 + milli ~/ 10;
    if (milli % 10 >= 5) minor += 1;
    return neg ? -minor : minor;
  }

  static String _group(int n) {
    var s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  static String fmtBdt(int poisha) {
    final neg = poisha < 0;
    poisha = poisha.abs();
    final taka = poisha ~/ 100;
    final paisa = poisha % 100;
    return '${neg ? '-' : ''}৳${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
  }

  static String fmtMinor(int minor) {
    final neg = minor < 0;
    minor = minor.abs();
    final major = minor ~/ 100;
    final sub = minor % 100;
    return '${neg ? '-' : ''}${_group(major)}.${sub.toString().padLeft(2, '0')}';
  }

  static double parseRate(dynamic v) {
    if (v == null || v == '') return 0.0;
    final r = double.tryParse(v.toString().trim().replaceAll(',', ''));
    if (r == null) return 0.0;
    return r >= 0 ? r : 0.0;
  }

  // BDT received (poisha), rounded ONCE, sign-aware half-up (mirror bdt_received)
  static int bdtReceived(int amountMinor, dynamic rate) {
    final r = parseRate(rate);
    final exact = amountMinor * r; // already poisha
    if (exact >= 0) return (exact + 0.5).floor();
    return -((-exact + 0.5).floor());
  }

  static _PRemitSummary remittanceSummary(List<Map<String, dynamic>> rows) {
    final out = <_PRemit>[];
    var totalMinor = 0;
    var totalBdt = 0;
    for (final r in rows) {
      final amt = toMinor(r['amount']);
      final rate = parseRate(r['rate']);
      final bdt = bdtReceived(amt, rate);
      totalMinor += amt;
      totalBdt += bdt;
      out.add(_PRemit(
        r,
        fmtMinor(amt),
        rate.toStringAsFixed(2),
        (r['date'] ?? '').toString(),
        fmtBdt(bdt),
      ));
    }
    final avg = totalMinor != 0 ? totalBdt / totalMinor : 0.0;
    return _PRemitSummary(
      out,
      out.length,
      fmtMinor(totalMinor),
      fmtBdt(totalBdt),
      avg.toStringAsFixed(2),
    );
  }

  // --- timezone pair (deterministic from a passed-in UTC instant) ---
  static String fmtOffset(int mins) {
    final sign = mins < 0 ? '-' : '+';
    mins = mins.abs();
    return 'UTC$sign${mins ~/ 60}:${(mins % 60).toString().padLeft(2, '0')}';
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static _PPair timezonePair(DateTime nowUtc, int abroadOffsetMin,
      {int homeOffset = homeOffsetMin}) {
    final utc = nowUtc.toUtc();
    final ab = utc.add(Duration(minutes: abroadOffsetMin));
    final hm = utc.add(Duration(minutes: homeOffset));
    final diff = homeOffset - abroadOffsetMin; // home ahead by this many mins
    final String ahead = diff > 0 ? 'home' : (diff < 0 ? 'abroad' : 'same');
    final d = diff.abs();
    final dh = d ~/ 60;
    final dm = d % 60;
    final hhmm = dm != 0 ? '$dh:${dm.toString().padLeft(2, '0')}' : '$dh';
    return _PPair(
      _hhmm(hm),
      _hhmm(ab),
      fmtOffset(homeOffset),
      fmtOffset(abroadOffsetMin),
      ahead,
      hhmm,
    );
  }

  // --- documents checklist (expiry from a passed-in `today`) ---
  static DateTime? _asDate(dynamic v) {
    if (v == null || v == '') return null;
    if (v is DateTime) return DateTime(v.year, v.month, v.day);
    try {
      final p = DateTime.parse(v.toString().substring(0, 10));
      return DateTime(p.year, p.month, p.day);
    } catch (_) {
      return null;
    }
  }

  static _PDocsOverview docsOverview(
      List<Map<String, dynamic>> rows, DateTime today,
      {int warnDays = defaultWarnDays}) {
    final td = DateTime(today.year, today.month, today.day);
    final out = <_PDoc>[];
    var expired = 0, expiring = 0, valid = 0, noDate = 0;
    for (final r in rows) {
      final exp = _asDate(r['expiry']);
      String status;
      int days;
      if (exp == null) {
        status = 'no_date';
        days = 0;
        noDate++;
      } else {
        days = exp.difference(td).inDays;
        if (days < 0) {
          status = 'expired';
          expired++;
        } else if (days <= warnDays) {
          status = 'expiring';
          expiring++;
        } else {
          status = 'valid';
          valid++;
        }
      }
      out.add(_PDoc(
        r,
        (r['kind'] ?? 'other').toString(),
        (r['label'] ?? '').toString(),
        days,
        status,
      ));
    }
    // most urgent first: expired, then soonest, then undated last (mirror sort)
    out.sort((a, b) {
      int rank(_PDoc d) {
        if (d.status == 'no_date') return 2;
        return d.daysLeft < 0 ? 0 : 1;
      }

      final ra = rank(a), rb = rank(b);
      if (ra != rb) return ra.compareTo(rb);
      if (a.status == 'no_date') return 0;
      return a.daysLeft.compareTo(b.daysLeft);
    });
    return _PDocsOverview(out, expired, expiring, valid, noDate);
  }
}

// ======================= INPUT SHEETS =======================
Future<Map<String, dynamic>?> _remitSheet(
    BuildContext context, Map<String, dynamic>? existing) async {
  final tr = AppLocalizations.of(context);
  final amountC = TextEditingController(
      text: existing == null ? '' : (existing['amount'] ?? '').toString());
  final rateC = TextEditingController(
      text: existing == null ? '' : (existing['rate'] ?? '').toString());
  DateTime date = _PMath._asDate(existing?['date']) ?? DateTime.now();
  String d(DateTime x) =>
      '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(existing == null ? tr.probashiLogSend : tr.probashiEditRemit,
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: amountC,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.probashiAmountSent,
                    helperText: tr.probashiAmountHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: rateC,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.probashiRate,
                    helperText: tr.probashiRateHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(tr.probashiDate),
                subtitle: Text(d(date)),
                trailing: TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setSheet(() => date = picked);
                  },
                  child: Text(tr.probashiPickDate),
                ),
              ),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (_PMath.toMinor(amountC.text) <= 0) {
                      ScaffoldMessenger.of(ctx)
                        ..clearSnackBars()
                        ..showSnackBar(SnackBar(
                            content: Text(tr.probashiAmountRequired)));
                      return;
                    }
                    if (_PMath.parseRate(rateC.text) <= 0) {
                      ScaffoldMessenger.of(ctx)
                        ..clearSnackBars()
                        ..showSnackBar(
                            SnackBar(content: Text(tr.probashiRateRequired)));
                      return;
                    }
                    Navigator.pop(ctx, {
                      'amount': amountC.text.trim(),
                      'rate': rateC.text.trim(),
                      'date': d(date),
                    });
                  },
                  child: Text(tr.save),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

Future<Map<String, dynamic>?> _docSheet(
    BuildContext context, Map<String, dynamic>? existing) async {
  final tr = AppLocalizations.of(context);
  String kind = (existing?['kind'] ?? 'passport').toString();
  if (!_docKinds.contains(kind)) kind = 'passport';
  final labelC = TextEditingController(
      text: (existing?['label'] ?? '').toString());
  final numberC = TextEditingController(
      text: (existing?['number'] ?? '').toString());
  DateTime? expiry = _PMath._asDate(existing?['expiry']);
  String d(DateTime x) =>
      '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(existing == null ? tr.probashiAddDoc : tr.probashiEditDoc,
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: InputDecoration(
                    labelText: tr.probashiDocKind,
                    border: const OutlineInputBorder()),
                items: [
                  for (final k in _docKinds)
                    DropdownMenuItem(
                        value: k, child: Text(_docKindLabel(tr, k))),
                ],
                onChanged: (v) => setSheet(() => kind = v ?? 'passport'),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: labelC,
                decoration: InputDecoration(
                    labelText: tr.probashiDocLabel,
                    helperText: tr.probashiDocLabelHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: numberC,
                decoration: InputDecoration(
                    labelText: tr.probashiDocNumber,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_busy),
                title: Text(tr.probashiExpiryDate),
                subtitle:
                    Text(expiry == null ? tr.probashiNoExpiry : d(expiry!)),
                trailing: TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: expiry ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setSheet(() => expiry = picked);
                  },
                  child: Text(tr.probashiPickDate),
                ),
              ),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, {
                    'kind': kind,
                    'label': labelC.text.trim(),
                    'number': numberC.text.trim(),
                    'expiry': expiry == null ? '' : d(expiry!),
                  }),
                  child: Text(tr.save),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

// Offset picker — common UTC offsets for Bangladeshi diaspora hubs.
Future<int?> _offsetSheet(BuildContext context, int current) async {
  final tr = AppLocalizations.of(context);
  // minutes offsets, ascending; labels are pure UTC strings (gate-exempt).
  const offsets = <int>[
    0, // UK/Portugal
    60, // Western Europe
    180, // Moscow/Gulf edge
    210, // Iran
    240, // Gulf (UAE/Oman/Qatar)
    300, // Pakistan edge
    330, // India
    360, // Bangladesh
    480, // Singapore/Malaysia
    540, // Japan/Korea
    600, // Sydney edge
    -300, // US East
    -480, // US West
    -240, // US East (DST)
  ];
  final sorted = [...offsets]..sort();
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(tr.probashiAbroadZone,
                style: Theme.of(ctx).textTheme.titleLarge),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final o in sorted)
                  RadioListTile<int>(
                    value: o,
                    groupValue: current,
                    title: Text(_PMath.fmtOffset(o)),
                    onChanged: (v) => Navigator.pop(ctx, v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Gap.sm),
        ]),
      );
    },
  );
}

Future<bool?> _confirm(BuildContext context, String title, String body) {
  final tr = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(tr.delete)),
      ],
    ),
  );
}
