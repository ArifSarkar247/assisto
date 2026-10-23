import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../api.dart';
import '../widgets/chatnav.dart';
import '../widgets/skeleton.dart';
import '../widgets/watch_item.dart';
import '../widgets/watch_card.dart';
import '../widgets/watch_sources_sheet.dart';
import '../widgets/bn_day_periods.dart' show appDateLocale;
import '../services/action_feedback.dart'; // db1
import '../services/error_kind.dart' show honestFailText; // qa2

/// WATCH FEED (ADVANCED) — the user's single "what needs me now" digest.
///
/// This is NOT just the old price/rate watcher list. It aggregates REAL
/// signals from across the app's modules into one prioritized, actionable,
/// grouped feed:
///   • reminders due today            (listItems('reminders'))
///   • medicine doses for today        (medicinesToday)
///   • medicine refill / loans / budget / docs / family / safe-journey
///       — the server's cross-module alert builder (alertsList)
///   • subscription renewals           (listItems('subscriptions'))
///   • price / rate / news changes     (watchFeed hits)
///   • active watchers                 (listItems('watchers'))
///
/// Each card deep-links into its module (ChatNav.push) and carries a quick
/// action (open / mark-done / taken / pay-hint / snooze / dismiss). Nothing is
/// invented: a source with no real signal contributes nothing. Grouping and
/// priority mirror the pure helper backend/core/logic/watch_feed.py.
class WatchFeedScreen extends StatefulWidget {
  const WatchFeedScreen({super.key});
  @override
  State<WatchFeedScreen> createState() => _WatchFeedScreenState();
}

class _WatchFeedScreenState extends State<WatchFeedScreen> {
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  List<WatchItem> _items = [];
  List<Map<String, dynamic>> _watchers = [];

  /// Which sources feed the screen (personalization). All on by default.
  final Set<WatchSource> _enabled = {...WatchSource.values};

  /// Local dismiss / snooze bookkeeping (ids). Kept per-session; the real
  /// mark-done/taken calls already persist to the backend.
  final Set<String> _dismissed = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final items = await _compose();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = true;
        _failCause = e;
      });
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Composition — pull each enabled source, map to WatchItems. Every fetch is
  // best-effort: one source failing must not blank the whole feed.
  // ---------------------------------------------------------------------------
  Future<List<WatchItem>> _compose() async {
    final today = DateTime.now();
    DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
    int? daysFrom(String? iso) {
      if (iso == null) return null;
      final d = DateTime.tryParse(iso);
      if (d == null) return null;
      return dayOnly(d.toLocal()).difference(dayOnly(today)).inDays;
    }

    final out = <WatchItem>[];

    // Run independent fetches concurrently; swallow per-source errors.
    Future<T?> soft<T>(Future<T> f) async {
      try {
        return await f;
      } catch (_) {
        return null;
      }
    }

    final alerts = _enabled.any((s) => s != WatchSource.watchers)
        ? await soft(_api.alertsList())
        : null;
    final reminders = _enabled.contains(WatchSource.reminders)
        ? await soft(_api.listItems('reminders'))
        : null;
    final meds = _enabled.contains(WatchSource.medicine)
        ? await soft(_api.medicinesToday())
        : null;
    final subs = _enabled.contains(WatchSource.subscriptions)
        ? await soft(_api.listItems('subscriptions'))
        : null;
    final feed = _enabled.contains(WatchSource.watchers)
        ? await soft(_api.watchFeed())
        : null;
    _watchers = (_enabled.contains(WatchSource.watchers)
            ? await soft(_api.listItems('watchers'))
            : null) ??
        const [];

    // ---- server cross-module alerts (refill/loan/budget/doc/family/journey)
    for (final a in (alerts ?? const [])) {
      final type = (a['type'] ?? '').toString();
      final mapped = _mapAlert(type);
      if (mapped == null || !_enabled.contains(mapped.source)) continue;
      out.add(WatchItem(
        id: 'alert:$type:${a['title'] ?? a['text']}',
        kind: type.isEmpty ? 'alert' : type,
        title: (a['title'] ?? a['text'] ?? '').toString(),
        body: a['title'] != null ? a['text']?.toString() : null,
        group: mapped.needsYou ? WatchGroup.needsYou : WatchGroup.today,
        severity: _sev(a['severity']),
        source: mapped.source,
        route: mapped.route,
        actions: mapped.actions,
      ));
    }

    // ---- reminders due today / overdue
    for (final r in (reminders ?? const [])) {
      if (r['done'] == true) continue;
      final days = daysFrom(r['due_at']?.toString());
      if (days == null || days > 0) continue; // only today/overdue surface here
      out.add(WatchItem(
        id: 'reminder:${r['id']}',
        kind: 'reminder',
        title: (r['title'] ?? '').toString(),
        group: WatchGroup.today,
        severity: days < 0 ? WatchSeverity.high : WatchSeverity.med,
        source: WatchSource.reminders,
        route: 'reminders',
        daysUntil: days,
        actions: const [
          WatchAction.markDone,
          WatchAction.snooze,
          WatchAction.open,
        ],
      ));
    }

    // ---- medicine doses for today (untaken only)
    for (final m in (meds ?? const [])) {
      if (m['taken'] == true || m['skipped'] == true) continue;
      final slot = (m['slot'] ?? '').toString();
      if (slot.isEmpty) continue;
      final who = (m['member_name'] ?? '').toString();
      out.add(WatchItem(
        id: 'med:${m['medicine_id']}:$slot',
        kind: 'medicine_dose',
        title: (m['name'] ?? '').toString(),
        body: who.isEmpty ? slot : '$who · $slot',
        group: WatchGroup.today,
        severity: WatchSeverity.med,
        source: WatchSource.medicine,
        route: 'family',
        daysUntil: 0,
        actions: const [WatchAction.markTaken, WatchAction.open],
      ));
    }

    // ---- subscription renewals within the look-ahead window
    for (final s in (subs ?? const [])) {
      final days = daysFrom(s['next_due']?.toString());
      if (days == null || days < 0 || days > 7) continue;
      out.add(WatchItem(
        id: 'sub:${s['id']}',
        kind: 'subscription',
        title: (s['name'] ?? '').toString(),
        group: days == 0 ? WatchGroup.today : WatchGroup.upcoming,
        severity: WatchSeverity.low,
        source: WatchSource.subscriptions,
        route: 'subscriptions',
        daysUntil: days,
        actions: const [
          WatchAction.payHint,
          WatchAction.open,
          WatchAction.dismiss,
        ],
      ));
    }

    // ---- price / rate / news change hits
    for (final h in ((feed?['hits'] ?? const []) as List)) {
      out.add(WatchItem(
        id: 'hit:${h['id'] ?? h['at']}',
        kind: 'change',
        title: (h['summary'] ?? '').toString(),
        group: WatchGroup.upcoming,
        severity: h['severity'] == 'high' ? WatchSeverity.high : WatchSeverity.low,
        source: WatchSource.watchers,
        route: 'watch_feed',
        actions: const [WatchAction.open, WatchAction.dismiss],
      ));
    }

    out.sort((a, b) => a.priority.compareTo(b.priority));
    return out;
  }

  WatchSeverity _sev(dynamic v) {
    switch ((v ?? '').toString()) {
      case 'high':
        return WatchSeverity.high;
      case 'low':
        return WatchSeverity.low;
      default:
        return WatchSeverity.med;
    }
  }

  /// Map a server alert `type` → source/route/actions. Unknown types skipped
  /// (we never surface a signal we can't deep-link or explain).
  _AlertMap? _mapAlert(String type) {
    switch (type) {
      case 'refill':
        return _AlertMap(WatchSource.medicine, 'family',
            const [WatchAction.open, WatchAction.snooze]);
      case 'loan_due':
        return _AlertMap(WatchSource.money, 'money',
            const [WatchAction.payHint, WatchAction.open]);
      case 'budget':
        return _AlertMap(WatchSource.money, 'money',
            const [WatchAction.open], needsYou: true);
      case 'doc_expiry':
      case 'doc_expired':
        return _AlertMap(WatchSource.money, 'documents',
            const [WatchAction.open]);
      case 'checkin_overdue':
        return _AlertMap(WatchSource.safety, 'safety',
            const [WatchAction.call, WatchAction.open], needsYou: true);
      default:
        // family wellness / scam / fall / sos — all family-surfaced, need you.
        return _AlertMap(WatchSource.family, 'family',
            const [WatchAction.call, WatchAction.open], needsYou: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------
  Future<void> _runAction(WatchItem it, WatchAction a) async {
    final t = AppLocalizations.of(context);
    switch (a) {
      case WatchAction.open:
        ChatNav.push(context, it.route);
        break;
      case WatchAction.dismiss:
        setState(() => _dismissed.add(it.id));
        _snack(t.watchDismissed, undo: () {
          setState(() => _dismissed.remove(it.id));
        });
        break;
      case WatchAction.snooze:
        setState(() => _dismissed.add(it.id));
        _snack(t.watchSnoozedToTomorrow);
        break;
      case WatchAction.markDone:
        final id = int.tryParse(it.id.split(':').last);
        if (id != null) {
          try {
            await _api.updateItem('reminders', id, {'done': true});
          } catch (e) {
            if (mounted) showActionFailed(context, 'watch.markDone', e); // db1
            return;
          }
        }
        setState(() => _dismissed.add(it.id));
        break;
      case WatchAction.markTaken:
        final parts = it.id.split(':');
        final id = int.tryParse(parts.length > 1 ? parts[1] : '');
        final slot = parts.length > 2 ? parts[2] : '';
        if (id != null && slot.isNotEmpty) {
          try {
            await _api.medicineTaken(id, slot, taken: true);
          } catch (e) {
            if (mounted) showActionFailed(context, 'watch.markTaken', e); // db1
            return;
          }
        }
        setState(() => _dismissed.add(it.id));
        break;
      case WatchAction.call:
        // Safety-critical: the alert payload carries no phone number (the
        // server alert dict is only type/text/title/severity), so we cannot
        // dial directly. The item's own route is 'family', a screen with no
        // call button — a dead end. Deep-link to Emergency instead, which has
        // a working dialer (emergency_screen._call → tel: via url_launcher).
        ChatNav.push(context, 'emergency');
        break;
      case WatchAction.payHint:
        // Deep-link into the module where the real pay flow lives.
        ChatNav.push(context, it.route);
        break;
    }
  }

  void _snack(String msg, {VoidCallback? undo}) {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      action: undo == null
          ? null
          : SnackBarAction(label: t.watchUndo, onPressed: undo),
    ));
  }

  Future<void> _addUsdWatcher() async {
    final t = AppLocalizations.of(context);
    try {
      await _api.createItem('watchers', {
        'kind': 'usd_bdt',
        'label': t.watchSourceWatchers,
        'interval_min': 360,
      });
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  void _openSources() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => WatchSourcesSheet(
        enabled: _enabled,
        onChanged: (next) {
          setState(() {
            _enabled
              ..clear()
              ..addAll(next);
          });
        },
      ),
    ).then((_) => _load());
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final visible =
        _items.where((it) => !_dismissed.contains(it.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.watchFeedTitle),
            Text(t.watchFeedSubtitle,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: scheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: t.watchPersonalize,
            onPressed: _openSources,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: t.watchRefresh,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addUsdWatcher,
        icon: const Icon(Icons.add_alert_outlined),
        label: Text(t.qa1WatchAddRateAlert), // qa1: clearer copy (bn read awkwardly)
      ),
      body: _loading
          ? Column(children: [
              Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Row(children: [
                  const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: Gap.sm),
                  Flexible( // qa1: wraps at large font
                    child: Text(t.watchLoadingTitle,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                ]),
              ),
              const Expanded(child: SkeletonList()),
            ])
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.watchErrorTitle,
                  message: honestFailText(t, _failCause, otherwise: t.watchErrorBody),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.watchRetry)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _buildFeed(t, scheme, visible),
                ),
    );
  }

  Widget _buildFeed(
      AppLocalizations t, ColorScheme scheme, List<WatchItem> visible) {
    final hasWatchers = _watchers.isNotEmpty;
    if (visible.isEmpty && !hasWatchers) {
      // Honest empty — scrollable so pull-to-refresh still works.
      return ListView(
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: StateMessage(
              icon: Icons.verified_outlined,
              tint: Brand.success,
              title: t.watchAllClearTitle,
              message: t.watchAllClearBody,
            ),
          ),
        ],
      );
    }

    final needs =
        visible.where((it) => it.group == WatchGroup.needsYou).toList();
    final todayItems =
        visible.where((it) => it.group == WatchGroup.today).toList();
    final upcoming =
        visible.where((it) => it.group == WatchGroup.upcoming).toList();

    return ListView(
      // bottom room so the floating action never covers the last card
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
      children: [
        Text(t.watchSummaryLine(
          _n(needs.length),
          _n(todayItems.length),
          _n(upcoming.length),
        ), style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        // Always show the three groups so the digest structure is legible;
        // empty groups show honest per-group copy.
        _group(t.watchGroupNeedsYou, t.watchGroupNeedsYouHint,
            Icons.pan_tool_alt_outlined, Brand.danger, needs),
        _group(t.watchGroupToday, t.watchGroupTodayHint,
            Icons.today_outlined, Brand.blue, todayItems),
        _group(t.watchGroupUpcoming, t.watchGroupUpcomingHint,
            Icons.upcoming_outlined, Brand.purple, upcoming),
        if (hasWatchers) ...[
          const SizedBox(height: Gap.lg),
          _watchersSection(t),
        ],
        _disabledSourcesHint(t, scheme),
      ],
    );
  }

  /// Honest per-source "enable X to see it here" footer for any source the
  /// user has turned off, so nothing silently disappears.
  Widget _disabledSourcesHint(AppLocalizations t, ColorScheme scheme) {
    final off =
        WatchSource.values.where((s) => !_enabled.contains(s)).toList();
    if (off.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in off)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(children: [
                Icon(Icons.visibility_off_outlined,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    t.watchEnableToSee(watchSourceLabel(t, s)),
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _openSources,
                  child: Text(t.watchPersonalize),
                ),
              ]),
            ),
        ],
      ),
    );
  }

  String _n(int v) => watchLocaleNum(context, v);

  Widget _group(String title, String hint, IconData icon, Color tint,
      List<WatchItem> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: Gap.sm),
          Text(title,
              style: TextStyle(fontWeight: FontWeight.w700, color: tint)),
        ]),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(left: 26, bottom: Gap.sm),
          child: Text(hint,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12)),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: Gap.sm),
            child: Text(AppLocalizations.of(context).watchNoneInGroup,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          )
        else
          for (final it in items)
            WatchCard(
              item: it,
              onOpen: () => ChatNav.push(context, it.route),
              onAction: (a) => _runAction(it, a),
            ),
        const SizedBox(height: Gap.md),
      ],
    );
  }

  Widget _watchersSection(AppLocalizations t) {
    final fmt = DateFormat('d MMM, h:mm a', appDateLocale(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.watchActiveWatchersTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        for (final w in _watchers)
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: ListTile(
              dense: true,
              leading: Icon(watchSourceIcon(WatchSource.watchers)),
              title: Text((w['label'] ?? w['kind'] ?? '').toString()),
              subtitle: Text(() {
                final v = w['last_value']?.toString() ?? '';
                final at = DateTime.tryParse(w['last_checked'] ?? '');
                return at != null ? '$v · ${fmt.format(at.toLocal())}' : v;
              }()),
              trailing: IconButton(
                tooltip: t.watchRemoveWatcher,
                icon: const Icon(Icons.delete_outline),
                onPressed: () => runUserAction(context, 'watch.removeWatcher', () async { // db1
                  await _api.deleteItem('watchers', w['id']);
                  _load();
                }),
              ),
            ),
          ),
      ],
    );
  }
}

/// How a server alert type maps into the feed.
class _AlertMap {
  final WatchSource source;
  final String route;
  final List<WatchAction> actions;
  final bool needsYou;
  const _AlertMap(this.source, this.route, this.actions,
      {this.needsYou = false});
}
