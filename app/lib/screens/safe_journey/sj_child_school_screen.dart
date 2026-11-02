import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../kids_watch_api.dart';
import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/journey_ride.dart' show jDigits;
import '../kids_watch/school_mode_child_screen.dart';
import '../kids_watch/school_plan_form.dart';
import 'sj_live_api.dart';

/// The four moments of a school day, in order: (today-key, event for the
/// gate camera). Pure, shared with the tests.
const List<(String, String)> kSjSchoolSteps = [
  ('left_home_at', 'left_home'),
  ('arrived_school_at', 'arrived_school'),
  ('left_school_at', 'left_school'),
  ('home_at', 'reached_home'),
];

/// 'YYYY-MM-DD' of a local date. Pure.
String sjIsoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Upcoming holidays only (today or later), sorted. Pure.
List<String> sjUpcomingHolidays(List<String> all, DateTime today) {
  final t = sjIsoDay(today);
  return (all.where((d) => d.compareTo(t) >= 0).toList()..sort());
}

/// sjlive — Card 1, button 2 "Child School": every child's school day on one
/// screen — left home, reached school, left school, reached home — with
/// school days and holidays, an alert when not at school by the set time,
/// both parents (watchers), many children (one plan each), and the school
/// gate camera's snapshot ONLY when a CCTV camera is linked (else hidden).
/// Automatic while the child's phone shares Live Location (or a kids watch /
/// tracker chip); otherwise the child taps "Leaving now" / "Reached".
class SjChildSchoolScreen extends StatefulWidget {
  const SjChildSchoolScreen({super.key});
  @override
  State<SjChildSchoolScreen> createState() => _SjChildSchoolScreenState();
}

class _SjChildSchoolScreenState extends State<SjChildSchoolScreen> {
  List<Map<String, dynamic>> _plans = [];
  List<Map<String, dynamic>> _mine = [];
  List<Map<String, dynamic>> _cams = [];
  bool _loading = true;
  bool _error = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.smPlans();
      List<Map<String, dynamic>> mine = const [];
      try {
        mine = kwRows(await _api.smMine(), 'plans');
      } catch (_) {
        mine = const []; // best-effort: the parent side still works
      }
      final cams = await _api.sjMyCameras(); // never throws
      if (!mounted) return;
      setState(() {
        _plans = kwRows(r, 'plans').where((p) => p['i_am_child'] != true).toList();
        _mine = mine;
        _cams = cams;
        _loading = false;
        _error = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  Future<void> _add() async {
    final ok = await showSchoolPlanForm(context);
    if (ok == true && mounted) await _load();
  }

  Future<void> _edit(Map<String, dynamic> p) async {
    final ok = await showSchoolPlanForm(context, plan: p);
    if (ok == true && mounted) await _load();
  }

  String _time(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    return d == null ? '—' : jDigits(context, TimeOfDay.fromDateTime(d).format(context));
  }

  Future<void> _patch(Map<String, dynamic> p, Map<String, dynamic> body) async {
    try {
      await _api.smUpdate((p['id'] as num).toInt(), body);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) showActionFailed(context, 'sjlive.school.patch', e);
    }
  }

  Future<void> _holidays(Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final cfg = (p['config'] as Map?) ?? const {};
    final days = <String>{...((cfg['holidays'] as List?) ?? const []).map((e) => '$e')};
    final changed = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final up = sjUpcomingHolidays(days.toList(), DateTime.now());
          return SafeArea(
            child: SingleChildScrollView(
              key: const ValueKey('sjl_holiday_sheet'),
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(t.sjlHolidays,
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.xs),
                Text(t.sjlHolidaysBody, style: AType.bodyMedium),
                const SizedBox(height: Gap.md),
                if (up.isEmpty)
                  Text(t.sjlHolidaysNone, style: AType.bodySmall)
                else
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    for (final d in up)
                      InputChip(
                        key: ValueKey('sjl_holiday_$d'),
                        label: Text(MaterialLocalizations.of(ctx)
                            .formatMediumDate(DateTime.parse(d))),
                        onDeleted: () => setS(() => days.remove(d)),
                        deleteButtonTooltipMessage: t.sjlRemove,
                      ),
                  ]),
                const SizedBox(height: Gap.md),
                OutlinedButton.icon(
                  key: const ValueKey('sjl_holiday_add'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.event_busy_rounded),
                  label: Text(t.sjlHolidayAdd),
                  onPressed: () async {
                    final now = DateTime.now();
                    final d = await showDatePicker(
                        context: ctx,
                        initialDate: now,
                        firstDate: DateTime(now.year, now.month, now.day),
                        lastDate: now.add(const Duration(days: 366)));
                    if (d != null) setS(() => days.add(sjIsoDay(d)));
                  },
                ),
                const SizedBox(height: Gap.sm),
                FilledButton(
                  key: const ValueKey('sjl_holiday_save'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.kwSave),
                ),
              ]),
            ),
          );
        },
      ),
    );
    if (changed == true && mounted) {
      // past days are dropped: they can never matter again
      await _patch(p, {'holidays': sjUpcomingHolidays(days.toList(), DateTime.now())});
    }
  }

  Future<void> _linkCamera(Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final cur = ((p['config'] as Map?) ?? const {})['gate_camera_id'];
    final pick = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(Gap.lg), children: [
          Text(t.sjlGateLink, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.sjlGateLinkBody, style: AType.bodyMedium),
          for (final c in _cams)
            RadioListTile<int>(
              key: ValueKey('sjl_gate_cam_${c['id']}'),
              value: (c['id'] as num).toInt(),
              groupValue: (cur as num?)?.toInt(),
              title: Text('${c['name'] ?? ''}'),
              subtitle: Text('${c['site'] ?? ''}'),
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
          if (cur != null)
            TextButton(
              key: const ValueKey('sjl_gate_unlink'),
              onPressed: () => Navigator.pop(ctx, 0),
              child: Text(t.sjlGateUnlink),
            ),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    await _patch(p, {'gate_camera_id': pick == 0 ? null : pick});
  }

  Future<void> _gate(Map<String, dynamic> p, String event) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await _api.sjGateSnapshot((p['id'] as num).toInt(), event);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(t.sjlGatePhoto),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.network('${r['url']}',
                key: const ValueKey('sjl_gate_img'),
                errorBuilder: (_, __, ___) => Text(t.sjlGateNone)),
            const SizedBox(height: Gap.sm),
            Text(t.sjlGateAt(_time('${r['at']}'))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.sjlClose)),
          ],
        ),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(e.message.contains('not_yet') ? t.sjlGateNotYet : t.sjlGateNone)));
    } catch (e) {
      if (mounted) showActionFailed(context, 'sjlive.school.gate', e);
    }
  }

  Widget _planCard(AppLocalizations t, Map<String, dynamic> p) {
    final cs = Theme.of(context).colorScheme;
    final today = (p['today'] as Map?)?.cast<String, dynamic>() ?? const {};
    final cfg = (p['config'] as Map?)?.cast<String, dynamic>() ?? const {};
    final mine = p['mine'] == true;
    final id = p['id'];
    final cam = cfg['gate_camera_id'];
    final names = kwRows(p, 'watchers').map((w) => '${w['name'] ?? ''}').join(', ');
    final schoolDay = today['school_day'] == true;
    final holiday = ((cfg['holidays'] as List?) ?? const [])
        .contains(sjIsoDay(DateTime.now()));
    final labels = [t.sjlStepLeftHome, t.sjlStepAtSchool, t.sjlStepLeftSchool, t.sjlStepHome];
    return Card(
      key: ValueKey('sjl_school_$id'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.school_rounded),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text('${p['child_name'] ?? ''}',
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (mine)
              IconButton(
                  key: ValueKey('sjl_school_edit_$id'),
                  tooltip: t.sjlEdit,
                  icon: const Icon(Icons.edit_rounded),
                  onPressed: () => _edit(p)),
          ]),
          if (p['accepted'] != true)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.sjlWaitingChild('${p['child_name'] ?? ''}'),
                  key: ValueKey('sjl_school_wait_$id'),
                  style: AType.bodyMedium.copyWith(color: Brand.warnInk(context))),
            )
          else if (holiday)
            Text(t.sjlTodayHoliday, style: AType.bodyMedium)
          else if (!schoolDay)
            Text(t.sjlNoSchoolToday, style: AType.bodyMedium)
          else ...[
            const SizedBox(height: Gap.sm),
            for (var i = 0; i < kSjSchoolSteps.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Icon(
                      today[kSjSchoolSteps[i].$1] != null
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: today[kSjSchoolSteps[i].$1] != null
                          ? Brand.successFill
                          : cs.onSurfaceVariant),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text(labels[i], style: AType.bodyMedium)),
                  Text(_time(today[kSjSchoolSteps[i].$1] as String?),
                      style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
            if (today['arrive_due'] != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.sjlAlertBy(_time(today['arrive_due'] as String?)),
                    style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
              ),
          ],
          if (names.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.sjlParents(names),
                  style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
            ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            OutlinedButton.icon(
              key: ValueKey('sjl_school_hist_$id'),
              icon: const Icon(Icons.history_rounded),
              label: Text(t.sjlHistory),
              onPressed: () => showSchoolEvents(context, p),
            ),
            if (mine)
              OutlinedButton.icon(
                key: ValueKey('sjl_school_holidays_$id'),
                icon: const Icon(Icons.event_busy_rounded),
                label: Text(t.sjlHolidays),
                onPressed: () => _holidays(p),
              ),
            // CCTV gate snapshot: only through the CCTV seam, only when a
            // camera is linked — otherwise nothing is shown
            if (cam != null)
              OutlinedButton.icon(
                key: ValueKey('sjl_school_gate_$id'),
                icon: const Icon(Icons.videocam_rounded),
                label: Text(t.sjlGatePhoto),
                onPressed: () => _gate(p, today['left_school_at'] != null
                    ? 'left_school'
                    : 'arrived_school'),
              )
            else if (mine && _cams.isNotEmpty)
              OutlinedButton.icon(
                key: ValueKey('sjl_school_gate_link_$id'),
                icon: const Icon(Icons.videocam_outlined),
                label: Text(t.sjlGateLink),
                onPressed: () => _linkCamera(p),
              ),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error) {
      body = ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Text(t.sjlWhereError, style: AType.bodyMedium),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.sjlRetry),
            onPressed: () {
              setState(() => _loading = true);
              _load();
            }),
      ]);
    } else {
      body = ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          if (_mine.isNotEmpty)
            Card(
              key: const ValueKey('sjl_school_me'),
              color: cs.secondaryContainer,
              margin: const EdgeInsets.only(bottom: Gap.md),
              child: ListTile(
                minVerticalPadding: Gap.md,
                leading: const Icon(Icons.visibility_rounded),
                title: Text(t.sjlSchoolOnMe),
                subtitle: Text(t.sjlSchoolOnMeBody),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SchoolModeChildScreen())),
              ),
            ),
          if (_plans.isEmpty) ...[
            Icon(Icons.school_rounded, size: 56, color: cs.primary),
            const SizedBox(height: Gap.md),
            Text(t.sjlSchoolEmptyTitle,
                textAlign: TextAlign.center,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            Text(t.sjlSchoolEmptyBody, textAlign: TextAlign.center, style: AType.bodyLarge),
          ] else
            for (final p in _plans) _planCard(t, p),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const ValueKey('sjl_school_add'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.add_rounded),
            label: Text(t.sjlSchoolAdd),
            onPressed: _add,
          ),
          const SizedBox(height: Gap.sm),
          Text(t.sjlSchoolHow,
              style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.sjlBtnSchool)),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }
}
