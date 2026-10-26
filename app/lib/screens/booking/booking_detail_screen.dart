import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../business/bizagent/seller_inbox_screen.dart' show SellerChatScreen;
import 'booking_source.dart';
import 'booking_widgets.dart';

/// booking-bot — one booking, business side: who / what / when, call or chat
/// the customer (their phone is visible only to this business), confirm,
/// mark done / no-show, move, cancel, block the number.
class BookingDetailScreen extends StatefulWidget {
  final BookingSource source;
  final int bookingId;
  final Map<String, dynamic>? initial;
  const BookingDetailScreen({super.key, required this.source, required this.bookingId, this.initial});

  @override
  State<BookingDetailScreen> createState() => _BookingDetailScreenState();
}

class _BookingDetailScreenState extends State<BookingDetailScreen> {
  Map<String, dynamic>? _b;
  Object? _loadErr;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _b = widget.initial;
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.source.booking(widget.bookingId);
      if (mounted) {
        setState(() {
          _b = d;
          _loadErr = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadErr = e);
    }
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  String _msg(Object e) {
    final t = AppLocalizations.of(context);
    return bkOffline(e) ? t.bkgOfflineBody : (bkError(e) ?? t.bkgErrorBody);
  }

  Future<void> _act(String action, {String? start}) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final d = await widget.source.act(widget.bookingId, action, start: start);
      setState(() => _b = d);
      _snack(t.bkgSaved);
    } catch (e) {
      _snack(_msg(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _cancel() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.bkgCancelQ),
        content: Text(t.bkgCancelQBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.bkgKeep)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.bkgCancelBooking)),
        ],
      ),
    );
    if (ok == true) await _act('cancelled');
  }

  Future<void> _reschedule() async {
    final b = _b!;
    final start = await showBkMoveSheet(
        context, (day) => widget.source.bizSlots(b['service_id'] as int, day, exclude: widget.bookingId));
    if (start != null) await _act('reschedule', start: start);
  }

  Future<void> _call(String phone) async {
    final t = AppLocalizations.of(context);
    if (!await launchUrl(Uri.parse('tel:$phone'))) _snack(t.bkgCantOpen);
  }

  Future<void> _chat(Map<String, dynamic> b) async {
    final t = AppLocalizations.of(context);
    final tid = b['thread_id'];
    if (tid is int) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SellerChatScreen(threadId: tid)));
      return;
    }
    final digits = b['customer_phone'].toString().replaceAll(RegExp(r'\D'), '');
    if (!await launchUrl(Uri.parse('https://wa.me/$digits'), mode: LaunchMode.externalApplication)) {
      _snack(t.bkgCantOpen);
    }
  }

  Future<void> _block(bool block) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await widget.source.block(_b!['customer_phone'].toString(), block);
      _snack(block ? t.bkgBlocked : t.bkgUnblocked);
      await _load();
    } catch (e) {
      _snack(_msg(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final b = _b;
    return Scaffold(
      appBar: AppBar(title: Text(t.bkgDetailTitle)),
      body: b == null
          ? (_loadErr != null
              ? bkErrorView(context, _loadErr!, _load)
              : const Center(child: CircularProgressIndicator()))
          : _body(t, b),
    );
  }

  Widget _body(AppLocalizations t, Map<String, dynamic> b) {
    final can = (b['can'] as List? ?? const []).map((e) => e.toString()).toSet();
    final phone = (b['customer_phone'] ?? '').toString();
    final name = (b['customer_name'] ?? '').toString();
    Widget btn(IconData icon, String label, VoidCallback? f, {bool filled = false}) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: filled
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                  icon: Icon(icon),
                  label: Text(label),
                  onPressed: _busy ? null : f)
              : OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
                  icon: Icon(icon),
                  label: Text(label),
                  onPressed: _busy ? null : f),
        );
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isNotEmpty ? name : t.bkgNoName, style: Theme.of(context).textTheme.titleLarge),
            if (phone.isNotEmpty) Text(bkDigits(bkLang(context), phone)),
            const SizedBox(height: Gap.sm),
            Text((b['service'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
            if ((b['staff'] ?? '').toString().isNotEmpty) Text(t.bkgWith(b['staff'].toString())),
            Text((b['when'] ?? '').toString()),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              BkStatusChip((b['status'] ?? '').toString()),
              Text(t.bkgVia(bkChannelText(t, (b['channel'] ?? '').toString())),
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
            if ((b['note'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(b['note'].toString()),
            ],
            if (b['stopped'] == true) ...[
              const SizedBox(height: Gap.sm),
              Text(t.bkgCustomerStopped, style: Theme.of(context).textTheme.bodySmall),
            ],
          ]),
        ),
      ),
      const SizedBox(height: Gap.md),
      if (phone.isNotEmpty) ...[
        btn(Icons.call_rounded, t.bkgCall, () => _call(phone)),
        btn(Icons.chat_rounded, t.bkgChat, () => _chat(b)),
      ],
      if (can.contains('confirmed')) btn(Icons.check_rounded, t.bkgConfirm, () => _act('confirmed'), filled: true),
      if (can.contains('done')) btn(Icons.task_alt_rounded, t.bkgMarkDone, () => _act('done'), filled: true),
      if (can.contains('no_show')) btn(Icons.person_off_outlined, t.bkgMarkNoShow, () => _act('no_show')),
      if (can.contains('reschedule')) btn(Icons.edit_calendar_rounded, t.bkgMove, _reschedule),
      if (can.contains('cancelled')) btn(Icons.event_busy_rounded, t.bkgCancelBooking, _cancel),
      if (phone.isNotEmpty)
        btn(Icons.block_rounded, b['blocked'] == true ? t.bkgUnblock : t.bkgBlock, () => _block(b['blocked'] != true)),
    ]);
  }
}

/// Bottom sheet: pick a new free time (server slots only). Returns ISO start.
Future<String?> showBkMoveSheet(BuildContext context, Future<Map<String, dynamic>> Function(String day) load) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _MoveSheet(load: load),
  );
}

class _MoveSheet extends StatefulWidget {
  final Future<Map<String, dynamic>> Function(String day) load;
  const _MoveSheet({required this.load});

  @override
  State<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<_MoveSheet> {
  String? _start;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.bkgMoveTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.md),
        BkSlotPicker(load: widget.load, onPick: (s) => setState(() => _start = s['start'].toString())),
        const SizedBox(height: Gap.lg),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _start == null ? null : () => Navigator.pop(context, _start),
          child: Text(t.bkgMoveHere),
        ),
      ]),
    );
  }
}
