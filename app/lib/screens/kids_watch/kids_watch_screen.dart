import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../kids_watch_api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/media/voice_player.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/fam_empty.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'kw_recorder.dart';
import 'school_plan_form.dart';

/// kidswatch (owner idea 2, 28 Oct) — the PARENT side: kids GPS watches and
/// School Mode plans. Behind the server flag `kids_watch` (route owned by it).
///
/// Honest by design:
///  * a WATCH is fully automatic (left home / reached school / left the school
///    area / home / late); on a PHONE, School Mode is one big button the child
///    presses — no background location;
///  * SOS, school alerts and the last location are free on every plan; an
///    unpaid watch runs in "safety only" mode;
///  * there is NO listen-in feature, and the screen says so.
class KidsWatchScreen extends StatefulWidget {
  const KidsWatchScreen({super.key});

  @override
  State<KidsWatchScreen> createState() => _KidsWatchScreenState();
}

class _KidsWatchScreenState extends State<KidsWatchScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _watches = const [];
  List<Map<String, dynamic>> _plans = const [];
  Map<String, dynamic> _cfg = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await Future.wait([_api.kwWatches(), _api.smPlans(), _api.kwConfig()]);
      if (!mounted) return;
      setState(() {
        _watches = kwRows(r[0], 'watches');
        _plans = kwRows(r[1], 'plans');
        _cfg = r[2];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  String _d(String s) => notifLocalizeDigits(context, s);

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _fail(Object e) {
    final t = AppLocalizations.of(context);
    _snack(e is ApiException && e.message.isNotEmpty ? e.message : t.kwActionFailed);
  }

  // ------------------------------------------------------------- actions

  Future<void> _addWatch() async {
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PairWatchSheet(cfg: _cfg),
    );
    if (ok == true) await _load();
  }

  Future<void> _addPhonePlan() async {
    final ok = await showSchoolPlanForm(context);
    if (ok == true) await _load();
  }

  Future<void> _command(Map<String, dynamic> w, String kind) async {
    final t = AppLocalizations.of(context);
    try {
      await _api.kwCommand(w['id'] as int, kind);
      _snack(kind == 'find_watch' ? t.kwFindSent : t.kwLocateSent);
      await _load();
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  Future<void> _openMap(Map<String, dynamic> live) async {
    final lat = live['lat'], lng = live['lng'];
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
        _snack(AppLocalizations.of(context).kwActionFailed);
      }
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).kwActionFailed);
    }
  }

  Future<void> _voice(Map<String, dynamic> w) async {
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _VoiceSheet(watch: w),
    );
    await _load();
  }

  Future<void> _sms(Map<String, dynamic> w) => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _SmsSheet(cfg: _cfg, code: '${w['code'] ?? ''}'),
      );

  Future<void> _plan(Map<String, dynamic>? plan, {Map<String, dynamic>? watch}) async {
    final ok = await showSchoolPlanForm(context, plan: plan, watch: watch);
    if (ok == true) await _load();
  }

  Future<void> _remove(Map<String, dynamic> w) async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.kwRemoveQ),
        content: Text(t.kwRemoveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.kwRemove)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await _api.kwRemove(w['id'] as int);
      await _load();
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  Future<void> _repair(Map<String, dynamic> w) async {
    try {
      await _api.kwRepair(w['id'] as int);
      if (mounted) await _sms(w);
      await _load();
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  Future<void> _deletePlan(Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.kwPlanDeleteQ),
        content: Text(t.kwPlanDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.kwRemove)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await _api.smDelete(p['id'] as int);
      await _load();
    } catch (e) {
      if (mounted) _fail(e);
    }
  }

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.kwTitle)),
      floatingActionButton: (_watches.isEmpty && _plans.isEmpty) || _loading || _failed
          ? null
          : FloatingActionButton.extended(
              heroTag: 'kw-fab',
              onPressed: _addMenu,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.kwAdd)),
      body: _body(t),
    );
  }

  Future<void> _addMenu() async {
    final t = AppLocalizations.of(context);
    final pick = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.watch_rounded),
          title: Text(t.kwAddWatch),
          subtitle: Text(t.kwAddWatchSub),
          onTap: () => Navigator.pop(ctx, 'watch'),
        ),
        ListTile(
          leading: const Icon(Icons.smartphone_rounded),
          title: Text(t.kwAddPhonePlan),
          subtitle: Text(t.kwAddPhonePlanSub),
          onTap: () => Navigator.pop(ctx, 'phone'),
        ),
      ]),
    );
    if (pick == 'watch') await _addWatch();
    if (pick == 'phone') await _addPhonePlan();
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.kwLoadFailed, textAlign: TextAlign.center, style: AType.bodyLarge),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
                onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.kwRetry)),
          ]),
        ),
      );
    }
    if (_watches.isEmpty && _plans.isEmpty) {
      return FamEmptyState(
        icon: Icons.watch_rounded,
        title: t.kwEmptyTitle,
        benefit: t.kwEmptyBenefit,
        primaryLabel: t.kwAddWatch,
        primaryIcon: Icons.watch_rounded,
        onPrimary: _addWatch,
        secondaryLabel: t.kwAddPhonePlan,
        onSecondary: _addPhonePlan,
        steps: [t.kwStep1, t.kwStep2, t.kwStep3, t.kwStep4],
        header: _HonestCard(),
      );
    }
    final phonePlans = _plans.where((p) => p['mode'] == 'phone').toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96)),
        children: [
          _HonestCard(),
          for (final w in _watches) _watchCard(t, w),
          if (phonePlans.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.xs),
              child: Text(t.kwPhonePlansHeading, style: AType.titleSmall),
            ),
            for (final p in phonePlans) _planCard(t, p),
          ],
        ],
      ),
    );
  }

  Widget _chip(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: AType.labelMedium.copyWith(color: fg)),
      );

  Widget _watchCard(AppLocalizations t, Map<String, dynamic> w) {
    final scheme = Theme.of(context).colorScheme;
    final mine = w['mine'] == true;
    final paired = w['state'] == 'paired';
    final full = w['mode'] == 'full';
    final live = w['live'] is Map ? (w['live'] as Map).cast<String, dynamic>() : null;
    final battery = w['battery'];
    final planId = w['school_plan_id'];
    final plan = planId == null
        ? null
        : _plans.firstWhere((p) => p['id'] == planId, orElse: () => <String, dynamic>{});
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.watch_rounded, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text('${w['child_name']}', style: AType.titleMedium)),
            if (battery != null)
              Text(t.kwBattery(_d('$battery')), style: AType.bodyMedium),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
            if (!paired)
              _chip(w['state'] == 'pending' ? t.kwWaitingWatch : t.kwPairExpired,
                  scheme.tertiaryContainer, scheme.onTertiaryContainer),
            if (paired)
              _chip(w['online'] == true ? t.kwOnline : t.kwOffline,
                  w['online'] == true ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                  w['online'] == true ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            if (paired)
              _chip(full ? t.kwModeFull : t.kwModeSafety,
                  full ? scheme.secondaryContainer : scheme.errorContainer,
                  full ? scheme.onSecondaryContainer : scheme.onErrorContainer),
          ]),
          if (paired && !full) ...[
            const SizedBox(height: Gap.xs),
            Text(t.kwSafetyOnlyNote(_d('${_cfg['month_credits'] ?? ''}')),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.sm),
          if (live != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_rounded),
              title: Text(t.kwLastSeenAt(_d(kwClock(live['at'])))),
              subtitle: Text(live['source'] == 'wifi' ? t.kwSourceWifi : t.kwSourceGps),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => _openMap(live),
            )
          else
            Text(paired ? t.kwNoLocationYet : t.kwPairHint,
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          if (plan != null && plan.isNotEmpty) _todayLine(t, plan),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            if (paired) ...[
              FilledButton.tonalIcon(
                  onPressed: () => _command(w, 'locate_now'),
                  icon: const Icon(Icons.my_location_rounded),
                  label: Text(t.kwLocateNow)),
              FilledButton.tonalIcon(
                  onPressed: () => _command(w, 'find_watch'),
                  icon: const Icon(Icons.notifications_active_rounded),
                  label: Text(t.kwRingWatch)),
              FilledButton.tonalIcon(
                  onPressed: () => _voice(w),
                  icon: const Icon(Icons.record_voice_over_rounded),
                  label: Text(t.kwVoiceMessages)),
            ],
            if (mine)
              OutlinedButton.icon(
                  onPressed: () => _plan(plan != null && plan.isNotEmpty ? plan : null, watch: w),
                  icon: const Icon(Icons.school_rounded),
                  label: Text(plan != null && plan.isNotEmpty ? t.kwEditSchoolMode : t.kwSetSchoolMode)),
            if (mine && !paired)
              OutlinedButton.icon(
                  onPressed: () => _repair(w),
                  icon: const Icon(Icons.sms_rounded),
                  label: Text(t.kwSmsSetup)),
            if (mine && paired)
              TextButton.icon(
                  onPressed: () => _sms(w),
                  icon: const Icon(Icons.sms_rounded),
                  label: Text(t.kwSmsSetup)),
            if (mine)
              TextButton.icon(
                  onPressed: () => _remove(w),
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

  Widget _planCard(AppLocalizations t, Map<String, dynamic> p) {
    final scheme = Theme.of(context).colorScheme;
    final accepted = p['accepted'] == true;
    final enabled = p['enabled'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.smartphone_rounded, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text('${p['child_name']}', style: AType.titleMedium)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(!enabled
              ? t.kwPlanStopped
              : (accepted ? t.kwPlanActivePhone : t.kwPlanWaitingChild),
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          if (enabled && accepted) _todayLine(t, p),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            OutlinedButton.icon(
                onPressed: () => _plan(p),
                icon: const Icon(Icons.edit_rounded),
                label: Text(t.kwEditSchoolMode)),
            OutlinedButton.icon(
                onPressed: () => showSchoolEvents(context, p),
                icon: const Icon(Icons.history_rounded),
                label: Text(t.kwHistory)),
            TextButton.icon(
                onPressed: () => _deletePlan(p),
                icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
                label: Text(t.kwRemove, style: TextStyle(color: scheme.error))),
          ]),
        ]),
      ),
    );
  }
}

/// Always visible: what is automatic, what is not, and what we never do.
class _HonestCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHigh,
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.verified_user_rounded, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.kwHonestTitle, style: AType.titleSmall)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.kwHonestWatch, style: AType.bodyMedium),
          const SizedBox(height: Gap.xs),
          Text(t.kwHonestPhone, style: AType.bodyMedium),
          const SizedBox(height: Gap.xs),
          Text(t.kwHonestFree, style: AType.bodyMedium),
          const SizedBox(height: Gap.xs),
          Text(t.kwNoListening, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

// =================================================================== pair

class _PairWatchSheet extends StatefulWidget {
  const _PairWatchSheet({required this.cfg});
  final Map<String, dynamic> cfg;

  @override
  State<_PairWatchSheet> createState() => _PairWatchSheetState();
}

class _PairWatchSheetState extends State<_PairWatchSheet> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _sos = TextEditingController();
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
    _code.dispose();
    _name.dispose();
    _sos.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final code = _code.text.replaceAll(RegExp(r'\D'), '');
    if (code.length < 10 || code.length > 15) {
      setState(() => _error = t.kwCodeInvalid);
      return;
    }
    if (_name.text.trim().isEmpty) {
      setState(() => _error = t.kwNameRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final sos = _sos.text
          .split(RegExp(r'[,\s]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .take(3)
          .toList();
      final r = await context.read<AppState>().api.kwPair(
          code: code, childName: _name.text.trim(), guardianIds: _guardians.toList(),
          sosNumbers: sos);
      if (mounted) setState(() => _done = r);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException && e.message.isNotEmpty ? e.message : t.kwActionFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_done != null) {
      return _SmsSheet(cfg: widget.cfg, code: _code.text.replaceAll(RegExp(r'\D'), ''),
          onDone: () => Navigator.of(context).pop(true));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.kwAddWatch, style: AType.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.kwPairIntro, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: t.kwChildName, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
              labelText: t.kwCodeLabel,
              helperText: t.kwCodeHelp,
              helperMaxLines: 3,
              border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _sos,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
              labelText: t.kwSosNumbers,
              helperText: t.kwSosNumbersHelp,
              helperMaxLines: 3,
              border: const OutlineInputBorder()),
        ),
        if (_people.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          Text(t.kwWhoElseSees, style: AType.titleSmall),
          for (final p in _people)
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
        if (_error.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: Gap.lg),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _save,
          child: Text(t.kwPairNext),
        ),
      ]),
    );
  }
}

// =================================================================== SMS steps

class _SmsSheet extends StatelessWidget {
  const _SmsSheet({required this.cfg, required this.code, this.onDone});
  final Map<String, dynamic> cfg;
  final String code;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final steps = kwRows(cfg, 'sms');
    final labels = {
      'check': t.kwSmsCheck,
      'server': t.kwSmsServer,
      'timezone': t.kwSmsTimezone,
      'interval': t.kwSmsInterval,
      'new_password': t.kwSmsPassword,
    };
    final mins = notifLocalizeDigits(context, '${cfg['pair_window_min'] ?? 30}');
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.kwSmsTitle, style: AType.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.kwSmsIntro(mins), style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        for (var i = 0; i < steps.length; i++)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(notifLocalizeDigits(context, '${i + 1}'))),
              title: Text(labels[steps[i]['step']] ?? ''),
              subtitle: SelectableText('${steps[i]['sms']}',
                  style: const TextStyle(fontFamily: 'monospace')),
              trailing: IconButton(
                tooltip: t.kwCopy,
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: '${steps[i]['sms']}'));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(t.kwCopied)));
                  }
                },
              ),
            ),
          ),
        const SizedBox(height: Gap.sm),
        Text(t.kwSmsPasswordNote, style: AType.bodySmall),
        const SizedBox(height: Gap.xs),
        Text(t.kwSmsLockedNote, style: AType.bodySmall),
        const SizedBox(height: Gap.lg),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: onDone ?? () => Navigator.of(context).pop(),
          child: Text(t.kwDone),
        ),
      ]),
    );
  }
}

// =================================================================== voice

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet({required this.watch});
  final Map<String, dynamic> watch;

  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  ApiClient get _api => context.read<AppState>().api;
  List<Map<String, dynamic>> _notes = const [];
  bool _loading = true;
  bool _sending = false;
  final Map<int, String> _files = {};
  final Map<int, String> _transcripts = {};

  int get _id => widget.watch['id'] as int;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await _api.kwVoiceList(_id);
      if (mounted) setState(() => _notes = kwRows(r, 'notes'));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _play(Map<String, dynamic> n) async {
    final t = AppLocalizations.of(context);
    final id = n['id'] as int;
    try {
      var path = _files[id];
      if (path == null) {
        final bytes = await _api.kwVoiceAudio(id);
        final ext = '${n['mime']}'.contains('amr') ? 'amr' : 'm4a';
        final f = File('${Directory.systemTemp.path}/kwv_$id.$ext');
        await f.writeAsBytes(bytes, flush: true);
        path = f.path;
        _files[id] = path;
      }
      await VoicePlayer.instance.toggle(path);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) _snack(t.kwPlayFailed);
    }
  }

  Future<void> _transcript(Map<String, dynamic> n) async {
    final t = AppLocalizations.of(context);
    try {
      final r = await _api.kwTranscript(n['id'] as int);
      if (mounted) setState(() => _transcripts[n['id'] as int] = '${r['text'] ?? ''}');
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(switch (e.status) {
        402 => t.kwTranscriptPaidOnly,
        429 => t.kwTranscriptCap,
        503 => t.kwTranscriptNoKey,
        _ => t.kwActionFailed,
      });
    } catch (_) {
      if (mounted) _snack(t.kwActionFailed);
    }
  }

  Future<void> _reply() async {
    final t = AppLocalizations.of(context);
    final bytes = await showKwRecorder(context, amr: true);
    if (bytes == null || !mounted) return;
    setState(() => _sending = true);
    try {
      await _api.kwSendVoice(_id, bytes);
      if (mounted) _snack(t.kwReplyQueued);
      await _load();
    } catch (e) {
      if (mounted) {
        _snack(e is ApiException && e.status == 402 ? t.kwVoiceNeedsFull : t.kwActionFailed);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.kwVoiceTitle('${widget.watch['child_name']}'), style: AType.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.kwVoiceIntro, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _sending ? null : _reply,
          icon: const Icon(Icons.mic_rounded),
          label: Text(t.kwRecordReply),
        ),
        const SizedBox(height: Gap.md),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_notes.isEmpty)
          Text(t.kwVoiceEmpty, style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant))
        else
          for (final n in _notes)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ListTile(
                    leading: Icon(n['direction'] == 'up'
                        ? Icons.call_received_rounded
                        : Icons.call_made_rounded),
                    title: Text(n['direction'] == 'up'
                        ? t.kwFromChild(notifLocalizeDigits(context, kwClock(n['at'])))
                        : t.kwFromYou(notifLocalizeDigits(context, kwClock(n['at'])))),
                    subtitle: Text(_noteState(t, n)),
                    trailing: IconButton(
                      tooltip: t.kwPlay,
                      icon: const Icon(Icons.play_circle_fill_rounded, size: 36),
                      onPressed: () => _play(n),
                    ),
                  ),
                  if (n['direction'] == 'up')
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
                      child: (_transcripts[n['id']] ?? '${n['transcript'] ?? ''}').isNotEmpty
                          ? Text(_transcripts[n['id']] ?? '${n['transcript']}',
                              style: AType.bodyMedium)
                          : TextButton.icon(
                              onPressed: () => _transcript(n),
                              icon: const Icon(Icons.subject_rounded),
                              label: Text(t.kwTranscribe)),
                    ),
                ]),
              ),
            ),
        const SizedBox(height: Gap.sm),
        Text(t.kwVoiceKeepNote(notifLocalizeDigits(context, '14')),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  String _noteState(AppLocalizations t, Map<String, dynamic> n) {
    if (n['direction'] == 'up') return n['heard'] == true ? t.kwHeard : t.kwNew;
    return switch ('${n['state']}') {
      'acked' => t.kwDelivered,
      'failed' => t.kwNotDelivered,
      _ => t.kwSending,
    };
  }
}
