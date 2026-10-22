import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../api.dart';
import '../notif_api.dart';
import '../messaging/badges_bus.dart';
import '../widgets/chatnav.dart';
import '../widgets/skeleton.dart';
import '../widgets/notif_models.dart';
import '../widgets/notif_reminder_card.dart';
import '../widgets/notif_feed_card.dart';
import '../push/push_payload.dart' show PushRouting;

/// NOTIFICATION CENTRE — the bell screen (per owner).
///
/// Two tabs:
///   a) REMINDERS       — GET /notif/reminders -> Today · Upcoming · Missed.
///                        Each item: Done · Snooze ▸ · Open (ChatNav deep-link).
///   b) NOTIFICATIONS   — GET /notif/feed -> cross-module events (circle /
///                        community / channel / family / scam / watch /
///                        business / CRM / security / plan / points / updates).
///                        Tap -> deep-link + mark seen. Filter chips by type.
///                        Mark-all-read. Chat messages are NOT here — they
///                        live in My Circle.
///
/// OFFLINE: the last fetched reminders + feed are cached in SharedPreferences
/// and shown (with an "offline — showing saved" note) when a fetch fails for
/// want of a network; a successful fetch re-syncs and overwrites the cache.
///
/// The backend already applies each module's notification settings; the UI
/// renders what it is given and does NOT re-filter by settings.
class NotificationCentreScreen extends StatefulWidget {
  const NotificationCentreScreen({super.key});

  @override
  State<NotificationCentreScreen> createState() =>
      _NotificationCentreScreenState();
}

/// b2-badges (Facebook / WhatsApp style): OPENING the centre clears the home
/// bell badge (POST notif/opened {scope: bell}); SHOWING a tab clears that
/// tab's badge (scope reminders / feed). Items stay bold until tapped one by
/// one, and SOS / family alerts keep counting until handled (server rule).
class _NotificationCentreScreenState extends State<NotificationCentreScreen>
    with SingleTickerProviderStateMixin {
  static const _scopes = ['reminders', 'feed'];
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final List<ValueNotifier<int>> _badges = [
    ValueNotifier<int>(0),
    ValueNotifier<int>(0),
  ];
  final Set<int> _cleared = {};

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _opened(const ['bell']);
      _clearTab(_tabs.index);
      _peekFeedBadge();
    });
  }

  /// TabBarView builds a tab only when it is shown, so the Notifications
  /// tab's count is fetched once here (the Reminders tab is the first view).
  Future<void> _peekFeedBadge() async {
    try {
      final j = await context.read<AppState>().api.notifFeed();
      if (!_cleared.contains(1)) _report(1, _asCount(j['badge']));
    } catch (_) {}
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTab);
    _tabs.dispose();
    for (final b in _badges) {
      b.dispose();
    }
    super.dispose();
  }

  void _onTab() {
    if (!_tabs.indexIsChanging) _clearTab(_tabs.index);
  }

  void _clearTab(int i) {
    _badges[i].value = 0;
    if (_cleared.add(i)) _opened([_scopes[i]]);
  }

  /// A tab reports its server badge after loading; the visible tab is
  /// already being looked at, so it shows none.
  void _report(int i, int n) {
    if (!mounted) return;
    _badges[i].value = _tabs.index == i ? 0 : n;
  }

  Future<void> _opened(List<String> scopes) async {
    if (!mounted) return;
    try {
      await context.read<AppState>().api.notifOpened(scopes);
      BadgesBus.instance.poke();
    } catch (_) {/* offline: the badge clears on the next open */}
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.notifCentreTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(child: _TabLabel(t.notifTabReminders, _badges[0])),
            Tab(child: _TabLabel(t.notifTabNotifications, _badges[1])),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _RemindersTab(onBadge: (n) => _report(0, n)),
          _FeedTab(onBadge: (n) => _report(1, n)),
        ],
      ),
    );
  }
}

/// Tab title + its count bubble (hidden at 0). The title ellipsizes so a
/// long Bangla label never clips at 360 px / large font.
class _TabLabel extends StatelessWidget {
  final String text;
  final ValueListenable<int> count;
  const _TabLabel(this.text, this.count);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: count,
      builder: (_, n, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis),
          ),
          if (n > 0) ...[
            const SizedBox(width: Gap.xs),
            Badge(
              key: const ValueKey('notifTabBadge'),
              backgroundColor: scheme.error,
              textColor: scheme.onError,
              label: Text(n > 99
                  ? '${99}${String.fromCharCode(0x2B)}'
                  : '$n'),
            ),
          ],
        ],
      ),
    );
  }
}

int _asCount(Object? v) =>
    v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// Shared offline banner shown above cached content.
class _OfflineNote extends StatelessWidget {
  const _OfflineNote();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: Brand.warning.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, size: 18, color: Brand.warning),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              t.notifOfflineNote,
              style: TextStyle(color: scheme.onSurface, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// TAB A — REMINDERS
// ===========================================================================

class _RemindersTab extends StatefulWidget {
  final ValueChanged<int>? onBadge;
  const _RemindersTab({this.onBadge});
  @override
  State<_RemindersTab> createState() => _RemindersTabState();
}

class _RemindersTabState extends State<_RemindersTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _error = false;
  bool _offline = false;
  final Map<ReminderSection, List<NotifReminder>> _sections = {
    ReminderSection.today: [],
    ReminderSection.upcoming: [],
    ReminderSection.missed: [],
  };

  @override
  bool get wantKeepAlive => true;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _apply(Map<String, dynamic> j) {
    // Sections are nested under `sections` by the backend; fall back to top-level.
    final s = (j['sections'] as Map?)?.cast<String, dynamic>() ?? j;
    List<NotifReminder> parse(String k) => ((s[k] as List?) ?? const [])
        .whereType<Map>()
        .map(NotifReminder.fromJson)
        .toList();
    _sections[ReminderSection.today] = parse('today');
    _sections[ReminderSection.upcoming] = parse('upcoming');
    _sections[ReminderSection.missed] = parse('missed');
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _offline = false;
    });
    try {
      final j = await _api.notifReminders();
      await Settings.setString(NotifCache.remindersKey, NotifCache.encode(j));
      if (!mounted) return;
      widget.onBadge?.call(_asCount(j['badge']));
      setState(() {
        _apply(j);
        _loading = false;
      });
    } catch (e) {
      // Network failure -> fall back to the last cached payload if we have one.
      final cached =
          NotifCache.decodeMap(await Settings.getString(NotifCache.remindersKey));
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _apply(cached);
          _offline = true;
          _loading = false;
        });
      } else {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _done(NotifReminder r) async {
    // Optimistic removal; restore on failure.
    final from = _sectionOf(r);
    setState(() => _sections[from]?.removeWhere((x) => x.id == r.id));
    try {
      await _api.reminderDone(r.id, module: r.module, route: r.route);
    } catch (_) {
      if (mounted) {
        setState(() => _sections[from]?.insert(0, r));
        _snack(AppLocalizations.of(context).notifActionFailed);
      }
    }
  }

  Future<void> _snooze(NotifReminder r, SnoozePreset preset) async {
    DateTime? until;
    String? presetKey;
    switch (preset) {
      case SnoozePreset.m15:
        presetKey = '15m';
        break;
      case SnoozePreset.h1:
        presetKey = '1h';
        break;
      case SnoozePreset.tomorrow:
        presetKey = 'tomorrow';
        break;
      case SnoozePreset.custom:
        until = await _pickCustom();
        if (until == null) return; // cancelled
        break;
    }
    try {
      await _api.reminderSnooze(r.id, preset: presetKey, until: until);
      if (mounted) {
        _snack(AppLocalizations.of(context).notifSnoozed);
        _load();
      }
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).notifActionFailed);
    }
  }

  Future<DateTime?> _pickCustom() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return null;
    final tod = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (tod == null) return null;
    return DateTime(d.year, d.month, d.day, tod.hour, tod.minute);
  }

  ReminderSection _sectionOf(NotifReminder r) {
    for (final e in _sections.entries) {
      if (e.value.any((x) => x.id == r.id)) return e.key;
    }
    return ReminderSection.today;
  }

  void _open(NotifReminder r) => ChatNav.push(context, r.route);

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);

    if (_loading) return const SkeletonList(count: 6);

    if (_error) {
      return _ErrorView(onRetry: _load);
    }

    final today = _sections[ReminderSection.today]!;
    final upcoming = _sections[ReminderSection.upcoming]!;
    final missed = _sections[ReminderSection.missed]!;
    final allClear = today.isEmpty && upcoming.isEmpty && missed.isEmpty;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        children: [
          if (_offline) ...[
            const SizedBox(height: Gap.sm),
            const _OfflineNote(),
          ],
          const SizedBox(height: Gap.md),
          if (allClear)
            StateMessage(
              icon: Icons.check_circle_outline,
              title: t.notifRemindersAllClear,
              message: t.notifRemindersAllClearBody,
              tint: Brand.success,
            )
          else ...[
            _Section(
              title: t.notifSectionToday,
              items: today,
              onDone: _done,
              onSnooze: _snooze,
              onOpen: _open,
            ),
            _Section(
              title: t.notifSectionUpcoming,
              items: upcoming,
              onDone: _done,
              onSnooze: _snooze,
              onOpen: _open,
            ),
            _Section(
              title: t.notifSectionMissed,
              items: missed,
              overdue: true,
              onDone: _done,
              onSnooze: _snooze,
              onOpen: _open,
            ),
          ],
        ],
      ),
    );
  }
}

/// A labelled reminder section. Renders nothing when empty (the all-clear
/// empty state is handled once at the tab level).
class _Section extends StatelessWidget {
  final String title;
  final List<NotifReminder> items;
  final bool overdue;
  final void Function(NotifReminder) onDone;
  final void Function(NotifReminder, SnoozePreset) onSnooze;
  final void Function(NotifReminder) onOpen;

  const _Section({
    required this.title,
    required this.items,
    required this.onDone,
    required this.onSnooze,
    required this.onOpen,
    this.overdue = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.sm),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: overdue ? Brand.danger : scheme.onSurface,
                ),
          ),
        ),
        for (final r in items)
          NotifReminderCard(
            reminder: r,
            overdue: overdue,
            onDone: () => onDone(r),
            onSnooze: (p) => onSnooze(r, p),
            onOpen: () => onOpen(r),
          ),
      ],
    );
  }
}

// ===========================================================================
// TAB B — NOTIFICATIONS (feed)
// ===========================================================================

class _FeedTab extends StatefulWidget {
  final ValueChanged<int>? onBadge;
  const _FeedTab({this.onBadge});
  @override
  State<_FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<_FeedTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _error = false;
  bool _offline = false;
  List<NotifEvent> _events = [];
  NotifType? _filter; // null => all

  @override
  bool get wantKeepAlive => true;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<NotifEvent> _parse(Map<String, dynamic> j) =>
      ((j['items'] as List?) ?? const [])
          .whereType<Map>()
          .map(NotifEvent.fromJson)
          .toList();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _offline = false;
    });
    try {
      final j = await _api.notifFeed();
      await Settings.setString(NotifCache.feedKey, NotifCache.encode(j));
      if (!mounted) return;
      widget.onBadge?.call(_asCount(j['badge']));
      setState(() {
        _events = _parse(j);
        _loading = false;
      });
    } catch (_) {
      final cached =
          NotifCache.decodeMap(await Settings.getString(NotifCache.feedKey));
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _events = _parse(cached);
          _offline = true;
          _loading = false;
        });
      } else {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _tap(NotifEvent e) async {
    // Mark seen locally first for instant feedback, then best-effort POST.
    if (!e.seen) {
      setState(() => e.seen = true);
      if (!_offline) {
        try {
          await _api.notifSeen(e.id);
        } catch (_) {/* best-effort: keep optimistic state */}
      }
    }
    // dl1: backend routes (e.g. account/delete) map to ChatNav keys.
    if (mounted) {
      ChatNav.push(context, PushRouting.routeMap[e.route] ?? e.route);
    }
  }

  Future<void> _markAllRead() async {
    final prev = _events.map((e) => e.seen).toList();
    setState(() {
      for (final e in _events) {
        e.seen = true;
      }
    });
    try {
      await _api.notifReadAll();
    } catch (_) {
      if (mounted) {
        setState(() {
          for (var i = 0; i < _events.length; i++) {
            _events[i].seen = prev[i];
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).notifActionFailed)),
        );
      }
    }
  }

  /// Distinct types present, in a stable display order, for the filter chips.
  List<NotifType> get _presentTypes {
    final order = NotifType.values;
    final seen = _events.map((e) => e.type).toSet();
    return [for (final t in order) if (seen.contains(t)) t];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);

    if (_loading) return const SkeletonList(count: 7);
    if (_error) return _ErrorView(onRetry: _load);

    if (_events.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            if (_offline) const _OfflineNote(),
            const SizedBox(height: Gap.xxl),
            StateMessage(
              icon: Icons.notifications_none,
              title: t.notifFeedEmpty,
              message: t.notifFeedEmptyBody,
            ),
          ],
        ),
      );
    }

    final anyUnseen = _events.any((e) => !e.seen);
    final visible = _filter == null
        ? _events
        : _events.where((e) => e.type == _filter).toList();

    return Column(
      children: [
        if (_offline) const _OfflineNote(),
        // Toolbar: Mark all read.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: anyUnseen ? _markAllRead : null,
                icon: const Icon(Icons.done_all, size: 18),
                label: Text(t.notifMarkAllRead),
              ),
            ],
          ),
        ),
        // Filter chips by type.
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: Gap.sm),
                child: ChoiceChip(
                  label: Text(t.notifFilterAll),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
              ),
              for (final type in _presentTypes)
                Padding(
                  padding: const EdgeInsets.only(right: Gap.sm),
                  child: ChoiceChip(
                    label: Text(notifTypeLabel(t, type)),
                    selected: _filter == type,
                    onSelected: (_) => setState(() => _filter = type),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
              itemCount: visible.length,
              itemBuilder: (_, i) => NotifFeedCard(
                event: visible[i],
                onTap: () => _tap(visible[i]),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// Shared error view
// ===========================================================================

class _ErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorView({required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return StateMessage(
      icon: Icons.error_outline,
      title: t.notifErrorTitle,
      message: t.notifErrorBody,
      tint: Brand.danger,
      action: FilledButton.tonalIcon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: Text(t.notifRetry),
      ),
    );
  }
}
