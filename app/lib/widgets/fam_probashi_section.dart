import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'fam_sharing_strings.dart';
import 'wrapped_share.dart';

/// #75 PROBASHI FAMILY (SPEC v2.1 §21) — ADVANCED upgrade of the FAMILY
/// good-bit, for expatriate Bangladeshis. Self-contained, clearly bounded,
/// embedded as ONE tab in FamilyScreen. Does not touch the famacct section (D5).
///
///   • two-timezone view — MY time + family-in-BD time (Asia/Dhaka, UTC+06:00,
///     no DST), computed with the device's own offset. Mirrors backend
///     family_sharing.two_timezone_now().
///   • scheduled calls across timezones — proposes slots that are polite at BOTH
///     ends, and (honestly) hands the chosen slot to the existing reminders/
///     meetings feature rather than placing a call itself.
///   • remittance CONTEXT — a reminder to SEND money. NEVER a wallet: Assisto
///     never holds, moves, or transfers money. The amount is a free-form note.
///   • a probashi share card (reuses the RepaintBoundary->PNG flow).
class FamProbashiSection extends StatefulWidget {
  const FamProbashiSection({super.key});

  @override
  State<FamProbashiSection> createState() => _FamProbashiSectionState();
}

class _FamProbashiSectionState extends State<FamProbashiSection> {
  static const int _bdOffsetMin = 6 * 60; // Asia/Dhaka UTC+06:00, no DST.
  final GlobalKey _boundaryKey = GlobalKey();

  // Remittance reminder context (NOT a wallet — pure reminder state).
  final _amount = TextEditingController();
  bool _weekly = false;
  DateTime? _lastSent;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  int get _myOffsetMin => DateTime.now().timeZoneOffset.inMinutes;

  DateTime get _bdNow => DateTime.now().toUtc().add(const Duration(minutes: _bdOffsetMin));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
      children: [
        _header(scheme),
        const SizedBox(height: Gap.md),
        _twoTimeCard(scheme),
        const SizedBox(height: Gap.md),
        _callsCard(scheme),
        const SizedBox(height: Gap.md),
        _remitCard(scheme),
        const SizedBox(height: Gap.md),
        RepaintBoundary(key: _boundaryKey, child: _shareCard()),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          onPressed: _shareImage,
          icon: const Icon(Icons.image_rounded),
          label: Text(famLabel(context, 'famProbashiShareCard')),
        ),
      ],
    );
  }

  Widget _header(ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.public_rounded, color: Colors.white),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(famLabel(context, 'famProbashiTitle'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(famLabel(context, 'famProbashiIntro'),
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ]),
      );

  // ---- two-timezone view ----
  Widget _twoTimeCard(ColorScheme scheme) {
    final my = DateTime.now();
    final bd = _bdNow;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(children: [
          Row(children: [
            Expanded(child: _clock(famLabel(context, 'famProbashiMyTime'), my, scheme)),
            Container(
                width: 1, height: 56, color: scheme.outlineVariant),
            Expanded(child: _clock(famLabel(context, 'famProbashiBdTime'), bd, scheme)),
          ]),
          const SizedBox(height: Gap.sm),
          Text(_diffLabel(), style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Text(famLabel(context, 'famProbashiTzNote'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _clock(String label, DateTime dt, ColorScheme scheme) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return Column(children: [
      Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.xs),
      Text('$hh:$mm',
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
    ]);
  }

  String _diffLabel() {
    // BD offset minus my offset, in minutes.
    final diff = _bdOffsetMin - _myOffsetMin;
    if (diff == 0) return famLabel(context, 'famProbashiDiffSame');
    final hours = (diff.abs() / 60);
    final hLabel = AppLocalizations.of(context).famProbashiHours(famNum(context, hours.round()));
    return diff > 0
        ? AppLocalizations.of(context).famProbashiDiffAhead(hLabel)
        : AppLocalizations.of(context).famProbashiDiffBehind(hLabel);
  }

  // ---- call slots (polite at both ends) ----
  List<DateTime> _politeSlots() {
    // Compute UTC instants over the next 24h; keep those polite (8..22) at both
    // my local time and BD time. Mirrors backend propose_call_slots().
    final out = <DateTime>[];
    var base = DateTime.now().toUtc();
    base = base.subtract(Duration(
        minutes: base.minute % 30, seconds: base.second, milliseconds: base.millisecond));
    base = base.add(const Duration(minutes: 30));
    for (int i = 0; i < 48; i++) {
      final utc = base.add(Duration(minutes: 30 * i));
      final my = utc.toLocal();
      final bd = utc.add(const Duration(minutes: _bdOffsetMin));
      final okMine = my.hour >= 8 && my.hour < 22;
      final okBd = bd.hour >= 8 && bd.hour < 22;
      if (okMine && okBd) out.add(utc);
      if (out.length >= 6) break;
    }
    return out;
  }

  Widget _callsCard(ColorScheme scheme) {
    final slots = _politeSlots();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.schedule_rounded, size: 18),
            const SizedBox(width: Gap.sm),
            Text(famLabel(context, 'famProbashiCallsTitle'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(famLabel(context, 'famProbashiCallsBody'),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          if (slots.isEmpty)
            Text(famLabel(context, 'famProbashiCallsEmpty'),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))
          else
            for (final utc in slots) _slotRow(utc, scheme),
          const SizedBox(height: Gap.xs),
          Row(children: [
            Icon(Icons.info_outline_rounded, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(famLabel(context, 'famProbashiScheduleNote'),
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _slotRow(DateTime utc, ColorScheme scheme) {
    final my = utc.toLocal();
    final bd = utc.add(const Duration(minutes: _bdOffsetMin));
    String hm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.call_rounded, size: 18),
      title: Text('${famLabel(context, 'famProbashiMyTime')} ${hm(my)}'
          '  ·  ${famLabel(context, 'famProbashiBdTime')} ${hm(bd)}'),
      trailing: TextButton(
        onPressed: () => _scheduleCall(utc),
        child: Text(famLabel(context, 'famProbashiScheduleCall')),
      ),
    );
  }

  Future<void> _scheduleCall(DateTime utc) async {
    // HONEST: this only adds a reminder for the chosen time (the integrator can
    // route it into meetings/calls). It does NOT place a call from here.
    final my = utc.toLocal();
    // m2-reality: the Reminder field is `due_at` (was `due` -> the reminder
    // was saved with NO time), and a failed save no longer claims success.
    var ok = true;
    try {
      await context.read<AppState>().api.createItem('reminders', {
        'title': famLabel(context, 'famProbashiScheduleCall'),
        'due_at': my.toIso8601String(),
      });
    } catch (_) {
      ok = false;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? famLabel(context, 'famProbashiScheduleNote')
              : AppLocalizations.of(context).grpActionFailed)));
    }
  }

  // ---- remittance reminder CONTEXT (never a wallet) ----
  Widget _remitCard(ColorScheme scheme) {
    final nextDue = _lastSent == null
        ? null
        : _lastSent!.add(Duration(days: _weekly ? 7 : 30));
    String d(DateTime x) =>
        '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.volunteer_activism_rounded, size: 18),
            const SizedBox(width: Gap.sm),
            Text(famLabel(context, 'famProbashiRemitTitle'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(famLabel(context, 'famProbashiRemitBody'),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _amount,
            decoration: InputDecoration(
                labelText: famLabel(context, 'famProbashiRemitAmount'),
                isDense: true),
          ),
          const SizedBox(height: Gap.sm),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                  value: false,
                  label: Text(famLabel(context, 'famProbashiRemitCadenceM'))),
              ButtonSegment(
                  value: true,
                  label: Text(famLabel(context, 'famProbashiRemitCadenceW'))),
            ],
            selected: {_weekly},
            onSelectionChanged: (s) => setState(() => _weekly = s.first),
          ),
          const SizedBox(height: Gap.sm),
          if (_lastSent != null) ...[
            Text(AppLocalizations.of(context).famProbashiRemitLastSent(d(_lastSent!)),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            if (nextDue != null)
              Text(AppLocalizations.of(context).famProbashiRemitNextDue(d(nextDue)),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () => setState(() => _lastSent = DateTime.now()),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(famLabel(context, 'famProbashiRemitMarkSent')),
            ),
          ),
          const SizedBox(height: Gap.sm),
          // HARD, EXPLICIT: never a wallet.
          Container(
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              color: Brand.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(children: [
              const Icon(Icons.account_balance_wallet_rounded,
                  size: 16, color: Brand.warning),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(famLabel(context, 'famProbashiNeverWallet'),
                    style: const TextStyle(
                        fontSize: 12, color: Brand.warning)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  // ---- probashi share card ----
  Widget _shareCard() {
    final my = DateTime.now();
    final bd = _bdNow;
    String hm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.lg),
          decoration: const BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
          ),
          child: Row(children: [
            const Icon(Icons.public_rounded, color: Colors.white),
            const SizedBox(width: Gap.md),
            Text(famLabel(context, 'famProbashiTitle'),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Expanded(
              child: Column(children: [
                Text(famLabel(context, 'famProbashiMyTime'),
                    style: const TextStyle(color: Colors.black54, fontSize: 12)),
                Text(hm(my),
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 24,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
            const Icon(Icons.swap_horiz_rounded, color: Colors.black38),
            Expanded(
              child: Column(children: [
                Text(famLabel(context, 'famProbashiBdTime'),
                    style: const TextStyle(color: Colors.black54, fontSize: 12)),
                Text(hm(bd),
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 24,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _shareImage() async {
    final ok = await WrappedShare.shareAsImage(
        _boundaryKey, famLabel(context, 'famProbashiTitle'));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(famLabel(context, 'famCardShareFailed'))));
    }
  }
}
