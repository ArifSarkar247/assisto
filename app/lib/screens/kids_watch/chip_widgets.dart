import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../kids_watch_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../vehicle/veh_setup.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../../widgets/where_to_buy.dart';
import 'school_plan_form.dart';
import '../../widgets/local_counter.dart';

/// chipbuy (owner 2 Nov) — TRACKER CHIP on the child card: a small 4G GPS
/// chip for a school bag or shoe. It is a vehicle-tracker device on our own
/// tracker server (same pairing window, same SMS setup screen VehSetupView,
/// same decoders) shown here, never in the vehicle list.
///
/// Honest by design: battery shows "not reported" when the model does not
/// send it; history is guardian-only and kept 48 h; the child (if on
/// Assisto) is told it is on and who can see it; it is free (safety).

/// Chip brands sold in Bangladesh -> protocol (teltonika is a car box).
const List<(String, String)> kChipBrands = [
  ('concox', 'gt06'),
  ('sinotrack', 'h02'),
  ('coban', 'tk103'),
  ('auto', 'auto'),
];

String chipBrandOf(String protocol) => switch (protocol) {
      'gt06' => 'concox',
      'h02' => 'sinotrack',
      'tk103' => 'coban',
      _ => 'auto',
    };

String chipReasonText(AppLocalizations t, Object e) {
  final code = e is ApiException ? e.message : '';
  return switch (code) {
    'bad_imei' => t.chipErrImei,
    'imei_taken' => t.chipErrTaken,
    'imei_is_vehicle' => t.chipErrIsVehicle,
    'limit' => t.chipErrLimit,
    'name_required' => t.kwNameRequired,
    _ => t.kwActionFailed,
  };
}

Future<void> _openMap(BuildContext context, Object? lat, Object? lng) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      messenger?.showSnackBar(SnackBar(content: Text(t.kwActionFailed)));
    }
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(t.kwActionFailed)));
  }
}

// =================================================================== card

/// The chip on the child card (parent / guardian side).
class ChipCard extends StatelessWidget {
  const ChipCard({super.key, required this.chip, this.plan, required this.onChanged});

  final Map<String, dynamic> chip;
  final Map<String, dynamic>? plan;
  final Future<void> Function() onChanged;

  Widget _pill(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: AType.labelMedium.copyWith(color: fg)),
      );

  Future<void> _setup(BuildContext context) async {
    final api = context.read<AppState>().api;
    final t = AppLocalizations.of(context);
    try {
      final r = await api.chipRepair(chip['id'] as int);
      if (!context.mounted) return;
      await showAppSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ChipSetupSheet(chip: (r['chip'] as Map?)?.cast<String, dynamic>() ?? chip),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(chipReasonText(t, e))));
      }
    }
    await onChanged();
  }

  Future<void> _remove(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.chipRemoveQ),
        content: Text(t.chipRemoveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.kwRemove)),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    try {
      await api.chipRemove(chip['id'] as int);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(chipReasonText(t, e))));
      }
    }
    await onChanged();
  }

  // chipbuy2 ---------------------------------------------------- find now
  Future<void> _find(BuildContext context) async {
    final api = context.read<AppState>().api;
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    String msg;
    try {
      await api.chipFind(chip['id'] as int);
      msg = t.chipFindAsked;
    } catch (e) {
      final tooSoon = e is ApiException && (e.message == 'too_soon' || e.reason == 'too_soon');
      msg = tooSoon ? t.chipFindTooSoon : chipReasonText(t, e);
    }
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
    await onChanged();
  }

  // chipbuy2 ------------------------------------------------- left behind
  Future<void> _left(BuildContext context, Map<String, dynamic> body, {String? done}) async {
    final api = context.read<AppState>().api;
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await api.chipLeftBehind(chip['id'] as int, body);
      if (done != null) {
        messenger
          ?..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      messenger
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(chipReasonText(t, e))));
    }
    await onChanged();
  }

  Widget? _findLine(AppLocalizations t, ColorScheme scheme) {
    final f = chip['find'] is Map ? (chip['find'] as Map).cast<String, dynamic>() : null;
    if (f == null || f['active'] != true) return null;
    final cmd = '${f['command'] ?? ''}';
    final text = switch (cmd) {
      'acked' => t.chipFindAcked,
      'failed' || 'expired' || 'cancelled' => t.chipFindFailed,
      _ => t.chipFindAsked,
    };
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Text(text,
          key: const ValueKey('chip-find-state'),
          style: AType.bodySmall.copyWith(
              color: cmd == 'failed' ? scheme.error : scheme.onSurfaceVariant)),
    );
  }

  Widget _leftSection(BuildContext context, AppLocalizations t, ColorScheme scheme,
      String Function(String) d, bool mine) {
    final lb = chip['left_behind'] is Map
        ? (chip['left_behind'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final on = lb['on'] == true;
    final min = (lb['min'] as num?)?.toInt() ?? 60;
    final choices = (lb['choices'] is List ? lb['choices'] as List : const [30, 60, 120])
        .whereType<num>()
        .map((n) => n.toInt())
        .toList();
    final safe = lb['safe'] is List ? (lb['safe'] as List).length : 0;
    final spot = lb['alerted_spot'] is Map ? (lb['alerted_spot'] as Map).cast<String, dynamic>() : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: Gap.sm),
      if (spot != null)
        Container(
          key: const ValueKey('chip-left-spot'),
          margin: const EdgeInsets.only(bottom: Gap.sm),
          padding: const EdgeInsets.all(Gap.sm),
          decoration: BoxDecoration(
              color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.chipLeftSpot,
                style: AType.bodyMedium.copyWith(
                    color: scheme.onErrorContainer, fontWeight: FontWeight.w700)),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              TextButton.icon(
                  onPressed: () => _openMap(context, spot['lat'], spot['lng']),
                  icon: const Icon(Icons.map_rounded),
                  label: Text(t.vehOpenMaps)),
              if (mine)
                FilledButton.tonalIcon(
                    key: const ValueKey('chip-safe-place'),
                    onPressed: () => _left(context, {
                          'safe_add': {'lat': spot['lat'], 'lng': spot['lng'], 'name': ''}
                        }, done: t.chipSafeSaved),
                    icon: const Icon(Icons.verified_user_rounded),
                    label: Text(t.chipSafePlace)),
            ]),
          ]),
        ),
      Text(t.chipLeftTitle, style: AType.titleSmall),
      if (mine) ...[
        Text(t.chipLeftSub, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
          ChoiceChip(
              key: const ValueKey('chip-left-0'),
              label: Text(t.chipLeftOff),
              selected: !on,
              onSelected: (_) => _left(context, {'on': false})),
          for (final m in choices)
            ChoiceChip(
                key: ValueKey('chip-left-$m'),
                label: Text(t.chipLeftMin(d('$m'))),
                selected: on && m == min,
                onSelected: (_) => _left(context, {'on': true, 'min': m})),
        ]),
      ] else
        Text(on ? t.chipLeftMin(d('$min')) : t.chipLeftOff,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      if (safe > 0)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xxs),
          child: Text(t.chipSafeCount(d('$safe')),
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ),
    ]);
  }

  Future<void> _plan(BuildContext context) async {
    final has = plan != null && plan!.isNotEmpty;
    final ok = await showSchoolPlanForm(context,
        plan: has ? plan : null,
        watch: {'id': chip['id'], 'kind': 'chip', 'child_name': chip['child_name']});
    if (ok == true) await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    String d(String s) => notifLocalizeDigits(context, s);
    final mine = chip['mine'] == true;
    final paired = chip['state'] == 'paired';
    final online = chip['online'] == true;
    final live = chip['live'] is Map ? (chip['live'] as Map).cast<String, dynamic>() : null;
    final battery = chip['battery'];
    final low = chip['battery_low'] == true;
    final hasPlan = plan != null && plan!.isNotEmpty;
    final guardians = kwRows(chip, 'guardians').map((g) => '${g['name']}').where((s) => s.isNotEmpty);
    return Card(
      key: ValueKey('chip-card-${chip['id']}'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.backpack_rounded, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${chip['child_name']}', style: AType.titleMedium),
                Text(t.chipKind, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(width: Gap.xs),
            Flexible(
              child: Text(
                battery == null ? t.chipBatteryUnknown : t.kwBattery(d('$battery')),
                key: const ValueKey('chip-battery'),
                textAlign: TextAlign.end,
                style: AType.bodyMedium.copyWith(
                    color: low ? scheme.error : null, fontWeight: low ? FontWeight.w700 : null),
              ),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
            if (!paired)
              _pill(chip['state'] == 'pending' ? t.chipWaiting : t.kwPairExpired,
                  scheme.tertiaryContainer, scheme.onTertiaryContainer),
            if (paired)
              _pill(online ? t.kwOnline : t.kwOffline,
                  online ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                  online ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            if (low) _pill(t.chipBatteryLow, scheme.errorContainer, scheme.onErrorContainer),
          ]),
          const SizedBox(height: Gap.sm),
          if (live != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_rounded),
              title: Text(t.kwLastSeenAt(d(kwClock(live['at'])))),
              subtitle: Text(t.kwSourceGps),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => _openMap(context, live['lat'], live['lng']),
            )
          else
            Text(paired ? t.chipNoLocationYet : t.chipPairHint,
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          if (hasPlan) _todayLine(t, plan!),
          if (_findLine(t, scheme) case final w?) w,
          if (guardians.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.chipWhoSees(guardians.join(', ')),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
          if (chip['child_has_app'] == true) ...[
            const SizedBox(height: Gap.xxs),
            Text(t.chipChildSeesNote,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
          _leftSection(context, t, scheme, d, mine),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            if (paired)
              FilledButton.icon(
                  key: const ValueKey('chip-find'),
                  onPressed: () => _find(context),
                  icon: const Icon(Icons.my_location_rounded),
                  label: Text(t.chipFindNow)),
            if (paired)
              FilledButton.tonalIcon(
                  key: const ValueKey('chip-history'),
                  onPressed: () => showAppSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => ChipHistorySheet(chip: chip)),
                  icon: const Icon(Icons.history_rounded),
                  label: Text(t.chipHistory)),
            if (mine)
              OutlinedButton.icon(
                  onPressed: () => _plan(context),
                  icon: const Icon(Icons.school_rounded),
                  label: Text(hasPlan ? t.kwEditSchoolMode : t.kwSetSchoolMode)),
            if (mine && paired)
              TextButton.icon(
                  key: const ValueKey('chip-setup'),
                  onPressed: () => _setup(context),
                  icon: const Icon(Icons.sms_rounded),
                  label: Text(t.kwSmsSetup)),
            if (mine && !paired)
              OutlinedButton.icon(
                  key: const ValueKey('chip-setup'),
                  onPressed: () => _setup(context),
                  icon: const Icon(Icons.sms_rounded),
                  label: Text(t.kwSmsSetup)),
            if (mine)
              TextButton.icon(
                  onPressed: () => _remove(context),
                  icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
                  label: Text(t.kwRemove, style: TextStyle(color: scheme.error))),
          ]),
        ]),
      ),
    );
  }

  Widget _todayLine(AppLocalizations t, Map<String, dynamic> plan) {
    final today = (plan['today'] as Map?)?.cast<String, dynamic>() ?? const {};
    final st = '${today['state'] ?? 'idle'}';
    final label = switch (st) {
      'at_home' => t.kwStateAtHome,
      'to_school' => t.kwStateToSchool,
      'at_school' => t.kwStateAtSchool,
      'to_home' => t.kwStateToHome,
      'home' => t.kwStateHome,
      _ => today['school_day'] == true ? t.kwStateIdle : t.kwStateNoSchool,
    };
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Row(children: [
        const Icon(Icons.school_rounded, size: 18),
        const SizedBox(width: Gap.xs),
        Expanded(child: Text(t.kwTodayLine(label), style: AType.bodyMedium)),
      ]),
    );
  }
}

/// What the CHILD sees on their own phone: the chip is on, who set it up,
/// who can see it. No location, no history.
class ChipWornCard extends StatelessWidget {
  const ChipWornCard({super.key, required this.worn});
  final Map<String, dynamic> worn;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final who = ((worn['watchers'] as List?) ?? const [])
        .map((e) => '$e')
        .where((s) => s.isNotEmpty)
        .join(', ');
    return Card(
      key: ValueKey('chip-worn-${worn['id']}'),
      color: scheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.backpack_rounded, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.chipWornTitle,
                  style: AType.titleMedium.copyWith(color: scheme.onSecondaryContainer)),
              const SizedBox(height: Gap.xxs),
              Text(t.chipWornBody('${worn['owner_name'] ?? ''}', who),
                  style: AType.bodyMedium.copyWith(color: scheme.onSecondaryContainer)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// =================================================================== history

class ChipHistorySheet extends StatefulWidget {
  const ChipHistorySheet({super.key, required this.chip});
  final Map<String, dynamic> chip;

  @override
  State<ChipHistorySheet> createState() => _ChipHistorySheetState();
}

class _ChipHistorySheetState extends State<ChipHistorySheet> {
  List<Map<String, dynamic>>? _pts;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final r = await context.read<AppState>().api.chipHistory(widget.chip['id'] as int, hours: 48);
      if (mounted) setState(() => _pts = kwRows(r, 'points').reversed.take(200).toList());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  String _when(BuildContext context, Object? iso) {
    final dt = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (dt == null) return '';
    final day = MaterialLocalizations.of(context).formatShortMonthDay(dt);
    return notifLocalizeDigits(context, '$day, ${kwClock(iso)}');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pts = _pts;
    return SingleChildScrollView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.chipHistoryTitle('${widget.chip['child_name']}'), style: AType.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.chipHistoryNote, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        if (_failed)
          Column(children: [
            Text(t.kwLoadFailed, style: AType.bodyMedium),
            const SizedBox(height: Gap.sm),
            FilledButton.icon(
                onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.kwRetry)),
          ])
        else if (pts == null)
          const Center(child: Padding(padding: EdgeInsets.all(Gap.lg), child: CircularProgressIndicator()))
        else if (pts.isEmpty)
          Text(t.chipHistoryEmpty, style: AType.bodyMedium)
        else
          for (final p in pts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_outlined),
              title: Text(_when(context, p['at'])),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => _openMap(context, p['lat'], p['lng']),
            ),
      ]),
    );
  }
}

// =================================================================== pair

/// Add a chip: name, IMEI, brand, SIM operator, child on Assisto, who sees.
/// Then the SAME live setup screen as a vehicle tracker (VehSetupView).
class ChipPairSheet extends StatefulWidget {
  const ChipPairSheet({super.key});

  @override
  State<ChipPairSheet> createState() => _ChipPairSheetState();
}

class _ChipPairSheetState extends State<ChipPairSheet> {
  final _imei = TextEditingController();
  final _name = TextEditingController();
  final _sim = TextEditingController();
  String _brand = 'concox';
  String _protocol = 'gt06';
  String _operator = 'gp';
  int? _child;
  List<Map<String, dynamic>> _people = const [];
  final Set<int> _guardians = {};
  bool _busy = false;
  String _error = '';
  Map<String, dynamic>? _done;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPeople());
  }

  Future<void> _loadPeople() async {
    try {
      final r = await context.read<AppState>().api.smPeople();
      if (mounted) setState(() => _people = kwRows(r, 'people'));
    } catch (_) {}
  }

  @override
  void dispose() {
    _imei.dispose();
    _name.dispose();
    _sim.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final imei = _imei.text.replaceAll(RegExp(r'\D'), '');
    if (_name.text.trim().isEmpty) {
      setState(() => _error = t.kwNameRequired);
      return;
    }
    if (imei.length < 10 || imei.length > 15) {
      setState(() => _error = t.chipErrImei);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final r = await context.read<AppState>().api.chipPair(
          imei: imei,
          childName: _name.text.trim(),
          protocol: _protocol,
          guardianIds: _guardians.toList(),
          childUserId: _child);
      if (mounted) setState(() => _done = (r['chip'] as Map?)?.cast<String, dynamic>() ?? {});
    } catch (e) {
      if (mounted) setState(() => _error = chipReasonText(t, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final done = _done;
    if (done != null) {
      return ChipSetupSheet(
          chip: done, operator: _operator, simNumber: _sim.text.trim(), brand: _brand);
    }
    return SingleChildScrollView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.chipAddTitle, style: AType.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.chipPairIntro, style: AType.bodyMedium),
        const SizedBox(height: Gap.xs),
        // chipbuy2: honest range — GPS chip vs Bluetooth tag
        Row(key: const ValueKey('chip-range-note'), crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline_rounded, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.xs),
          Expanded(
              child: Text(t.chipRangeNote,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant))),
        ]),
        const WhereToBuyLink(product: BuyProduct.chip, dense: true),
        const SizedBox(height: Gap.sm),
        TextField(
          key: const ValueKey('chip-name'),
          controller: _name,
          maxLength: 60,
          buildCounter: localCounter,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: t.kwChildName, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          key: const ValueKey('chip-imei'),
          controller: _imei,
          keyboardType: TextInputType.number,
          maxLength: 15,
          buildCounter: localCounter,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
              labelText: t.chipImeiLabel,
              helperText: t.chipImeiHelp,
              helperMaxLines: 3,
              border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.v100BrandLabel, style: AType.titleSmall),
        const SizedBox(height: Gap.xs),
        // radio rows (not chips): long brand names wrap at 200% text
        RadioGroup<String>(
          groupValue: _brand,
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _brand = v;
              _protocol = kChipBrands.firstWhere((b) => b.$1 == v).$2;
            });
          },
          child: Column(children: [
            for (final b in kChipBrands)
              RadioListTile<String>(
                key: ValueKey('chip-brand-${b.$1}'),
                contentPadding: EdgeInsets.zero,
                value: b.$1,
                title: Text(vehBrandLabel(t, b.$1)),
              ),
          ]),
        ),
        const SizedBox(height: Gap.md),
        Text(t.chipSimOperator, style: AType.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final o in kVehOperators)
            ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text(vehOperatorLabel(o)),
              selected: _operator == o,
              onSelected: (_) => setState(() => _operator = o),
            ),
        ]),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _sim,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
              labelText: t.chipSimNumber,
              helperText: t.chipSimHelp,
              helperMaxLines: 3,
              border: const OutlineInputBorder()),
        ),
        if (_people.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<int?>(
            initialValue: _child,
            isExpanded: true,
            decoration: InputDecoration(
                labelText: t.chipChildOnApp,
                helperText: t.chipChildOnAppHelp,
                helperMaxLines: 3,
                border: const OutlineInputBorder()),
            items: [
              DropdownMenuItem<int?>(value: null, child: Text(t.chipChildNoApp)),
              for (final p in _people)
                DropdownMenuItem<int?>(
                    value: p['id'] as int?,
                    child: Text('${p['name']}', maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() {
              _child = v;
              if (v != null) _guardians.remove(v);
            }),
          ),
          const SizedBox(height: Gap.md),
          Text(t.kwWhoElseSees, style: AType.titleSmall),
          for (final p in _people.where((p) => p['id'] != _child))
            CheckboxListTile(
              value: _guardians.contains(p['id']),
              title: Text('${p['name']}'),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _guardians.add(p['id'] as int);
                } else {
                  _guardians.remove(p['id']);
                }
              }),
            ),
        ],
        const SizedBox(height: Gap.xs),
        Text(t.chipFreeNote, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text(_error, key: const ValueKey('chip-error'), style: TextStyle(color: scheme.error)),
        ],
        const SizedBox(height: Gap.lg),
        FilledButton(
          key: const ValueKey('chip-pair-submit'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _save,
          child: Text(t.kwPairNext),
        ),
      ]),
    );
  }
}

/// The SMS setup + live wait for the first ping (VehSetupView, reused).
class ChipSetupSheet extends StatelessWidget {
  const ChipSetupSheet(
      {super.key, required this.chip, this.operator = 'gp', this.simNumber = '', this.brand});
  final Map<String, dynamic> chip;
  final String operator;
  final String simNumber;
  final String? brand;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final id = chip['id'] as int? ?? 0;
    return SingleChildScrollView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg)),
      child: VehSetupView(
        tracker: chip,
        brand: brand ?? chipBrandOf('${chip['protocol'] ?? 'auto'}'),
        operator: operator,
        simNumber: simNumber,
        firstFixText: t.chipFirstFix,
        retry: () async {
          final r = await api.chipRepair(id);
          return (r['chip'] as Map?)?.cast<String, dynamic>() ?? chip;
        },
        onClose: () => Navigator.of(context).pop(true),
      ),
    );
  }
}
