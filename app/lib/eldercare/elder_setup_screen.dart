import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api.dart' show ApiException;
import '../l10n/app_localizations.dart';
import '../ds/ds.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/chatnav.dart';
import 'elder_common.dart';

/// fcelder — ELDER SETUP BY A CHILD, the CHILD's phone.
///
/// 1. pick the parent from the family in one tap (empty state: why + a big
///    "Add family member" + how);
/// 2. choose what to turn on (Easy home, Care Call, Silent Watch: quiet
///    hours, day window, nearby person);
/// 3. a QR (https://lifeassisto.com/e/<CODE>) + the same 8-letter code, live
///    for 15 minutes. The parent's phone scans it with its own camera (or
///    types the code), hears the consent in Bangla and taps one big YES —
///    the server then configures everything at once and tells this phone.
class ElderSetupScreen extends StatefulWidget {
  const ElderSetupScreen({super.key, this.debugPeople, this.debugPair});

  /// Tests / gallery.
  final List<Map<String, dynamic>>? debugPeople;
  final Map<String, dynamic>? debugPair;

  @override
  State<ElderSetupScreen> createState() => _ElderSetupScreenState();
}

class _ElderSetupScreenState extends State<ElderSetupScreen> {
  List<Map<String, dynamic>>? _people;
  String? _error;
  int? _elderId;
  bool _easy = true, _care = true, _watch = true;
  int _hours = 4;
  TimeOfDay _start = const TimeOfDay(hour: 7, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 22, minute: 0);
  int? _nearbyId;
  Map<String, dynamic>? _pair;
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _pair = widget.debugPair;
    _load();
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && _pair != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.debugPeople != null) {
      setState(() => _people = widget.debugPeople);
      return;
    }
    final api = ElderHooks.api(context);
    if (api == null) return;
    try {
      final p = await api.people();
      if (mounted) {
        setState(() {
          _people = p;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = AppLocalizations.of(context).fceOffline);
    }
  }

  String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _make() async {
    final api = ElderHooks.api(context);
    final t = AppLocalizations.of(context);
    if (api == null || _elderId == null) return;
    if (_start.hour * 60 + _start.minute >= _end.hour * 60 + _end.minute) {
      setState(() => _error = t.fceSetupDayInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.startSetup({
        'elder_user_id': _elderId,
        'easy_home': _easy,
        'carecall': _care,
        'silent_watch': _watch,
        'hours': _hours,
        'day_start': _hhmm(_start),
        'day_end': _hhmm(_end),
        if (_nearbyId != null) 'nearby_user_id': _nearbyId,
      });
      r['made_at'] = clock.now().millisecondsSinceEpoch;
      if (mounted) setState(() => _pair = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = t.fceOffline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.fceSetupTitle)),
      body: _pair != null ? _qr(t) : _form(t),
    );
  }

  Widget _form(AppLocalizations t) {
    final ds = DsTokens.of(context);
    final bn = ElderHooks.lang(context) == 'bn';
    final people = _people;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
      children: [
        Text(t.fceSetupBenefit, style: AType.titleMedium.copyWith(color: ds.muted)),
        const SizedBox(height: Gap.lg),
        Text(t.fceSetupWho, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700, color: ds.text)),
        const SizedBox(height: Gap.sm),
        if (people == null && _error == null)
          DsSkeleton.card(lines: 2)
        else if (people != null && people.isEmpty)
          _empty(t)
        else if (people != null)
          // designv2: people from My Circle in one tap — one scrolling row
          DsChipRow(
            padding: EdgeInsets.zero,
            children: [
              for (final p in people)
                DsChip(
                  key: Key('fce-who-${p['user_id']}'),
                  icon: Icons.person_rounded,
                  label: '${p['name']}',
                  selected: _elderId == p['user_id'],
                  onSelected: (_) => setState(() => _elderId = p['user_id'] as int?),
                ),
            ],
          ),
        if (people != null && people.isNotEmpty) ...[
          const SizedBox(height: Gap.lg),
          DsCard(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.fceSetupWhat, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700, color: ds.text)),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _easy,
              onChanged: (v) => setState(() => _easy = v),
              title: Text(t.fceSetupEasyHome),
              subtitle: Text(t.fceSetupEasyHomeSub)),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _care,
              onChanged: (v) => setState(() => _care = v),
              title: Text(t.fceSetupCareCall),
              subtitle: Text(t.fceSetupCareCallSub)),
          SwitchListTile(
              key: const Key('fce-setup-watch'),
              contentPadding: EdgeInsets.zero,
              value: _watch,
              onChanged: (v) => setState(() => _watch = v),
              title: Text(t.fceWatchTitle),
              subtitle: Text(t.fceSetupWatchSub)),
          if (_watch) ...[
            const SizedBox(height: Gap.sm),
            Text(t.fceSetupHours2, style: AType.titleMedium.copyWith(color: ds.text)),
            const SizedBox(height: Gap.xs),
            DsChipRow(padding: EdgeInsets.zero, children: [
              for (final h in const [3, 4, 6, 8])
                DsChip(
                    label: t.fceHoursN(elderDigits(h, bn)),
                    selected: _hours == h,
                    onSelected: (_) => setState(() => _hours = h)),
            ]),
            const SizedBox(height: Gap.md),
            Text(t.fceSetupDay, style: AType.titleMedium.copyWith(color: ds.text)),
            const SizedBox(height: Gap.xs),
            DsChipRow(padding: EdgeInsets.zero, children: [
              DsChip(
                  icon: Icons.wb_sunny_outlined,
                  label: elderHhmm(_start.hour * 60 + _start.minute, bn),
                  onSelected: (_) async {
                    final v = await showTimePicker(context: context, initialTime: _start);
                    if (v != null && mounted) setState(() => _start = v);
                  }),
              DsChip(
                  icon: Icons.nightlight_outlined,
                  label: elderHhmm(_end.hour * 60 + _end.minute, bn),
                  onSelected: (_) async {
                    final v = await showTimePicker(context: context, initialTime: _end);
                    if (v != null && mounted) setState(() => _end = v);
                  }),
            ]),
            const SizedBox(height: Gap.md),
            Text(t.fceSetupNearby, style: AType.titleMedium.copyWith(color: ds.text)),
            Text(t.fceSetupNearbyWhy, style: AType.bodyMedium.copyWith(color: ds.muted)),
            const SizedBox(height: Gap.xs),
            DsChipRow(padding: EdgeInsets.zero, children: [
              DsChip(
                  label: t.fceSetupNearbyNone,
                  selected: _nearbyId == null,
                  onSelected: (_) => setState(() => _nearbyId = null)),
              for (final p in people)
                if (p['user_id'] != _elderId)
                  DsChip(
                      label: '${p['name']}',
                      selected: _nearbyId == p['user_id'],
                      onSelected: (_) => setState(() => _nearbyId = p['user_id'] as int?)),
            ]),
          ],
            ]),
          ),
          const SizedBox(height: Gap.lg),
          DsButton(
            key: const Key('fce-setup-make'),
            expand: true,
            busy: _busy,
            onPressed: _elderId == null ? null : _make,
            icon: Icons.qr_code_2_rounded,
            label: _elderId == null ? t.fceSetupPickFirst : t.fceSetupMakeQr,
          ),
        ],
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: Gap.md),
              child: Text(_error!, style: AType.titleMedium.copyWith(color: ds.dangerInk))),
      ],
    );
  }

  Widget _empty(AppLocalizations t) => DsEmptyState(
        icon: Icons.family_restroom_rounded,
        title: t.fceSetupEmptyTitle,
        benefit: t.fceSetupEmptyBody,
        actionLabel: t.fceSetupEmptyCta,
        actionKey: const Key('fce-setup-add'),
        onAction: () => ChatNav.push(context, 'family'),
      );

  Widget _qr(AppLocalizations t) {
    final p = _pair!;
    final bn = ElderHooks.lang(context) == 'bn';
    final name = '${p['elder_name'] ?? ''}';
    final code = '${p['code'] ?? ''}';
    final made = (p['made_at'] as int?) ?? clock.now().millisecondsSinceEpoch;
    final ttl = (p['ttl_s'] as num?)?.toInt() ?? 900;
    final remainS = ttl - (clock.now().millisecondsSinceEpoch - made) ~/ 1000;
    final expired = remainS <= 0;
    final left = (remainS + 59) ~/ 60; // whole minutes, rounded up: 900 s -> 15
    final ds = DsTokens.of(context);
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
      children: [
        Text(t.fceSetupQrTitle(name),
            style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800, color: ds.text)),
        const SizedBox(height: Gap.md),
        Center(
          child: Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(DsRadius.card),
                border: Border.all(color: ds.border),
                boxShadow: DsPerf.liteOf(context) ? null : ds.shadows),
            child: Opacity(
              opacity: expired ? 0.15 : 1,
              child: QrImageView(
                  key: const Key('fce-qr'), data: '${p['url'] ?? ''}', size: 220, backgroundColor: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        Center(
          child: SelectableText(elderDigits(code, bn),
              key: const Key('fce-code'),
              style: AType.headlineLarge.copyWith(fontWeight: FontWeight.w800, letterSpacing: 4, color: ds.text)),
        ),
        Center(
          child: Text(expired ? t.fceSetupExpired : t.fceSetupExpires(elderDigits(left, bn)),
              style: AType.titleMedium.copyWith(color: expired ? ds.dangerInk : ds.muted)),
        ),
        const SizedBox(height: Gap.lg),
        _step(1, t.fceSetupQrStep1(name), bn),
        _step(2, t.fceSetupQrStep2, bn),
        _step(3, t.fceSetupQrStep3(name), bn),
        const SizedBox(height: Gap.md),
        Text(t.fceSetupDoneHint(name), style: AType.titleMedium.copyWith(color: ds.muted)),
        const SizedBox(height: Gap.lg),
        DsButton.secondary(
          expand: true,
          busy: _busy,
          onPressed: _elderId == null ? () => setState(() => _pair = null) : _make,
          icon: Icons.refresh_rounded,
          label: t.fceSetupNewCode,
        ),
      ],
    );
  }

  Widget _step(int n, String text, bool bn) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DsStepNumber(n),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(text, style: AType.titleMedium.copyWith(color: DsTokens.of(context).text))),
        ]),
      );
}
