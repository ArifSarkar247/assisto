import 'dart:async';

import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../business_khata_api.dart';
import '../../widgets/skeleton.dart';
import 'business_common.dart';
import '../../services/error_kind.dart' show FailKind, failKindOf, honestFailText; // qa2
import '../../services/cashbox_offline.dart'; // proof-ledger
import '../../services/khata_offline.dart' show KhataOffline; // proof-ledger: saved copy
import '../../widgets/app_sheet.dart';
import 'package:share_plus/share_plus.dart';
import '../../messaging/date_separators.dart' show fmtDate, localDigits;
import '../../services/action_feedback.dart' show showActionFailed, showNeedInput;

/// Cashbox (plan §2): one business day's drawer — opening cash, cash in/out
/// entries, and end-of-day reconciliation (expected vs counted + variance).
/// Allowed for staff (no cost/profit exposure). Defaults to today; the owner
/// can step to earlier days.
///
/// bizbar: rebuilt on the server's real contract (khata.cashbox_close_view) —
/// the old screen read keys the server never sent and always showed ৳0. The
/// day's POS cash sales, khata dues collected, supplier payments and expenses
/// now arrive as read-only lines; the opening carries yesterday's counted
/// cash; a failed tap says so (it used to vanish silently); the close can be
/// re-counted and shared.
class CashboxScreen extends StatefulWidget {
  final Map<String, dynamic> business;
  const CashboxScreen({super.key, required this.business});
  @override
  State<CashboxScreen> createState() => _CashboxScreenState();
}

class _CashboxScreenState extends State<CashboxScreen> with WidgetsBindingObserver {
  int get _bizId => (widget.business['id'] as num?)?.toInt() ?? 0;
  DateTime _day = DateTime.now();
  Map<String, dynamic>? _summary;
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  // proof-ledger: offline. Rows typed with no internet wait here (on the
  // phone, they survive the app being killed) and the day opens from the
  // last saved copy — before, the screen was a dead "check your internet"
  // and a cash sale typed offline was not written anywhere.
  List<CashboxOp> _ops = const [];
  DateTime? _savedAt; // showing the saved copy from this time
  bool _offline = false; // no answer from our server this load
  bool _syncing = false;
  StreamSubscription<void>? _opsSub;

  String get _cacheKey => 'cashbox:$_bizId:$_dayKey';

  String get _dayKey =>
      '${_day.year}-${_day.month.toString().padLeft(2, '0')}-${_day.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _opsSub = CashboxOffline.changes.listen((_) => _refreshOps());
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
    // back from another app / back online after a while: sync + refresh
    if (state == AppLifecycleState.resumed && mounted && !_loading) _load();
  }

  Future<void> _refreshOps() async {
    final ops = await CashboxOffline.forDay(_bizId, _dayKey);
    if (mounted) setState(() => _ops = ops);
  }

  Future<void> _load({bool afterSync = false}) async {
    setState(() {
      _loading = _summary == null;
      _error = false;
    });
    final api = context.read<AppState>().api;
    final key = _cacheKey;
    try {
      _summary = await api.cashboxDay(_bizId, _dayKey).timeout(CashboxOffline.requestTimeout);
      _savedAt = null;
      _offline = false;
      unawaited(KhataOffline.cachePut(key, _summary!));
    } catch (e) {
      _failCause = e;
      if (failKindOf(e) == FailKind.refused) {
        _error = true;
      } else {
        // no internet / our server down: the saved copy, or an empty day —
        // cash in / out still work and wait on the phone
        final saved = await KhataOffline.cacheGet(key);
        _summary = saved?.value ?? const <String, dynamic>{};
        _savedAt = saved?.saved;
        _offline = true;
      }
    }
    await _refreshOps();
    if (mounted) setState(() => _loading = false);
    if (!_offline && !_error && !afterSync && _ops.any((o) => o.isPending)) {
      final r = await CashboxOffline.sync(api);
      if (r.synced > 0 && mounted) await _load(afterSync: true);
    }
  }

  Future<void> _syncNow() async {
    final t = AppLocalizations.of(context);
    setState(() => _syncing = true);
    final r = await CashboxOffline.sync(context.read<AppState>().api);
    if (!mounted) return;
    setState(() => _syncing = false);
    final msg = r.offline
        ? t.ldgStillOffline
        : (r.failed > 0
            ? t.ldgSyncFailed(localDigits('${r.failed}', Localizations.localeOf(context).languageCode))
            : t.ldgSynced(localDigits('${r.synced}', Localizations.localeOf(context).languageCode)));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _load(afterSync: true);
  }

  void _stepDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateTime.now())) return;
    setState(() {
      _day = next;
      _summary = null; // proof-ledger: never show the other day's numbers
      _ops = const [];
    });
    _load();
  }

  Future<void> _setOpening() async {
    final t = AppLocalizations.of(context);
    final poisha = await _amountDialog(context, t.cashboxOpening);
    if (poisha == null) return;
    try {
      _summary = await context
          .read<AppState>()
          .api
          .cashboxSetOpening(businessId: _bizId, day: _dayKey, openingPoisha: poisha);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showActionFailed(context, 'cashbox.opening', e);
    }
  }

  Future<void> _addEntry(String kind) async {
    final t = AppLocalizations.of(context);
    final res = await showAppSheet<(int, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CashEntrySheet(
          title: kind == 'in' ? t.cashboxCashIn : t.cashboxCashOut),
    );
    if (res == null || !mounted) return;
    final op = CashboxOp(
      cid: CashboxOffline.newClientId(),
      bizId: _bizId,
      day: _dayKey,
      kind: kind,
      amountPoisha: res.$1,
      note: res.$2,
      createdAt: DateTime.now(),
    );
    final messenger = ScaffoldMessenger.of(context);
    try {
      _summary = await CashboxOffline.sendNow(context.read<AppState>().api, op);
      _savedAt = null;
      _offline = false;
      unawaited(KhataOffline.cachePut(_cacheKey, _summary!));
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      if (!CashboxOffline.isRetryable(e)) {
        showActionFailed(context, 'cashbox.entry', e); // a real refusal: nothing booked
        return;
      }
      // proof-ledger: no internet / our server busy — keep it on the phone
      try {
        await CashboxOffline.enqueue(op);
      } catch (e2) {
        if (mounted) showActionFailed(context, 'cashbox.enqueue', e2);
        return;
      }
      await _refreshOps();
      messenger.showSnackBar(
          SnackBar(content: Text(t.ldgSavedOffline)));
    }
  }

  Future<void> _reconcile() async {
    final t = AppLocalizations.of(context);
    final poisha = await _amountDialog(context, t.cashboxCounted);
    if (poisha == null) return;
    try {
      _summary = await context
          .read<AppState>()
          .api
          .cashboxReconcile(businessId: _bizId, day: _dayKey, countedPoisha: poisha);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showActionFailed(context, 'cashbox.reconcile', e);
    }
  }

  Future<void> _share() async {
    final text = '${(_summary ?? const {})['share_text'] ?? ''}';
    if (text.isEmpty) return;
    try {
      await Share.share(text);
    } catch (e) {
      if (mounted) showActionFailed(context, 'cashbox.share', e, open: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _summary ?? const {};
    final reconciled = s['reconciled'] == true;
    final lang = Localizations.localeOf(context).languageCode;
    final zero = '৳${localDigits('0', lang)}';
    final autoLines = ((s['auto_lines'] ?? const []) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final duesCollected = autoLines.any((l) =>
        l['key'] == 'dues_collected' && ((l['amount'] as num?) ?? 0) > 0);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.cashboxTitle),
        actions: [
          if (!_loading && !_error && !_offline)
            IconButton(
              key: const ValueKey('bb-cb-share'),
              tooltip: t.share,
              icon: const Icon(Icons.share_rounded),
              onPressed: _share,
            ),
        ],
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: t.cashboxTitle,
                  message: honestFailText(t, _failCause, otherwise: t.businessLoadFailed),
                  action:
                      FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
                    children: [
                      // proof-ledger: offline state + rows waiting on the phone
                      if (_offline) ...[
                        _OfflineBanner(
                          key: const ValueKey('cb-offline-banner'),
                          icon: Icons.cloud_off_rounded,
                          text: _savedAt == null
                              ? t.ldgStillOffline
                              : t.ldgSavedCopy(fmtDate('d MMM, h:mm a', _savedAt!, lang)),
                          action: TextButton(onPressed: _load, child: Text(t.retry)),
                        ),
                        const SizedBox(height: Gap.sm),
                      ],
                      if (_ops.any((o) => o.isPending)) ...[
                        _OfflineBanner(
                          key: const ValueKey('cb-pending-banner'),
                          icon: Icons.cloud_upload_outlined,
                          text: t.ldgPendingSync(localDigits(
                              '${_ops.where((o) => o.isPending).length}', lang)),
                          action: _syncing
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : TextButton(
                                  key: const ValueKey('cb-sync-now'),
                                  onPressed: _syncNow,
                                  child: Text(t.ldgSyncNow)),
                        ),
                        const SizedBox(height: Gap.sm),
                      ],
                      for (final o in _ops.where((o) => !o.isPending)) ...[
                        _OfflineBanner(
                          icon: Icons.error_outline_rounded,
                          error: true,
                          text: '${t.ldgSyncFailed(localDigits('1', lang))} · '
                              '${poishaToTaka(o.amountPoisha)}'
                              '${o.error.isEmpty ? '' : ' · ${o.error}'}',
                          action: TextButton(
                              onPressed: () => CashboxOffline.discard(o.cid),
                              child: Text(t.ldgDiscard)),
                        ),
                        const SizedBox(height: Gap.sm),
                      ],
                      // Expected-cash hero first (page rule), with the day
                      // stepper on its top row — the number is what the
                      // shopkeeper opens this screen for.
                      DsHeroCard(
                        padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.lg),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                IconButton(
                                    tooltip: AppLocalizations.of(context).f2PrevDay,
                                    onPressed: () => _stepDay(-1),
                                    icon: const Icon(Icons.chevron_left_rounded)),
                                Expanded(
                                  child: Text(
                                      DateFormat.yMMMEd(Localizations.localeOf(context).toLanguageTag())
                                          .format(_day),
                                      textAlign: TextAlign.center,
                                      style: AType.titleMedium.copyWith(
                                          color: scheme.ds.text, fontWeight: FontWeight.w600)),
                                ),
                                IconButton(
                                    tooltip: AppLocalizations.of(context).f2NextDay,
                                    onPressed: _isToday ? null : () => _stepDay(1),
                                    icon: const Icon(Icons.chevron_right_rounded)),
                              ]),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                                child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: Gap.xs),
                                      Text(t.cashboxExpected,
                                          style: AType.titleSmall.copyWith(color: scheme.ds.muted)),
                                      const SizedBox(height: Gap.xxs),
                                      DsNumber(
                                          pair(context, s['expected_display'],
                                              fallback: zero),
                                          key: const ValueKey('bb-cb-expected')),
                                      if (_ops.any((o) => o.isPending))
                                        Text(
                                            t.ldgPendingEstimate(pair(
                                                context,
                                                poishaToTaka(((s['expected_poisha'] as num?)?.toInt() ?? 0) +
                                                    _ops
                                                        .where((o) => o.isPending)
                                                        .fold<int>(0, (a, o) => a + o.signed)))),
                                            key: const ValueKey('cb-pending-estimate'),
                                            style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
                                      const SizedBox(height: Gap.xs),
                                      Text(t.bbCbHowTo,
                                          style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
                                    ]),
                              ),
                            ]),
                      ),
                      const SizedBox(height: Gap.md),

                      // Cash in / out right under the hero — the two things
                      // done all day (always open: a row added after the
                      // close re-computes the difference honestly).
                      Row(children: [
                        Expanded(
                          child: FilledButton.icon(
                            key: const ValueKey('cb-cash-in'),
                            style: Brand.successButton(),
                            icon: const Icon(Icons.add_rounded),
                            label: Text(t.cashboxCashIn,
                                maxLines: 2, textAlign: TextAlign.center),
                            onPressed: () => _addEntry('in'),
                          ),
                        ),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: FilledButton.icon(
                            key: const ValueKey('cb-cash-out'),
                            style: Brand.dangerButton(),
                            icon: const Icon(Icons.remove_rounded),
                            label: Text(t.cashboxCashOut,
                                maxLines: 2, textAlign: TextAlign.center),
                            onPressed: () => _addEntry('out'),
                          ),
                        ),
                      ]),
                      const SizedBox(height: Gap.lg),

                      // Breakdown: opening + what the shop already booked
                      // today (read-only) + hand-written rows.
                      DsCard(
                        padding: EdgeInsets.zero,
                        child: Column(children: [
                          _Line(
                              label: t.cashboxOpening,
                              sub: s['opening_carried'] == true
                                  ? t.bbCbCarried
                                  : null,
                              value: pair(context, s['opening_display'],
                                  fallback: zero),
                              trailing: TextButton(
                                  onPressed: _setOpening,
                                  child: Text(t.edit))),
                          for (final ln in autoLines) ...[
                            const Divider(height: 1),
                            _Line(
                                label: pair(context, ln['label']),
                                sub: ((ln['count'] as num?) ?? 0) > 0
                                    ? t.bbCbCount(localDigits(
                                        '${ln['count']}', lang))
                                    : null,
                                sign: ln['kind'] == 'in' ? '+' : '−',
                                value: pair(context, ln['amount_display'],
                                    fallback: zero),
                                valueColor: ln['kind'] == 'in'
                                    ? AssistoTokens.of(context).success
                                    : Theme.of(context).colorScheme.error),
                          ],
                          const Divider(height: 1),
                          _Line(
                              label: t.bbCbOtherIn,
                              sign: '+',
                              value: pair(context, s['manual_in_display'],
                                  fallback: zero),
                              valueColor: AssistoTokens.of(context).success),
                          const Divider(height: 1),
                          _Line(
                              label: t.bbCbOtherOut,
                              sign: '−',
                              value: pair(context, s['manual_out_display'],
                                  fallback: zero),
                              valueColor: Theme.of(context).colorScheme.error),
                        ]),
                      ),
                      if (duesCollected)
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.sm),
                          child: Text(t.bbCbDuesHint,
                              style: AType.bodySmall
                                  .copyWith(color: scheme.ds.muted)),
                        ),
                      const SizedBox(height: Gap.md),

                      // Day close.
                      if (reconciled) ...[
                        _ReconciledCard(summary: s),
                        const SizedBox(height: Gap.sm),
                      ],
                      DsButton.secondary(
                        buttonKey: const ValueKey('bb-cb-close'),
                        icon: Icons.fact_check_rounded,
                        label: reconciled ? t.bbCbRecount : t.cashboxReconcile,
                        onPressed: _reconcile,
                        expand: true,
                      ),

                      // Entries list: one grouped DS card.
                      DsSectionHeader(t.stmtParticulars),
                      ...(() {
                        final entries = [
                          // proof-ledger: rows still on the phone, marked
                          for (final o in _ops.where((o) => o.isPending))
                            <String, dynamic>{
                              'kind': o.kind,
                              'note': o.note,
                              'ref': t.ldgPendingChip,
                              'amount_display': poishaToTaka(o.amountPoisha),
                            },
                          ...((s['entries'] ?? []) as List).cast<Map<String, dynamic>>(),
                        ];
                        if (entries.isEmpty) {
                          return [
                            DsCard(
                              child: Row(children: [
                                Icon(Icons.receipt_long_rounded, color: scheme.ds.muted),
                                const SizedBox(width: Gap.md),
                                Expanded(
                                  child: Text(t.cashboxNoEntries,
                                      style: AType.bodyMedium.copyWith(
                                          color: scheme.ds.muted)),
                                ),
                              ]),
                            )
                          ];
                        }
                        return [
                          DsGroup(margin: EdgeInsets.zero, children: [
                            for (final e in entries) _CashEntryTile(entry: e),
                          ]),
                        ];
                      })(),
                    ],
                  ),
                ),
    );
  }

  bool get _isToday {
    final now = DateTime.now();
    return _day.year == now.year &&
        _day.month == now.month &&
        _day.day == now.day;
  }
}

class _Line extends StatelessWidget {
  final String label;
  final String? sub;
  final String sign;
  final String value;
  final Color? valueColor;
  final Widget? trailing;
  const _Line(
      {required this.label,
      required this.value,
      this.sub,
      this.sign = '',
      this.valueColor,
      this.trailing});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Gap.lg, vertical: Gap.md),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label),
            if (sub != null)
              Text(sub!,
                  style: AType.bodySmall.copyWith(
                      color: Theme.of(context).colorScheme.ds.muted)),
          ]),
        ),
        const SizedBox(width: Gap.sm),
        Text(sign.isEmpty ? value : '$sign $value',
            style: AType.bodyMedium.copyWith(fontFeatures: AFonts.tabular,
                fontWeight: FontWeight.w700, color: valueColor)),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class _ReconciledCard extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _ReconciledCard({required this.summary});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final variancePoisha = (summary['variance_poisha'] as num?)?.toInt() ?? 0;
    final color = variancePoisha == 0
        ? AssistoTokens.of(context).success
        : (variancePoisha > 0 ? AssistoTokens.of(context).warning : Theme.of(context).colorScheme.error);
    final icon = variancePoisha == 0
        ? Icons.check_circle_outline_rounded
        : (variancePoisha > 0
            ? Icons.trending_up_rounded
            : Icons.trending_down_rounded);
    return DsSurface(color: color.withValues(alpha: 0.10),
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: Gap.sm),
            Text(pair(context, summary['variance_status'],
                fallback: t.cashboxBalanced),
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: color)),
          ]),
          const SizedBox(height: Gap.md),
          _MiniRow(
              label: t.cashboxCounted,
              value:
                  pair(context, summary['counted_display'], fallback: '৳0')),
          _MiniRow(
              label: t.cashboxExpected,
              value: pair(context, summary['expected_display'],
                  fallback: '৳0')),
          _MiniRow(
              label: t.cashboxVariance,
              value: pair(context, summary['variance_display'],
                  fallback: '৳0'),
              color: color),
        ]),
    );
  }
}

class _MiniRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _MiniRow({required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
      child: Row(children: [
        Expanded(
            child: Text(label,
                style: AType.bodyMedium.copyWith(
                    color: Theme.of(context).colorScheme.ds.muted))),
        Text(value,
            style: AType.bodyMedium.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }
}

/// proof-ledger: one honest line about the offline state (same look as the
/// khata's banners).
class _OfflineBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  final bool error;
  const _OfflineBanner(
      {super.key, required this.icon, required this.text, this.action, this.error = false});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = error ? scheme.error : scheme.ds.text;
    return DsCard(
      child: Row(children: [
        Icon(icon, color: error ? scheme.error : scheme.ds.muted),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(text, style: AType.bodyMedium.copyWith(color: ink))),
        if (action != null) action!,
      ]),
    );
  }
}

class _CashEntryTile extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _CashEntryTile({required this.entry});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isIn = (entry['kind'] ?? '') == 'in';
    final note = (entry['note'] ?? '').toString();
    final colour = isIn ? scheme.ds.successInk : scheme.ds.dangerInk;
    final ref = (entry['ref'] ?? '').toString();
    return DsListRow(
      leading: Icon(isIn ? Icons.south_west_rounded : Icons.north_east_rounded,
          color: colour),
      title: note.isEmpty
          ? (isIn
              ? AppLocalizations.of(context).cashboxCashIn
              : AppLocalizations.of(context).cashboxCashOut)
          : note,
      subtitle: ref.isEmpty ? null : ref,
      trailing: Text(pair(context, entry['amount_display']),
          style: AType.bodyMedium.copyWith(fontFeatures: AFonts.tabular,
              fontWeight: FontWeight.w700, color: colour)),
    );
  }
}

// ========================= sheets / dialogs ==============================

class _CashEntrySheet extends StatefulWidget {
  final String title;
  const _CashEntrySheet({required this.title});
  @override
  State<_CashEntrySheet> createState() => _CashEntrySheetState();
}

class _CashEntrySheetState extends State<_CashEntrySheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.lg),
        TextField(
          key: const ValueKey('cb-entry-amount'),
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: t.entryAmount, prefixText: '৳ '),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          key: const ValueKey('cb-entry-note'),
          controller: _note,
          decoration: InputDecoration(
              labelText: t.entryNote,
              prefixIcon: const Icon(Icons.notes_rounded)),
        ),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('cb-entry-save'),
            onPressed: () {
              final poisha = takaToPoisha(_amount.text);
              if (poisha == null || poisha <= 0) {
                showNeedInput(context);
                return;
              }
              Navigator.pop(context, (poisha, _note.text.trim()));
            },
            child: Text(t.save),
          ),
        ),
      ]),
    );
  }
}

Future<int?> _amountDialog(BuildContext context, String label) {
  final t = AppLocalizations.of(context);
  final ctrl = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true, // insets: 200% text / keyboard
      title: Text(label),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: t.entryAmount, prefixText: '৳ '),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
        FilledButton(
          onPressed: () {
            final poisha = takaToPoisha(ctrl.text);
            if (poisha == null || poisha < 0) return;
            Navigator.pop(ctx, poisha);
          },
          child: Text(t.save),
        ),
      ],
    ),
  );
}
