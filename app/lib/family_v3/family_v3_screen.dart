import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../carecall/carecall_new_screen.dart';
import '../feature_flags.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;
import '../l10n/app_localizations.dart';
import '../screens/circle_guardians_screen.dart';
import '../screens/emergency_hub_screen.dart';
import '../screens/family_alerts_screen.dart';
import '../screens/family_screen.dart';
import '../screens/guardian_journey_screen.dart';
import '../screens/nominee_screen.dart'; // svcclean
import '../screens/probashi/probashi_plan_screen.dart'; // svcclean
import '../screens/scam_screen.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/fam_card_section.dart' show FamCardScreen;
import '../widgets/family_push_banner.dart';
import '../widgets/local_counter.dart';
import '../widgets/skeleton.dart';
import '../widgets/voice_input.dart';
import 'fc_add_member.dart';
import 'fc_api.dart';
import 'fc_fix_guide.dart';
import 'fc_manage.dart'; // fcrest
import 'fc_member_card.dart';
import 'fc_member_page.dart';
import 'fc_section_page.dart';
import 'fc_slots.dart';
import 'fc_slots_register.dart';
import 'fc_status.dart';
import 'fc_text.dart';
import 'fc_widget_sync.dart';
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

/// fcscreen — SCREEN 1 FAMILY (owner order 9 Nov 10:50, a–j). One screen
/// replaces the 6 tabs; every old feature stays one tap away in More.
///   a family switcher (multi-family) · b status line · c ask bar (+mic)
///   d member cards, alerts first · e honest gray dashed cards + fix guide
///   f shared tasks ("I will do it") · g Today · h night news slot (fcbrain)
///   i More rows · j red 56 dp SOS button (fcsos sender; fallback Emergency).
/// Status is re-checked with the phone clock every minute (zero false green).
class FamilyV3Screen extends StatefulWidget {
  final DateTime? debugNow;

  /// Gallery: start scrolled (tasks / Today / More shots).
  final double debugScrollOffset;
  const FamilyV3Screen({super.key, this.debugNow, this.debugScrollOffset = 0});
  @override
  State<FamilyV3Screen> createState() => _FamilyV3ScreenState();
}

class _FamilyV3ScreenState extends State<FamilyV3Screen>
    with AdBlockedState<FamilyV3Screen> {
  Map<String, dynamic>? _fams;
  Map<String, dynamic>? _board;
  int? _fid;
  bool _loading = true;
  bool _failed = false;
  Timer? _tick;
  final _ask = TextEditingController();
  VoiceDictation? _voice;
  FcAskAnswer? _answer;
  bool _asking = false;
  late final ScrollController _scroll =
      ScrollController(initialScrollOffset: widget.debugScrollOffset);

  DateTime get _now => widget.debugNow ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    ApiClient? api;
    try {
      api = context.read<AppState>().api;
    } catch (_) {
      api = null; // a preview without AppState: slots without the server ask
    }
    fcRegisterSlots(api); // fcrest: fcsos + fcbrain + fcelder hooks
    _load();
    if (widget.debugNow == null) {
      // re-run the status rules with the phone clock (no network)
      _tick = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    _ask.dispose();
    _voice?.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;

  Future<void> _load({int? switchTo}) async {
    try {
      final f = await _api.fcFamilies();
      final ids = [
        for (final x in (f['families'] as List? ?? const []))
          if (x is Map) (x['id'] as num).toInt()
      ];
      var fid = switchTo ?? _fid;
      if (fid == null || !ids.contains(fid)) fid = ids.isEmpty ? null : ids.first;
      Map<String, dynamic>? board;
      if (fid != null) board = await _api.fcBoard(fid);
      _fams = f;
      _fid = fid;
      _board = board;
      _failed = false;
      if (board != null && mounted) FcWidgetSync.push(context, board);
    } catch (_) {
      _failed = _board == null;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _members => [
        for (final m in (_board?['members'] as List? ?? const []))
          if (m is Map) m.cast<String, dynamic>()
      ];

  String _nameOf(Map m) {
    final t = AppLocalizations.of(context);
    if (m['me'] == true) return t.fc3You;
    final l = '${m['label'] ?? ''}'.trim();
    return l.isNotEmpty ? l : '${m['name'] ?? ''}';
  }

  // ------------------------------------------------------------ actions
  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:$phone');
    try {
      await launchUrl(uri);
    } catch (e) {
      if (mounted) showActionFailed(context, 'fc3.call', e);
    }
  }

  void _openMember(Map<String, dynamic> m) {
    final fid = _fid;
    if (fid == null) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FcMemberPage(
              familyId: fid,
              userId: (m['user_id'] as num).toInt(),
              seed: m,
              debugNow: widget.debugNow,
              cardBuilder: (ctx, mm) => _card(mm, inPage: true),
              myRole: '${(_board?['me'] as Map?)?['role'] ?? ''}', // fcrest
            ))).then((_) {
      if (mounted) _load();
    });
  }

  void _fix(Map<String, dynamic> m) {
    final st = fcRecheck(m, _now);
    showFcFixGuide(context,
        name: _nameOf(m), reason: st.reason, brain: m['brain'] as Map?, isMe: m['me'] == true);
  }

  Future<void> _sos() async {
    final open = FcSlots.openSosSender;
    if (open != null) {
      await open(context, familyId: _fid);
    } else {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const EmergencyHubScreen()));
    }
    if (mounted) _load();
  }

  Future<void> _addMember() async {
    final fid = _fid;
    if (fid == null) return;
    await showFcAddMember(context,
        familyId: fid, inFamilyUserIds: {for (final m in _members) (m['user_id'] as num).toInt()});
    if (mounted) _load();
  }

  Future<void> _newFamily() async {
    final t = AppLocalizations.of(context);
    // fcrest: the shared sheet owns its controller (no disposed-controller assert)
    final name = await fcrTextSheet(context,
        title: t.fc3NewFamily, hint: t.fc3NewFamilyHint, max: 60,
        fieldKey: const ValueKey('fc3-new-family-name'), action: t.fc3Create);
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final r = await _api.fcCreateFamily(name.trim());
      final id = ((r['family'] as Map?)?['id'] as num?)?.toInt();
      await _load(switchTo: id);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) showActionFailed(context, 'fc3.newFamily', e);
    }
  }

  Future<void> _answerInvite(Map inv, bool yes) async {
    try {
      await _api.fcAnswerInvite((inv['membership_id'] as num).toInt(), yes);
      await _load(switchTo: yes ? (inv['family_id'] as num).toInt() : null);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) showActionFailed(context, 'fc3.invite', e);
    }
  }

  Future<void> _leave() async {
    final t = AppLocalizations.of(context);
    final fid = _fid;
    if (fid == null) return;
    final fam = '${(_board?['family'] as Map?)?['name'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.fc3MoreLeave),
        content: Text(t.fc3LeaveConfirm(fam)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              key: const ValueKey('fc3-leave-ok'),
              style: FilledButton.styleFrom(backgroundColor: Brand.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fc3Leave)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.fcLeave(fid);
      _fid = null;
      await _load();
    } catch (e) {
      if (mounted) showActionFailed(context, 'fc3.leave', e);
    }
  }

  // ---------------------------------------------------------------- ask
  FcAskContext _askCtx() => FcAskContext(_fid ?? 0, [
        for (final m in _members)
          {
            'userId': m['user_id'],
            'name': m['name'],
            'label': m['label'],
            'role': m['role'],
            'placeLabel': fcPlace(context, m['brain'] as Map?),
            'state': fcRecheck(m, _now).state,
            'reason': fcRecheck(m, _now).reason,
            'relation': m['relation'],
            'lastSeen': (m['brain'] as Map?)?['last_seen'],
            'battery': (m['brain'] as Map?)?['battery'],
            'paused': fcRecheck(m, _now).state == 'paused',
            'me': m['me'] == true,
          }
      ]);

  /// Last-resort offline answer: find a member's name / label in the question.
  FcAskAnswer? _localAnswer(String q) {
    final s = q.toLowerCase();
    for (final m in _members) {
      if (m['me'] == true) continue;
      final keys = ['${m['label'] ?? ''}', '${m['name'] ?? ''}']
          .map((x) => x.trim().toLowerCase())
          .where((x) => x.length >= 2);
      if (keys.any(s.contains)) {
        final st = fcRecheck(m, _now);
        final place = fcPlace(context, m['brain'] as Map?);
        final parts = [
          _nameOf(m),
          fcStateWord(AppLocalizations.of(context), st.state),
          if (st.state != 'ok') fcReason(context, st.reason, m['brain'] as Map?),
          if (place.isNotEmpty && st.state != 'stale') place,
        ];
        return FcAskAnswer(parts.join(' · '),
            memberUserId: (m['user_id'] as num).toInt(), action: 'open_member');
      }
    }
    return null;
  }

  Future<void> _doAsk() async {
    final q = _ask.text.trim();
    if (q.isEmpty || _fid == null) return;
    FocusScope.of(context).unfocus();
    setState(() => _asking = true);
    FcAskAnswer? a;
    try {
      a = FcSlots.askParser?.call(q, _askCtx());
    } catch (_) {
      a = null;
    }
    if (a == null) {
      try {
        final r = await FcSlots.serverAsk?.call(_fid!, q);
        if (r != null && r.text.isNotEmpty) a = r;
      } catch (_) {
        a = null; // fcbrain not deployed / offline -> local names
      }
    }
    a ??= _localAnswer(q);
    if (!mounted) return;
    setState(() {
      _asking = false;
      _answer = a ?? FcAskAnswer(AppLocalizations.of(context).fc3AskNoAnswer);
    });
  }

  void _act(FcAskAnswer a) {
    final m = _members.where((x) => x['user_id'] == a.memberUserId).toList();
    if (m.isEmpty) return;
    switch (a.action) {
      case 'call':
        final p = '${m.first['phone'] ?? ''}';
        if (p.isNotEmpty) _call(p);
      case 'location':
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const GuardianJourneyScreen(locationOnly: true)));
      default:
        _openMember(m.first);
    }
  }

  // ------------------------------------------------------------- pieces
  Widget _card(Map<String, dynamic> m, {bool inPage = false}) {
    final me = m['me'] == true;
    final phone = '${m['phone'] ?? ''}';
    final careOn = FeatureFlags.instance.isOn('care_call');
    return FcMemberCard(
      member: m,
      now: _now,
      onTap: inPage ? null : () => _openMember(m),
      onFix: () => _fix(m),
      onCall: !me && phone.isNotEmpty ? () => _call(phone) : null,
      onCareCall: !me && careOn
          ? () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CareCallNewScreen(person: {
                    'user_id': m['user_id'],
                    'name': _nameOf(m),
                    'initial': fcInitial(_nameOf(m)),
                  })))
          : null,
      onLocation: !me
          ? () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const GuardianJourneyScreen(locationOnly: true)))
          : null,
    );
  }

  Widget _switcher() {
    final t = AppLocalizations.of(context);
    final fams = [
      for (final f in (_fams?['families'] as List? ?? const []))
        if (f is Map) f
    ];
    return SingleChildScrollView(
      key: const ValueKey('fc3-switcher'),
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final f in fams)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: Gap.sm),
            child: Semantics(
              label: t.fc3SwitcherA11y('${f['name']}'),
              selected: f['id'] == _fid,
              excludeSemantics: true,
              child: ChoiceChip(
                key: ValueKey('fc3-fam-${f['id']}'),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text('${f['name']}'),
                selected: f['id'] == _fid,
                onSelected: (_) {
                  setState(() => _loading = true);
                  _load(switchTo: (f['id'] as num).toInt());
                },
              ),
            ),
          ),
        ActionChip(
          key: const ValueKey('fc3-new-family'),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          avatar: const Icon(Icons.add_rounded, size: 18),
          label: Text(t.fc3NewFamily),
          onPressed: _newFamily,
        ),
      ]),
    );
  }

  List<Widget> _invites() {
    final t = AppLocalizations.of(context);
    return [
      for (final inv in (_fams?['invites'] as List? ?? const []))
        if (inv is Map)
          Card(
            key: ValueKey('fc3-invite-${inv['membership_id']}'),
            margin: const EdgeInsets.only(top: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.fc3InviteFrom('${inv['invited_by_name']}', '${inv['family_name']}'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  Text(t.fc3InviteConsent),
                  const SizedBox(height: Gap.sm),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    FilledButton(
                        key: ValueKey('fc3-join-${inv['membership_id']}'),
                        onPressed: () => _answerInvite(inv, true),
                        child: Text(t.fc3Join)),
                    OutlinedButton(
                        onPressed: () => _answerInvite(inv, false), child: Text(t.fc3NoThanks)),
                  ]),
                ],
              ),
            ),
          ),
    ];
  }

  Widget _statusLine() {
    final t = AppLocalizations.of(context);
    final others = [
      for (final m in _members)
        if (m['me'] != true)
          () {
            final st = fcRecheck(m, _now);
            return {'user_id': m['user_id'], 'name': _nameOf(m), 'state': st.state, 'reason': st.reason};
          }()
    ];
    final line = fcFamilyLine(others);
    final m = others.where((x) => x['user_id'] == line.userId).toList();
    final brain = m.isEmpty
        ? null
        : _members.firstWhere((x) => x['user_id'] == line.userId)['brain'] as Map?;
    final (String title, String? sub, IconData icon) = switch (line.state) {
      'ok' => (t.fc3LineOk, t.fc3LineOkSub, Icons.check_circle_rounded),
      'sos' => (t.fc3LineSos(line.name), null, Icons.sos_rounded),
      'check' => (t.fc3LineCheck(line.name), fcReason(context, line.reason, brain), Icons.error_rounded),
      'stale' => (t.fc3LineStale(line.name), fcReason(context, line.reason, brain), Icons.help_rounded),
      _ => (t.fc3LineEmpty, null, Icons.family_restroom_rounded),
    };
    final more = line.count > 1 && line.state != 'ok' ? ' · ${t.fc3LineMore(fcDigits(context, line.count - 1))}' : '';
    final ink = fcInk(context, line.state == 'empty' ? 'stale' : line.state);
    final bg = switch (line.state) {
      'ok' => Brand.success.withValues(alpha: 0.12),
      'check' => Brand.warning.withValues(alpha: 0.14),
      'sos' => Brand.danger.withValues(alpha: 0.14),
      _ => Theme.of(context).colorScheme.surfaceContainerHighest,
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: ValueKey('fc3-line-${line.state}'),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Icon(icon, color: ink, size: 32),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$title$more',
                  style: TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 18)),
              if (sub != null) Text(sub),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _askBar() {
    final t = AppLocalizations.of(context);
    _voice ??= VoiceDictation();
    final a = _answer;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: const ValueKey('fc3-ask'),
        controller: _ask,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _doAsk(),
        inputFormatters: [LengthLimitingTextInputFormatter(200)],
        decoration: InputDecoration(
          hintText: t.fc3AskHint,
          hintMaxLines: 2,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
          contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            VoiceMicButton(voice: _voice!, input: _ask),
            IconButton(
              key: const ValueKey('fc3-ask-send'),
              tooltip: t.fc3AskSend,
              onPressed: _asking ? null : _doAsk,
              icon: _asking
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
            ),
          ]),
        ),
      ),
      if (a != null)
        Card(
          key: const ValueKey('fc3-ask-answer'),
          margin: const EdgeInsets.only(top: Gap.xs),
          child: ListTile(
            title: Text(a.text),
            trailing: a.memberUserId != null
                ? TextButton(onPressed: () => _act(a), child: Text(t.fc3AskOpen))
                : null,
          ),
        ),
    ]);
  }

  Widget _section(String title, {Widget? trailing, Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xs),
        child: Row(children: [
          Expanded(
            child: Text(title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
          if (trailing != null) trailing,
        ]),
      );

  List<Widget> _tasks() {
    final t = AppLocalizations.of(context);
    final tasks = [
      for (final x in (_board?['tasks'] as List? ?? const []))
        if (x is Map) x
    ];
    return [
      _section(t.fc3TasksTitle,
          key: const ValueKey('fc3-tasks'),
          trailing: TextButton.icon(
              key: const ValueKey('fc3-task-add'),
              onPressed: _addTask,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.fc3TaskAdd))),
      if (tasks.isEmpty)
        Text(t.fc3TaskEmpty, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      for (final x in tasks) _taskTile(x),
    ];
  }

  Widget _taskTile(Map x) {
    final t = AppLocalizations.of(context);
    final done = x['done'] == true;
    final mine = x['mine'] == true;
    final taken = x['taken_by'] != null;
    final kind = switch ('${x['kind']}') {
      'medicine' => (t.fc3TaskKindMedicine, Icons.medication_rounded),
      'doctor' => (t.fc3TaskKindDoctor, Icons.local_hospital_rounded),
      'bill' => (t.fc3TaskKindBill, Icons.receipt_long_rounded),
      _ => (t.fc3TaskKindOther, Icons.task_alt_rounded),
    };
    final due = x['due_date'] != null ? t.fc3TaskDue(_dateLabel('${x['due_date']}')) : '';
    final who = done
        ? t.fc3TaskDoneBy('${x['done_by_name']}')
        : mine
            ? t.fc3TaskTakenByMe
            : taken
                ? t.fc3TaskTakenBy('${x['taken_by_name']}')
                : '';
    final id = (x['id'] as num).toInt();
    return Card(
      key: ValueKey('fc3-task-$id'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(kind.$2, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${x['title']}',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        decoration: done ? TextDecoration.lineThrough : null)),
                Text([kind.$1, if (due.isNotEmpty) due].join(' · '),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                if (who.isNotEmpty)
                  Text(who, style: TextStyle(color: fcInk(context, 'ok'), fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
          if (!done) ...[
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              if (!taken)
                FilledButton(
                    key: ValueKey('fc3-task-take-$id'),
                    onPressed: () => _taskAct(id, 'take'),
                    child: Text(t.fc3TaskWillDo)),
              if (mine)
                OutlinedButton(onPressed: () => _taskAct(id, 'release'), child: Text(t.fc3TaskRelease)),
              OutlinedButton.icon(
                  key: ValueKey('fc3-task-done-$id'),
                  onPressed: () => _taskAct(id, 'done'),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(t.fc3TaskDone)),
            ]),
          ],
        ]),
      ),
    );
  }

  String _dateLabel(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return fcDigits(context, MaterialLocalizations.of(context).formatShortDate(d));
  }

  Future<void> _taskAct(int id, String action) async {
    try {
      await _api.fcTaskAction(id, action);
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        _load();
      }
    } catch (e) {
      if (mounted) showActionFailed(context, 'fc3.task', e);
    }
  }

  Future<void> _addTask() async {
    final fid = _fid;
    if (fid == null) return;
    final r = await showAppSheet<(String, String, DateTime?)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _TaskForm(),
    );
    if (r == null || !mounted) return;
    try {
      final d = r.$3;
      await _api.fcAddTask(fid, r.$1,
          kind: r.$2,
          dueDate: d == null
              ? null
              : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (mounted) showActionFailed(context, 'fc3.addTask', e);
    }
  }

  List<Widget> _today() {
    final t = AppLocalizations.of(context);
    final td = (_board?['today'] as Map?) ?? const {};
    final cc = (td['carecalls'] as Map?) ?? const {};
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final ccTotal = n(cc['done']) + n(cc['missed']) + n(cc['pending']);
    final bills = n(td['bills_due']);
    final bazar = n(td['bazar_open']);
    final births = [for (final b in (td['birthdays'] as List? ?? const [])) '$b'];
    Widget row(IconData i, String s, {Color? ink, VoidCallback? onTap}) => ListTile(
          contentPadding: EdgeInsets.zero,
          minTileHeight: 48,
          leading: Icon(i, color: ink),
          title: Text(s, style: TextStyle(color: ink)),
          trailing: onTap != null ? const Icon(Icons.chevron_right_rounded) : null,
          onTap: onTap,
        );
    return [
      _section(t.fc3TodayTitle, key: const ValueKey('fc3-today')),
      row(
          Icons.record_voice_over_rounded,
          ccTotal == 0
              ? t.fc3TodayCareNone
              : t.fc3TodayCare(fcDigits(context, n(cc['done'])), fcDigits(context, n(cc['missed'])),
                  fcDigits(context, n(cc['pending']))),
          ink: n(cc['missed']) > 0 ? fcInk(context, 'check') : null),
      row(Icons.receipt_long_rounded,
          bills == 0 ? t.fc3TodayBillsNone : t.fc3TodayBills(fcDigits(context, bills)),
          ink: bills > 0 ? fcInk(context, 'check') : null),
      if (births.isNotEmpty) row(Icons.cake_rounded, t.fc3TodayBirthday(births.join(', '))),
      row(Icons.shopping_basket_rounded,
          bazar == 0 ? t.fc3TodayBazarNone : t.fc3TodayBazar(fcDigits(context, bazar)),
          onTap: () => _openSection(FcSection.papers, t.fc3MorePapers)),
    ];
  }

  void _openSection(FcSection s, String title) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => FcSectionPage(section: s, title: title)))
      .then((_) => _load());

  List<Widget> _more() {
    final t = AppLocalizations.of(context);
    final abroad = _board?['someone_abroad'] == true;
    Widget row(Key key, IconData i, String title, VoidCallback onTap, {String? sub, Color? ink}) =>
        ListTile(
          key: key,
          contentPadding: EdgeInsets.zero,
          minTileHeight: 56,
          leading: Icon(i, color: ink ?? Theme.of(context).colorScheme.primary),
          title: Text(title, style: ink != null ? TextStyle(color: ink) : null),
          subtitle: sub != null ? Text(sub) : null,
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        );
    final extra = FcSlots.moreRows?.call(context, _fid ?? 0) ?? const <Widget>[];
    return [
      _section(t.fc3MoreTitle, key: const ValueKey('fc3-more')),
      row(const ValueKey('fc3-more-add'), Icons.person_add_alt_1_rounded, t.fc3MoreAdd, _addMember),
      row(const ValueKey('fc3-more-kids'), Icons.school_rounded, t.fc3MoreKids,
          () => _openSection(FcSection.school, t.fc3MoreKids)),
      row(const ValueKey('fc3-more-ledger'), Icons.account_balance_wallet_rounded, t.fc3MoreLedger,
          () => _openSection(FcSection.ledger, t.fc3MoreLedger)),
      row(const ValueKey('fc3-more-papers'), Icons.lock_rounded, t.fc3MorePapers,
          () => _openSection(FcSection.papers, t.fc3MorePapers),
          sub: t.fc3MorePapersSub),
      if (abroad)
        row(const ValueKey('fc3-more-probashi'), Icons.flight_rounded, t.fc3MoreProbashi,
            () => _openSection(FcSection.probashi, t.fc3MoreProbashi)),
      row(const ValueKey('fc3-more-card'), Icons.badge_rounded, t.fc3MoreCard,
          () => _openSection(FcSection.card, t.fc3MoreCard)),
      row(const ValueKey('fc3-more-members'), Icons.groups_rounded, t.fc3MoreMembers,
          () => _openSection(FcSection.members, t.fc3MoreMembers)),
      if ((_board?['me'] as Map?)?['role'] == 'admin' && _fid != null) // fcrest
        row(const ValueKey('fcr-more-rename'), Icons.edit_rounded, t.fcrRename, () async {
          final fam = '${(_board?['family'] as Map?)?['name'] ?? ''}';
          if (await fcrRenameFamily(context, _fid!, fam) && mounted) _load();
        }, sub: '${(_board?['family'] as Map?)?['name'] ?? ''}'),
      if (kMedicalFeaturesAllowed)
        row(const ValueKey('fc3-more-medical'), Icons.medication_rounded, t.fc3MoreMedical,
            () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const FamilyScreen(initialTab: 'today')))),
      if (FcSlots.privacyScreen != null && _fid != null)
        row(const ValueKey('fc3-more-privacy'), Icons.privacy_tip_rounded, t.fc3MorePrivacy,
            () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (c) => FcSlots.privacyScreen!(c, _fid!)))
                .then((_) => _load())),
      row(const ValueKey('fa100-tile'), Icons.notifications_active_rounded, t.fa100Title,
          () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const FamilyAlertsScreen()))
              .then((_) => _load())),
      // svcclean (owner 10 Nov): Guardians & who sees me, Nominee access and
      // the Probashi family plan live HERE now (no separate All Services
      // tiles); their old routes land on Family and open the row's screen.
      row(const ValueKey('cga-tile'), Icons.supervisor_account_rounded, t.g2SidebarLabel,
          () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const CircleGuardiansScreen(),
              settings: const RouteSettings(name: 'guardians')))),
      if (FeatureFlags.instance.isOn('nominee'))
        row(const ValueKey('svc-fam-nominee'), Icons.shield_rounded, t.nominee,
            () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const NomineeScreen(),
                settings: const RouteSettings(name: 'nominee'))),
            sub: t.svcFamNomineeSub),
      if (abroad && FeatureFlags.instance.isOn('probashi_plan'))
        row(const ValueKey('svc-fam-probashi-plan'), Icons.flight_takeoff_rounded, t.pbsTitle,
            () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ProbashiPlanScreen(),
                settings: const RouteSettings(name: 'probashi_plan')))),
      row(const ValueKey('fc3-more-scam'), Icons.shield_rounded, t.familyScamCheckerTitle,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScamScreen()))),
      ...extra,
      row(const ValueKey('fc3-more-leave'), Icons.logout_rounded, t.fc3MoreLeave, _leave,
          ink: fcInk(context, 'sos')),
    ];
  }

  Widget _empty() {
    final t = AppLocalizations.of(context);
    return Padding(
      key: const ValueKey('fc3-empty'),
      padding: const EdgeInsets.symmetric(vertical: Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.family_restroom_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: Gap.sm),
        Text(t.fc3EmptyTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.fc3EmptyBody, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          key: const ValueKey('fc3-empty-add'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _addMember,
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: Text(t.fc3MoreAdd),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.fc3EmptyHow,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _sosBar() {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm)),
      child: Semantics(
        button: true,
        label: t.fc3SosA11y,
        excludeSemantics: true,
        child: FilledButton.icon(
          key: const ValueKey('fc3-sos'),
          style: FilledButton.styleFrom(
            backgroundColor: Brand.danger,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(56),
            // keep the theme's font family (a bare TextStyle drops it)
            textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          onPressed: _sos,
          icon: const Icon(Icons.sos_rounded, size: 28),
          label: Text(t.fc3Sos),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final members = _members;
    final others = members.where((m) => m['me'] != true).toList()
      ..sort((a, b) {
        final c = fcStateRank(fcRecheck(a, _now).state).compareTo(fcStateRank(fcRecheck(b, _now).state));
        return c != 0 ? c : _nameOf(a).compareTo(_nameOf(b));
      });
    final me = members.where((m) => m['me'] == true).toList();
    final invited = [
      for (final x in (_board?['invited'] as List? ?? const []))
        if (x is Map) x
    ];
    final night = (_fid != null) ? FcSlots.nightNewsCard?.call(context, _fid!) : null;
    final journey = (_fid != null) ? FcSlots.journeyTile?.call(context, _fid!) : null;
    return Scaffold(
      appBar: AppBar(title: Text(t.fc3Title), actions: [
        IconButton(
            tooltip: t.refresh,
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
            icon: const Icon(Icons.sync_rounded)),
      ]),
      bottomNavigationBar: _sosBar(),
      body: _loading
          ? const SkeletonList()
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: t.loadFailed,
                  message: t.fcOfflineCardHint,
                  tint: Brand.danger,
                  action: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, alignment: WrapAlignment.center, children: [
                    FilledButton.icon(
                      onPressed: () {
                        setState(() => _loading = true);
                        _load();
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('fc-offline-card'),
                      onPressed: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => const FamCardScreen())),
                      icon: const Icon(Icons.badge_rounded),
                      label: Text(t.fcOpenSavedCard),
                    ),
                  ]),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    key: const ValueKey('fc3-list'),
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
                    children: [
                      _switcher(),
                      ..._invites(),
                      const FamilyPushBanner(),
                      const SizedBox(height: Gap.sm),
                      _statusLine(),
                      if (others.isNotEmpty) ...[
                        const SizedBox(height: Gap.md),
                        _askBar(),
                      ],
                      if (journey != null) ...[const SizedBox(height: Gap.md), journey],
                      if (night != null) ...[const SizedBox(height: Gap.md), night],
                      if (others.isEmpty) _empty(),
                      for (final m in [...others, ...me])
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.md),
                          child: _card(m),
                        ),
                      for (final x in invited)
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.sm),
                          child: Text(t.fc3Waiting('${x['name']}'),
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ),
                      ..._tasks(),
                      ..._today(),
                      ..._more(),
                    ],
                  ),
                ),
    );
  }
}

class _TaskForm extends StatefulWidget {
  const _TaskForm();
  @override
  State<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<_TaskForm> {
  final _title = TextEditingController();
  String _kind = 'medicine';
  DateTime? _due;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final kinds = [
      ('medicine', t.fc3TaskKindMedicine),
      ('doctor', t.fc3TaskKindDoctor),
      ('bill', t.fc3TaskKindBill),
      ('other', t.fc3TaskKindOther),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.fc3TaskAdd,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          TextField(
            key: const ValueKey('fc3-task-title'),
            controller: _title,
            autofocus: true,
            maxLength: 120,
            buildCounter: localCounter,
            decoration: InputDecoration(labelText: t.fc3TaskTitleHint),
          ),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final (k, label) in kinds)
              ChoiceChip(
                key: ValueKey('fc3-task-kind-$k'),
                label: Text(label),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                  context: context,
                  firstDate: DateTime(now.year, now.month, now.day),
                  lastDate: now.add(const Duration(days: 365)),
                  initialDate: _due ?? now);
              if (d != null) setState(() => _due = d);
            },
            icon: const Icon(Icons.event_rounded),
            label: Text(_due == null
                ? t.fc3TaskPickDate
                : t.fc3TaskDue(fcDigits(context, MaterialLocalizations.of(context).formatShortDate(_due!)))),
          ),
          const SizedBox(height: Gap.sm),
          FilledButton(
            key: const ValueKey('fc3-task-save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () {
              final s = _title.text.trim();
              if (s.isEmpty) return;
              Navigator.pop(context, (s, _kind, _due));
            },
            child: Text(t.fc3Save),
          ),
        ],
      ),
    );
  }
}
