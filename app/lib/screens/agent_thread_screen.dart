import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/chatnav.dart';
import '../widgets/chat_cards.dart';
import '../widgets/voice_input.dart';

class _Msg {
  final bool user;
  final String text;
  final List<Map<String, dynamic>> cards;
  _Msg(this.user, this.text, [this.cards = const []]);
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
  const AgentThreadScreen(
      {super.key,
      this.debugSeed,
      this.debugListening = false,
      this.onInputFocus,
      this.sessionId,
      this.fresh = false,
      this.greeting,
      this.initialSend});

  /// SharedPreferences key of the home thread that survives restarts.
  static const sessionKey = 'home_session_id';
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

  // Live speech-to-text into the input (shared with Assisto AI chat).
  late final VoiceDictation _voice = VoiceDictation(lang: 'bn');
  String? _sessionId;

  AppLocalizations get t => AppLocalizations.of(context);

  List<(IconData, String)> get _suggestions => [
        (Icons.wb_sunny_outlined, t.suggestionToday),
        (Icons.query_stats_outlined, t.suggestionSpendMonth),
        (Icons.receipt_long_outlined, t.suggestionExpense),
        (Icons.medication_outlined, t.suggestionMedicine),
      ];

  @override
  void initState() {
    super.initState();
    // A1 — the thread's input must always sit above the keyboard and the list
    // must auto-scroll when the keyboard opens. Observe metrics for that.
    WidgetsBinding.instance.addObserver(this);
    _voice.addListener(_rebuild);
    // A1 — the home collapses its Discover cards as soon as the input focuses.
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus) {
        widget.onInputFocus?.call();
        _toBottom();
      }
    });
    if (widget.debugSeed != null) {
      for (final m in widget.debugSeed!) {
        _msgs.add(_Msg(m['user'] == true, (m['text'] ?? '').toString(),
            ((m['cards'] ?? []) as List).cast<Map<String, dynamic>>()));
      }
      return; // previews don't poll
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _voice.loadLang(t.localeName);
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
    if (widget.fresh) {
      await Settings.setString(AgentThreadScreen.sessionKey, '');
    } else {
      sid ??= await Settings.getString(AgentThreadScreen.sessionKey);
    }
    if (sid == null || sid.isEmpty) {
      _afterRestore();
      return _loadAlerts();
    }
    _sessionId = sid;
    final app = context.read<AppState>();
    try {
      final rows = await app.api.chatMessages(sid);
      if (!mounted) return;
      setState(() {
        for (final m in rows) {
          final meta = (m['meta'] is Map) ? m['meta'] as Map : const {};
          _msgs.add(_Msg(m['role'] == 'user', (m['text'] ?? '').toString(),
              ((meta['cards'] ?? []) as List).cast<Map<String, dynamic>>()));
        }
      });
      await Settings.setString(AgentThreadScreen.sessionKey, sid);
      _toBottom();
      _afterRestore();
    } catch (_) {
      // deleted/foreign thread → start fresh, never show an error wall
      _sessionId = null;
      await Settings.setString(AgentThreadScreen.sessionKey, '');
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
      final urgent = alerts.where((a) => a['severity'] == 'high').toList();
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

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
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
    setState(() {
      _msgs.add(_Msg(true, text));
      _sending = true;
    });
    _toBottom();
    final app = context.read<AppState>();
    try {
      final r = await app.api.agent(text, sessionId: _sessionId);
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
      setState(() => _msgs.add(_Msg(false, r['reply'] ?? '', cards)));
      app.reminders.sync();
      app.txns.sync();
      app.loans.sync();
    } catch (e) {
      setState(() => _msgs.add(_Msg(false, t.sendFailed)));
    } finally {
      if (mounted) setState(() => _sending = false);
      _toBottom();
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
            : ListView.builder(
                controller: _scroll,
                padding:
                    const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
                itemCount: _msgs.length,
                itemBuilder: (_, i) => _bubble(_msgs[i]),
              ),
      ),
      _inputBar(),
    ]);
  }

  // ---------------- welcome / empty state ----------------
  Widget _welcome() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xxl, Gap.xl, Gap.md),
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
        const SizedBox(height: Gap.xl),
        for (final s in _suggestions) ...[
          _suggestionCard(s.$1, s.$2),
          const SizedBox(height: Gap.sm),
        ],
      ],
    );
  }

  Widget _suggestionCard(IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => _send(text),
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Text(text,
                    style: const TextStyle(fontWeight: FontWeight.w500))),
            Icon(Icons.north_east, size: 16, color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }

  // ---------------- bubbles ----------------
  Widget _bubble(_Msg m) {
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
          Text(m.text,
              style: TextStyle(
                  color: m.user ? Colors.white : scheme.onSurface,
                  height: 1.4)),
        for (final c in m.cards) ChatCard(c, onUndo: _undo),
      ]),
    );

    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: bubble),
      );
    }
    // assistant: avatar + bubble
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _logoMark(28),
        const SizedBox(width: Gap.sm),
        Flexible(child: bubble),
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
          const SizedBox(width: Gap.xs),
          // Hold the mic to talk (release stops), tap to toggle; the bn/EN chip
          // picks the voice language. Fills the box, never auto-sends.
          VoiceMicButton(
              voice: _voice,
              input: _input,
              debugListening: widget.debugListening),
          _sending
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton.filled(
                  onPressed: () => _send(),
                  icon: const Icon(Icons.arrow_upward)),
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
