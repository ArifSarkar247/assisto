import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import 'booking_detail_screen.dart';
import 'booking_setup_screen.dart';
import 'booking_source.dart';
import 'booking_widgets.dart';

/// booking-bot — the BUSINESS side: today / upcoming / a calendar day view,
/// the public link to share, the setup wizard, and a phone / walk-in booking.
/// Behind the server flag `booking_bot`; the server answers 403 feature_off
/// while hidden and this screen says so honestly. No ads here.
class BookingBizScreen extends StatefulWidget {
  final BookingSource? source;

  /// Tests / gallery: force the first-run guide on (true) or off (false).
  final bool? guide;
  final int initialTab;
  const BookingBizScreen({super.key, this.source, this.guide, this.initialTab = 0});

  @override
  State<BookingBizScreen> createState() => _BookingBizScreenState();
}

const _kGuideSeen = 'bk_biz_guide_seen_v1';

class _BookingBizScreenState extends State<BookingBizScreen> {
  late final BookingSource _src =
      widget.source ?? ApiBookingSource(context.read<AppState>().api);
  bool _loading = true;
  Object? _err;
  Map<String, dynamic> _page = const {};
  bool _showGuide = false;
  int _rev = 0;

  @override
  void initState() {
    super.initState();
    _initGuide();
    _load();
  }

  Future<void> _initGuide() async {
    if (widget.guide != null) {
      _showGuide = widget.guide!;
      return;
    }
    try {
      final p = await SharedPreferences.getInstance();
      if (mounted) setState(() => _showGuide = !(p.getBool(_kGuideSeen) ?? false));
    } catch (_) {}
  }

  Future<void> _closeGuide() async {
    setState(() => _showGuide = false);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kGuideSeen, true);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _page = await _src.page();
    } catch (e) {
      _err = e;
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _rev++;
      });
    }
  }

  bool get _ready =>
      bkList(_page['ready_problems']).isEmpty && (_page['ready_problems'] is List);

  Future<void> _setup() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BookingSetupScreen(source: _src, initial: _page)));
    await _load();
  }

  Future<void> _addManual() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => BkManualSheet(source: _src, services: bkList(_page['services'])),
    );
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final setUp = !_loading && _err == null && bkList(_page['services']).isNotEmpty;
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.bkgTitle),
          actions: [
            IconButton(
              tooltip: t.bkgHelp,
              icon: const Icon(Icons.help_outline_rounded),
              onPressed: () => setState(() => _showGuide = !_showGuide),
            ),
            if (!_loading && _err == null && _page['is_owner'] == true)
              IconButton(
                tooltip: t.bkgSetupTitle,
                icon: const Icon(Icons.tune_rounded),
                onPressed: _setup,
              ),
          ],
          bottom: setUp
              ? TabBar(isScrollable: true, tabs: [
                  Tab(text: t.bkgTabToday),
                  Tab(text: t.bkgTabUpcoming),
                  Tab(text: t.bkgTabCalendar),
                ])
              : null,
        ),
        floatingActionButton: setUp
            ? FloatingActionButton.extended(
                onPressed: _addManual,
                icon: const Icon(Icons.add_rounded),
                label: Text(t.bkgAddBooking),
              )
            : null,
        body: _body(t, setUp),
      ),
    );
  }

  Widget _body(AppLocalizations t, bool setUp) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) return bkErrorView(context, _err!, _load);
    if (!setUp) {
      return ListView(padding: const EdgeInsets.only(bottom: Gap.xxl), children: [
        BookingGuideCard(onClose: null),
        _Welcome(owner: _page['is_owner'] == true, onStart: _setup),
      ]);
    }
    final header = _Header(page: _page, ready: _ready, onSetup: _setup);
    return TabBarView(children: [
      _BookingList(
          key: ValueKey('today$_rev'),
          source: _src,
          scope: 'today',
          header: [if (_showGuide) BookingGuideCard(onClose: _closeGuide), header],
          onChanged: _load),
      _BookingList(key: ValueKey('up$_rev'), source: _src, scope: 'upcoming', header: const [], onChanged: _load),
      _DayView(key: ValueKey('day$_rev'), source: _src, onChanged: _load),
    ]);
  }
}

class _Welcome extends StatelessWidget {
  final bool owner;
  final VoidCallback onStart;
  const _Welcome({required this.owner, required this.onStart});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.bkgWelcomeTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.xs + 2),
        Text(owner ? t.bkgWelcomeBody : t.bkgWelcomeStaff),
        const SizedBox(height: Gap.lg),
        if (owner)
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(t.bkgStartSetup),
            onPressed: onStart,
          ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  final Map<String, dynamic> page;
  final bool ready;
  final VoidCallback onSetup;
  const _Header({required this.page, required this.ready, required this.onSetup});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = bkLang(context);
    final counts = bkMap(page['counts']);
    final on = page['enabled'] == true;
    final url = (page['public_url'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(on ? Icons.check_circle_rounded : Icons.pause_circle_outline_rounded,
                color: on ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(on ? t.bkgTakingOn : t.bkgTakingOff,
                    style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
          if (!on && page['is_owner'] == true)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(page['plan_ok'] == false ? t.bkgNeedsPlan : t.bkgTurnOnHint),
            ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.lg, runSpacing: Gap.xs, children: [
            Text(t.bkgCountToday(bkDigits(lang, counts['today'] ?? 0))),
            Text(t.bkgCountPending(bkDigits(lang, counts['pending'] ?? 0))),
            Text(t.bkgCountUpcoming(bkDigits(lang, counts['upcoming'] ?? 0))),
          ]),
          if (url.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            SelectableText(url, style: Theme.of(context).textTheme.bodySmall),
            Wrap(spacing: Gap.sm, children: [
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.copy_rounded),
                label: Text(t.bkgCopyLink),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.bkgCopied)));
                  }
                },
              ),
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.share_rounded),
                label: Text(t.bkgShareLink),
                onPressed: () => Share.share(t.bkgShareText(url)),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _BookingList extends StatefulWidget {
  final BookingSource source;
  final String scope;
  final List<Widget> header;
  final Future<void> Function() onChanged;
  const _BookingList(
      {super.key, required this.source, required this.scope, required this.header, required this.onChanged});

  @override
  State<_BookingList> createState() => _BookingListState();
}

class _BookingListState extends State<_BookingList> {
  bool _loading = true;
  Object? _err;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _rows = bkList((await widget.source.bookings(widget.scope))['bookings']);
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(Map<String, dynamic> b) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BookingDetailScreen(source: widget.source, bookingId: b['id'] as int, initial: b)));
    await _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) return bkErrorView(context, _err!, _fetch);
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        ...widget.header,
        if (_rows.isEmpty)
          Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Text(widget.scope == 'today' ? t.bkgEmptyToday : t.bkgEmptyUpcoming,
                textAlign: TextAlign.center),
          ),
        for (final b in _rows) BkBookingTile(b: b, onTap: () => _open(b)),
      ]),
    );
  }
}

/// Calendar day view: one day at a time, bookings in time order under their
/// hour, previous / next day.
class _DayView extends StatefulWidget {
  final BookingSource source;
  final Future<void> Function() onChanged;
  const _DayView({super.key, required this.source, required this.onChanged});

  @override
  State<_DayView> createState() => _DayViewState();
}

class _DayViewState extends State<_DayView> {
  DateTime _day = bkToday();
  bool _loading = true;
  Object? _err;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _rows = bkList((await widget.source.bookings('day', day: bkIsoDay(_day)))['bookings']);
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _move(int days) {
    _day = _day.add(Duration(days: days));
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = bkLang(context);
    final byHour = <int, List<Map<String, dynamic>>>{};
    for (final b in _rows) {
      final dt = DateTime.tryParse(b['start'].toString())?.toUtc().add(const Duration(hours: 6));
      byHour.putIfAbsent(dt?.hour ?? 0, () => []).add(b);
    }
    final hours = byHour.keys.toList()..sort();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        child: Row(children: [
          IconButton(
              tooltip: t.bkgPrevDay,
              icon: const Icon(Icons.chevron_left_rounded),
              onPressed: () => _move(-1)),
          Expanded(
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                final d = await showDatePicker(
                    context: context,
                    initialDate: _day,
                    firstDate: bkToday().subtract(const Duration(days: 365)),
                    lastDate: bkToday().add(const Duration(days: 120)));
                if (d != null) {
                  _day = DateTime(d.year, d.month, d.day);
                  _fetch();
                }
              },
              child: Text(bkDayLabel(context, _day), textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          IconButton(
              tooltip: t.bkgNextDay,
              icon: const Icon(Icons.chevron_right_rounded),
              onPressed: () => _move(1)),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null
                ? bkErrorView(context, _err!, _fetch)
                : RefreshIndicator(
                    onRefresh: _fetch,
                    child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                      if (_rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(Gap.xl),
                          child: Text(t.bkgEmptyDay, textAlign: TextAlign.center),
                        ),
                      for (final h in hours) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
                          child: Text(bkDigits(lang, '${h.toString().padLeft(2, '0')}:00'),
                              style: Theme.of(context).textTheme.labelLarge),
                        ),
                        for (final b in byHour[h]!)
                          BkBookingTile(
                              b: b,
                              onTap: () async {
                                await Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => BookingDetailScreen(
                                        source: widget.source, bookingId: b['id'] as int, initial: b)));
                                await _fetch();
                              }),
                      ],
                    ]),
                  ),
      ),
    ]);
  }
}

/// The business adds a phone-call / walk-in booking (same free-slot engine,
/// same DB locks — it can never double-book either).
class BkManualSheet extends StatefulWidget {
  final BookingSource source;
  final List<Map<String, dynamic>> services;
  const BkManualSheet({super.key, required this.source, required this.services});

  @override
  State<BkManualSheet> createState() => _BkManualSheetState();
}

class _BkManualSheetState extends State<BkManualSheet> {
  late int? _svc = widget.services.where((s) => s['active'] != false).firstOrNull?['id'] as int?;
  String? _start;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (_svc == null || _start == null) {
      setState(() => _err = t.bkgPickTimeFirst);
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.source.addManual({
        'service': _svc,
        'start': _start,
        'name': _name.text.trim(),
        if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _err = bkOffline(e) ? t.bkgOfflineBody : (bkError(e) ?? t.bkgErrorBody));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final active = widget.services.where((s) => s['active'] != false).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.bkgAddBooking, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<int>(
            initialValue: _svc,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.bkgService),
            items: [
              for (final s in active)
                DropdownMenuItem(value: s['id'] as int, child: Text(s['name'].toString(), overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() {
              _svc = v;
              _start = null;
            }),
          ),
          const SizedBox(height: Gap.md),
          if (_svc != null)
            BkSlotPicker(
              key: ValueKey(_svc),
              load: (day) => widget.source.bizSlots(_svc!, day),
              onPick: (s) => _start = s['start'].toString(),
            ),
          const SizedBox(height: Gap.md),
          TextField(controller: _name, decoration: InputDecoration(labelText: t.bkgCustomerName)),
          const SizedBox(height: Gap.sm),
          TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: t.bkgCustomerPhoneOptional)),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: Gap.lg),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: _busy ? null : _save,
            child: Text(t.bkgSaveBooking),
          ),
        ]),
      ),
    );
  }
}
