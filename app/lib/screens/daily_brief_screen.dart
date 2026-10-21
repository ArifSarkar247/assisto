import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/health_api.dart'; // birthdaysList() extension
import '../widgets/daily_brief_engine.dart';

/// MORNING BRIEF & NIGHT SUMMARY (#7, SPEC v2.1 §6, built to ADVANCED §21).
///
/// Two daily digest cards assembled DETERMINISTICALLY from the user's OWN app
/// data — today's reminders, due payments (subscriptions/bills), birthdays and
/// calendar/appointments:
///   • MORNING — what's ahead today (overdue-that-needs-you first, then today)
///   • NIGHT   — what happened today (done vs still-open) + a tomorrow preview
///
/// Nothing is invented: an empty source contributes nothing and the UI shows an
/// honest "nothing scheduled" state. Weather (morning) and news (night) are
/// HONEST key-gated placeholders — Assisto never fabricates a forecast or a
/// headline; they fill in only when the owner connects the `weather` / `news`
/// Integrations key. The assembly mirrors `backend/core/logic/daily_brief.py`
/// (`daily_brief_engine.dart`). A warm AI narration of the same items is a
/// documented key-gated seam (`anthropic`); see up_quickbrief_integration.md.
class DailyBriefScreen extends StatefulWidget {
  const DailyBriefScreen({super.key});
  @override
  State<DailyBriefScreen> createState() => _DailyBriefScreenState();
}

class _DailyBriefScreenState extends State<DailyBriefScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  bool _loading = true;
  bool _error = false;

  // raw source rows, fetched best-effort from existing endpoints
  List<Map<String, dynamic>> _reminders = [];
  List<Map<String, dynamic>> _payments = [];
  List<Map<String, dynamic>> _birthdays = [];
  List<Map<String, dynamic>> _events = [];

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;

    Future<T?> soft<T>(Future<T> f) async {
      try {
        return await f;
      } catch (_) {
        return null;
      }
    }

    // flatten a generic-collection row: {id, data:{...}} or already-flat
    List<Map<String, dynamic>> flat(List<Map<String, dynamic>>? rows) =>
        (rows ?? const [])
            .map((r) => (r['data'] as Map<String, dynamic>?) ?? r)
            .toList();

    final reminders = await soft(api.listItems('reminders'));
    final subs = await soft(api.listItems('subscriptions'));
    final appts = await soft(api.listItems('appointments'));
    // PA Schedule writes to its OWN `pa_schedule` collection (per-slot rows with
    // start/title), so meetings entered there never surfaced in the brief. Load
    // it too and MERGE those slots into the brief's events below. Best-effort:
    // on failure `paSlots` is null and the brief degrades to appointments only.
    final paSched = await soft(api.listItems('pa_schedule'));
    final bdays = await soft(api.birthdaysList());

    if (!mounted) return;

    // all sources null → honest hard error; otherwise degrade per-source
    if (reminders == null &&
        subs == null &&
        appts == null &&
        bdays == null) {
      setState(() {
        _error = true;
        _loading = false;
      });
      return;
    }

    // subscriptions → payments (name + next_due/due_date + amount + paid)
    final payments = flat(subs)
        .map((s) => {
              'name': s['title'] ?? s['name'],
              'due_date': s['due_date'] ?? s['next_due'] ?? s['due_at'],
              'amount': s['amount'],
              'paid': s['paid'] ?? s['done'],
            })
        .toList();

    // appointments → events. Meetings screen stores {items:[...]} or flat rows.
    final events = <Map<String, dynamic>>[];
    for (final row in flat(appts)) {
      if (row['items'] is List) {
        for (final e in (row['items'] as List)) {
          if (e is Map) events.add(e.cast<String, dynamic>());
        }
      } else {
        events.add(row);
      }
    }

    // MERGE the PA Schedule slots as events. A pa_schedule slot is shaped
    // {title, start (ISO), duration_min, kind, status, ...} — the brief engine
    // keys events off `title` + `start`, so those two fields are all we must
    // map. Each slot is its own row, but older builds wrote wrapper rows shaped
    // {items:[...]}; handle both. Dedupe against appointment events already
    // collected (same title + same start instant) so a meeting that lives in
    // both collections shows once. Cancelled slots are dropped (nothing ahead).
    // Guarded: a malformed pa_schedule payload must never break the brief.
    try {
      String dedupeKey(Map m) {
        final title = (m['title'] ?? m['name'] ?? '').toString().trim().toLowerCase();
        final start =
            DateTime.tryParse((m['start'] ?? m['when'] ?? '').toString());
        return '$title@${start?.toIso8601String() ?? ''}';
      }

      final seen = events.map(dedupeKey).toSet();
      final paRows = <Map<String, dynamic>>[];
      for (final row in flat(paSched)) {
        if (row['items'] is List) {
          for (final e in (row['items'] as List)) {
            if (e is Map) paRows.add(e.cast<String, dynamic>());
          }
        } else {
          paRows.add(row);
        }
      }
      for (final slot in paRows) {
        if ('${slot['status'] ?? ''}' == 'cancelled') continue;
        if ((slot['title'] ?? slot['name'] ?? '').toString().trim().isEmpty) {
          continue;
        }
        final key = dedupeKey(slot);
        if (!seen.add(key)) continue; // already present from appointments
        events.add({
          'title': slot['title'] ?? slot['name'],
          'start': slot['start'] ?? slot['when'],
        });
      }
    } catch (_) {
      // pa_schedule merge failed — fall back to appointments-only events.
    }

    // birthdays endpoint → {upcoming:[{name, next_date, days_until}]}
    final upcoming =
        ((bdays?['upcoming'] ?? const []) as List).cast<Map<String, dynamic>>();
    final birthdays = upcoming
        .map((b) => {'name': b['name'], 'next': b['next_date'] ?? b['date']})
        .toList();

    setState(() {
      _reminders = flat(reminders);
      _payments = payments;
      _events = events;
      _birthdays = birthdays;
      _loading = false;
    });
  }

  DailyBrief _brief(String mode) => buildBrief(
        mode: mode,
        now: DateTime.now(),
        reminders: _reminders,
        payments: _payments,
        birthdays: _birthdays,
        events: _events,
      );

  Future<void> _share(DailyBrief b) async {
    final text = shareBriefText(
      b,
      labels: {
        'overdue': t.dbSecOverdue,
        'today': t.dbSecToday,
        'tomorrow': t.dbSecTomorrow,
        'done': t.dbSecDone,
        'open': t.dbSecOpen,
        'nothing': t.dbNothing,
      },
    );
    await Clipboard.setData(ClipboardData(text: text));
    await Share.share(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.dbTitle),
        bottom: TabBar(
          // large font: scroll instead of cutting tab labels
          isScrollable: MediaQuery.textScalerOf(context).scale(1) > 1.2,
          tabAlignment: MediaQuery.textScalerOf(context).scale(1) > 1.2
              ? TabAlignment.start
              : null,
          controller: _tabs,
          tabs: [
            Tab(text: t.dbTabMorning),
            Tab(text: t.dbTabNight),
          ],
        ),
      ),
      body: _loading
          ? const SkeletonList(count: 4)
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: Brand.danger,
                  title: t.dbLoadError,
                  action: FilledButton.tonal(
                      onPressed: _load, child: Text(t.retry)),
                )
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _morningTab(_brief('morning')),
                    _nightTab(_brief('night')),
                  ],
                ),
    );
  }

  // --------------------------------------------------------------- morning

  Widget _morningTab(DailyBrief b) {
    final dateStr = _fmtDate(b.date);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
        children: [
          _Header(title: t.dbMorningHeading, subtitle: dateStr),
          const SizedBox(height: Gap.lg),
          _weatherSlot(b),
          const SizedBox(height: Gap.lg),
          if (b.empty)
            _emptyCard(t.dbMorningEmpty)
          else ...[
            if (b.overdue.isNotEmpty) ...[
              _sectionTitle(t.dbSecOverdue, Brand.danger),
              ...b.overdue.map(_itemTile),
              const SizedBox(height: Gap.md),
            ],
            if (b.today.isNotEmpty) ...[
              _sectionTitle(t.dbSecToday, Brand.blue),
              ...b.today.map(_itemTile),
            ],
          ],
          const SizedBox(height: Gap.lg),
          _shareButton(b),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- night

  Widget _nightTab(DailyBrief b) {
    final dateStr = _fmtDate(b.date);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
        children: [
          _Header(title: t.dbNightHeading, subtitle: dateStr),
          const SizedBox(height: Gap.lg),
          if (!b.empty)
            _completionBar(b.completionPct, b.doneCount, b.openCount),
          const SizedBox(height: Gap.lg),
          if (b.empty)
            _emptyCard(t.dbNightEmpty)
          else ...[
            if (b.doneToday.isNotEmpty) ...[
              _sectionTitle(t.dbSecDone, Brand.success),
              ...b.doneToday.map(_itemTile),
              const SizedBox(height: Gap.md),
            ],
            if (b.openToday.isNotEmpty) ...[
              _sectionTitle(t.dbSecOpen, Brand.warning),
              ...b.openToday.map(_itemTile),
              const SizedBox(height: Gap.md),
            ],
            if (b.tomorrow.isNotEmpty) ...[
              _sectionTitle(t.dbSecTomorrow, Brand.blue),
              ...b.tomorrow.map(_itemTile),
            ],
          ],
          const SizedBox(height: Gap.lg),
          _newsSlot(b),
          const SizedBox(height: Gap.lg),
          _shareButton(b),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- pieces

  String _fmtDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return DateFormat.yMMMEd().format(d);
  }

  Widget _sectionTitle(String label, Color tint) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm, top: Gap.xs),
        child: Row(children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
          const SizedBox(width: Gap.sm),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _itemTile(BriefItem it) {
    final scheme = Theme.of(context).colorScheme;
    IconData icon;
    String kindLabel;
    switch (it.kind) {
      case 'payment':
        icon = Icons.payments_outlined;
        kindLabel = t.dbKindPayment;
        break;
      case 'birthday':
        icon = Icons.cake_outlined;
        kindLabel = t.dbKindBirthday;
        break;
      case 'event':
        icon = Icons.event_outlined;
        kindLabel = t.dbKindEvent;
        break;
      default:
        icon = Icons.notifications_outlined;
        kindLabel = t.dbKindReminder;
    }
    final time = _timeOf(it.when);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(it.title,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(time == null ? kindLabel : '$kindLabel · $time',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
      ),
    );
  }

  String? _timeOf(String? iso) {
    if (iso == null) return null;
    final d = DateTime.tryParse(iso);
    if (d == null) return null;
    if (d.hour == 0 && d.minute == 0) return null;
    return DateFormat.Hm().format(d);
  }

  Widget _completionBar(int pct, int done, int open) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.dbCompletion(/* (done, pct, total) */ done, pct, done + open),
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      const SizedBox(height: Gap.xs),
      ClipRRect(
        borderRadius: BorderRadius.circular(Radii.pill),
        child: LinearProgressIndicator(
          value: pct / 100.0,
          minHeight: 8,
          backgroundColor: scheme.surfaceContainerHighest,
          color: Brand.success,
        ),
      ),
    ]);
  }

  Widget _emptyCard(String msg) => StateMessage(
        icon: Icons.wb_sunny_outlined,
        tint: Brand.blue,
        title: msg,
      );

  Widget _weatherSlot(DailyBrief b) {
    if (b.weatherConnected) return const SizedBox.shrink();
    return _KeyGatedChip(
      icon: Icons.cloud_outlined,
      text: t.dbWeatherNeedsKey,
    );
  }

  Widget _newsSlot(DailyBrief b) {
    if (b.newsConnected) return const SizedBox.shrink();
    return _KeyGatedChip(
      icon: Icons.article_outlined,
      text: t.dbNewsNeedsKey,
    );
  }

  Widget _shareButton(DailyBrief b) => OutlinedButton.icon(
        onPressed: b.empty ? null : () => _share(b),
        icon: const Icon(Icons.ios_share, size: 18),
        label: Text(t.share),
      );
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  const _Header({required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 2),
      Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant)),
    ]);
  }
}

/// Honest "connect a weather/news key" chip. Never fabricated content.
class _KeyGatedChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _KeyGatedChip({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4)),
        ),
      ]),
    );
  }
}
