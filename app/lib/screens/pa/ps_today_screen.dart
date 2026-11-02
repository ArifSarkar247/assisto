import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../ps/ps_circle.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
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
      final b = await context.read<AppState>().api.getJson('/ps/today');
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

  Future<void> _pickup() async {
    final added = await showPsPickupSheet(context);
    if (added == true && mounted) _load();
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
    final children = <Widget>[_actions(t)];
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
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
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

  Widget _actions(AppLocalizations t) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.tonalIcon(
            key: const ValueKey('ps-act-pickup'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _pickup,
            icon: const Icon(Icons.content_paste_go_rounded),
            label: Text(t.psecPickupTitle),
          ),
          OutlinedButton.icon(
            key: const ValueKey('ps-act-meeting'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => _open(const PaScheduleScreen()),
            icon: const Icon(Icons.event_rounded),
            label: Text(t.psecAddMeeting),
          ),
          OutlinedButton.icon(
            key: const ValueKey('ps-act-followup'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => _open(const LiaisonScreen()),
            icon: const Icon(Icons.forward_to_inbox_rounded),
            label: Text(t.psecAddFollowup),
          ),
        ]),
      );

  Widget _failedBox(AppLocalizations t) => Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(children: [
          Text(t.psecLoadFailed, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.retry)),
        ]),
      );

  Widget _empty(AppLocalizations t) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('ps-today-empty'),
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
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
            style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          key: const ValueKey('ps-empty-add'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: () => _open(const PaScheduleScreen()),
          icon: const Icon(Icons.event_rounded),
          label: Text(t.psecAddMeeting),
        ),
      ]),
    );
  }

  Widget _nextCard(Map next) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer,
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.schedule_rounded, color: cs.onPrimaryContainer),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(_line(next),
                style: TextStyle(
                    color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }

  Widget _section(AppLocalizations t, Map s) {
    final cs = Theme.of(context).colorScheme;
    final key = '${s['key']}';
    final lines = (s['lines'] as List? ?? const []).whereType<Map>().toList();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
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
      ),
    );
  }

  Widget _lineTile(AppLocalizations t, String section, Map l) {
    final cs = Theme.of(context).colorScheme;
    final people = psCirclePeople(l['circle']);
    final state = '${l['state'] ?? ''}';
    final late = state == 'overdue';
    final buttons = <Widget>[];
    if (section == 'meetings') {
      for (final p in people) {
        buttons.add(OutlinedButton.icon(
          key: ValueKey('ps-tell-${p['id']}'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => _tell(l, p),
          icon: const Icon(Icons.chat_rounded, size: 18),
          label: Text(t.psecTell('${p['name']}')),
        ));
      }
    } else if (section == 'followups') {
      for (final p in people) {
        buttons.add(OutlinedButton.icon(
          key: ValueKey('ps-remind-${p['id']}'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => _remind(l, p),
          icon: const Icon(Icons.chat_rounded, size: 18),
          label: Text(t.psecRemind('${p['name']}')),
        ));
      }
      buttons.add(TextButton.icon(
        key: ValueKey('ps-done-${(l['src'] as Map?)?['id']}'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => _markDone(l),
        icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
        label: Text(t.psecMarkDone),
      ));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
                late
                    ? Icons.error_rounded
                    : (l['clash'] == true
                        ? Icons.warning_amber_rounded
                        : Icons.circle_outlined),
                size: 16,
                color: late || l['clash'] == true ? cs.error : cs.onSurfaceVariant),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(_line(l),
                style: TextStyle(
                    color: late ? cs.error : cs.onSurface,
                    fontWeight: late ? FontWeight.w600 : FontWeight.normal)),
          ),
        ]),
        if (buttons.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: Gap.lg),
            child: Wrap(spacing: Gap.sm, children: buttons),
          ),
      ]),
    );
  }
}
