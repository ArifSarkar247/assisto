import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ads/ad_placements.dart' show AdExit, AdExitPlacement; // adcontrol
import '../../api.dart';
import '../../config.dart';
import '../../l10n/app_localizations.dart';
import '../../mess_v2_api.dart';
import '../../messaging/msg_notify.dart' show loadStoredIdentity;
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../ds/ds.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/skeleton.dart';
import '../circle_group_chat_screen.dart';
import '../mess_accounting_screen.dart' show showMessSettingsSheet;
import '../plans_screen.dart';
import 'mess_ad.dart';
import 'mess_sheets.dart';
import 'mess_store.dart';

/// MESS AND BACHELOR V2 — one shared mess (owner order 10 Nov, Part 2 A–L).
///
/// Tabs: Meals (my days; default ON; cut-off; several days off; manager
/// corrections) · Bazar (receipt photo, turn schedule) · Money (deposits,
/// optional advance, service charges split equal / by seat — NOT in the meal
/// rate) · Month (meal rate = bazar ÷ meals; per member meals × rate +
/// service − deposits → will pay / gets back; close month locks; report into
/// the E2E group + PDF; free due reminders) · Members (My Circle only; roles;
/// edit history). Works offline: writes queue in [MessOutbox] and sync.
class MessDetailScreen extends StatefulWidget {
  const MessDetailScreen(
      {super.key, required this.messId, this.fromGroup = false, this.initialTab = 0});
  final int messId;

  /// 0 Meals · 1 Bazar · 2 Deposits and bills · 3 Month end · 4 Members.
  final int initialTab;

  /// Opened from the mess group's card: "Share in group" closes this screen
  /// and opens the group with the report ready to send (no second chat copy
  /// left underneath).
  final bool fromGroup;

  @override
  State<MessDetailScreen> createState() => _MessDetailScreenState();
}

class _MessDetailScreenState extends State<MessDetailScreen> with WidgetsBindingObserver {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _offline = false;
  int _pending = 0;
  String? _month; // null = current month
  bool _busy = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final api = _api;
    try {
      final f = await MessOutbox.flush(api);
      if (f.refused.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).mv2SyncRefused(f.refused.first))));
      }
      final r = await api.messDetail(widget.messId, month: _month);
      if (_month == null) await MessOutbox.cache(widget.messId, r);
      final p = await MessOutbox.pending(widget.messId);
      if (mounted) {
        setState(() {
          _d = r;
          _error = null;
          _offline = false;
          _pending = p;
        });
      }
    } catch (e) {
      final c = (e is ApiException || _month != null) ? null : await MessOutbox.cached(widget.messId);
      final p = await MessOutbox.pending(widget.messId);
      if (!mounted) return;
      setState(() {
        if (c != null && _d == null) _d = c;
        _offline = c != null || _d != null;
        _pending = p;
        if (_d == null) _error = e;
      });
    }
  }

  // ------------------------------------------------------------ getters
  Map<String, dynamic> get _mess => ((_d?['mess'] as Map?) ?? const {}).cast<String, dynamic>();
  Map<String, dynamic> get _monthInfo => ((_d?['month'] as Map?) ?? const {}).cast<String, dynamic>();
  Map<String, dynamic> get _summary => ((_d?['summary'] as Map?) ?? const {}).cast<String, dynamic>();
  List<Map<String, dynamic>> _list(Object? v) =>
      ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  List<Map<String, dynamic>> get _members => _list(_d?['members']);
  List<Map<String, dynamic>> get _entries => _list(_d?['entries']);
  bool get _staff => _mess['can_manage'] == true;
  bool get _admin => _mess['is_admin'] == true;
  bool get _closedMonth => _monthInfo['closed'] == true;
  bool get _messOpen => _mess['status'] == 'active';
  int get _myId => (_mess['my_member_id'] as num?)?.toInt() ?? 0;
  String get _base => '/mess/v2/${widget.messId}';

  // ------------------------------------------------------------ writes
  Future<void> _write(String path, Map<String, dynamic> body, {String? ok}) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await MessOutbox.write(_api, widget.messId, '$_base/$path', body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r == 'queued' ? t.mv2SavedOffline : (ok ?? t.mv2Saved))));
      await _load();
    } catch (e) {
      if (mounted) _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(Object e) {
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is ApiException && e.message.isNotEmpty ? e.message : honestFailText(t, e)),
        action: SnackBarAction(label: t.retry, onPressed: _load)));
  }

  Future<void> _call(Future<Map<String, dynamic>> Function() f, {String? ok}) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await f();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ?? t.mv2Saved)));
      await _load();
    } catch (e) {
      if (mounted) _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editDay(Map<String, dynamic> day, {Map<String, dynamic>? member}) async {
    final res = await showMealDaySheet(context,
        dateLabel: messShortDate(context, '${day['date']}'), day: day,
        forName: member == null ? null : '${member['name']}');
    if (res == null) return;
    await _write('meals', {
      'date': day['date'],
      ...res,
      if (member != null) 'member_id': member['id'],
    });
  }

  Future<void> _daysOff({Map<String, dynamic>? member}) async {
    final r = await showDaysOffSheet(context);
    if (r == null) return;
    await _write('meals/off', {
      'from': messIsoDate(r.from),
      'to': messIsoDate(r.to),
      'on': r.on,
      if (member != null) 'member_id': member['id'],
    });
  }

  Future<void> _addEntry(String kind) async {
    final body = await showEntrySheet(context,
        kind: kind, members: _members, myMemberId: _myId, staff: _staff);
    if (body == null) return;
    await _write('entries', body);
  }

  Future<void> _correctMeals() async {
    final t = AppLocalizations.of(context);
    final m = await _pickMember(t.mv2CorrectWho);
    if (m == null || !mounted) return;
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: now.subtract(const Duration(days: 40)),
        lastDate: now.add(const Duration(days: 30)));
    if (d == null || !mounted) return;
    await _editDay({'date': messIsoDate(d)}, member: m);
  }

  Future<Map<String, dynamic>?> _pickMember(String title) {
    final active = _members.where((m) => m['status'] == 'active').toList();
    return showAppSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => AppSheetBody(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(ctx).textTheme.titleMedium),
          for (final m in active)
            ListTile(
                minTileHeight: 52,
                title: Text('${m['name']}'),
                onTap: () => Navigator.pop(ctx, m)),
        ]),
      ),
    );
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final r = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => AppSheetBody(
        primary: FilledButton(
            key: const ValueKey('mess-confirm-yes'),
            onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(body),
        ]),
      ),
    );
    return r == true;
  }

  Future<void> _closeMonth() async {
    final t = AppLocalizations.of(context);
    if (!await _confirm(t.mv2CloseMonthTitle, t.mv2CloseMonthBody, t.mv2CloseMonth)) return;
    var closed = false;
    await _call(() async {
      final r = await _api.messClose(widget.messId);
      closed = true;
      return r;
    }, ok: t.mv2MonthClosed);
    // adcontrol (owner ads order 10 Nov 03:45): the month-end report is ready
    // -> one interstitial (Free only, owner switch + caps; never in the chat)
    if (closed && mounted) AdExit.transition(AdExitPlacement.messMonthReport);
  }

  Future<void> _shareInGroup() async {
    final t = AppLocalizations.of(context);
    final gid = (_mess['group_id'] as num?)?.toInt();
    if (gid == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.mv2NoGroupYet)));
      return;
    }
    setState(() => _busy = true);
    try {
      final rep = await _api.messReport(widget.messId, month: _month);
      final identity = await loadStoredIdentity();
      if (!mounted) return;
      if (identity == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.mv2KeyMissing)));
        return;
      }
      final g = await _api.getJson('/circle/groups/$gid');
      if (!mounted) return;
      final route = MaterialPageRoute<void>(
          builder: (_) => CircleGroupChatScreen(
              group: g, identity: identity, initialDraft: '${rep['text'] ?? ''}'));
      final nav = Navigator.of(context);
      if (widget.fromGroup) {
        // replace the chat we came from (under this screen) with the drafted one
        nav.pop();
        await nav.pushReplacement(route);
      } else {
        await nav.push(route);
      }
    } catch (e) {
      if (mounted) _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pdf() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final bytes = await _api.messReportPdf(widget.messId, month: _month);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/mess-${_monthInfo['key'] ?? 'month'}.pdf');
      await f.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(f.path, mimeType: 'application/pdf')],
          text: '${_mess['name'] ?? ''}');
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.status == 402) {
        _premiumSheet(t.mv2PremiumOldMonths);
      } else {
        _fail(e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _premiumSheet(String text) {
    final t = AppLocalizations.of(context);
    showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => AppSheetBody(
        primary: FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlansScreen()));
            },
            child: Text(t.mv2SeePremium)),
        child: Text(text, style: Theme.of(ctx).textTheme.bodyLarge),
      ),
    );
  }

  Future<void> _history() async {
    try {
      final r = await _api.messHistory(widget.messId);
      if (!mounted) return;
      final rows = _list(r['results']);
      await showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => AppSheetBody(child: MessHistoryList(rows: rows)),
      );
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  Future<void> _memberActions(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context);
    final mid = (m['id'] as num).toInt();
    final isSelf = mid == _myId;
    final act = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => AppSheetBody(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${m['name']}', style: Theme.of(ctx).textTheme.titleLarge),
          if (_admin && m['role'] != 'admin')
            ListTile(minTileHeight: 52, leading: const Icon(Icons.shield_rounded),
                title: Text(t.mv2MakeAdmin), onTap: () => Navigator.pop(ctx, 'make_admin')),
          if (_admin && m['role'] == 'admin')
            ListTile(minTileHeight: 52, leading: const Icon(Icons.remove_moderator_rounded),
                title: Text(t.mv2RemoveAdmin), onTap: () => Navigator.pop(ctx, 'remove_admin')),
          if (_admin && m['is_manager'] != true)
            ListTile(minTileHeight: 52, leading: const Icon(Icons.manage_accounts_rounded),
                title: Text(t.mv2MakeManager), onTap: () => Navigator.pop(ctx, 'make_manager')),
          if (_admin)
            ListTile(minTileHeight: 52, leading: const Icon(Icons.bed_rounded),
                title: Text(t.mv2SeatShare),
                subtitle: Text(messDigits(ctx, m['seat_share'])),
                onTap: () => Navigator.pop(ctx, 'seat_share')),
          if (_staff)
            ListTile(minTileHeight: 52, leading: const Icon(Icons.event_busy_rounded),
                title: Text(t.mv2DaysOffFor), onTap: () => Navigator.pop(ctx, 'days_off')),
          if (_admin || isSelf)
            ListTile(minTileHeight: 52,
                leading: Icon(Icons.logout_rounded, color: Theme.of(ctx).colorScheme.error),
                title: Text(isSelf ? t.mv2LeaveMess : t.mv2RemoveMember),
                onTap: () => Navigator.pop(ctx, 'remove')),
        ]),
      ),
    );
    if (act == null || !mounted) return;
    if (act == 'days_off') return _daysOff(member: m);
    int? value;
    if (act == 'seat_share') {
      value = await showAppSheet<int>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => AppSheetBody(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.mv2SeatShareHelp),
            Wrap(spacing: Gap.sm, children: [
              for (var i = 0; i <= 4; i++)
                ChoiceChip(
                    label: Text(messDigits(ctx, i)),
                    selected: m['seat_share'] == i,
                    onSelected: (_) => Navigator.pop(ctx, i)),
            ]),
          ]),
        ),
      );
      if (value == null) return;
    }
    if (act == 'remove' &&
        !await _confirm(isSelf ? t.mv2LeaveMess : t.mv2RemoveMember, t.mv2RemoveBody, t.mv2Confirm)) {
      return;
    }
    await _call(() => _api.messMemberAction(widget.messId, mid, act, value: value));
  }

  Future<void> _entryActions(Map<String, dynamic> e) async {
    final t = AppLocalizations.of(context);
    if (_closedMonth) return;
    final del = await _confirm(t.mv2DeleteEntry, t.mv2DeleteEntryBody, t.mv2Delete);
    if (!del) return;
    await _write('entries/${e['id']}', {'action': 'delete'}, ok: t.mv2Deleted);
  }

  // ------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_d == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.mv2Title)),
        body: _error == null
            ? const SkeletonList()
            : ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
                // design2: DS error state (drawn illustration, one big retry)
                DsEmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: t.mv2Title,
                  benefit: honestFailText(t, _error),
                  actionLabel: t.retry,
                  onAction: _load,
                ),
              ]),
        bottomNavigationBar: const MessAdBanner(),
      );
    }
    return DefaultTabController(
      length: 5,
      initialIndex: widget.initialTab.clamp(0, 4),
      child: Scaffold(
        appBar: AppBar(
          title: Text('${_mess['name'] ?? ''}', maxLines: 2),
          actions: [
            if (_admin && _messOpen)
              IconButton(
                  tooltip: t.mv2EditMess,
                  icon: const Icon(Icons.edit_rounded),
                  onPressed: () async {
                    final r = await showMessSettingsSheet(context, current: _mess);
                    if (r != null) await _call(() => _api.messEdit(widget.messId, r));
                  }),
            IconButton(
                tooltip: t.mv2History, icon: const Icon(Icons.history_rounded), onPressed: _history),
          ],
          // design2 (lead review): tighter label padding so more tabs fit, and
          // the bar fades out at the end edge — reads as "scroll", never as a
          // clipped label
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(kTextTabBarHeight),
            // GPU-light (perf guard): a plain gradient strip over the end
            // edge instead of a shader mask (no offscreen layer)
            child: Builder(builder: (context) {
              final bar = Theme.of(context).appBarTheme.backgroundColor ??
                  Theme.of(context).colorScheme.ds.bg;
              return Stack(children: [
                TabBar(isScrollable: true, tabAlignment: TabAlignment.start,
                    // room after the last tab so, scrolled to the end, it sits clear of the fade
                    padding: const EdgeInsetsDirectional.only(end: Gap.xxl),
                    labelPadding: const EdgeInsets.symmetric(horizontal: Gap.md), tabs: [
                  Tab(text: t.mv2TabMeals),
                  Tab(text: t.mv2TabBazar),
                  Tab(text: t.mv2TabMoney),
                  Tab(text: t.mv2TabMonth),
                  Tab(text: t.mv2TabMembers),
                ]),
                PositionedDirectional(
                  end: 0,
                  top: 0,
                  bottom: 2,
                  width: Gap.xxl,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: AlignmentDirectional.centerStart,
                          end: AlignmentDirectional.centerEnd,
                          colors: [bar.withValues(alpha: 0), bar],
                        ),
                      ),
                    ),
                  ),
                ),
              ]);
            }),
          ),
        ),
        body: Column(children: [
          if (_offline || _pending > 0)
            DsOfflineStrip(
              label: _offline ? t.mv2OfflineBanner : t.mv2PendingBanner(messDigits(context, _pending)),
              retryLabel: t.retry,
              onRetry: _load,
            ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: TabBarView(children: [
              _mealsTab(t),
              _bazarTab(t),
              _moneyTab(t),
              _monthTab(t),
              _membersTab(t),
            ]),
          ),
        ]),
        bottomNavigationBar: const MessAdBanner(),
      ),
    );
  }

  Widget _scroll(List<Widget> children) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
            padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)), children: children),
      );

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.xs),
        child: Text(s, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      );

  Widget _bigButton(String label, IconData icon, VoidCallback? onTap, {Key? key}) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        // min height, not a fixed one: a 2-line label at 200 % font grows
        child: FilledButton.tonalIcon(
            key: key,
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm)),
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label, textAlign: TextAlign.center)),
      );

  // ---- Meals
  Widget _mealsTab(AppLocalizations t) {
    final today = _d?['today'] is Map ? (_d!['today'] as Map).cast<String, dynamic>() : null;
    final days = _list(_d?['my_days']);
    final todayIso = messIsoDate(DateTime.now());
    final upcoming = days.where((d) => '${d['date']}'.compareTo(todayIso) >= 0).take(15).toList();
    final bm = (_mess['breakfast_milli'] as num?)?.toInt() ?? 500;
    String dayTotal(Map<String, dynamic> d) {
      int n(String k) => (d[k] as num?)?.toInt() ?? 0;
      final milli = (n('b') + n('gb')) * bm + (n('l') + n('gl') + n('d') + n('gd')) * 1000;
      final s = (milli / 1000).toStringAsFixed(milli % 1000 == 0 ? 0 : 1);
      return messDigits(context, s);
    }

    return _scroll([
      // design2: today's mess at a glance is the soft hero (page rule: most
      // important first), meals in a big bold line
      if (today != null)
        DsHeroCard(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.mv2CardTitle,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700, color: DsTokens.of(context).muted)),
            const SizedBox(height: Gap.xs),
            Text(t.mv2CardMeals(messDigits(context, today['meals_today'])),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800, letterSpacing: -0.3, color: DsTokens.of(context).text)),
            Text(t.mv2CardBazar(messDigits(context, today['bazar_today_display'])),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: DsTokens.of(context).text)),
            const SizedBox(height: Gap.xs),
            Row(children: [
              Icon(
                  ((today['not_set_tomorrow'] as List?) ?? const []).isEmpty
                      ? Icons.check_circle_rounded
                      : Icons.schedule_rounded,
                  size: 18,
                  color: ((today['not_set_tomorrow'] as List?) ?? const []).isEmpty
                      ? DsTokens.of(context).successInk
                      : DsTokens.of(context).primaryInk),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(((today['not_set_tomorrow'] as List?) ?? const []).isEmpty
                    ? t.mv2CardAllSet
                    : t.mv2CardNotSet((today['not_set_tomorrow'] as List).join(', '))),
              ),
            ]),
          ]),
        ),
      _sectionTitle(t.mv2MyMeals),
      if (_messOpen && !_closedMonth)
        _bigButton(t.mv2DaysOffTitle, Icons.event_busy_rounded, _busy ? null : () => _daysOff(),
            key: const ValueKey('mess-days-off')),
      if (_messOpen && _staff && !_closedMonth)
        _bigButton(t.mv2CorrectMeals, Icons.edit_calendar_rounded, _busy ? null : _correctMeals),
      // design2 (page rule): actions first, the cut-off rule as a short muted line after them
      Text(t.mv2MealsHelp(messDigits(context, '${((_mess['cutoff_hour'] as num?) ?? 22).toString().padLeft(2, '0')}:00')),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.ds.muted)),
      const SizedBox(height: Gap.sm),
      for (final d in upcoming)
        DsCard(
          padding: EdgeInsets.zero,
          child: ListTile(
            key: ValueKey('mess-day-${d['date']}'),
            minTileHeight: 56,
            title: Text(messShortDate(context, '${d['date']}')),
            subtitle: Text(_slotsLine(t, d)),
            // design2 (lead review): the meal count is its own right-aligned
            // badge, so the slots line never pushes it onto a line of its own
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
                decoration: BoxDecoration(
                  color: DsTokens.of(context).primarySoft,
                  borderRadius: BorderRadius.circular(DsRadius.button),
                ),
                child: Text(t.mv2MealCount(dayTotal(d)),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700, color: DsTokens.of(context).primaryInk)),
              ),
              const SizedBox(width: Gap.sm),
              Icon(d['can_edit'] == true ? Icons.edit_rounded : Icons.lock_clock_rounded,
                  semanticLabel: d['can_edit'] == true ? t.mv2Edit : t.mv2Locked),
            ]),
            onTap: d['can_edit'] == true && _messOpen ? () => _editDay(d) : null,
          ),
        ),
    ]);
  }

  String _slotsLine(AppLocalizations t, Map<String, dynamic> d) {
    final on = [
      if (d['b'] == 1) t.mv2Breakfast,
      if (d['l'] == 1) t.mv2Lunch,
      if (d['d'] == 1) t.mv2Dinner,
    ];
    return on.isEmpty ? t.mv2MealsOff : on.join(' · ');
  }

  // ---- Bazar
  Widget _bazarTab(AppLocalizations t) {
    final bazar = _entries.where((e) => e['kind'] == 'bazar').toList();
    final turns = _entries.where((e) => e['kind'] == 'turn').toList()
      ..sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    final can = _messOpen && !_closedMonth;
    return _scroll([
      if (can)
        _bigButton(t.mv2AddBazar, Icons.shopping_basket_rounded, _busy ? null : () => _addEntry('bazar'),
            key: const ValueKey('mess-add-bazar')),
      _sectionTitle(t.mv2Turns),
      if (can && _staff)
        _bigButton(t.mv2AddTurn, Icons.event_repeat_rounded, _busy ? null : () => _addEntry('turn')),
      if (turns.isEmpty) Text(t.mv2TurnsEmpty),
      for (final e in turns)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_available_rounded),
          title: Text('${e['member_name']}'),
          subtitle: Text(messShortDate(context, '${e['date']}')),
          onLongPress: _staff ? () => _entryActions(e) : null,
        ),
      _sectionTitle(t.mv2TabBazar),
      if (bazar.isEmpty) _emptyLine(t.mv2BazarEmpty),
      for (final e in bazar) _entryTile(e, t),
    ]);
  }

  Widget _emptyLine(String s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        child: Text(s, textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Widget _entryTile(Map<String, dynamic> e, AppLocalizations t) {
    final data = ((e['data'] as Map?) ?? const {}).cast<String, dynamic>();
    final photo = e['photo_url'];
    final sub = <String>[
      messShortDate(context, '${e['date']}'),
      if (e['kind'] == 'charge') messChargeLabel(t, '${data['kind'] ?? 'other'}'),
      if (e['kind'] == 'charge') data['split'] == 'seat' ? t.mv2SplitSeatShort : t.mv2SplitEqualShort,
      if (e['kind'] == 'deposit' && data['advance'] == true) t.mv2Advance,
      if ('${data['items'] ?? ''}'.isNotEmpty) '${data['items']}',
      if ('${data['title'] ?? ''}'.isNotEmpty) '${data['title']}',
    ];
    return DsCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        key: ValueKey('mess-entry-${e['id']}'),
        minTileHeight: 56,
        title: Text(e['kind'] == 'charge'
            ? messChargeLabel(t, '${data['kind'] ?? 'other'}')
            : '${e['member_name'] ?? ''}'),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (e['kind'] != 'turn')
            Text(messDigits(context, e['amount_display']),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
          Text(sub.join(' · ')),
        ]),
        trailing: photo is String && photo.isNotEmpty
            ? IconButton(
                tooltip: t.mv2ViewReceipt,
                icon: const Icon(Icons.receipt_long_rounded),
                onPressed: () => _showPhoto(photo),
              )
            : null,
        // the server allows the author or the manager; anyone else gets a
        // clear "not allowed" message (never a silent no-op)
        onLongPress: !_closedMonth && _messOpen ? () => _entryActions(e) : null,
      ),
    );
  }

  void _showPhoto(String url) {
    final full = url.startsWith('http') ? url : '${AppConfig.apiBase}$url';
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: InteractiveViewer(
          child: Image.network(full, fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Text(AppLocalizations.of(ctx).loadFailed))),
        ),
      ),
    );
  }

  // ---- Money
  Widget _moneyTab(AppLocalizations t) {
    final deps = _entries.where((e) => e['kind'] == 'deposit').toList();
    final charges = _entries.where((e) => e['kind'] == 'charge').toList();
    final can = _messOpen && !_closedMonth;
    return _scroll([
      _sectionTitle(t.mv2Deposits),
      if (can)
        _bigButton(t.mv2AddDeposit, Icons.savings_rounded, _busy ? null : () => _addEntry('deposit'),
            key: const ValueKey('mess-add-deposit')),
      if (deps.isEmpty) _emptyLine(t.mv2DepositsEmpty),
      for (final e in deps) _entryTile(e, t),
      _sectionTitle(t.mv2ServiceCharges),
      Text(t.mv2ChargeNoteDays, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.sm),
      if (can && _staff)
        _bigButton(t.mv2AddCharge, Icons.receipt_rounded, _busy ? null : () => _addEntry('charge'),
            key: const ValueKey('mess-add-charge')),
      if (charges.isEmpty) _emptyLine(t.mv2ChargesEmpty),
      for (final e in charges) _entryTile(e, t),
    ]);
  }

  // ---- Month
  Widget _monthTab(AppLocalizations t) {
    final s = _summary;
    final rows = _list(s['members']);
    final months = ((_d?['months_closed'] as List?) ?? const []).map((e) => '$e').toList();
    final key = '${_monthInfo['key'] ?? ''}';
    return _scroll([
      Row(children: [
        Expanded(
          child: Text(_closedMonth ? t.mv2MonthClosedLabel(messDigits(context, key)) : t.mv2MonthOpenLabel(messDigits(context, key)),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (months.isNotEmpty)
          PopupMenuButton<String>(
            tooltip: t.mv2OldMonths,
            icon: const Icon(Icons.calendar_month_rounded),
            onSelected: (v) {
              setState(() => _month = v == 'now' ? null : v);
              _load();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'now', child: Text(t.mv2ThisMonth)),
              for (final m in months) PopupMenuItem(value: m, child: Text(messDigits(context, m))),
            ],
          ),
      ]),
      const SizedBox(height: Gap.sm),
      if (_monthInfo['full'] == false)
        DsSurface(color: DsTokens.of(context).primarySoft,
          padding: EdgeInsets.zero,
          child: ListTile(
            title: Text(t.mv2PremiumOldMonths),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _premiumSheet(t.mv2PremiumOldMonths),
          ),
        ),
      DsHeroCard(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _kv(t.mv2TotalBazar, s['bazar_total_display']),
            _kv(t.mv2TotalMeals, s['meals_total']),
            _kv(t.mv2MealRate, s['meal_rate_display'], strong: true),
            _kv(t.mv2ServiceCharges, s['charges_total_display']),
            _kv(t.mv2Deposits, s['deposits_total_display']),
            const SizedBox(height: Gap.xs),
            Text(t.mv2RateFormula, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DsTokens.of(context).muted)),
          ]),
      ),
      _sectionTitle(t.mv2PerMember),
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: DsCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${r['name']}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              _kv(t.mv2Meals, r['meals']),
              _kv(t.mv2MealCost, r['meal_cost_display']),
              _kv(t.mv2ServiceCharge, r['service_display']),
              _kv(t.mv2Deposit, r['deposits_display']),
              if ((r['carry_in'] as num? ?? 0) != 0) _kv(t.mv2CarryIn, r['carry_in_display']),
              const Divider(),
              Text(
                switch ('${r['state']}') {
                  'will_pay' => t.mv2WillPay(messDigits(context, r['due_display'])),
                  'gets_back' => t.mv2GetsBack(messDigits(context, r['due_display'])),
                  _ => t.mv2AllClear,
                },
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: r['state'] == 'will_pay'
                        ? DsTokens.of(context).dangerInk
                        : DsTokens.of(context).successInk),
              ),
            ]),
          ),
        ),
      if (rows.isEmpty) _emptyLine(t.mv2MonthEmpty),
      const SizedBox(height: Gap.sm),
      if (!_closedMonth && _staff && _messOpen && _month == null)
        _bigButton(t.mv2CloseMonth, Icons.lock_rounded, _busy ? null : _closeMonth,
            key: const ValueKey('mess-close-month')),
      _bigButton(t.mv2ShareInGroup, Icons.forum_rounded, _busy ? null : _shareInGroup,
          key: const ValueKey('mess-share-group')),
      _bigButton(t.mv2Pdf, Icons.picture_as_pdf_rounded, _busy ? null : _pdf),
      if (_staff && months.isNotEmpty)
        _bigButton(t.mv2RemindDues, Icons.notifications_active_rounded,
            _busy ? null : () => _call(() => _api.messRemind(widget.messId), ok: t.mv2RemindSent)),
    ]);
  }

  Widget _kv(String k, Object? v, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(k)),
          const SizedBox(width: Gap.sm),
          Flexible(
            child: Text(messDigits(context, v ?? '—'),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: strong ? FontWeight.w800 : FontWeight.w600)),
          ),
        ]),
      );

  // ---- Members
  Widget _membersTab(AppLocalizations t) {
    final active = _members.where((m) => m['status'] == 'active').toList();
    return _scroll([
      if (_admin && _messOpen)
        _bigButton(t.mv2AddMember, Icons.person_add_rounded, _busy ? null : () async {
          final added = await showMessCirclePicker(context, widget.messId);
          if (added == true) _load();
        }, key: const ValueKey('mess-add-member')),
      if (active.length <= 1) _emptyLine(t.mv2MembersEmpty),
      for (final m in active)
        DsCard(
          padding: EdgeInsets.zero,
          child: ListTile(
            key: ValueKey('mess-member-${m['id']}'),
            minTileHeight: 56,
            leading: CircleAvatar(
                child: Text(('${m['name'] ?? ''}'.trim().isEmpty ? '?' : '${m['name']}'.trim()[0])
                    .toUpperCase())),
            title: Text('${m['name'] ?? ''}'),
            subtitle: Text([
              if (m['role'] == 'admin') t.mv2RoleAdmin,
              if (m['is_manager'] == true) t.mv2RoleManager,
              if (m['role'] != 'admin' && m['is_manager'] != true) t.mv2RoleMember,
              if (m['linked'] != true) t.mv2NotLinked,
            ].join(' · ')),
            trailing: const Icon(Icons.more_vert_rounded),
            onTap: _messOpen ? () => _memberActions(m) : null,
          ),
        ),
      if (_admin && _messOpen) ...[
        const SizedBox(height: Gap.lg),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 52), foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: _busy
              ? null
              : () async {
                  if (await _confirm(t.mv2CloseMess, t.mv2CloseMessBody, t.mv2CloseMess)) {
                    await _call(() => _api.messCloseMess(widget.messId));
                  }
                },
          icon: const Icon(Icons.door_front_door_rounded),
          label: Text(t.mv2CloseMess),
        ),
      ],
    ]);
  }
}

/// gap-money: the mess edit history (who, WHAT changed, when) — its own
/// widget so the gallery can show it (mess_v2_history).
class MessHistoryList extends StatelessWidget {
  const MessHistoryList({super.key, required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.mv2History,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.sm),
      if (rows.isEmpty) Text(t.mv2HistoryEmpty),
      for (final h in rows)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${h['actor']}: ${_messActionLabel(t, '${h['action']}')}'),
          // show WHAT changed (amount / meals / date), not only who and
          // when — the point of an edit history is trust.
          subtitle: Text(messDigits(context, [
            messHistoryDetail(h['before'], h['after']),
            if ((h['after'] as Map?)?['offline_saved_at'] != null) t.mv2SyncedLateNote,
            _messWhen('${h['at']}'),
          ].where((x) => x.isNotEmpty).join('\n'))),
        ),
    ]);
  }
}

String _messWhen(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.day}/${d.month} ${two(d.hour)}:${two(d.minute)}';
}

String _messActionLabel(AppLocalizations t, String a) {
  final kind = a.split('.').first;
  final op = a.contains('.') ? a.split('.').last : '';
  final what = switch (kind) {
    'meal' => t.mv2TabMeals,
    'bazar' => t.mv2TabBazar,
    'deposit' => t.mv2Deposits,
    'charge' => t.mv2ServiceCharges,
    'turn' => t.mv2Turns,
    'member' => t.mv2TabMembers,
    'month' => t.mv2TabMonth,
    'due' => t.mv2RemindDues,
    _ => t.mv2Title,
  };
  final how = switch (op) {
    'add' || 'create' => t.mv2OpAdded,
    'edit' || 'set' => t.mv2OpChanged,
    'delete' || 'remove' => t.mv2OpRemoved,
    'close' => t.mv2OpClosed,
    _ => t.mv2OpChanged,
  };
  return '$what — $how';
}
