import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import 'booking_detail_screen.dart' show showBkMoveSheet;
import 'booking_source.dart';
import 'booking_widgets.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// booking-bot — the CUSTOMER side: my bookings (upcoming / past), cancel or
/// move inside the business' own policy, and booking with a business from
/// its link. Logged in = no SMS code needed. No ads on these screens.
class MyBookingsScreen extends StatefulWidget {
  final BookingSource? source;
  final bool? guide;
  const MyBookingsScreen({super.key, this.source, this.guide});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

const _kGuideSeen = 'bk_my_guide_seen_v1';

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  late final BookingSource _src =
      widget.source ?? ApiBookingSource(context.read<AppState>().api);
  bool _loading = true;
  Object? _err;
  List<Map<String, dynamic>> _up = const [], _past = const [];
  bool _showGuide = false;

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
      final d = await _src.mine();
      _up = bkList(d['upcoming']);
      _past = bkList(d['past']);
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _bookNew() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BookWithBusinessScreen(source: _src)));
    await _load();
  }

  Future<void> _open(Map<String, dynamic> b) async {
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MyBookingSheet(source: _src, booking: b),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.bkgMyTitle), actions: [
        IconButton(
          tooltip: t.bkgHelp,
          icon: const Icon(Icons.help_outline_rounded),
          onPressed: () => setState(() => _showGuide = !_showGuide),
        ),
      ]),
      floatingActionButton: _loading || _err != null
          ? null
          : FloatingActionButton.extended(
              onPressed: _bookNew, icon: const Icon(Icons.add_rounded), label: Text(t.bkgBookNew)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
              ? bkErrorView(context, _err!, _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                    if (_showGuide || (_up.isEmpty && _past.isEmpty))
                      BookingGuideCard(business: false, onClose: _up.isEmpty && _past.isEmpty ? null : _closeGuide),
                    if (_up.isEmpty && _past.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(Gap.lg),
                        child: Text(t.bkgMyEmpty, textAlign: TextAlign.center),
                      ),
                    if (_up.isNotEmpty) _h(t.bkgUpcoming),
                    for (final b in _up) BkBookingTile(b: b, business: false, onTap: () => _open(b)),
                    if (_past.isNotEmpty) _h(t.bkgPast),
                    for (final b in _past) BkBookingTile(b: b, business: false, onTap: () => _open(b)),
                  ]),
                ),
    );
  }

  Widget _h(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Text(s, style: Theme.of(context).textTheme.titleMedium),
      );
}

class MyBookingSheet extends StatefulWidget {
  final BookingSource source;
  final Map<String, dynamic> booking;
  const MyBookingSheet({super.key, required this.source, required this.booking});

  @override
  State<MyBookingSheet> createState() => _MyBookingSheetState();
}

class _MyBookingSheetState extends State<MyBookingSheet> {
  late Map<String, dynamic> _b = widget.booking;
  bool _busy = false;
  String? _msg;

  Future<void> _do(String action, {String? start}) async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      _b = await widget.source.myAct(_b['id'] as int, action, start: start);
      _msg = action == 'cancelled' ? t.bkgCancelledMsg : t.bkgMovedMsg;
    } catch (e) {
      _msg = bkOffline(e) ? t.bkgOfflineBody : (bkError(e) ?? t.bkgErrorBody);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = bkLang(context);
    final can = (_b['can'] as List? ?? const []).map((e) => e.toString()).toSet();
    final active = ['requested', 'confirmed'].contains(_b['status']);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(bkMap(_b['business'])['name']?.toString() ?? '', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.xs),
        Text((_b['service'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
        Text((_b['when'] ?? '').toString()),
        const SizedBox(height: Gap.sm),
        Align(alignment: Alignment.centerLeft, child: BkStatusChip((_b['status'] ?? '').toString())),
        const SizedBox(height: Gap.md),
        if (active && can.isEmpty)
          Text(t.bkgTooLateToChange(bkDigits(lang, _b['cancel_hours'] ?? 0))),
        if (can.contains('reschedule'))
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
              icon: const Icon(Icons.edit_calendar_rounded),
              label: Text(t.bkgMove),
              onPressed: _busy
                  ? null
                  : () async {
                      final s = await showBkMoveSheet(
                          context, (day) => widget.source.mySlots(_b['id'] as int, day));
                      if (s != null) await _do('reschedule', start: s);
                    },
            ),
          ),
        if (can.contains('cancelled'))
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(Icons.event_busy_rounded),
            label: Text(t.bkgCancelBooking),
            onPressed: _busy ? null : () => _do('cancelled'),
          ),
        if (_msg != null) Padding(padding: const EdgeInsets.only(top: Gap.md), child: Text(_msg!)),
      ]),
    );
  }
}

/// Book with a business from its link (lifeassisto.com/b/<name>).
class BookWithBusinessScreen extends StatefulWidget {
  final BookingSource source;
  final String? slug;
  const BookWithBusinessScreen({super.key, required this.source, this.slug});

  @override
  State<BookWithBusinessScreen> createState() => _BookWithBusinessScreenState();
}

class _BookWithBusinessScreenState extends State<BookWithBusinessScreen> {
  final _link = TextEditingController();
  final _note = TextEditingController();
  String? _slug;
  Map<String, dynamic>? _page;
  int? _svc;
  String? _start;
  bool _busy = false;
  String? _err;
  Map<String, dynamic>? _done;

  @override
  void initState() {
    super.initState();
    if (widget.slug != null) {
      _link.text = widget.slug!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  @override
  void dispose() {
    _link.dispose();
    _note.dispose();
    super.dispose();
  }

  String _m(Object e) {
    final t = AppLocalizations.of(context);
    if (bkStatus(e) == 404) return t.bkgLinkNotFound;
    return bkOffline(e) ? t.bkgOfflineBody : (bkError(e) ?? t.bkgErrorBody);
  }

  Future<void> _open() async {
    final t = AppLocalizations.of(context);
    final slug = bkSlugFrom(_link.text);
    if (slug == null) {
      setState(() => _err = t.bkgLinkInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final p = await widget.source.publicPage(slug);
      _slug = slug;
      _page = p;
      final svcs = bkList(p['services']);
      _svc = svcs.length == 1 ? svcs.first['id'] as int : null;
    } catch (e) {
      _err = _m(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _book() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      _done = await widget.source.book(_slug!, _svc!, _start!, _note.text.trim());
    } catch (e) {
      _err = _m(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.bkgBookNew)),
      body: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: _done != null ? _success(t) : _form(t)),
    );
  }

  List<Widget> _success(AppLocalizations t) => [
        const SizedBox(height: Gap.xl),
        Icon(Icons.event_available_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: Gap.md),
        Text(_done!['status'] == 'confirmed' ? t.bkgBookedTitle : t.bkgRequestedTitle,
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.sm),
        Text('${_done!['service']} — ${_done!['when']}', textAlign: TextAlign.center),
        const SizedBox(height: Gap.sm),
        Text(_done!['status'] == 'confirmed' ? t.bkgBookedBody : t.bkgRequestedBody, textAlign: TextAlign.center),
        const SizedBox(height: Gap.xl),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.bkgDone),
        ),
      ];

  List<Widget> _form(AppLocalizations t) {
    final lang = bkLang(context);
    final p = _page;
    final svcs = p == null ? const <Map<String, dynamic>>[] : bkList(p['services']);
    return [
      if (p == null) ...[
        Text(t.bkgLinkTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.xs),
        Text(t.bkgLinkBody),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _link,
          decoration: InputDecoration(labelText: t.bkgLinkLabel, hintText: 'lifeassisto.com/b/…'),
          onSubmitted: (_) => _open(),
        ),
        const SizedBox(height: Gap.md),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _busy ? null : _open,
          child: Text(t.bkgOpenLink),
        ),
      ] else ...[
        Text((p['title'] ?? '').toString(), style: Theme.of(context).textTheme.titleLarge),
        if ((p['about'] ?? '').toString().isNotEmpty) Text(p['about'].toString()),
        if ((p['address'] ?? '').toString().isNotEmpty)
          Text(p['address'].toString(), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Gap.md),
        if (p['taking_bookings'] != true)
          Text(t.bkgNotTaking)
        else ...[
          Text(t.bkgService, style: Theme.of(context).textTheme.titleSmall),
          for (final s in svcs)
            ListTile(
              minVerticalPadding: Gap.md,
              selected: _svc == s['id'],
              leading: Icon(_svc == s['id'] ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded),
              title: Text(s['name'].toString()),
              subtitle: Text([
                t.bkgMinutes(bkDigits(lang, s['duration_min'] ?? 0)),
                if ((s['price_bdt'] ?? 0) != 0) t.bkgPriceShort(bkDigits(lang, s['price_bdt'])),
              ].join(' · ')),
              onTap: () => setState(() {
                _svc = s['id'] as int;
                _start = null;
              }),
            ),
          if (_svc != null) ...[
            const SizedBox(height: Gap.md),
            BkSlotPicker(
              key: ValueKey(_svc),
              load: (day) => widget.source.publicSlots(_slug!, _svc!, day),
              onPick: (s) => setState(() => _start = s['start'].toString()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
                controller: _note,
                inputFormatters: [LengthLimitingTextInputFormatter(300)],
                decoration: InputDecoration(labelText: t.bkgNoteOptional)),
            Text(t.bkgPolicyLine(bkDigits(lang, p['cancel_hours'] ?? 0)),
                style: Theme.of(context).textTheme.bodySmall),
            Text(t.bkgPrivacyLine, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.md),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _busy || _start == null ? null : _book,
              child: Text(t.bkgConfirmBooking),
            ),
          ],
        ],
      ],
      if (_err != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
    ];
  }
}
