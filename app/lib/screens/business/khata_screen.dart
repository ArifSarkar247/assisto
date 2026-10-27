import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

import '../../api.dart' show ApiException;
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show fmtDate, localDigits;
import '../../state.dart';
import '../../theme.dart';
import '../../business_khata_api.dart';
import '../../widgets/khata_free_promise.dart';
import '../../widgets/skeleton.dart';
import 'business_common.dart';
import 'tagada_schedule_sheet.dart';
import 'tagada_send_screen.dart';
import '../../services/action_feedback.dart'; // db1
import '../../services/error_report.dart'; // db1
import '../../services/error_kind.dart'
    show FailKind, failKindOf, honestFailText; // qa2
import '../../services/khata_offline.dart'; // ledger100

/// Digital Khata (plan §2): two-sided dues — customer receivables +
/// supplier payables. The supplier tab is hidden for staff (they must
/// not see cost). Party list shows a running balance; tap a party for the full
/// statement + add-entry / payment. A net-position header summarises both
/// books.
///
/// ledger100: works OFFLINE (saved copy + a local queue of entries that
/// syncs later, see services/khata_offline.dart), sends ONE separate tagada
/// per customer (tagada_send_screen.dart), schedules tagada
/// (tagada_schedule_sheet.dart), handles 500+ customers (lazy list +
/// search) and states the "free forever" promise (khata_free_promise.dart).
class KhataScreen extends StatefulWidget {
  final Map<String, dynamic> business;
  const KhataScreen({super.key, required this.business});
  @override
  State<KhataScreen> createState() => _KhataScreenState();
}

class _KhataScreenState extends State<KhataScreen> {
  int get _bizId => (widget.business['id'] as num?)?.toInt() ?? 0;
  bool get _isStaff => (widget.business['role'] ?? 'owner') == 'staff';

  // Owner sees two tabs; staff sees only the customer book.
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_isStaff) {
      return Scaffold(
        appBar: AppBar(title: Text(t.khataTitle)),
        body: _BookTab(
            businessId: _bizId,
            business: widget.business,
            book: 'customer',
            isStaff: true),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.khataTitle),
          bottom: TabBar(
              // large font: scroll instead of cutting "Customers (Dues)"
              isScrollable: MediaQuery.textScalerOf(context).scale(10) > 11.5,
              tabAlignment: MediaQuery.textScalerOf(context).scale(10) > 11.5
                  ? TabAlignment.start
                  : null,
              tabs: [
            Tab(child: Text(t.khataCustomers, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.khataSuppliers, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        body: TabBarView(children: [
          _BookTab(
              businessId: _bizId,
              business: widget.business,
              book: 'customer',
              isStaff: false),
          _BookTab(
              businessId: _bizId,
              business: widget.business,
              book: 'supplier',
              isStaff: false),
        ]),
      ),
    );
  }
}

String _d(BuildContext context, Object v) =>
    localDigits('$v', Localizations.localeOf(context).languageCode);

String _savedLabel(BuildContext context, DateTime at) {
  final lang = Localizations.localeOf(context).languageCode;
  return fmtDate('d MMM, h:mm a', at, lang);
}

/// One book (customer or supplier): net header + offline/sync banners +
/// search + lazily built party list + bulk tagada + add-party FAB.
class _BookTab extends StatefulWidget {
  final int businessId;
  final Map<String, dynamic> business;
  final String book;
  final bool isStaff;
  const _BookTab(
      {required this.businessId,
      required this.business,
      required this.book,
      required this.isStaff});
  @override
  State<_BookTab> createState() => _BookTabState();
}

class _BookTabState extends State<_BookTab> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _parties = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  DateTime? _savedAt; // ledger100: non-null = showing the saved copy (offline)
  List<KhataOp> _ops = [];
  List<Map<String, dynamic>> _awaiting = [];
  StreamSubscription<void>? _opsSub;
  bool _syncing = false;
  String _query = '';
  bool _selecting = false; // bulk-tagada selection mode
  final Set<int> _picked = {};

  bool get _isCustomer => widget.book == 'customer';
  String get _cacheKey => KhataOffline.partiesKey(widget.businessId, widget.book);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _opsSub = KhataOffline.changes.listen((_) => _refreshOps());
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _opsSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // back from WhatsApp / back online after a while: sync + refresh
    if (state == AppLifecycleState.resumed && mounted && !_loading) _load();
  }

  Future<void> _refreshOps() async {
    final ops = (await KhataOffline.forBusiness(widget.businessId))
        .where((o) => o.book == widget.book)
        .toList();
    if (mounted) setState(() => _ops = ops);
  }

  Future<void> _load({bool afterSync = false}) async {
    setState(() {
      _loading = _parties.isEmpty;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final r = await api
          .khataParties(widget.businessId, widget.book)
          .timeout(KhataOffline.requestTimeout);
      _parties = ((r['parties'] ?? []) as List).cast<Map<String, dynamic>>();
      _savedAt = null;
      unawaited(KhataOffline.cachePut(_cacheKey, {'parties': _parties}));
    } catch (e) {
      final saved = failKindOf(e) == FailKind.refused
          ? null
          : await KhataOffline.cacheGet(_cacheKey);
      if (saved != null) {
        _parties = ((saved.value['parties'] ?? []) as List)
            .cast<Map<String, dynamic>>();
        _savedAt = saved.saved;
      } else {
        _error = true;
        _failCause = e;
      }
    }
    await _refreshOps();
    if (mounted) setState(() => _loading = false);
    if (_savedAt == null && !_error) {
      if (_isCustomer && !widget.isStaff) unawaited(_loadAwaiting());
      if (!afterSync && _ops.any((o) => o.isPending)) {
        final res = await KhataOffline.sync(api);
        if (res.synced > 0 && mounted) await _load(afterSync: true);
      }
    }
  }

  Future<void> _loadAwaiting() async {
    try {
      final r = await context.read<AppState>().api.tagadaSchedules(widget.businessId);
      final a = ((r['awaiting'] ?? []) as List).cast<Map<String, dynamic>>();
      if (mounted) setState(() => _awaiting = a);
    } catch (e) {
      reportNonFatal('khata.awaiting', e); // best-effort: the banner stays hidden
    }
  }

  Future<void> _syncNow() async {
    final t = AppLocalizations.of(context);
    setState(() => _syncing = true);
    final res = await KhataOffline.sync(context.read<AppState>().api);
    if (!mounted) return;
    setState(() => _syncing = false);
    final msg = res.offline
        ? t.ldgStillOffline
        : (res.failed > 0
            ? t.ldgSyncFailed(_d(context, res.failed))
            : t.ldgSynced(_d(context, res.synced)));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _load(afterSync: true);
  }

  Future<void> _reviewFailed() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FailedOpsSheet(
          ops: _ops.where((o) => !o.isPending).toList()),
    );
    await _refreshOps();
  }

  Future<void> _addParty() async {
    final t = AppLocalizations.of(context);
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddPartySheet(
          businessId: widget.businessId, book: widget.book),
    );
    if (created == true) {
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.khataPartyAdded)));
      }
    }
  }

  Future<void> _openParty(Map<String, dynamic> party) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PartyStatementScreen(
        business: widget.business,
        party: party,
        book: widget.book,
      ),
    ));
    if (mounted) _load();
  }

  int _bal(Map<String, dynamic> p) =>
      (p['balance_poisha'] as num?)?.toInt() ??
      (p['balance'] as num?)?.toInt() ??
      0;

  Future<void> _bulkTagada() async {
    final t = AppLocalizations.of(context);
    if (_picked.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.ldgPickSome)));
      return;
    }
    final picked = _parties
        .where((p) => _picked.contains((p['id'] as num?)?.toInt()))
        .toList();
    await _sendTo(picked);
    if (mounted) {
      setState(() {
        _selecting = false;
        _picked.clear();
      });
    }
  }

  Future<void> _sendTo(List<Map<String, dynamic>> parties,
      {Map<int, int> schedules = const {}}) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TagadaSendScreen(
            business: widget.business,
            parties: parties,
            scheduleByParty: schedules)));
    if (mounted) _load();
  }

  Future<void> _sendAwaiting() async {
    final byId = {for (final p in _parties) (p['id'] as num?)?.toInt(): p};
    final parties = <Map<String, dynamic>>[];
    final sched = <int, int>{};
    for (final a in _awaiting) {
      final pid = (a['party_id'] as num?)?.toInt();
      final p = byId[pid];
      if (pid == null || p == null) continue;
      parties.add(p);
      sched[pid] = (a['id'] as num).toInt();
    }
    if (parties.isNotEmpty) await _sendTo(parties, schedules: sched);
  }

  List<Map<String, dynamic>> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _parties;
    final digits = q.replaceAll(RegExp(r'\D'), '');
    return _parties.where((p) {
      final name = '${p['name'] ?? ''}'.toLowerCase();
      final phone = '${p['phone'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
      return name.contains(q) || (digits.isNotEmpty && phone.contains(digits));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const SkeletonList();
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.khataTitle,
        message: honestFailText(t, _failCause, otherwise: t.businessLoadFailed),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    final pendingByParty = <int, List<KhataOp>>{};
    for (final o in _ops) {
      pendingByParty.putIfAbsent(o.partyId, () => []).add(o);
    }
    final pending = _ops.where((o) => o.isPending).length;
    final failed = _ops.length - pending;
    final visible = _visible;
    final dueIds = [
      for (final p in _parties)
        if (_bal(p) > 0) (p['id'] as num).toInt()
    ];
    return Scaffold(
      floatingActionButton: _selecting
          ? FloatingActionButton.extended(
              key: const ValueKey('ldg-bulk-send'),
              onPressed: _bulkTagada,
              icon: const Icon(Icons.campaign_rounded),
              label: Text(t.ldgSendToN(_d(context, _picked.length))),
            )
          : FloatingActionButton(
              tooltip: _isCustomer ? t.khataAddCustomer : t.khataAddSupplier,
              onPressed: _savedAt != null
                  ? () => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t.ldgAddPartyOnline)))
                  : _addParty,
              child: const Icon(Icons.person_add_alt_1_rounded)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
              sliver: SliverList.list(children: [
                if (_savedAt != null) ...[
                  _Banner(
                    icon: Icons.cloud_off_rounded,
                    text: t.ldgSavedCopy(_savedLabel(context, _savedAt!)),
                    action: TextButton(onPressed: _load, child: Text(t.retry)),
                  ),
                  const SizedBox(height: Gap.sm),
                ],
                if (pending > 0) ...[
                  _Banner(
                    key: const ValueKey('ldg-pending-banner'),
                    icon: Icons.cloud_upload_outlined,
                    text: t.ldgPendingSync(_d(context, pending)),
                    action: _syncing
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : TextButton(onPressed: _syncNow, child: Text(t.ldgSyncNow)),
                  ),
                  const SizedBox(height: Gap.sm),
                ],
                if (failed > 0) ...[
                  _Banner(
                    icon: Icons.error_outline_rounded,
                    error: true,
                    text: t.ldgSyncFailed(_d(context, failed)),
                    action: TextButton(onPressed: _reviewFailed, child: Text(t.ldgReview)),
                  ),
                  const SizedBox(height: Gap.sm),
                ],
                if (_awaiting.isNotEmpty) ...[
                  _Banner(
                    key: const ValueKey('ldg-awaiting'),
                    icon: Icons.alarm_rounded,
                    text: t.ldgAwaitingTitle(_d(context, _awaiting.length)),
                    action: FilledButton.tonal(
                        onPressed: _sendAwaiting, child: Text(t.ldgAwaitingSend)),
                  ),
                  const SizedBox(height: Gap.sm),
                ],
                if (_parties.isNotEmpty) ...[
                  _NetHeader(
                      businessId: widget.businessId,
                      isCustomer: _isCustomer,
                      isStaff: widget.isStaff,
                      offline: _savedAt != null,
                      fallbackPoisha: _parties
                          .map(_bal)
                          .where((b) => b > 0)
                          .fold<int>(0, (a, b) => a + b)),
                  const SizedBox(height: Gap.md),
                  // Wrap: on a large font the "remind everyone" button moves
                  // to its own line instead of squeezing the title.
                  Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${_isCustomer ? t.khataCustomers : t.khataSuppliers} (${_d(context, _parties.length)})',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_isCustomer)
                          TextButton.icon(
                            key: const ValueKey('ldg-bulk-toggle'),
                            icon: Icon(
                                _selecting ? Icons.close_rounded : Icons.campaign_rounded,
                                size: 18),
                            label: Text(_selecting ? t.cancel : t.tagadaSendAll),
                            onPressed: () => setState(() {
                              _selecting = !_selecting;
                              _picked.clear();
                            }),
                          ),
                      ]),
                  if (_selecting && dueIds.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: ActionChip(
                        key: const ValueKey('ldg-select-due'),
                        avatar: const Icon(Icons.done_all_rounded, size: 18),
                        label: Text(t.ldgSelectDue),
                        onPressed: () => setState(() {
                          _picked
                            ..clear()
                            ..addAll(dueIds);
                        }),
                      ),
                    ),
                  if (_parties.length > 8) ...[
                    const SizedBox(height: Gap.sm),
                    TextField(
                      key: const ValueKey('ldg-search'),
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: t.ldgSearchHint,
                        prefixIcon: const Icon(Icons.search_rounded),
                      ),
                    ),
                  ],
                  const SizedBox(height: Gap.sm),
                ],
              ]),
            ),
            if (_parties.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: StateMessage(
                  icon: _isCustomer
                      ? Icons.people_outline_rounded
                      : Icons.local_shipping_rounded,
                  title: _isCustomer ? t.khataNoCustomers : t.khataNoSuppliers,
                  message: t.khataAddPartyHint,
                  action: FilledButton.icon(
                    onPressed: _addParty,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(_isCustomer ? t.khataAddCustomer : t.khataAddSupplier),
                  ),
                ),
              )
            else if (visible.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Center(child: Text(t.ldgNoMatch)),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                // ledger100: lazily built — 500 customers stay smooth
                sliver: SliverList.builder(
                  itemCount: visible.length,
                  itemBuilder: (_, i) {
                    final p = visible[i];
                    final id = (p['id'] as num?)?.toInt();
                    return _PartyTile(
                      party: p,
                      book: widget.book,
                      ops: pendingByParty[id] ?? const [],
                      selecting: _selecting && _isCustomer,
                      picked: _picked.contains(id),
                      onTogglePick: () {
                        if (id == null) return;
                        setState(() {
                          if (!_picked.remove(id)) _picked.add(id);
                        });
                      },
                      onTap: () => _openParty(p),
                    );
                  },
                ),
              ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 96),
              sliver: SliverToBoxAdapter(child: KhataFreePromise()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  final bool error;
  const _Banner(
      {super.key,
      required this.icon,
      required this.text,
      this.action,
      this.error = false});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = error ? scheme.errorContainer : scheme.secondaryContainer;
    final fg = error ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.md)),
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600))),
          if (action != null) ...[
            const SizedBox(width: Gap.xs),
            // a11y: the banner's own ink colour (primary on the container
            // failed 4.5:1 in dark)
            TextButtonTheme(
              data: TextButtonThemeData(
                  style: TextButton.styleFrom(foregroundColor: fg)),
              child: action!,
            ),
          ],
        ],
      ),
    );
  }
}

/// Failed / conflicting queued entries: the server's reason + discard.
class _FailedOpsSheet extends StatefulWidget {
  final List<KhataOp> ops;
  const _FailedOpsSheet({required this.ops});
  @override
  State<_FailedOpsSheet> createState() => _FailedOpsSheetState();
}

class _FailedOpsSheetState extends State<_FailedOpsSheet> {
  late List<KhataOp> _ops = widget.ops;
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.ldgFailedTitle, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.sm),
              if (_ops.isEmpty) Text(t.ldgAllDone),
              for (final o in _ops)
                _OpTile(
                  op: o,
                  onDiscard: () async {
                    await KhataOffline.discard(o.cid);
                    if (mounted) {
                      setState(() => _ops = _ops.where((x) => x.cid != o.cid).toList());
                    }
                  },
                ),
            ]),
      ),
    );
  }
}

/// One queued entry: what it is, its state chip, and (when it failed) the
/// server's reason + discard.
class _OpTile extends StatelessWidget {
  final KhataOp op;
  final VoidCallback? onDiscard;
  const _OpTile({required this.op, this.onDiscard});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final what = op.kind == 'edit'
        ? t.ldgEditEntry
        : (op.kind == 'payment'
            ? (op.book == 'customer' ? t.entryReceivePayment : t.entryMakePayment)
            : t.entryAddCredit);
    final chip = op.isPending
        ? t.ldgPendingChip
        : (op.state == 'conflict' ? t.ldgConflict : t.ldgStatusFailed);
    final chipColor = op.isPending ? scheme.tertiary : scheme.error;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.schedule_rounded, size: 18, color: chipColor),
                Text(chip,
                    style: TextStyle(color: chipColor, fontWeight: FontWeight.w700)),
                Text('· ${op.partyName} · $what'),
                Text(pair(context, poishaToTaka(op.amountPoisha)),
                    style: TextStyle(
                        fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
              ]),
          if (op.note.isNotEmpty)
            Text(op.note, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          if (!op.isPending && op.error.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(op.error, style: AType.bodySmall.copyWith(color: scheme.error)),
          ],
          if (!op.isPending && onDiscard != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(t.ldgDiscard),
                onPressed: onDiscard,
              ),
            ),
        ]),
      ),
    );
  }
}

/// Net-position summary strip for the active book.
class _NetHeader extends StatefulWidget {
  final int businessId;
  final bool isCustomer;
  final bool isStaff;
  final bool offline;
  final int fallbackPoisha;
  const _NetHeader(
      {required this.businessId,
      required this.isCustomer,
      required this.isStaff,
      this.offline = false,
      this.fallbackPoisha = 0});
  @override
  State<_NetHeader> createState() => _NetHeaderState();
}

class _NetHeaderState extends State<_NetHeader> {
  Map<String, dynamic>? _np;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.offline) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      _np = await context
          .read<AppState>()
          .api
          .khataNetPosition(widget.businessId)
          .timeout(KhataOffline.requestTimeout);
    } catch (e) {
      // db1: automatic load (not a tap). On failure the card shows the sum
      // of the list it sits on (same rows) — never a made-up figure.
      reportNonFatal('khata.netPosition', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return const Card(
          child: Padding(
              padding: EdgeInsets.all(Gap.lg),
              child: Skeleton(width: 160, height: 16)));
    }
    final np = _np ?? const {};
    final label = widget.isCustomer ? t.netReceivable : t.netPayable;
    final fallback = pair(context, poishaToTaka(widget.fallbackPoisha));
    final value = widget.isCustomer
        ? pair(context, np['receivable_display'], fallback: fallback)
        : pair(context, np['payable_display'], fallback: fallback);
    final color = widget.isCustomer ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.error;
    return BrandBand(
      padding: const EdgeInsets.all(Gap.lg),
      child: Row(children: [
        Icon(widget.isCustomer
            ? Icons.call_received_rounded
            : Icons.call_made_rounded),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AType.bodyMedium),
            const SizedBox(height: Gap.xxs),
            Text(value,
                style: AType.headlineSmall.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
          ]),
        ),
        Icon(Icons.circle_rounded, size: 10, color: color.withValues(alpha: 0.9)),
      ]),
    );
  }
}

String _initial(String name) =>
    name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();

class _PartyTile extends StatelessWidget {
  final Map<String, dynamic> party;
  final String book;
  final List<KhataOp> ops;
  final bool selecting;
  final bool picked;
  final VoidCallback onTogglePick;
  final VoidCallback onTap;
  const _PartyTile({
    required this.party,
    required this.book,
    required this.ops,
    required this.selecting,
    required this.picked,
    required this.onTogglePick,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final vip = party['vip'] == true;
    final balanceDisplay = pair(context, party['balance_display'] ?? party['balance_fmt']);
    final balanceStatus = pair(context, party['balance_status'] ?? party['status']);
    final poisha = (party['balance_poisha'] as num?)?.toInt() ??
        (party['balance'] as num?)?.toInt() ??
        0;
    final pending = ops.where((o) => o.isPending).toList();
    final delta = pending.fold<int>(0, (a, o) => a + o.signedDelta);
    final hasFailed = ops.any((o) => !o.isPending);
    // Owner-POV colouring: positive receivable/payable -> brand tint; settled
    // -> neutral. We colour purely by sign for a quick read.
    final color = poisha == 0
        ? scheme.onSurfaceVariant
        : (book == 'customer' ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.error);
    final sub = <Widget>[
      if (balanceStatus.isNotEmpty) Text(balanceStatus),
      if (pending.isNotEmpty)
        Text(
            delta == 0
                ? t.ldgPendingChip
                : '${t.ldgPendingChip} · ${t.ldgPendingEstimate(pair(context, poishaToTaka(poisha + delta)))}',
            style: TextStyle(color: scheme.tertiary, fontWeight: FontWeight.w600)),
      if (hasFailed)
        Text(t.ldgSyncFailed(_d(context, ops.length - pending.length)),
            style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: ListTile(
        onTap: selecting ? onTogglePick : onTap,
        leading: selecting
            ? Checkbox(value: picked, onChanged: (_) => onTogglePick())
            : CircleAvatar(
                backgroundColor: scheme.secondaryContainer,
                child: Text(
                  _initial((party['name'] ?? '').toString()),
                  style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700),
                ),
              ),
        title: Row(children: [
          Flexible(
            child: Text((party['name'] ?? '').toString(),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (vip) ...[
            const SizedBox(width: Gap.xs),
            Icon(Icons.star_rounded, size: 14, color: AssistoTokens.of(context).warning),
          ],
        ]),
        subtitle: sub.isEmpty
            ? null
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: sub),
        trailing: Text(balanceDisplay,
            style: TextStyle(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700, color: color)),
      ),
    );
  }
}

// ========================= add party sheet ===============================

class _AddPartySheet extends StatefulWidget {
  final int businessId;
  final String book;
  const _AddPartySheet({required this.businessId, required this.book});
  @override
  State<_AddPartySheet> createState() => _AddPartySheetState();
}

class _AddPartySheetState extends State<_AddPartySheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _area = TextEditingController();
  bool _vip = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _area.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.khataCreateParty(
            businessId: widget.businessId,
            book: widget.book,
            name: name,
            phone: _phone.text.trim(),
            area: _area.text.trim(),
            vip: _vip,
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showActionFailed(context, 'khata.addParty', e); // ledger100: was silent
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final isCustomer = widget.book == 'customer';
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(isCustomer ? t.khataAddCustomer : t.khataAddSupplier,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.lg),
        TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: t.name, prefixIcon: const Icon(Icons.person_outline_rounded))),
        const SizedBox(height: Gap.md),
        TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
                labelText: t.phone, prefixIcon: const Icon(Icons.call_rounded))),
        const SizedBox(height: Gap.md),
        TextField(
            controller: _area,
            decoration: InputDecoration(
                labelText: t.khataPartyArea,
                prefixIcon: const Icon(Icons.location_on_rounded))),
        const SizedBox(height: Gap.sm),
        if (isCustomer)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _vip,
            title: Text(t.khataPartyVip),
            onChanged: (v) => setState(() => _vip = v),
          ),
        const SizedBox(height: Gap.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(t.save),
          ),
        ),
      ]),
    );
  }
}

// ===================== party statement screen ============================

class _PartyStatementScreen extends StatefulWidget {
  final Map<String, dynamic> business;
  final Map<String, dynamic> party;
  final String book;
  const _PartyStatementScreen(
      {required this.business, required this.party, required this.book});
  @override
  State<_PartyStatementScreen> createState() => _PartyStatementScreenState();
}

class _PartyStatementScreenState extends State<_PartyStatementScreen> {
  Map<String, dynamic>? _stmt;
  bool _loading = true;
  Object? _fail;
  DateTime? _savedAt;
  List<KhataOp> _ops = [];
  StreamSubscription<void>? _opsSub;

  int get _partyId => (widget.party['id'] as num?)?.toInt() ?? 0;
  bool get _isCustomer => widget.book == 'customer';
  bool get _isOwner => (widget.business['role'] ?? 'owner') != 'staff';

  @override
  void initState() {
    super.initState();
    _opsSub = KhataOffline.changes.listen((_) => _refreshOps());
    _load();
  }

  @override
  void dispose() {
    _opsSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshOps() async {
    final ops = await KhataOffline.forParty(_partyId);
    if (mounted) setState(() => _ops = ops);
  }

  Future<void> _load({bool afterSync = false}) async {
    setState(() {
      _loading = _stmt == null;
      _fail = null;
    });
    final api = context.read<AppState>().api;
    try {
      _stmt = await api.khataStatement(_partyId).timeout(KhataOffline.requestTimeout);
      _savedAt = null;
      unawaited(KhataOffline.cachePut(KhataOffline.statementKey(_partyId), _stmt!));
    } catch (e) {
      final saved = failKindOf(e) == FailKind.refused
          ? null
          : await KhataOffline.cacheGet(KhataOffline.statementKey(_partyId));
      if (saved != null) {
        _stmt = saved.value;
        _savedAt = saved.saved;
      } else if (_stmt == null) {
        _fail = e;
      }
    }
    await _refreshOps();
    if (mounted) setState(() => _loading = false);
    if (_savedAt == null && !afterSync && _ops.any((o) => o.isPending)) {
      final r = await KhataOffline.sync(api);
      if (r.synced > 0 && mounted) await _load(afterSync: true);
    }
  }

  Map<String, dynamic> get _partyNow {
    final p = Map<String, dynamic>.from(widget.party);
    final s = _stmt;
    if (s != null && s['balance_poisha'] != null) {
      p['balance_poisha'] = s['balance_poisha'];
      p['balance_display'] = s['balance_display'];
      p['balance_status'] = s['balance_status'];
    }
    return p;
  }

  Future<void> _openSheet(_EntrySheet sheet) async {
    final t = AppLocalizations.of(context);
    final res = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => sheet,
    );
    if (!mounted || res == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res == 'offline'
            ? t.ldgSavedOffline
            : (res == 'edited' ? t.ldgEdited : t.ldgSaved))));
    await _load();
  }

  Future<void> _addEntry({required bool isDue}) => _openSheet(_EntrySheet(
        business: widget.business,
        partyId: _partyId,
        partyName: '${widget.party['name'] ?? ''}',
        book: widget.book,
        isDue: isDue,
      ));

  Future<void> _editLine(Map<String, dynamic> line) async {
    final t = AppLocalizations.of(context);
    if (!_isOwner) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.ldgEditOwnerOnly)));
      return;
    }
    if (line['editable'] == false) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.ldgEditLinked)));
      return;
    }
    final eid = (line['entry_id'] as num?)?.toInt();
    if (eid == null) return;
    await _openSheet(_EntrySheet(
      business: widget.business,
      partyId: _partyId,
      partyName: '${widget.party['name'] ?? ''}',
      book: widget.book,
      isDue: (line['debit_display'] is Map) &&
          '${(line['debit_display'] as Map)['en'] ?? ''}'.isNotEmpty,
      edit: line,
    ));
  }

  Future<void> _tagada() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TagadaSendScreen(
            business: widget.business, parties: [_partyNow])));
    if (mounted) _load();
  }

  Future<void> _schedule() async {
    await showTagadaScheduleSheet(context,
        business: widget.business, party: _partyNow);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = (widget.party['name'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_isCustomer)
            IconButton(
              tooltip: t.tagadaSendReminder,
              icon: const Icon(Icons.campaign_rounded),
              onPressed: _tagada,
            ),
          if (_isCustomer && _isOwner)
            IconButton(
              key: const ValueKey('ldg-schedule'),
              tooltip: t.ldgSchedAction,
              icon: const Icon(Icons.alarm_add_rounded),
              onPressed: _schedule,
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: Text(t.entryAddCredit,
                    maxLines: 2, textAlign: TextAlign.center),
                onPressed: () => _addEntry(isDue: true),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.payments_rounded),
                label: Text(
                    _isCustomer ? t.entryReceivePayment : t.entryMakePayment,
                    maxLines: 2,
                    textAlign: TextAlign.center),
                onPressed: () => _addEntry(isDue: false),
              ),
            ),
          ]),
        ),
      ),
      body: _loading
          ? const SkeletonList()
          : (_fail != null
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: name,
                  message: honestFailText(t, _fail, otherwise: t.businessLoadFailed),
                  action: FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _StatementBody(
                      stmt: _stmt ?? const {},
                      party: _partyNow,
                      book: widget.book,
                      ops: _ops,
                      savedAt: _savedAt,
                      onTapLine: _editLine,
                      onDiscard: (o) => KhataOffline.discard(o.cid)),
                )),
    );
  }
}

class _StatementBody extends StatelessWidget {
  final Map<String, dynamic> stmt;
  final Map<String, dynamic> party;
  final String book;
  final List<KhataOp> ops;
  final DateTime? savedAt;
  final void Function(Map<String, dynamic>) onTapLine;
  final void Function(KhataOp) onDiscard;
  const _StatementBody(
      {required this.stmt,
      required this.party,
      required this.book,
      required this.ops,
      required this.savedAt,
      required this.onTapLine,
      required this.onDiscard});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lines = ((stmt['lines'] ?? []) as List).cast<Map<String, dynamic>>();
    final balanceDisplay = pair(context, party['balance_display']);
    final balanceStatus = pair(context, party['balance_status']);
    final bal = (party['balance_poisha'] as num?)?.toInt() ?? 0;
    final delta = ops
        .where((o) => o.isPending)
        .fold<int>(0, (a, o) => a + o.signedDelta);
    final phone = (party['phone'] ?? '').toString();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xl),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: lines.length + 1,
      itemBuilder: (context, i) {
        if (i > 0) return _StatementRow(line: lines[i - 1], onTap: onTapLine);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (savedAt != null) ...[
            _Banner(
                icon: Icons.cloud_off_rounded,
                text: t.ldgSavedCopy(_savedLabel(context, savedAt!))),
            const SizedBox(height: Gap.sm),
          ],
          BrandBand(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(balanceStatus.isEmpty ? t.khataDueLabel : balanceStatus,
                  style: AType.bodyMedium),
              const SizedBox(height: Gap.xxs),
              Text(balanceDisplay,
                  style: AType.headlineMedium.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
              if (delta != 0) ...[
                const SizedBox(height: Gap.xxs),
                Text(t.ldgPendingEstimate(pair(context, poishaToTaka(bal + delta))),
                    style: AType.bodySmall),
              ],
            ]),
          ),
          const SizedBox(height: Gap.lg),
          if (phone.isNotEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.call_rounded),
                title: Text(phone),
                trailing: Icon(Icons.call_rounded, color: AssistoTokens.of(context).success),
                onTap: () => openForUser(context, Uri.parse('tel:$phone'),
                    where: 'khata.call'),
              ),
            ),
          if (ops.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            for (final o in ops)
              _OpTile(op: o, onDiscard: o.isPending ? null : () => onDiscard(o)),
          ],
          const SizedBox(height: Gap.lg),
          Row(children: [
            const Icon(Icons.history_rounded, size: 18),
            const SizedBox(width: Gap.sm),
            Text(t.stmtParticulars,
                style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: Gap.sm),
          if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Center(
                  child: Text(t.khataNoDues,
                      style: TextStyle(color: scheme.onSurfaceVariant))),
            ),
        ]);
      },
    );
  }
}

class _StatementRow extends StatelessWidget {
  final Map<String, dynamic> line;
  final void Function(Map<String, dynamic>) onTap;
  const _StatementRow({required this.line, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final debit = pair(context, line['debit_display']);
    final credit = pair(context, line['credit_display']);
    final isDebit = debit.isNotEmpty && debit != '৳0';
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => onTap(line),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Icon(isDebit ? Icons.north_east_rounded : Icons.south_west_rounded,
                size: 18, color: isDebit ? Theme.of(context).colorScheme.error : AssistoTokens.of(context).success),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        pair(context, line['particulars'],
                            fallback: isDebit ? t.stmtDebit : t.stmtCredit),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: Gap.xxs),
                    Text(pair(context, line['at_display'],
                        fallback: (line['at'] ?? '').toString()),
                        style: AType.bodySmall.copyWith(fontFeatures: AFonts.tabular, color: scheme.onSurfaceVariant)),
                  ]),
            ),
            const SizedBox(width: Gap.sm),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(isDebit ? debit : credit,
                  style: TextStyle(fontFeatures: AFonts.tabular,
                      fontWeight: FontWeight.w700,
                      color: isDebit ? Theme.of(context).colorScheme.error : AssistoTokens.of(context).success)),
              Text(pair(context, line['balance_display']),
                  style:
                      AType.bodySmall.copyWith(fontFeatures: AFonts.tabular, color: scheme.onSurfaceVariant)),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ========================= add / edit entry sheet ========================

class _EntrySheet extends StatefulWidget {
  final Map<String, dynamic> business;
  final int partyId;
  final String partyName;
  final String book;
  final bool isDue; // true -> add due/credit; false -> payment
  final Map<String, dynamic>? edit; // a statement line to change
  const _EntrySheet(
      {required this.business,
      required this.partyId,
      required this.book,
      required this.isDue,
      this.partyName = '',
      this.edit});
  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  DateTime _at = DateTime.now();
  bool _notifyCustomer = false;
  bool _saving = false;
  String? _error;

  bool get _isCustomer => widget.book == 'customer';
  bool get _isEdit => widget.edit != null;

  // Owner-POV direction mapping:
  //  customer + due      -> 'gave' (I gave goods on credit)
  //  customer + payment  -> 'got'  (I received payment)
  //  supplier + due      -> 'got'  (I received goods on credit)
  //  supplier + payment  -> 'gave' (I paid the supplier)
  String get _direction {
    if (_isCustomer) return widget.isDue ? 'gave' : 'got';
    return widget.isDue ? 'got' : 'gave';
  }

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    if (e != null) {
      final a = (e['amount'] as num?)?.toInt() ?? 0;
      _amount.text = poishaToTaka(a).replaceAll('৳', '');
      _note.text = '${e['note'] ?? ''}';
      _at = DateTime.tryParse('${e['at'] ?? ''}')?.toLocal() ?? _at;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final poisha = takaToPoisha(_amount.text);
    if (poisha == null || poisha <= 0) {
      showNeedInput(context); // db1: was a dead tap
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final bizId = (widget.business['id'] as num?)?.toInt() ?? 0;
    final op = KhataOp(
      cid: KhataOffline.newClientId(),
      bizId: bizId,
      partyId: widget.partyId,
      partyName: widget.partyName,
      book: widget.book,
      kind: _isEdit ? 'edit' : (widget.isDue ? 'entry' : 'payment'),
      direction: _direction,
      amountPoisha: poisha,
      note: _note.text.trim(),
      atIso: _at.toIso8601String(),
      entryId: (widget.edit?['entry_id'] as num?)?.toInt(),
      baseVersion: (widget.edit?['version'] as num?)?.toInt(),
      createdAt: DateTime.now(),
    );
    final api = context.read<AppState>().api;
    try {
      final r = await KhataOffline.sendNow(api, op,
          notifyCustomer: !_isEdit && widget.isDue && _isCustomer && _notifyCustomer);
      if (!mounted) return;
      // If the server returned an "entry added" message to notify the
      // customer, offer to share it (the owner's own tap sends it).
      final msg = r['entry_added_message'];
      if (msg != null) {
        final text = pair(context, msg);
        if (text.isNotEmpty) {
          try {
            await Share.share(text);
          } catch (e) {
            reportNonFatal('khata.entryShare', e); // best-effort: entry is saved
          }
        }
      }
      if (mounted) Navigator.pop(context, _isEdit ? 'edited' : 'saved');
    } catch (e) {
      if (!mounted) return;
      if (failKindOf(e) == FailKind.refused) {
        // validation / access / conflict: say the server's sentence, keep
        // the sheet open so the owner can fix it (nothing was booked)
        setState(() {
          _saving = false;
          _error = e is ApiException ? e.message : t(context).actionFailedRetry;
        });
        return;
      }
      // no internet / our server down: keep it on the phone, sync later
      try {
        await KhataOffline.enqueue(op);
      } catch (e2) {
        if (!mounted) return;
        setState(() => _saving = false);
        showActionFailed(context, 'khata.enqueue', e2);
        return;
      }
      if (mounted) Navigator.pop(context, 'offline');
    }
  }

  static AppLocalizations t(BuildContext c) => AppLocalizations.of(c);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final title = _isEdit
        ? t.ldgEditEntry
        : (widget.isDue
            ? t.entryAddCredit
            : (_isCustomer ? t.entryReceivePayment : t.entryMakePayment));
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.lg),
          TextField(
            key: const ValueKey('ldg-entry-amount'),
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: t.entryAmount, prefixText: '৳ '),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _note,
            decoration: InputDecoration(
                labelText: t.entryNote,
                prefixIcon: const Icon(Icons.notes_rounded)),
          ),
          const SizedBox(height: Gap.sm),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_rounded),
            title: Text(t.entryDate),
            // qa1: localized date (was ISO "2026-10-22" in both languages)
            trailing: Text(localDigits(
                DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
                    .format(_at),
                Localizations.localeOf(context).languageCode)),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _at,
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 1)),
              );
              if (picked != null) {
                final n = DateTime.now();
                setState(() => _at = DateTime(picked.year, picked.month,
                    picked.day, n.hour, n.minute));
              }
            },
          ),
          if (!_isEdit && widget.isDue && _isCustomer)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _notifyCustomer,
              title: Text(t.tagadaNotifyCustomerOnDue),
              onChanged: (v) => setState(() => _notifyCustomer = v),
            ),
          if (_error != null) ...[
            const SizedBox(height: Gap.sm),
            Semantics(
              liveRegion: true,
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ],
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('ldg-entry-save'),
              onPressed: _saving ? null : _save,
              child: Text(t.save),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Gallery/preview access to the private entry sheet (screenshot harness).
@visibleForTesting
Widget khataEntrySheetPreview(Map<String, dynamic> business,
        {int partyId = 1, String book = 'customer', bool isDue = true}) =>
    _EntrySheet(business: business, partyId: partyId, book: book, isDue: isDue);

/// ledger100: gallery/preview access to the private statement screen.
@visibleForTesting
Widget khataStatementPreview(Map<String, dynamic> business,
        Map<String, dynamic> party) =>
    _PartyStatementScreen(business: business, party: party, book: 'customer');
