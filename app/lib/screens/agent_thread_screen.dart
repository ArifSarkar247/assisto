import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/chatnav.dart';
import '../widgets/chat_cards.dart';
import '../widgets/permission_reason.dart';
import '../widgets/voice_command_sheet.dart';

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
  const AgentThreadScreen(
      {super.key, this.debugSeed, this.debugListening = false, this.onInputFocus});
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

  // A4 — live speech-to-text into the input box. Lazily initialised on the
  // FIRST mic tap only (never at launch). _listening doubles as the UI state
  // for both the seeded preview and the live mic.
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  // Text already in the box before dictation began, so partial results are
  // appended (not overwritten) each time onResult fires.
  String _speechBase = '';

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
    // A1 — the home collapses its Discover cards as soon as the input focuses.
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus) {
        widget.onInputFocus?.call();
        _toBottom();
      }
    });
    if (widget.debugSeed != null) {
      _listening = widget.debugListening;
      for (final m in widget.debugSeed!) {
        _msgs.add(_Msg(
            m['user'] == true,
            (m['text'] ?? '').toString(),
            ((m['cards'] ?? []) as List).cast<Map<String, dynamic>>()));
      }
      return; // previews don't poll
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAlerts());
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
    try {
      _speech.cancel();
    } catch (_) {}
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
        setState(() => _msgs.add(_Msg(false, t.urgentForYou,
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
      final r = await app.api.agent(text);
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

  // Advanced voice command: opens a sheet that transcribes on-device, shows the
  // understood intent, and waits for an explicit confirm. The confirmed
  // transcript then flows through the SAME pipeline as typed chat (_send →
  // local route → backend route → agent), so Bangla/Banglish commands the
  // on-device mapper can't resolve are still handled by the server.
  Future<void> _openVoice() async {
    HapticFeedback.selectionClick();
    final text = await showVoiceCommandSheet(context);
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _send(text);
  }

  // A4 — live speech-to-text straight into the input box. Tapping the mic
  // toggles listening; partial results stream LIVE into the TextField (append
  // to whatever was already typed). Auto-send stays OFF — we only fill the box.
  // Everything is guarded so the mic can never crash or block the UI.
  Future<void> _toggleMic() async {
    if (_listening) {
      await _stopMic();
      return;
    }
    HapticFeedback.selectionClick();
    try {
      // Lazy init on the FIRST tap only — never at launch.
      if (!_speechReady) {
        final okReason = await showPermissionReason(context, PermKind.mic);
        if (!okReason || !mounted) return;
        _speechReady = await _speech.initialize(
          onStatus: (s) {
            if ((s == 'done' || s == 'notListening') && mounted && _listening) {
              setState(() => _listening = false);
            }
          },
          onError: (_) {
            if (mounted && _listening) {
              setState(() => _listening = false);
              _micUnavailable();
            }
          },
        );
      }
      // Honest device gate: no speech engine (common on ColorOS/Realme) → show
      // a clear message, never a fake transcript. Offer to open settings.
      if (!_speechReady) {
        if (mounted) _micUnavailable();
        return;
      }
      _speechBase = _input.text;
      if (_speechBase.isNotEmpty && !_speechBase.endsWith(' ')) {
        _speechBase = '$_speechBase ';
      }
      setState(() => _listening = true);
      // Recognise in the app's ACTIVE language. Without this the plugin uses the
      // DEVICE locale, so a Bangla speaker on a non-Bengali device isn't heard.
      final localeId = t.localeName.startsWith('bn') ? 'bn_BD' : 'en_US';
      await _speech.listen(
        onResult: (r) {
          if (!mounted) return;
          final live = '$_speechBase${r.recognizedWords}';
          _input.value = TextEditingValue(
            text: live,
            selection: TextSelection.collapsed(offset: live.length),
          );
        },
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (_) {
      // Never crash: fall back to the idle state and tell the user honestly.
      if (mounted) {
        setState(() => _listening = false);
        _micUnavailable();
      }
    }
  }

  Future<void> _stopMic() async {
    try {
      await _speech.stop();
    } catch (_) {}
    if (mounted) setState(() => _listening = false);
  }

  // Server transcription fallback (if a key ever exists) is NOT built here; this
  // is a later build. For now we guide the user to install Google speech.
  void _micUnavailable() {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Text(t.micEnableSpeech),
      action: SnackBarAction(
        label: t.open,
        onPressed: () {
          try {
            openAppSettings();
          } catch (_) {}
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: _msgs.isEmpty
            ? _welcome()
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
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
                child: Text(text, style: const TextStyle(fontWeight: FontWeight.w500))),
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
                  color: m.user ? Colors.white : scheme.onSurface, height: 1.4)),
        for (final c in m.cards) ChatCard(c, onUndo: _undo),
      ]),
    );

    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs), child: bubble),
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
                hintText: _listening ? t.listening : t.inputHint,
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: Gap.xs),
          // A4 — tap: live speech-to-text into the box (fills, never auto-sends).
          // Long-press: the advanced voice-command sheet (confirm-before-run).
          Tooltip(
            message: t.voiceTitle,
            child: GestureDetector(
              onLongPress: _listening ? null : _openVoice,
              child: _listening
                  ? _MicPulse(onTap: _toggleMic)
                  : IconButton(
                      onPressed: _toggleMic,
                      icon: Icon(Icons.mic_none, color: scheme.onSurfaceVariant),
                    ),
            ),
          ),
          _sending
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton.filled(
                  onPressed: () => _send(), icon: const Icon(Icons.arrow_upward)),
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

/// A4 — visible "listening" state for the inline mic: a gently pulsing red
/// stop button. Tapping it stops dictation.
class _MicPulse extends StatefulWidget {
  final VoidCallback onTap;
  const _MicPulse({required this.onTap});
  @override
  State<_MicPulse> createState() => _MicPulseState();
}

class _MicPulseState extends State<_MicPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: widget.onTap,
      icon: AnimatedBuilder(
        animation: _c,
        builder: (_, child) =>
            Transform.scale(scale: 1 + _c.value * 0.18, child: child),
        child: const Icon(Icons.stop_circle, color: Brand.danger),
      ),
    );
  }
}
