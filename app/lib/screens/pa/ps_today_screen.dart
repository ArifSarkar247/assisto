import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../ps/ps_circle.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/reminders_nlp.dart' show ParsedReminder;
import '../../reminders/exact_alarm_ui.dart' show maybeAskExactAlarms;
import '../booking/booking_biz_screen.dart';
import '../booking/booking_detail_screen.dart';
import '../booking/booking_source.dart';
import '../booking/my_bookings_screen.dart';
import '../reminders_quick_add.dart' show QuickAddBar;
import '../reminders_screen.dart';
import '../subscriptions_screen.dart';
import 'liaison_screen.dart';
import 'pa_schedule_screen.dart';
import 'ps_pickup_sheet.dart';

/// pssec: Personal Secretary "Today" — one page for today's meetings (with
/// clash warnings), follow-ups that are late / due, today's reminders and
/// bills. Built by the server ONLY from the user's own rows (GET /ps/today;
/// no AI, nothing invented). Meeting people and follow-up counterparts picked
/// from My Circle get a one-tap "Tell / Remind" that opens their encrypted
/// chat with a ready draft. Flag `ps_secretary`.
class PsTodayScreen extends StatefulWidget {
  const PsTodayScreen({super.key});

  @override
  State<PsTodayScreen> createState() => _PsTodayScreenState();
}

class _PsTodayScreenState extends State<PsTodayScreen> {
  Map<String, dynamic>? _brief;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      // bizassist S2: the phone's own clock (a probashi's brief in their time)
      final tz = DateTime.now().timeZoneOffset.inMinutes;
      final b = await context.read<AppState>().api.getJson('/ps/today?tz=$tz');
      if (!mounted) return;
      setState(() => _brief = b);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  bool get _bn => Localizations.localeOf(context).languageCode == 'bn';
  String _txt(Map m, String key) => '${m['${key}_${_bn ? 'bn' : 'en'}'] ?? ''}';
  String _line(Map m) => '${m[_bn ? 'bn' : 'en'] ?? ''}';

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  Future<void> _pickup({String? seed}) async {
    final added = await showPsPickupSheet(context, initialText: seed);
    if (added == true && mounted) _load();
  }

  /// bizassist S6: a spoken / typed task ("kal sokal 10tay Karim bhaike phone")
  /// becomes a reminder in the phone's own clock — the same offline-first
  /// repo + alarm as the Reminders screen — then the brief reloads.
  Future<void> _addTask(ParsedReminder p, String title, Map<String, dynamic>? link) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    await app.reminders.add({
      'title': title,
      'notes': '',
      'due_at': p.dateTime?.toUtc().toIso8601String(),
      'recurrence': p.recurrence?.freq ?? 'none',
      'recurrence_rule': p.recurrence?.toJson() ?? <String, dynamic>{},
      'date_only': p.dateOnly,
      'done': false,
      'source': 'nlp',
      if (link != null) 'link': link,
    });
    messenger.showSnackBar(SnackBar(content: Text(t.psecTaskAdded)));
    if (p.dateTime != null && !p.dateOnly && mounted) await maybeAskExactAlarms(context);
    if (mounted) _load();
  }

  /// bizassist S7: every brief line opens the row it came from.
  Widget? _sourceScreen(Map line) {
    final src = line['src'];
    if (src is! Map) return null;
    final id = src['id'];
    final api = context.read<AppState>().api;
    switch ('${src['kind']}') {
      case 'reminder':
        return const RemindersScreen();
      case 'schedule':
        return const PaScheduleScreen();
      case 'followup':
        return const LiaisonScreen();
      case 'subscription':
        return const SubscriptionsScreen();
      case 'booking_biz':
        return id is int
            ? BookingDetailScreen(source: ApiBookingSource(api), bookingId: id)
            : const BookingBizScreen();
      case 'booking_mine':
        return const MyBookingsScreen();
    }
    return null;
  }

  Future<void> _markDone(Map line) async {
    final t = AppLocalizations.of(context);
    final id = (line['src'] as Map?)?['id'];
    if (id is! int) return;
    try {
      await context.read<AppState>().api.updateItem('pa/followups', id, {
        'status': 'done',
        'completed_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.psecDoneToast)));
      _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.saveFailed)));
    }
  }

  Future<void> _tell(Map line, Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final at = DateTime.tryParse('${line['start'] ?? ''}');
    final when = at == null ? '' : psWhen(context, at);
    final place = '${line['place'] ?? ''}'.trim();
    await psOpenChatWithDraft(context,
        circleId: p['id'] as int,
        name: '${p['name']}',
        text: t.psecInviteText('${p['name']}', '${line['title'] ?? ''}',
            place.isEmpty ? when : '$when, $place'));
  }

  Future<void> _remind(Map line, Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final id = (line['src'] as Map?)?['id'];
    await psOpenChatWithDraft(context,
        circleId: p['id'] as int,
        name: '${p['name']}',
        text: t.psecNudgeText('${p['name']}', '${line['title'] ?? ''}'));
    if (!mounted || id is! int) return;
    try {
      await context.read<AppState>().api.updateItem('pa/followups', id,
          {'last_nudged_at': DateTime.now().toUtc().toIso8601String()});
    } catch (_) {} // best-effort: the nudge time is a convenience; the chat already opened
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final b = _brief;
    final children = <Widget>[_dictate(t), _actions(t)];
    if (_failed && b == null) {
      children.add(_failedBox(t));
    } else if (b == null) {
      children.add(const Padding(
          padding: EdgeInsets.all(Gap.xl),
          child: Center(child: CircularProgressIndicator())));
    } else if (b['empty'] == true) {
      children.add(_empty(t));
    } else {
      final next = b['next'];
      if (next is Map) children.add(_nextCard(next));
      for (final s in (b['sections'] as List? ?? const [])) {
        if (s is Map) children.add(_section(t, s));
      }
      children.add(Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Text(t.psecGroundedNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.ds.muted)),
      ));
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.psecTodayTitle), actions: [
        IconButton(
            tooltip: t.retry,
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('ps-today-list'),
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
          children: children,
        ),
      ),
    );
  }

  Widget _dictate(AppLocalizations t) => Padding(
        key: const ValueKey('ps-dictate'),
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.psecDictateLabel,
              style: AType.bodyMedium.copyWith(
                  color: Theme.of(context).colorScheme.ds.muted)),
          QuickAddBar(onCommit: _addTask),
        ]),
      );

  Widget _actions(AppLocalizations t) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          DsButton.secondary(buttonKey: const ValueKey('ps-act-pickup'), onPressed: _pickup, icon: Icons.content_paste_go_rounded, label: t.psecPickupTitle),
          DsButton.secondary(buttonKey: const ValueKey('ps-act-meeting'), onPressed: () => _open(const PaScheduleScreen()), icon: Icons.event_rounded, label: t.psecAddMeeting),
          DsButton.secondary(buttonKey: const ValueKey('ps-act-followup'), onPressed: () => _open(const LiaisonScreen()), icon: Icons.forward_to_inbox_rounded, label: t.psecAddFollowup),
        ]),
      );

  Widget _failedBox(AppLocalizations t) => Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(children: [
          Text(t.psecLoadFailed, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          DsButton(onPressed: _load, icon: Icons.refresh_rounded, label: t.retry),
        ]),
      );

  Widget _empty(AppLocalizations t) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('ps-today-empty'),
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: cs.ds.cardHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.wb_sunny_rounded, size: 40, color: cs.primary),
        const SizedBox(height: Gap.sm),
        Text(t.psecEmptyBenefit,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(t.psecEmptyHow,
            textAlign: TextAlign.center,
            style: AType.bodyMedium.copyWith(color: cs.ds.muted)),
        const SizedBox(height: Gap.md),
        DsButton(buttonKey: const ValueKey('ps-empty-add'), onPressed: () => _open(const PaScheduleScreen()), icon: Icons.event_rounded, label: t.psecAddMeeting),
      ]),
    );
  }

  Widget _nextCard(Map next) {
    final cs = Theme.of(context).colorScheme;
    return Padding(padding: const EdgeInsets.only(bottom: Gap.md), child: DsSurface(color: cs.ds.primarySoft,
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.schedule_rounded, color: cs.ds.primaryInk),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(_line(next),
                style: AType.bodyMedium.copyWith(
                    color: cs.ds.primaryInk, fontWeight: FontWeight.w700)),
          ),
        ]),
      ));
  }

  Widget _section(AppLocalizations t, Map s) {
    final cs = Theme.of(context).colorScheme;
    final key = '${s['key']}';
    final lines = (s['lines'] as List? ?? const []).whereType<Map>().toList();
    return Padding(padding: const EdgeInsets.only(bottom: Gap.md), child: DsSurface(flat: true, borderColor: Theme.of(context).colorScheme.ds.border,
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            header: true,
            child: Text(_txt(s, 'title'),
                style: AType.titleSmall
                    .copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: Gap.sm),
          for (final l in lines) _lineTile(t, key, l),
        ]),
      ));
  }

  Widget _lineTile(AppLocalizations t, String section, Map l) {
    final cs = Theme.of(context).colorScheme;
    final people = psCirclePeople(l['circle']);
    final state = '${l['state'] ?? ''}';
    final late = state == 'overdue';
    final buttons = <Widget>[];
    if (section == 'meetings') {
      for (final p in people) {
        buttons.add(DsButton.secondary(buttonKey: ValueKey('ps-tell-${p['id']}'), onPressed: () => _tell(l, p), icon: Icons.chat_rounded, label: t.psecTell('${p['name']}')));
      }
    } else if (section == 'followups') {
      for (final p in people) {
        buttons.add(DsButton.secondary(buttonKey: ValueKey('ps-remind-${p['id']}'), onPressed: () => _remind(l, p), icon: Icons.chat_rounded, label: t.psecRemind('${p['name']}')));
      }
      buttons.add(TextButton.icon(
        key: ValueKey('ps-done-${(l['src'] as Map?)?['id']}'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => _markDone(l),
        icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
        label: Text(t.psecMarkDone),
      ));
    }
    if (section == 'missed_calls') {
      // bizassist S4: call back from the chat (its call button) or write a
      // follow-up note ("call him back tomorrow 11 am") in one tap
      final who = '${l['counterpart'] ?? ''}';
      for (final p in people) {
        buttons.add(DsButton.secondary(
            buttonKey: ValueKey('ps-callback-${p['id']}'),
            onPressed: () => psOpenChatWithDraft(context,
                circleId: p['id'] as int, name: '${p['name']}', text: t.psecMissedDraft('${p['name']}')),
            icon: Icons.call_rounded,
            label: t.psecCallBack('${p['name']}')));
      }
      buttons.add(TextButton.icon(
        key: ValueKey('ps-missednote-${(l['src'] as Map?)?['id']}'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => _pickup(seed: t.psecMissedNoteSeed(who)),
        icon: const Icon(Icons.edit_note_rounded, size: 18),
        label: Text(t.psecAddNote),
      ));
    }
    final target = _sourceScreen(l);
    final row = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
                late
                    ? Icons.error_rounded
                    : (l['clash'] == true
                        ? Icons.warning_amber_rounded
                        : Icons.circle_outlined),
                size: 16,
                color: late || l['clash'] == true ? cs.error : cs.ds.muted),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(_line(l),
                style: AType.bodyMedium.copyWith(
                    color: late ? cs.error : cs.ds.text,
                    fontWeight: late ? FontWeight.w600 : FontWeight.normal)),
          ),
          if (target != null)
            Icon(Icons.chevron_right_rounded, size: 20, color: cs.ds.muted),
        ]);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (target == null)
          row
        else
          InkWell(
            key: ValueKey('ps-line-${(l['src'] as Map?)?['kind']}-${(l['src'] as Map?)?['id']}'),
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => _open(target),
            child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48), child: row),
          ),
        if (buttons.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: Gap.lg),
            child: Wrap(spacing: Gap.sm, children: buttons),
          ),
      ]),
    );
  }
}
