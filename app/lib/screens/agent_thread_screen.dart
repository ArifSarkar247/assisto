import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../widgets/ai_action_buttons.dart'; // aifinal
import '../widgets/ai_generated_label.dart'; // aifinal
import '../widgets/ai_level_picker.dart'; // aifinal
import '../widgets/ai_markdown.dart'; // aifinal
import '../api.dart';
import '../chat_vision/chat_photo.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../payments/credits_out_sheet.dart';
import '../widgets/chatnav.dart';
import '../widgets/chat_cards.dart';
import '../widgets/voice_input.dart';
import '../widgets/ai_report.dart';
import '../widgets/ai_turn_meta.dart'; // aibar

/// own-device (owner 24 Oct): an /alerts row about the signed-in user's OWN
/// protected phone (anti-theft, owner_id == me). The home urgent card never
/// shows these — he is holding the phone. Family members' phones still show.
@visibleForTesting
bool isOwnDeviceAlert(Map<String, dynamic> a, int? me) {
  if (a['own_device'] == true) return true;
  final t = a['type'];
  if (t != 'antitheft' && t != 'security') return false;
  final o = a['owner_id'];
  if (me == null || o == null) return false;
  return '$o' == '$me';
}

class _Msg {
  final bool user;
  // aileft: an answer being typed out (streamed) grows in place
  String text;
  bool streaming = false;
  final List<Map<String, dynamic>> cards;

  /// h1-home: an attached photo turn (kept on this device only — the photo is
  /// never saved to the chat history).
  final ChatPhotoRequest? photo;

  /// ai-report: a server answer the user can report (not local notices such
  /// as the greeting, "send failed" or "undone"). [id] = stored message id.
  final bool reportable;
  final String? id;

  /// aibar: a user turn's idempotency id ("Send again" reuses it), whether it
  /// failed to go out (+ why), and an answer's credit meta.
  String? clientId;
  bool failed = false;
  Object? failCause;
  Map<String, dynamic> meta = const {};
  _Msg(this.user, this.text,
      [this.cards = const [], this.photo, this.reportable = false, this.id]);
}

/// The heart of the app: a conversation with Assisto. The screen is only the
/// thread — modules live in the drawer. Rich cards appear inline with actions.
class AgentThreadScreen extends StatefulWidget {
  /// Preview/screenshot seed: a list of {user: bool, text: String, cards: [...]}.
  /// When set, the thread renders this conversation instead of polling alerts.
  final List<Map<String, dynamic>>? debugSeed;
  final bool debugListening;

  /// Fired when the text input gains focus (A1). The home screen uses this to
  /// collapse the Discover/suggestion area so the chat + input fill the screen
  /// and the keyboard never covers what the user is typing.
  final VoidCallback? onInputFocus;

  /// Saved home conversation to reopen (from the sidebar history). Null =
  /// continue the remembered home thread (or start fresh when [fresh]).
  final String? sessionId;

  /// "New chat": start an empty thread and forget the remembered one.
  final bool fresh;

  /// Assistant greeting shown when the thread is empty (home uses this
  /// instead of the built-in welcome cards).
  final String? greeting;

  /// Text to send as soon as the thread is ready (a tapped home suggestion) —
  /// it goes through the normal send path, so it is saved like any turn.
  final String? initialSend;

  /// h1-home: builds the top of the empty-thread welcome. Gets the normal
  /// logo + "Hi, I'm Assisto" block, whether the input has focus and the
  /// height the welcome area really has; the home returns its ad hero (which
  /// falls back to that block). Null = the block.
  final Widget Function(BuildContext context, Widget logoBlock, bool collapsed,
      double availableHeight)? heroBuilder;

  /// Test seam for the photo picker (camera / gallery).
  final ChatPhotoPicker? photoPicker;
  const AgentThreadScreen(
      {super.key,
      this.debugSeed,
      this.debugListening = false,
      this.onInputFocus,
      this.sessionId,
      this.fresh = false,
      this.greeting,
      this.initialSend,
      this.heroBuilder,
      this.photoPicker,
      this.starters = const [],
      this.showLevels = false});

  /// aifinal PART 3: the answer-level picker above the input (Assisto AI
  /// screen only; hidden while the owner switch is off).
  final bool showLevels;

  /// aifinal (owner AI chat history order 4 Nov 00:33): 3-4 starter questions
  /// shown on an EMPTY chat (Assisto AI screen only; the home passes none).
  final List<String> starters;

  /// SharedPreferences key of the home thread that survives restarts.
  static const sessionKey = 'home_session_id';

  /// Whether a failed restore means the saved thread is GONE (deleted, or
  /// not this user's) and must be forgotten. Offline / timeout / 5xx keep it:
  /// the thread is still on the server and comes back on the next start.
  static bool forgetsSession(Object error) =>
      error is ApiException &&
      (error.status == 404 || error.status == 403 || error.status == 400);
  @override
  State<AgentThreadScreen> createState() => _AgentThreadScreenState();
}

class _AgentThreadScreenState extends State<AgentThreadScreen>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  final List<_Msg> _msgs = [];
  bool _sending = false;

  // aileft: home streaming + Stop (same SSE protocol as Assisto AI).
  StreamSubscription<Map<String, dynamic>>? _streamSub;
  Timer? _typeTimer;
  String _pending = '';
  Completer<void>? _drained;
  _Msg? _live;
  _Msg? _liveFor;
  Completer<Map<String, dynamic>?>? _turn;

  // Live speech-to-text into the input (shared with Assisto AI chat).
  late final VoiceDictation _voice = VoiceDictation();
  String? _sessionId;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    // A1 — the thread's input must always sit above the keyboard and the list
    // must auto-scroll when the keyboard opens. Observe metrics for that.
    WidgetsBinding.instance.addObserver(this);
    _voice.addListener(_rebuild);
    // A1 — the home collapses its Discover cards as soon as the input focuses.
    _inputFocus.addListener(() {
      // h1-home: the welcome hero collapses while the input has focus
      if (widget.heroBuilder != null && _msgs.isEmpty) _rebuild();
      if (_inputFocus.hasFocus) {
        widget.onInputFocus?.call();
        _toBottom();
      }
    });
    if (widget.debugSeed != null) {
      for (final m in widget.debugSeed!) {
        final seeded = _Msg(
            m['user'] == true,
            (m['text'] ?? '').toString(),
            ((m['cards'] ?? []) as List).cast<Map<String, dynamic>>(),
            null,
            m['user'] != true && m['reportable'] != false,
            m['id']?.toString());
        // aibar (gallery): a not-sent turn and an answer's credit meta
        if (m['failed'] == true) seeded.failed = true;
        final meta = m['meta'];
        if (meta is Map) seeded.meta = meta.cast<String, dynamic>();
        _msgs.add(seeded);
      }
      return; // previews don't poll
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _voice.loadMode();
      _restoreThread();
    });
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  // Reopen the saved home conversation so it survives app restarts (and so a
  // sidebar history tap shows it). Falls back to the welcome state + alerts.
  Future<void> _restoreThread() async {
    String? sid = widget.sessionId;
    try {
      if (widget.fresh) {
        await Settings.setString(AgentThreadScreen.sessionKey, '');
      } else {
        sid ??= await Settings.getString(AgentThreadScreen.sessionKey);
      }
    } catch (_) {}
    if (!mounted) return;
    if (sid == null || sid.isEmpty) {
      _afterRestore();
      return _loadAlerts();
    }
    _sessionId = sid;
    final app = context.read<AppState>();
    try {
      final rows = await app.api.chatMessages(sid);
      if (!mounted) return;
      final restored = <_Msg>[
        for (final m in rows)
          _Msg(
              m['role'] == 'user',
              (m['text'] ?? '').toString(),
              (((m['meta'] is Map ? m['meta'] as Map : const {})['cards'] ??
                      []) as List)
                  .cast<Map<String, dynamic>>(),
              null,
              m['role'] == 'assistant',
              m['id']?.toString()),
      ];
      // history goes BEFORE anything the user already sent while it loaded
      setState(() => _msgs.insertAll(0, restored));
      await Settings.setString(AgentThreadScreen.sessionKey, sid);
      _toBottom();
      _afterRestore();
    } catch (e) {
      if (AgentThreadScreen.forgetsSession(e)) {
        // deleted/foreign thread → start fresh once (no retry loop), never an
        // error wall. The next send creates a new home session.
        if (_sessionId == sid) _sessionId = null;
        try {
          await Settings.setString(AgentThreadScreen.sessionKey, '');
        } catch (_) {}
      }
      _afterRestore();
      _loadAlerts();
    }
  }

  void _afterRestore() {
    if (!mounted) return;
    final g = widget.greeting;
    if (_msgs.isEmpty && g != null && g.isNotEmpty) {
      setState(() => _msgs.add(_Msg(false, g)));
    }
    final pending = widget.initialSend;
    if (pending != null && pending.trim().isNotEmpty) _send(pending);
  }

  // A1 — when the on-screen keyboard opens/closes the window insets change;
  // keep the newest message pinned to the bottom (above the keyboard).
  @override
  void didChangeMetrics() {
    if (_inputFocus.hasFocus) _toBottom();
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _typeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _voice.dispose();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // Surface anything urgent proactively as the first assistant message. If
  // nothing's urgent, the beautiful welcome state stays.
  Future<void> _loadAlerts() async {
    final app = context.read<AppState>();
    try {
      final alerts = await app.api.alertsList();
      // own-device (owner 24 Oct): never an anti-theft item about THIS
      // user's own phone here (he is holding it); family items still show.
      final me = app.user?.id;
      final urgent = alerts
          .where((a) => a['severity'] == 'high')
          .where((a) => !isOwnDeviceAlert(a, me))
          .toList();
      if (urgent.isNotEmpty && mounted) {
        setState(() => _msgs.add(_Msg(
            false,
            t.urgentForYou,
            urgent
                .map((a) => {
                      'type': 'alert',
                      'title': a['text'],
                      'subtitle': '',
                      'severity': a['severity']
                    })
                .toList())));
        _toBottom();
      }
    } catch (_) {}
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.base, curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send([String? preset, bool creditsRetry = false]) async {
    final text = (preset ?? _input.text).trim();
    // db1: Send on an empty box is never a dead tap — it opens the keyboard.
    if (text.isEmpty && preset == null && !_sending) {
      _inputFocus.requestFocus();
      return;
    }
    if (text.isEmpty || _sending) return;
    HapticFeedback.selectionClick();

    // open-from-chat, layer 1: English local fast-path (offline, zero latency).
    // Requires an open-verb + known subject so normal data entry isn't hijacked.
    final local = ChatNav.detectRoute(text);
    if (local != null) {
      _input.clear();
      if (ChatNav.push(context, local)) return;
    }

    _input.clear();
    // aibar: one id per typed message — "Send again" reuses it, so a retry
    // after a lost answer never logs the expense / reminder twice.
    final mine = _Msg(true, text)..clientId = newChatClientId();
    setState(() {
      _msgs.add(mine);
      _sending = true;
    });
    _toBottom();
    await _deliver(mine, creditsRetry);
  }

  /// aibar: "Send again" on a turn that did not go out.
  Future<void> _retry(_Msg mine) async {
    if (_sending || !mine.failed) return;
    HapticFeedback.selectionClick();
    setState(() {
      mine.failed = false;
      mine.failCause = null;
      _msgs.remove(mine);
      _msgs.add(mine);
      _sending = true;
    });
    _toBottom();
    await _deliver(mine, false);
  }

  Future<void> _deliver(_Msg mine, bool creditsRetry) async {
    final text = mine.text;
    final app = context.read<AppState>();
    var outOfCredits = false;
    var creditsNeed = 0; // billapp: the server's 402 `need`
    try {
      app.api.chatExtra = {
        if (_level != null) 'level': _level,
        if (_follow != null) 'follow': _follow,
      };
      _follow = null;
      // aileft: stream first (typed out live, Stop pays only what was
      // shown); a stream that cannot start falls back to POST /agent with
      // the same client id (the server replays, never answers twice).
      final Map<String, dynamic>? streamed = await _streamTurn(app.api, mine);
      if (!mounted) return;
      if (streamed != null && streamed['_stopped'] == true) return;
      final r = streamed ??
          await app.api.agent(text, sessionId: _sessionId, clientId: mine.clientId);
      final sid = r['session_id']?.toString();
      if (sid != null && sid.isNotEmpty && sid != _sessionId) {
        _sessionId = sid;
        Settings.setString(AgentThreadScreen.sessionKey, sid);
      }
      // open-from-chat, layer 2: backend route (authoritative, bilingual —
      // the only path that understands Bangla open-phrases). If it navigates,
      // skip rendering a reply bubble.
      if (mounted && ChatNav.push(context, r['route'] as String?)) {
        setState(() => _sending = false);
        return;
      }
      final cards = ((r['cards'] ?? []) as List).cast<Map<String, dynamic>>();
      final answer = _Msg(false, r['reply'] ?? '', cards, null, true,
          r['message_id']?.toString());
      // aibar: a keyed-AI answer shows what it really cost
      if (r['ai_used'] == true) {
        answer.meta = {
          'source': 'ai',
          'credits': r['credits'] ?? 0,
          if (r['balance'] != null) 'balance': r['balance'],
          if (r['text_cut'] == true) 'text_cut': true,
          // aifinal: cut / refund / level / hint / actions / label
          for (final k in const ['cut', 'refunded', 'level', 'hint_better', 'actions',
            'ai_generated', 'follow'])
            if (r[k] != null) k: r[k],
        };
      }
      setState(() => _msgs.add(answer));
      app.reminders.sync();
      app.txns.sync();
      app.loans.sync();
    } catch (e) {
      if (isOutOfCredits(e) && mounted) {
        // credout: nothing was saved server-side — put the text back in the
        // box (never lost) and open the buy-credits sheet at once.
        outOfCredits = true;
        final n = (e as ApiException).body?['need'];
        creditsNeed = n is num ? n.toInt() : 0;
        setState(() {
          _msgs.remove(mine);
          if (_input.text.trim().isEmpty) _input.text = text;
        });
      } else if (mounted) {
        // aibar: the text stays in its bubble with the honest reason and
        // "Send again" (was: a generic notice and the text was lost)
        setState(() {
          mine.failed = true;
          mine.failCause = e;
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _toBottom();
    }
    if (outOfCredits && mounted) {
      final ok = creditsRetry
          ? false // already retried once after a purchase: keep the draft
          : await CreditsOut.offer(context,
              screen: 'home', draftKept: true, need: creditsNeed);
      // after a verified purchase / reward: the same request, once
      if (ok && mounted && _input.text.trim() == text) {
        _input.clear();
        await _send(text, true);
      }
    }
  }

  // ---------------- aileft: streaming + Stop ----------------

  /// One home turn over POST /agent/stream. Returns the full /agent body when
  /// the answer finished typing out, `{'_stopped': true}` when the user
  /// tapped Stop (handled here), or null when the stream could not deliver
  /// (the caller falls back to POST /agent with the same client id). Out of
  /// credits / too fast / still answering are rethrown like POST /agent.
  Future<Map<String, dynamic>?> _streamTurn(ApiClient api, _Msg mine) async {
    final live = _Msg(false, '')..streaming = true;
    final turn = Completer<Map<String, dynamic>?>();
    Object? err;
    setState(() {
      _live = live;
      _liveFor = mine;
      _pending = '';
      _msgs.add(live);
    });
    _turn = turn;
    try {
      _streamSub = api
          .agentStream(mine.text, sessionId: _sessionId, clientId: mine.clientId)
          .listen((ev) {
        if (ev['kind'] == 'token') {
          _pending += (ev['chunk'] ?? '').toString();
          _startTyping();
        } else if (ev['kind'] == 'done') {
          final raw = ev['raw'];
          if (!turn.isCompleted) {
            turn.complete(raw is Map ? raw.cast<String, dynamic>() : null);
          }
        }
      }, onError: (Object e) {
        err = e;
        if (!turn.isCompleted) turn.complete(null);
      }, onDone: () {
        if (!turn.isCompleted) turn.complete(null);
      }, cancelOnError: true);
    } catch (e) {
      err = e;
      if (!turn.isCompleted) turn.complete(null);
    }
    var body = await turn.future;
    _streamSub = null;
    if (body != null && body['_stopped'] == true) return body;
    if (body != null) {
      // let the typed-out text reach the end before the final bubble
      if (_pending.isNotEmpty) {
        _drained = Completer<void>();
        await _drained!.future;
        if (_turn == null) return {'_stopped': true}; // Stop while typing
      }
    }
    _typeTimer?.cancel();
    _typeTimer = null;
    _turn = null;
    if (mounted) {
      setState(() {
        _msgs.remove(live);
        _live = null;
        _liveFor = null;
      });
    }
    final e = err;
    if (body == null && e is ApiException &&
        (e.status == 402 || e.status == 429 || e.status == 409 ||
            isOutOfCredits(e))) {
      throw e;
    }
    return body;
  }

  /// Types the received answer out at a reading pace (~400 chars/s, faster
  /// for a long backlog) so Stop means something, like ChatGPT.
  void _startTyping() {
    if (_typeTimer != null) return;
    _typeTimer = Timer.periodic(const Duration(milliseconds: 30), (tm) {
      final live = _live;
      if (!mounted || live == null) {
        tm.cancel();
        _typeTimer = null;
        return;
      }
      if (_pending.isEmpty) {
        tm.cancel();
        _typeTimer = null;
        final d = _drained;
        _drained = null;
        if (d != null && !d.isCompleted) d.complete();
        return;
      }
      var n = _pending.length ~/ 50;
      if (n < 12) n = 12;
      if (n > _pending.length) n = _pending.length;
      // never split a surrogate pair (emoji)
      if (n < _pending.length) {
        final c = _pending.codeUnitAt(n - 1);
        if (c >= 0xD800 && c <= 0xDBFF) n++;
      }
      setState(() {
        live.text += _pending.substring(0, n);
        _pending = _pending.substring(n);
      });
      _toBottom();
    });
  }

  /// Stop: freeze the answer where it is, tell the server how much was
  /// shown (it charges only that share — nothing under its minimum).
  Future<void> _stop() async {
    final live = _live;
    final mine = _liveFor;
    if (live == null || mine == null) return;
    HapticFeedback.selectionClick();
    final sub = _streamSub;
    _streamSub = null;
    _typeTimer?.cancel();
    _typeTimer = null;
    _pending = '';
    await sub?.cancel();
    if (!mounted) return;
    final turn = _turn;
    _turn = null;
    final d = _drained;
    _drained = null;
    final shown = live.text.length;
    final kept = _Msg(false, live.text, const [], null, shown > 0)
      ..meta = {'source': 'ai', 'stopped': true, 'credits': 0};
    setState(() {
      final i = _msgs.indexOf(live);
      if (i >= 0) {
        _msgs[i] = kept;
      }
      _live = null;
      _liveFor = null;
      _sending = false;
    });
    if (turn != null && !turn.isCompleted) turn.complete({'_stopped': true});
    if (d != null && !d.isCompleted) d.complete();
    final cid = mine.clientId;
    if (cid == null) return;
    try {
      final r = await context.read<AppState>().api.chatStop(cid, shown);
      if (!mounted) return;
      final sid = r['session_id']?.toString();
      if (sid != null && sid.isNotEmpty && _sessionId == null) {
        _sessionId = sid;
        Settings.setString(AgentThreadScreen.sessionKey, sid);
      }
      setState(() => kept.meta = {
            ...kept.meta,
            'credits': r['credits'] ?? 0,
            if (r['refunded'] != null) 'refunded': r['refunded'],
            if (r['balance'] != null) 'balance': r['balance'],
          });
    } catch (_) {
      // offline: the server still parks nothing — the answer was already
      // saved; the credit line keeps the honest "stopped" note
    }
  }

  Future<void> _undo(Map<String, dynamic> card) async {
    final app = context.read<AppState>();
    try {
      await app.api.deleteByModel(card['model'], card['id']);
      app.reminders.sync();
      app.txns.sync();
      app.loans.sync();
      if (mounted) {
        setState(() => _msgs.add(_Msg(false, t.undone)));
        _toBottom();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: _msgs.isEmpty
            ? _welcome()
            : _thread(),
      ),
      if (widget.showLevels)
        AiLevelPicker(
            load: () => context.read<AppState>().api.getJson('/chat/levels'),
            welcome: () =>
                context.read<AppState>().api.postJson('/chat/welcome-credits', {}),
            onChanged: (l) => _level = l),
      _inputBar(),
    ]);
  }

  // ---------------- welcome / empty state ----------------
  // OWNER ORDER (h1-home): no suggestion questions here any more — just the
  // logo + "Hi, I'm Assisto" block (which the home may swap for its ad hero).
  Widget _logoBlock() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('welcome-logo-block'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Gap.xl),
        Center(child: _logoMark(76)),
        const SizedBox(height: Gap.lg),
        Text(t.welcomeHeadline,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        Text(t.welcomeBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ],
    );
  }

  Widget _welcome() {
    final block = _logoBlock();
    final hero = widget.heroBuilder;
    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.md),
        children: [
          hero == null
              ? block
              : hero(context, block, _inputFocus.hasFocus,
                  box.maxHeight.isFinite ? box.maxHeight - Gap.lg - Gap.md : 0),
          if (widget.starters.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            for (final q in widget.starters)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: OutlinedButton(
                  key: ValueKey('starter-$q'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      alignment: Alignment.centerLeft),
                  onPressed: _sending ? null : () => _send(q),
                  child: Text(q),
                ),
              ),
          ],
        ],
      ),
    );
  }

  // Messages. On the home, until the user has sent anything (only proactive
  // urgent cards so far), the logo + "Hi, I'm Assisto" block stays on top —
  // never the ad: urgent cards come first, nothing pushes them down.
  Widget _thread() {
    final hero = widget.heroBuilder;
    final header = hero != null && !_msgs.any((m) => m.user);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
      itemCount: _msgs.length + (header ? 1 : 0),
      itemBuilder: (_, i) {
        if (header) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: Gap.lg),
              child: hero(context, _logoBlock(), true, 0),
            );
          }
          return _bubble(_msgs[i - 1]);
        }
        return _bubble(_msgs[i]);
      },
    );
  }

  // h1-home: attach a photo and ask about it. The typed text (if any) is the
  // question; the turn lives only on this device.
  void _attachPhoto(Uint8List bytes) {
    final q = _input.text.trim();
    _input.clear();
    widget.onInputFocus?.call(); // the home collapses Discover + hero
    setState(() => _msgs.add(_Msg(true, q, const [], ChatPhotoRequest(bytes, q))));
    _toBottom();
  }

  // ---------------- aifinal: level, Continue, More detail, Copy ----------------
  String? _level;
  String? _follow;

  _Msg? _lastAssistant() {
    for (final m in _msgs.reversed) {
      if (m.photo != null) return null;
      if (!m.user) return m;
      return null;
    }
    return null;
  }

  Widget _followRow(_Msg m) {
    final cut = m.meta['cut'] == true;
    return Wrap(spacing: 4, children: [
      if (cut)
        FilledButton.tonalIcon(
          key: const ValueKey('ai-continue'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () {
            _follow = 'continue';
            _send(t.aiContinue);
          },
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: Text(t.aiContinue),
        ),
      if (m.meta['source'] == 'ai' && !cut)
        TextButton.icon(
          key: const ValueKey('ai-more'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () {
            _follow = 'more';
            _send(t.aiMoreDetail);
          },
          icon: const Icon(Icons.unfold_more_rounded, size: 18),
          label: Text(t.aiMoreDetail),
        ),
      IconButton(
        key: const ValueKey('ai-copy'),
        tooltip: t.aiCopy,
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: m.text));
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(SnackBar(content: Text(t.aiCopied)));
          }
        },
        icon: const Icon(Icons.copy_rounded, size: 18),
      ),
    ]);
  }

  // ---------------- bubbles ----------------
  Widget _bubble(_Msg m) {
    final photo = m.photo;
    if (photo != null) {
      // aifinal round 2: ONE direct answer bubble, saved into this chat
      return ChatPhotoTurn(
          request: photo,
          direct: true,
          sessionId: photo.sessionId ?? _sessionId ?? 'home:new',
          onSession: (sid) {
            if (_sessionId == sid) return;
            _sessionId = sid;
            Settings.setString(AgentThreadScreen.sessionKey, sid);
          });
    }
    final scheme = Theme.of(context).colorScheme;
    final bubble = Container(
      constraints:
          BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
      decoration: BoxDecoration(
        color: m.user ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(m.user ? 18 : 4),
          bottomRight: Radius.circular(m.user ? 4 : 18),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (m.text.isNotEmpty)
          m.user
              ? Text(m.text,
                  style: TextStyle(color: scheme.onPrimary, height: 1.4))
              // aifinal round 2 item 7: safe markdown (no raw ** in answers)
              : AiMarkdown(
                  text: m.text, color: scheme.onSurface, linkColor: scheme.primary),
        for (final c in m.cards) ChatCard(c, onUndo: _undo),
      ]),
    );

    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: m.failed
                ? Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    bubble,
                    FailedSendRow(
                        cause: m.failCause,
                        onRetry: _sending ? null : () => _retry(m)),
                  ])
                : bubble),
      );
    }
    // assistant: avatar + bubble (+ ai-report: long-press menu + flag)
    final report = m.reportable && m.text.trim().isNotEmpty
        ? AiReportTarget(
            surface: 'home',
            text: m.text,
            messageId: m.id,
            sessionId: _sessionId)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _logoMark(28),
        const SizedBox(width: Gap.sm),
        Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          report == null
              ? bubble
              : AiAnswerLongPress(target: report, child: bubble),
          if (AiCreditLine.shows(m.meta)) AiCreditLine(m.meta),
          if (AiGeneratedLabel.shows(m.meta, null)) const AiGeneratedLabel(),
          if (AiBetterHint.shows(m.meta)) AiBetterHint(m.meta),
          if (AiActionButtons.shows(m.meta)) AiActionButtons(m.meta),
          if (identical(m, _lastAssistant()) && !_sending) _followRow(m),
        ])),
        if (report != null) AiReportButton(target: report),
      ]),
    );
  }

  // ---------------- input ----------------
  Widget _inputBar() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _inputFocus,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              minLines: 1,
              // A1 — grow up to ~5 lines, then scroll internally so the typed
              // text is always visible and the bar never outgrows the screen.
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: (_voice.listening || widget.debugListening)
                    ? t.listening
                    : t.inputHint,
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: Gap.lg, vertical: Gap.md),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          ChatPhotoAttachButton(
              onPicked: _attachPhoto, picker: widget.photoPicker),
          // Hold the mic to talk (release stops), tap to toggle; the bn/EN chip
          // picks the voice language. Fills the box, never auto-sends.
          VoiceMicButton(
              voice: _voice,
              input: _input,
              debugListening: widget.debugListening),
          // aileft: while an answer streams, Send becomes Stop
          _sending && _live != null
              ? IconButton.filled(
                  key: const ValueKey('home-stop'),
                  tooltip: t.aichatStop,
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_rounded))
              : _sending
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton.filled(
                  tooltip: AppLocalizations.of(context).send,
                  onPressed: () => _send(),
                  icon: const Icon(Icons.arrow_upward_rounded)),
        ]),
      ),
    );
  }

  Widget _logoMark(double size) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.26),
        child: Image.asset('assets/branding/new_logo.png',
            width: size, height: size, fit: BoxFit.cover),
      );
}
