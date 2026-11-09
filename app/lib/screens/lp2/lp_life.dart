/// lpapp — LIFE ENGLISH (stage 1: 10 scenarios, bundled → offline).
///
/// Scenario list → scenario (key sentences with Bangla meaning, words,
/// listen with the phone's voice, "say it" pronunciation check) → ROLE-PLAY
/// (owner-approved screen 3): the AI officer's question bubble, the user's
/// answer, the yellow correction card, pronunciation percent and the
/// hold-to-speak button. Two modes:
///   * AI conversation — POST /lp/life/roleplay (Claude plays the officer /
///     seller through the shared AI router; free daily quota then credits).
///   * Guided practice — key-free and offline: the scenario's questions with
///     model answers; the phone's own speech recogniser scores pronunciation.
/// The microphone opens only while the user holds the button (first use
/// shows the app's reason screen) — no new permission.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../plans_screen.dart' show PlansScreen;
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/voice_input.dart';
import '../ielts_engine.dart' show alignWords, AlignResult;
import 'lp_data.dart';
import 'lp_ui.dart';

IconData lpScenarioIcon(String? name) => switch (name) {
      'flight' => Icons.flight_rounded,
      'assignment_ind' => Icons.assignment_ind_rounded,
      'storefront' => Icons.storefront_rounded,
      'subway' => Icons.subway_rounded,
      'directions_bus' => Icons.directions_bus_rounded,
      'signpost' => Icons.directions_rounded,
      'electric_rickshaw' => Icons.local_taxi_rounded,
      'local_hospital' => Icons.local_hospital_rounded,
      'account_balance' => Icons.account_balance_rounded,
      'work' => Icons.work_rounded,
      _ => Icons.chat_rounded,
    };

/// Tests: a fixed "heard" text instead of the microphone.
@visibleForTesting
VoiceDictation Function()? debugLpVoice;

VoiceDictation lpVoice() => (debugLpVoice ?? () => VoiceDictation(mode: 'en'))();

class LpLifeListScreen extends StatefulWidget {
  const LpLifeListScreen({super.key});
  @override
  State<LpLifeListScreen> createState() => _LpLifeListScreenState();
}

class _LpLifeListScreenState extends State<LpLifeListScreen> {
  List<Map<String, dynamic>> _items = const [];
  Set<String> _done = const {};
  bool _loading = true;
  Object? _fail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    try {
      _items = await LpContent.scenarios();
    } catch (e) {
      _fail = e;
    }
    try {
      final days = await context.read<AppState>().api.listItems(kLpDays);
      _done = {
        for (final d in days)
          if ('${d['kind']}'.startsWith('life:')) '${d['kind']}'.substring(5),
      };
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return Scaffold(appBar: AppBar(title: Text(tr.lp2LifeTitle)), body: const SkeletonList());
    if (_fail != null || _items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.lp2LifeTitle)),
        body: StateMessage(
          icon: Icons.error_outline_rounded,
          title: tr.loadFailed,
          message: honestFailText(tr, _fail, otherwise: tr.lp2ContentFail),
          action: FilledButton.tonalIcon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.lp2LifeTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(tr.lp2LifeIntro, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Icon(Icons.offline_pin_rounded, size: 18, color: Brand.onTint(context, Brand.success)),
            const SizedBox(width: Gap.xs),
            Expanded(child: Text(tr.lp2LifeOffline, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant))),
          ]),
          const SizedBox(height: Gap.md),
          for (final s in _items)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                key: Key('lp2-sc-${s['id']}'),
                minVerticalPadding: Gap.md,
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(lpScenarioIcon('${s['icon']}'), color: scheme.onPrimaryContainer),
                ),
                title: Text(lpLoc(context, s, 'title'), style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(tr.lp2LifeRole(lpLoc(context, s, 'role'))),
                trailing: _done.contains('${s['id']}')
                    ? Icon(Icons.check_circle_rounded, color: Brand.onTint(context, Brand.success))
                    : const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LpScenarioScreen(scenario: s)));
                  if (mounted) unawaited(_load());
                },
              ),
            ),
        ],
      ),
    );
  }
}

class LpScenarioScreen extends StatelessWidget {
  final Map<String, dynamic> scenario;
  const LpScenarioScreen({super.key, required this.scenario});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = scenario;
    final bn = lpBn(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(lpLoc(context, s, 'title')),
          bottom: TabBar(tabs: [Tab(text: tr.lp2KeySentences), Tab(text: tr.lp2Words)]),
        ),
        body: TabBarView(children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
            children: [
              Text(tr.lp2Goals, style: const TextStyle(fontWeight: FontWeight.w700)),
              for (final g in lpStrs(bn ? s['goals_bn'] : s['goals_en']))
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.check_rounded, size: 18, color: scheme.primary),
                    const SizedBox(width: Gap.xs),
                    Expanded(child: Text(g, style: const TextStyle(height: 1.4))),
                  ]),
                ),
              const SizedBox(height: Gap.md),
              for (final x in lpList(s['sentences']))
                Card(
                  margin: const EdgeInsets.only(bottom: Gap.sm),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${x['en']}', style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35)),
                          const SizedBox(height: Gap.xxs),
                          Text('${x['bn']}', style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
                        ]),
                      ),
                      LpListenButton(text: '${x['en']}'),
                      IconButton(
                        tooltip: tr.lp2SayIt,
                        constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
                        icon: const Icon(Icons.mic_none_rounded),
                        onPressed: () => showLpSayIt(context, '${x['en']}', '${x['bn']}'),
                      ),
                    ]),
                  ),
                ),
            ],
          ),
          ListView(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
            children: [
              for (final v in lpList(s['vocab']))
                Card(
                  margin: const EdgeInsets.only(bottom: Gap.sm),
                  child: ListTile(
                    title: Text('${v['w']}  ·  ${v['bn']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${v['ex'] ?? ''}'),
                    trailing: LpListenButton(text: '${v['w']}. ${v['ex'] ?? ''}'),
                  ),
                ),
            ],
          ),
        ]),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
            child: FilledButton.icon(
              key: const Key('lp2-roleplay'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => LpRolePlayScreen(scenario: s))),
              icon: const Icon(Icons.forum_rounded),
              label: Text(tr.lp2StartRolePlay(lpLoc(context, s, 'role'))),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Say it" sheet: hold to speak one sentence; the phone's speech recogniser
/// marks each word heard as said (free, on the phone).
Future<void> showLpSayIt(BuildContext context, String target, String meaning) => showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SayItSheet(target: target, meaning: meaning),
    );

class _SayItSheet extends StatefulWidget {
  final String target, meaning;
  final ValueChanged<int>? onScore;
  const _SayItSheet({required this.target, required this.meaning, this.onScore});
  @override
  State<_SayItSheet> createState() => _SayItSheetState();
}

class _SayItSheetState extends State<_SayItSheet> {
  late final VoiceDictation _voice = lpVoice();
  final _heard = TextEditingController();
  int? _score;
  List<String> _missed = const [];

  @override
  void dispose() {
    _voice.stop();
    _voice.dispose();
    _heard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
              child: Text(widget.target,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
          LpListenButton(text: widget.target),
        ]),
        Text(widget.meaning, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.lg),
        if (_score != null) ...[
          Align(alignment: AlignmentDirectional.centerStart, child: LpPronChip(percent: _score!)),
          const SizedBox(height: Gap.sm),
          Text(_heard.text, style: const TextStyle(fontStyle: FontStyle.italic)),
          if (_missed.isNotEmpty)
            Text(tr.lp2SayClearer(_missed.join(', ')), style: TextStyle(color: Brand.warnInk(context), height: 1.4)),
          const SizedBox(height: Gap.md),
        ],
        LpHoldToSpeak(
          voice: _voice,
          heard: _heard,
          onDone: (t) {
            final r = alignWords(widget.target, t);
            setState(() {
              _score = r.score;
              _missed = [for (final w in r.rows) if (w.status != 'ok') w.word];
            });
            widget.onScore?.call(r.score);
          },
        ),
        const SizedBox(height: Gap.sm),
        Text(tr.lp2PronHow, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
      ]),
    );
  }
}

// ======================= role-play (screen 3) =======================

class _Turn {
  final bool ai;
  final String text;
  String? fixWrong, fixRight, fixWhy;
  int? pron;
  bool good = false;
  _Turn(this.ai, this.text);
}

class LpRolePlayScreen extends StatefulWidget {
  final Map<String, dynamic> scenario;
  /// Gallery/tests: start in guided practice with these turns already done.
  final bool debugGuidedDone;
  const LpRolePlayScreen({super.key, required this.scenario, this.debugGuidedDone = false});
  @override
  State<LpRolePlayScreen> createState() => _LpRolePlayScreenState();
}

class _LpRolePlayScreenState extends State<LpRolePlayScreen> {
  late final VoiceDictation _voice = lpVoice();
  final _heard = TextEditingController();
  final _typed = TextEditingController();
  final _scroll = ScrollController();
  final List<_Turn> _turns = [];
  bool _guided = false, _busy = false, _typing = false, _logged = false;
  int _drill = 0;
  String? _note; // why AI conversation is not available right now
  int _userTurns = 0;

  Map<String, dynamic> get _s => widget.scenario;
  List<Map<String, dynamic>> get _drills => lpList(_s['drill']);

  @override
  void initState() {
    super.initState();
    if (!widget.debugGuidedDone) _turns.add(_Turn(true, '${_s['opening']}'));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.debugGuidedDone && _turns.isEmpty) {
      _guided = true;
      _turns.add(_Turn(true, '${_drills.first['q']}'));
      final a = '${_drills.first['a']}';
      final heard = a.replaceFirst(RegExp(r'\bwork\b'), 'walk');
      final r = alignWords(a, heard);
      _turns.add(_Turn(false, heard)
        ..pron = r.score
        ..fixRight = a
        ..fixWhy = _guidedWhy(r, '${_drills.first['bn']}'));
      _drill = 1;
      _turns.add(_Turn(true, '${_drills[1]['q']}'));
    }
  }

  @override
  void dispose() {
    _voice.stop();
    _voice.dispose();
    _heard.dispose();
    _typed.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _guidedWhy(AlignResult r, String bn) {
    final missed = [for (final w in r.rows) if (w.status != 'ok') w.word];
    final tr = AppLocalizations.of(context);
    final parts = <String>[if (lpBn(context)) bn];
    if (missed.isNotEmpty) parts.add(tr.lp2SayClearer(missed.join(', ')));
    return parts.join('\n');
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  void _logOnce() {
    if (_logged || _userTurns < 3) return;
    _logged = true;
    unawaited(lpLogPractice(context.read<AppState>().api, 'life:${_s['id']}', 10));
  }

  void _startGuided({String? note}) {
    setState(() {
      _guided = true;
      _note = note;
      _drill = 0;
      _turns
        ..clear()
        ..add(_Turn(true, '${_drills.first['q']}'));
    });
  }

  void _startAi() {
    setState(() {
      _guided = false;
      _note = null;
      _turns
        ..clear()
        ..add(_Turn(true, '${_s['opening']}'));
    });
  }

  Future<void> _answer(String text) async {
    final msg = text.trim();
    if (msg.isEmpty || _busy) return;
    _userTurns++;
    if (_guided) {
      final d = _drills[_drill % _drills.length];
      final r = alignWords('${d['a']}', msg);
      setState(() {
        _turns.add(_Turn(false, msg)
          ..pron = r.score
          ..good = r.score >= 90
          ..fixRight = r.score >= 90 ? null : '${d['a']}'
          ..fixWhy = r.score >= 90 ? null : _guidedWhy(r, '${d['bn']}'));
        _drill++;
        if (_drill < _drills.length) _turns.add(_Turn(true, '${_drills[_drill]['q']}'));
      });
      _logOnce();
      _toEnd();
      return;
    }
    final history = [
      for (final t in _turns) {'role': t.ai ? 'assistant' : 'user', 'content': t.text},
    ];
    final me = _Turn(false, msg);
    setState(() {
      _busy = true;
      _turns.add(me);
    });
    _toEnd();
    final tr = AppLocalizations.of(context);
    try {
      final r = await context.read<AppState>().api.postJson('/lp/life/roleplay', {
        'scenario_id': _s['id'],
        'history': history,
        'message': msg,
        'lang': lpBn(context) ? 'bn' : 'en',
      });
      if (!mounted) return;
      final st = '${r['ai_state']}';
      if (st != 'used' || '${r['reply'] ?? ''}'.trim().isEmpty) {
        setState(() {
          _turns.remove(me);
          _userTurns--;
        });
        _aiUnavailable(st);
      } else {
        final fix = r['fix'];
        setState(() {
          if (fix is Map && '${fix['right'] ?? ''}'.trim().isNotEmpty) {
            me
              ..fixWrong = '${fix['wrong'] ?? ''}'
              ..fixRight = '${fix['right']}'
              ..fixWhy = lpBn(context) ? '${fix['why_bn'] ?? ''}' : '${fix['why_en'] ?? ''}';
          } else {
            me.good = true;
          }
          _turns.add(_Turn(true, '${r['reply']}'));
        });
        _logOnce();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _turns.remove(me);
          _userTurns--;
        });
        lpToast(context, honestFailText(tr, e, otherwise: tr.lp2AiFail));
      }
    }
    if (mounted) setState(() => _busy = false);
    _toEnd();
  }

  void _aiUnavailable(String st) {
    final tr = AppLocalizations.of(context);
    final msg = switch (st) {
      'credits' => tr.lp2AiNoCredits,
      'premium' => tr.lp2AiPremium,
      'no_key' => tr.lp2AiNotConnected,
      _ => tr.lp2AiBusy,
    };
    showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(msg, style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () {
              Navigator.of(ctx).pop();
              _startGuided(note: msg);
            },
            icon: const Icon(Icons.school_rounded),
            label: Text(tr.lp2GuidedInstead),
          ),
          if (st == 'credits' || st == 'premium')
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlansScreen()));
              },
              child: Text(tr.lp2SeePlans),
            ),
        ]),
      ),
    );
  }

  /// "Say it right" on the latest correction: pronunciation of the better sentence.
  Future<void> _sayRight(_Turn t) async {
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SayItSheet(
          target: t.fixRight!,
          meaning: t.fixWhy ?? '',
          onScore: (s) {
            if (mounted) setState(() => t.pron = s);
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final role = lpLoc(context, _s, 'role');
    final finished = _guided && _drill >= _drills.length;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(lpLoc(context, _s, 'title'), overflow: TextOverflow.ellipsis),
          Text(tr.lp2LifeRole(role), style: AType.bodySmall),
        ]),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(tr.lp2ModeAi), icon: const Icon(Icons.auto_awesome_rounded)),
              ButtonSegment(value: true, label: Text(tr.lp2ModeGuided), icon: const Icon(Icons.school_rounded)),
            ],
            selected: {_guided},
            onSelectionChanged: (v) => v.first ? _startGuided() : _startAi(),
          ),
        ),
        if (_note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
            child: Text(_note!, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg),
            children: [
              for (final t in _turns) ...[
                _Bubble(turn: t, role: role),
                if (!t.ai && t.fixRight != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: LpFixCard(
                      wrong: t.fixWrong,
                      right: t.fixRight!,
                      why: t.fixWhy ?? '',
                      pron: t.pron,
                      action: _guided
                          ? null
                          : OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
                              onPressed: () => _sayRight(t),
                              icon: const Icon(Icons.mic_rounded),
                              label: Text(tr.lp2SayItRight),
                            ),
                    ),
                  ),
              ],
              if (_busy)
                Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Row(children: [
                    const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: Gap.sm),
                    Text(tr.lp2Thinking(role)),
                  ]),
                ),
              if (finished)
                Card(
                  color: Brand.success.withValues(alpha: 0.12),
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(tr.lp2GuidedDone, style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: Gap.sm),
                      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                        FilledButton.tonal(
                            style: FilledButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
                            onPressed: () => _startGuided(note: _note),
                            child: Text(tr.lp2Again)),
                        OutlinedButton(
                            style: OutlinedButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
                            onPressed: _startAi,
                            child: Text(tr.lp2ModeAi)),
                      ]),
                    ]),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
            child: _typing
                ? Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _typed,
                        maxLength: 400,
                        buildCounter: localCounter,
                        minLines: 1,
                        maxLines: 3,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (v) {
                          _typed.clear();
                          _answer(v);
                        },
                        decoration: InputDecoration(
                            hintText: tr.lp2TypeAnswer, border: const OutlineInputBorder()),
                      ),
                    ),
                    IconButton.filled(
                      tooltip: tr.lp2Send,
                      constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
                      onPressed: finished || _busy
                          ? null
                          : () {
                              final v = _typed.text;
                              _typed.clear();
                              _answer(v);
                            },
                      icon: const Icon(Icons.send_rounded),
                    ),
                    IconButton(
                      tooltip: tr.lp2HoldToSpeak,
                      constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
                      onPressed: () => setState(() => _typing = false),
                      icon: const Icon(Icons.mic_rounded),
                    ),
                  ])
                : Row(children: [
                    Expanded(
                      child: LpHoldToSpeak(
                        voice: _voice,
                        heard: _heard,
                        enabled: !finished && !_busy,
                        onDone: _answer,
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    IconButton(
                      key: const Key('lp2-type'),
                      tooltip: tr.lp2TypeAnswer,
                      constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
                      onPressed: () => setState(() => _typing = true),
                      icon: const Icon(Icons.keyboard_rounded),
                    ),
                  ]),
          ),
        ),
      ]),
    );
  }
}

class _Bubble extends StatelessWidget {
  final _Turn turn;
  final String role;
  const _Bubble({required this.turn, required this.role});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ai = turn.ai;
    final bg = ai ? scheme.surfaceContainerHighest : scheme.primaryContainer;
    final fg = ai ? scheme.onSurface : scheme.onPrimaryContainer;
    return Align(
      alignment: ai ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
        child: Container(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadiusDirectional.only(
              topStart: const Radius.circular(16),
              topEnd: const Radius.circular(16),
              bottomStart: Radius.circular(ai ? 4 : 16),
              bottomEnd: Radius.circular(ai ? 16 : 4),
            ).resolve(Directionality.of(context)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ai ? role : tr.lp2You, style: AType.bodySmall.copyWith(color: fg, fontWeight: FontWeight.w700)),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Flexible(child: Text(turn.text, style: TextStyle(color: fg, height: 1.4))),
              if (ai) LpListenButton(text: turn.text) else const SizedBox(width: Gap.sm),
            ]),
            if (!ai && (turn.good || (turn.pron != null && turn.fixRight == null)))
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs, right: Gap.sm),
                child: Wrap(spacing: Gap.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (turn.good)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.check_circle_rounded, size: 16, color: Brand.onTint(context, Brand.success)),
                      const SizedBox(width: Gap.xs),
                      Text(tr.lp2GoodEnglish,
                          style: AType.bodySmall.copyWith(color: Brand.onTint(context, Brand.success))),
                    ]),
                  if (turn.pron != null && turn.fixRight == null) LpPronChip(percent: turn.pron!),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}
