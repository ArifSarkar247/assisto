import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api.dart' show ApiException;
import '../l10n/app_localizations.dart';
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
    final scheme = Theme.of(context).colorScheme;
    final bn = ElderHooks.lang(context) == 'bn';
    final people = _people;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
      children: [
        Text(t.fceSetupBenefit, style: AType.titleMedium.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.lg),
        Text(t.fceSetupWho, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        if (people == null && _error == null)
          const Center(child: Padding(padding: EdgeInsets.all(Gap.lg), child: CircularProgressIndicator()))
        else if (people != null && people.isEmpty)
          _empty(t)
        else if (people != null)
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final p in people)
                ChoiceChip(
                  key: Key('fce-who-${p['user_id']}'),
                  label: Text('${p['name']}'),
                  selected: _elderId == p['user_id'],
                  onSelected: (_) => setState(() => _elderId = p['user_id'] as int?),
                ),
            ],
          ),
        if (people != null && people.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          Text(t.fceSetupWhat, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
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
            Text(t.fceSetupHours, style: AType.titleMedium),
            Wrap(spacing: Gap.sm, children: [
              for (final h in const [3, 4, 6, 8])
                ChoiceChip(
                    label: Text(t.fceHoursN(elderDigits(h, bn))),
                    selected: _hours == h,
                    onSelected: (_) => setState(() => _hours = h)),
            ]),
            const SizedBox(height: Gap.md),
            Text(t.fceSetupDay, style: AType.titleMedium),
            Wrap(spacing: Gap.sm, children: [
              ActionChip(
                  avatar: const Icon(Icons.wb_sunny_outlined),
                  label: Text(elderHhmm(_start.hour * 60 + _start.minute, bn)),
                  onPressed: () async {
                    final v = await showTimePicker(context: context, initialTime: _start);
                    if (v != null && mounted) setState(() => _start = v);
                  }),
              ActionChip(
                  avatar: const Icon(Icons.nightlight_outlined),
                  label: Text(elderHhmm(_end.hour * 60 + _end.minute, bn)),
                  onPressed: () async {
                    final v = await showTimePicker(context: context, initialTime: _end);
                    if (v != null && mounted) setState(() => _end = v);
                  }),
            ]),
            const SizedBox(height: Gap.md),
            Text(t.fceSetupNearby, style: AType.titleMedium),
            Text(t.fceSetupNearbyWhy, style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              ChoiceChip(
                  label: Text(t.fceSetupNearbyNone),
                  selected: _nearbyId == null,
                  onSelected: (_) => setState(() => _nearbyId = null)),
              for (final p in people)
                if (p['user_id'] != _elderId)
                  ChoiceChip(
                      label: Text('${p['name']}'),
                      selected: _nearbyId == p['user_id'],
                      onSelected: (_) => setState(() => _nearbyId = p['user_id'] as int?)),
            ]),
          ],
          const SizedBox(height: Gap.xl),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              key: const Key('fce-setup-make'),
              onPressed: _elderId == null || _busy ? null : _make,
              icon: const Icon(Icons.qr_code_2_rounded),
              label: Text(_elderId == null ? t.fceSetupPickFirst : t.fceSetupMakeQr,
                  style: AType.titleMedium),
            ),
          ),
        ],
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: Gap.md),
              child: Text(_error!, style: AType.titleMedium.copyWith(color: scheme.error))),
      ],
    );
  }

  Widget _empty(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Icon(Icons.family_restroom_rounded, size: 48, color: scheme.primary),
          const SizedBox(height: Gap.sm),
          Text(t.fceSetupEmptyTitle, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.fceSetupEmptyBody, style: AType.bodyLarge),
          const SizedBox(height: Gap.md),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              key: const Key('fce-setup-add'),
              onPressed: () => ChatNav.push(context, 'family'),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(t.fceSetupEmptyCta),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _qr(AppLocalizations t) {
    final p = _pair!;
    final bn = ElderHooks.lang(context) == 'bn';
    final name = '${p['elder_name'] ?? ''}';
    final code = '${p['code'] ?? ''}';
    final made = (p['made_at'] as int?) ?? clock.now().millisecondsSinceEpoch;
    final ttl = (p['ttl_s'] as num?)?.toInt() ?? 900;
    final left = (ttl - (clock.now().millisecondsSinceEpoch - made) ~/ 1000) ~/ 60;
    final expired = left < 0;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
      children: [
        Text(t.fceSetupQrTitle(name), style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.md),
        Center(
          child: Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
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
              style: AType.headlineLarge.copyWith(fontWeight: FontWeight.w800, letterSpacing: 4)),
        ),
        Center(
          child: Text(expired ? t.fceSetupExpired : t.fceSetupExpires(elderDigits(left + 1, bn)),
              style: AType.titleMedium.copyWith(color: expired ? scheme.error : scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: Gap.lg),
        _step(1, t.fceSetupQrStep1(name), bn),
        _step(2, t.fceSetupQrStep2, bn),
        _step(3, t.fceSetupQrStep3(name), bn),
        const SizedBox(height: Gap.md),
        Text(t.fceSetupDoneHint(name), style: AType.titleMedium.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.lg),
        SizedBox(
          height: 52,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _make,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.fceSetupNewCode),
          ),
        ),
      ],
    );
  }

  Widget _step(int n, String text, bool bn) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 14, child: Text(elderDigits(n, bn))),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(text, style: AType.titleMedium)),
        ]),
      );
}
