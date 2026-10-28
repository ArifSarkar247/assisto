import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../widgets/skeleton.dart';
import '../widgets/subs_common.dart';
import '../widgets/subs_cards.dart';
import '../widgets/subs_edit_sheet.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/action_feedback.dart'; // db1
import '../services/error_kind.dart' show honestFailText; // qa2

/// Advanced subscription tracker (benchmarked on Bobby / Rocket Money, adapted
/// to Bangladesh: bKash/Nagad/card/cash; Netflix/Spotify/Daraz/ISP/gym/recharge).
///
/// Smart views computed client-side off the list-endpoint shape, mirroring
/// backend/core/logic/subscriptions.py. Money is integer poisha throughout.
/// Fields beyond name/amount/cycle/next_due persist only if the backend adds
/// them (see .phaseB/up_subs_integration.md); the UI degrades gracefully when
/// they are absent.
class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});
  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  List<Map<String, dynamic>> _subs = [];
  bool _loading = true;
  bool _error = false;
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
    try {
      _subs = await context.read<AppState>().api.listItems('subscriptions');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // The backend persists only name/amount/cycle/next_due today. We still send
  // the full map so a richer serializer picks the extra keys up automatically.
  Map<String, dynamic> _wire(Map<String, dynamic> form) => {
        'name': form['name'],
        'amount': form['amount'],
        'cycle': cycleWire('${form['cycle']}'),
        if (form['next_due'] != null) 'next_due': form['next_due'],
        if (form['interval_days'] != null) 'interval_days': form['interval_days'],
        if (form['category'] != null) 'category': form['category'],
        if (form['payment_method'] != null)
          'payment_method': form['payment_method'],
        if (form['trial_end'] != null) 'trial_end': form['trial_end'],
        'auto_renew': form['auto_renew'],
        if ((form['notes'] ?? '').toString().isNotEmpty) 'notes': form['notes'],
        'status': form['status'],
      };

  Future<void> _add() async {
    final t = AppLocalizations.of(context);
    final form = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) => const SubsEditSheet(),
    );
    if (form == null || !mounted) return;
    final created =
        await context.read<AppState>().api.createItem('subscriptions', _wire(form));
    // Honour the "I'll remind you before each is due" promise: schedule a local
    // reminder for the new subscription (guarded, never blocks the add).
    _scheduleDueReminder(t, created['id'], created['name'] ?? form['name'],
        created['next_due'] ?? form['next_due']);
    await _load();
  }

  Future<void> _edit(Map<String, dynamic> sub) async {
    final t = AppLocalizations.of(context);
    final form = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SubsEditSheet(initial: sub),
    );
    if (form == null || !mounted) return;
    await context
        .read<AppState>()
        .api
        .updateItem('subscriptions', sub['id'] as int, _wire(form));
    // Re-schedule against the edited next-due (stable id ⇒ replaces, never dupes).
    _scheduleDueReminder(
        t, sub['id'], form['name'] ?? sub['name'], form['next_due']);
    await _load();
  }

  Future<void> _markPaid(Map<String, dynamic> sub) async {
    final next = rollNextDue(sub, DateTime.now());
    final t = AppLocalizations.of(context);
    try {
      await context
          .read<AppState>()
          .api
          .updateItem('subscriptions', sub['id'] as int, {'next_due': next});
    } catch (e) {
      // db1: offline / server error — say so; nothing was marked paid.
      if (mounted) showActionFailed(context, 'subs.markPaid', e);
      return;
    }
    // The new cycle now has a next_due — schedule its reminder (same stable id
    // ⇒ the previous one is replaced, not duplicated).
    _scheduleDueReminder(t, sub['id'], sub['name'], next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.subsMarkedPaid('${sub['name']}'))),
    );
    await _load();
  }

  /// Schedule a local "due soon" reminder for a subscription. Fired the morning
  /// (09:00 local) BEFORE the due date so the user has a day to act; if that is
  /// already past we fall back to 09:00 ON the due date. Past/missing dates are
  /// skipped. The notification id is derived from the backend subscription id
  /// ("sub-<id>") so re-scheduling on edit / mark-paid REPLACES the old alert.
  /// Fully guarded — notifications are best-effort and never block the UX.
  void _scheduleDueReminder(
      AppLocalizations t, dynamic id, dynamic name, dynamic nextDue) {
    try {
      if (id == null) return;
      final due = parseDate(nextDue);
      if (due == null) return;
      final title = (name ?? '').toString().trim();
      if (title.isEmpty) return;
      final now = DateTime.now();
      final dayBefore = DateTime(due.year, due.month, due.day - 1, 9);
      final onDue = DateTime(due.year, due.month, due.day, 9);
      // Prefer the day-before nudge; fall back to the morning-of if that passed.
      final when = dayBefore.isAfter(now) ? dayBefore : onDue;
      if (!when.isAfter(now)) return; // already due/overdue — nothing to fire
      final body = dayBefore.isAfter(now) ? t.subsDueTomorrow : t.subsDueToday;
      Notifications.schedule('sub-$id', title, body, when);
    } catch (_) {
      // best-effort only
    }
  }

  Future<void> _delete(Map<String, dynamic> sub) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.subsDeleteTitle),
        content: Text(t.subsDeleteBody('${sub['name']}')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context
        .read<AppState>()
        .api
        .deleteItem('subscriptions', sub['id'] as int);
    // Drop any pending due reminder for this subscription.
    try {
      if (sub['id'] != null) Notifications.cancel('sub-${sub['id']}');
    } catch (_) {}
    await _load();
  }

  // ---------------------------------------------------------------- derived

  /// Known monthly income in poisha, or null when unknown. Wired to null today
  /// (no income source in scope); set once AppState/money exposes it.
  int? get _knownMonthlyIncomePoisha => null;

  int get _monthly => _subs.fold(0, (a, s) => a + monthlyPoisha(s));
  int get _yearly => _subs.fold(0, (a, s) => a + yearlyPoisha(s));
  int get _activeCount =>
      _subs.where((s) => (s['status'] ?? 'active') == 'active').length;

  List<Map<String, dynamic>> _upcoming(int days) {
    final now = DateTime.now();
    final list = _subs.where((s) {
      if ((s['status'] ?? 'active') != 'active') return false;
      final n = daysUntil(s['next_due'], now);
      return n != null && n <= days;
    }).toList()
      ..sort((a, b) => '${a['next_due']}'.compareTo('${b['next_due']}'));
    return list;
  }

  List<Map<String, dynamic>> get _trials {
    final now = DateTime.now();
    final list = _subs.where((s) {
      if ((s['status'] ?? 'active') == 'cancelled') return false;
      final n = daysUntil(s['trial_end'], now);
      return n != null && n <= 7;
    }).toList()
      ..sort((a, b) => '${a['trial_end']}'.compareTo('${b['trial_end']}'));
    return list;
  }

  List<Map<String, dynamic>> get _cancelCandidates {
    final now = DateTime.now();
    final list = _subs.where((s) {
      if ((s['status'] ?? 'active') != 'active') return false;
      final n = daysUntil(s['last_used'], now);
      return n != null && -n >= 60;
    }).toList()
      ..sort((a, b) => yearlyPoisha(b).compareTo(yearlyPoisha(a)));
    return list;
  }

  /// {key: {label, icon, tint, monthly}} grouped + sorted desc.
  List<_Bucket> _group(String field) {
    final map = <String, int>{};
    for (final s in _subs) {
      if ((s['status'] ?? 'active') != 'active') continue;
      final k = (s[field] ?? (field == 'category' ? 'other' : 'cash')).toString();
      map[k] = (map[k] ?? 0) + monthlyPoisha(s);
    }
    final out = map.entries.map((e) => _Bucket(e.key, e.value)).toList()
      ..sort((a, b) => b.monthly.compareTo(a.monthly));
    return out;
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.subscriptions)),
      floatingActionButton: _subs.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.addSubscription)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: Theme.of(context).colorScheme.error,
                  title: t.loadFailed,
                  message: honestFailText(t, _failCause, otherwise: t.loadFailedBody),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry)))
              : _subs.isEmpty
                  ? StateMessage(
                      icon: Icons.autorenew_rounded,
                      title: t.subscriptions,
                      message: t.subscriptionsEmpty,
                      action: FilledButton.icon(
                          onPressed: _add,
                          icon: const Icon(Icons.add_rounded),
                          label: Text(t.addSubscription)))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _body(t),
                    ),
    );
  }

  Widget _body(AppLocalizations t) {
    final cs = Theme.of(context).colorScheme;
    final up7 = _upcoming(7);
    final up30 = _upcoming(30);
    final trials = _trials;
    final nudges = _cancelCandidates;
    final cats = _group('category');
    final pays = _group('payment_method');
    final expensive = List<Map<String, dynamic>>.from(_subs
        .where((s) => (s['status'] ?? 'active') == 'active'))
      ..sort((a, b) => monthlyPoisha(b).compareTo(monthlyPoisha(a)));
    // Income is unknown here (AppState exposes none, and state.dart is out of
    // scope for this change). When the money module later surfaces a known
    // monthly income the burden gauge lights up automatically — see
    // .phaseB/up_subs_integration.md. Null → gauge hidden (no divide-by-zero).
    final int? income = _knownMonthlyIncomePoisha;

    return ListView(
      // Bottom inset clears the extended FAB (height ~56 + 16 margin) PLUS the
      // trailing footer, so the last card and the footer hint are never hidden
      // behind the floating "Add subscription" button.
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
      children: [
        SubsSpendHero(
          monthlyPoisha: _monthly,
          yearlyPoisha: _yearly,
          activeCount: _activeCount,
        ),

        // Trial alerts — stop a surprise charge.
        for (final s in trials) ...[
          const SizedBox(height: Gap.sm),
          SubsAlertBanner(
            icon: Icons.hourglass_bottom_rounded,
            tint: Brand.warning,
            title: t.subsTrialAlertTitle('${s['name']}'),
            body: t.subsTrialAlertBody(
              fmtInt(context, daysUntil(s['trial_end'], DateTime.now()) ?? 0),
              taka(context, poishaOf(s)),
            ),
            onTap: () => _edit(s),
          ),
        ],

        // Cancel-candidate nudges — "you could save X by cancelling Y".
        for (final s in nudges.take(2)) ...[
          const SizedBox(height: Gap.sm),
          SubsAlertBanner(
            icon: Icons.savings_rounded,
            tint: Brand.success,
            title: t.subsNudgeTitle('${s['name']}'),
            body: t.subsNudgeBody(
              fmtInt(context, -(daysUntil(s['last_used'], DateTime.now()) ?? 0)),
              taka(context, yearlyPoisha(s)),
            ),
            onTap: () => _edit(s),
          ),
        ],

        // Income burden (only when income is known).
        if (income != null && income > 0) ...[
          const SizedBox(height: Gap.md),
          SubsBurdenGauge(
            burdenPct: _monthly * 100 / income,
            monthlyPoisha: _monthly,
            incomePoisha: income,
          ),
        ],

        // Upcoming next 7 days.
        if (up7.isNotEmpty) ...[
          SubsSection(icon: Icons.event_available_rounded, title: t.subsUpcoming7),
          for (final s in up7) _tile(s),
        ],

        // Upcoming 8–30 days.
        if (up30.length > up7.length) ...[
          SubsSection(icon: Icons.calendar_month_rounded, title: t.subsUpcoming30),
          for (final s in up30.where((e) => !up7.contains(e))) _tile(s),
        ],

        // By category.
        if (cats.length > 1) ...[
          SubsSection(icon: Icons.category_rounded, title: t.subsByCategory),
          _breakdown(cats, (b) => categoryIcon(b.key),
              (b) => categoryLabel(t, b.key)),
        ],

        // By payment method.
        if (pays.length > 1) ...[
          SubsSection(
              icon: Icons.account_balance_wallet_rounded,
              title: t.subsByPayment),
          _breakdown(pays, (b) => paymentIcon(b.key),
              (b) => paymentLabel(t, b.key)),
        ],

        // Most expensive.
        if (expensive.length > 1) ...[
          SubsSection(
              icon: Icons.trending_up_rounded,
              title: t.subsMostExpensive,
              tint: Brand.warning),
          for (final s in expensive.take(3)) _tile(s),
        ],

        // Everything (incl. paused / cancelled) with delete via long-swipe.
        SubsSection(icon: Icons.list_alt_rounded, title: t.subsAll),
        for (final s in _subs) _dismissibleTile(s),

        const SizedBox(height: Gap.lg),
        Text(t.subsFooterHint,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.outline)),
      ],
    );
  }

  Widget _tile(Map<String, dynamic> s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: SubsTile(
          sub: s,
          onEdit: () => _edit(s),
          onMarkPaid: () => _markPaid(s),
        ),
      );

  Widget _dismissibleTile(Map<String, dynamic> s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Dismissible(
        key: ValueKey('sub-${s['id']}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: Gap.lg),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Icon(Icons.delete_outline_rounded,
              color: Theme.of(context).colorScheme.onErrorContainer),
        ),
        confirmDismiss: (_) async {
          await _delete(s);
          return false; // _load() rebuilds the list
        },
        child: SubsTile(
          sub: s,
          onEdit: () => _edit(s),
          onMarkPaid: () => _markPaid(s),
        ),
      ),
    );
  }

  Widget _breakdown(List<_Bucket> buckets,
      IconData Function(_Bucket) icon, String Function(_Bucket) label) {
    final max = buckets.first.monthly;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          children: [
            for (final b in buckets)
              SubsBreakdownRow(
                icon: icon(b),
                tint: subColor(context, b.key),
                label: label(b),
                monthlyPoisha: b.monthly,
                fraction: max > 0 ? b.monthly / max : 0,
              ),
          ],
        ),
      ),
    );
  }
}

class _Bucket {
  final String key;
  final int monthly;
  _Bucket(this.key, this.monthly);
}
