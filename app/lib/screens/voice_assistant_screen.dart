import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../voice/va_actions.dart';
import '../voice/va_confirm_sheet.dart';
import '../voice/va_launch.dart';
import '../voice/va_native.dart';
import '../voice/va_wake.dart';
import '../voice/voice_intents.dart';
import '../widgets/chat_cards.dart';
import '../widgets/chatnav.dart';
import '../widgets/voice_input.dart';
import 'voice_assistant_settings_screen.dart';

/// One exchange on the voice screen.
class VaTurn {
  final String said;
  final VaOutcome? outcome; // null while thinking
  const VaTurn(this.said, [this.outcome]);
}

/// Part 3 — "Assisto Voice": full-screen, hands-free assistant.
///
/// Opens listening immediately (from the drawer, chat, the assist gesture or
/// the wake word). Speech is turned into an intent ON-DEVICE
/// ([VoiceIntentParser]); outgoing actions always ask first
/// ([VaConfirmSheet]); anything else goes to the Assisto agent. Replies are
/// shown as cards and spoken (bn / en) when spoken replies are on.
class VoiceAssistantScreen extends StatefulWidget {
  final bool autoListen;
  final List<VaTurn>? debugTurns;
  final bool debugListening;
  final String? debugPartial;

  const VoiceAssistantScreen({
    super.key,
    this.autoListen = true,
    this.debugTurns,
    this.debugListening = false,
    this.debugPartial,
  });

  /// True while the screen is on the stack (so a second assist press only
  /// restarts listening instead of stacking another screen).
  static bool isOpen = false;

  @override
  State<VoiceAssistantScreen> createState() => _VoiceAssistantScreenState();
}

enum _Phase { idle, listening, thinking }

class _VoiceAssistantScreenState extends State<VoiceAssistantScreen>
    with SingleTickerProviderStateMixin
    implements VaConfirmVoice {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));
  final _ctrl = TextEditingController();
  final _typed = TextEditingController();
  final _scroll = ScrollController();
  VoiceDictation? _voice;
  final List<VaTurn> _turns = [];
  _Phase _phase = _Phase.idle;
  bool _wasListening = false;
  bool _yesNoMode = false;
  bool _typing = false;
  bool _ttsOn = true;

  /// Opened over the lock screen (power long-press / wake word while locked).
  bool _locked = false;

  /// Language of the last thing the user said (answers + TTS follow it).
  String? _replyLang;

  AppLocalizations get t => AppLocalizations.of(context);
  String get _uiLang => Localizations.localeOf(context).languageCode;

  @override
  void initState() {
    super.initState();
    VoiceAssistantScreen.isOpen = true;
    if (widget.debugTurns != null) {
      _turns.addAll(widget.debugTurns!);
      // qa2: a restored conversation opens at its newest turn, like a live
      // one (which scrolls after every answer) — not at the oldest.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    if (widget.debugListening) {
      _phase = _Phase.listening;
      _ctrl.text = widget.debugPartial ?? '';
    }
    VaLaunch.relisten.addListener(_onRelisten);
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    if (!mounted) return;
    final v = VoiceDictation();
    _voice = v;
    unawaited(v.loadMode());
    v.addListener(_onVoice);
    try {
      // Recognition language: VoiceDictation's own setting (Auto by default,
      // override in Settings > Voice — owned by voice_input.dart).
      _ttsOn = await Settings.getBool(VaWake.ttsKey, true);
      if (widget.debugTurns == null && !widget.debugListening) {
        _locked = await VaNative.isLocked();
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    if (widget.autoListen && widget.debugTurns == null && !widget.debugListening) {
      _listen();
    }
  }

  void _onRelisten() {
    if (mounted && _phase != _Phase.listening) _listen();
  }

  @override
  void dispose() {
    VoiceAssistantScreen.isOpen = false;
    VaLaunch.relisten.removeListener(_onRelisten);
    _voice?.removeListener(_onVoice);
    _voice?.dispose();
    try {
      VaNative.stopSpeaking();
      if (_locked) VaNative.leaveLockScreen(moveBack: true);
    } catch (_) {}
    _pulse.dispose();
    _ctrl.dispose();
    _typed.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- listening --------------------------------------------------------------

  void _onVoice() {
    final v = _voice;
    if (v == null || !mounted) return;
    if (_yesNoMode) return;
    if (v.listening && !_wasListening) {
      _wasListening = true;
      _pulse.repeat();
      setState(() => _phase = _Phase.listening);
    } else if (!v.listening && _wasListening) {
      _wasListening = false;
      _pulse.stop();
      // Give the engine a moment to deliver its final result.
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        final said = _ctrl.text.trim();
        if (said.isEmpty) {
          setState(() => _phase = _Phase.idle);
        } else {
          _handle(said);
        }
      });
    }
    setState(() {});
  }

  Future<void> _listen() async {
    final v = _voice;
    if (v == null) return;
    try {
      await VaNative.stopSpeaking();
    } catch (_) {} // best-effort: stop TTS before listening
    _ctrl.clear();
    if (!mounted) return;
    await v.start(context, _ctrl);
  }

  Future<void> _stopListening() async => _voice?.stop();

  // ---- VaConfirmVoice (spoken yes / no inside the confirm sheet) -----------

  @override
  Future<void> say(String text) async {
    if (!_ttsOn) return;
    try {
      await VaNative.speak(text, _replyLang ?? _uiLang)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  @override
  Future<bool?> listenYesNo(BuildContext sheetContext) async {
    final v = _voice;
    if (v == null) return null;
    final c = TextEditingController();
    _yesNoMode = true;
    bool? answer;
    try {
      await v.start(sheetContext, c);
      final started = DateTime.now();
      final until = started.add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(until)) {
        await Future.delayed(const Duration(milliseconds: 200));
        answer = VaYesNo.classify(c.text);
        if (answer != null) break;
        final settled = DateTime.now().difference(started) >
            const Duration(milliseconds: 800);
        if (settled && !v.listening) {
          // the engine stopped on its own: one last look at the words
          await Future.delayed(const Duration(milliseconds: 300));
          answer = VaYesNo.classify(c.text);
          break;
        }
      }
    } catch (_) {
    } finally {
      await v.stop();
      _yesNoMode = false;
      _wasListening = false;
      c.dispose();
    }
    return answer;
  }

  @override
  void stop() {
    try {
      VaNative.stopSpeaking();
    } catch (_) {}
    if (_yesNoMode) _voice?.stop();
  }

  // ---- understanding + acting -------------------------------------------------

  Future<void> _handle(String said) async {
    HapticFeedback.selectionClick();
    setState(() {
      _phase = _Phase.thinking;
      _turns.add(VaTurn(said));
      _ctrl.clear();
    });
    _toBottom();
    final intent =
        VoiceIntentParser.parse(said, detectRoute: ChatNav.detectRoute);
    _replyLang = VaText.replyLang(said);
    final out = await VaExecutor(context,
        confirmVoice: this,
        locked: _locked,
        onUnlocked: _onUnlocked,
        replyLang: _replyLang).run(intent);
    if (!mounted) return;
    setState(() {
      _turns[_turns.length - 1] = VaTurn(said, out);
      _phase = _Phase.idle;
    });
    _toBottom();
    _speak(out.reply);
  }

  void _onUnlocked() {
    _locked = false;
    VaNative.leaveLockScreen();
    if (mounted) setState(() {});
  }

  /// Closing while still locked: hand the phone back to the lock screen
  /// FIRST, then drop the route, so nothing of Assisto shows unlocked.
  Future<void> _close() async {
    if (_locked) {
      await VaNative.leaveLockScreen(moveBack: true);
      _locked = false;
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (mounted) Navigator.maybePop(context);
  }

  Future<void> _speak(String text) async {
    if (!_ttsOn || text.isEmpty) return;
    final lang = _replyLang ?? _uiLang;
    final r = await VaNative.speak(text, lang);
    if (r == 'no_voice' && lang == 'bn' && mounted) {
      final shown = await Settings.getBool('va_tts_hint_shown', false);
      if (shown || !mounted) return;
      await Settings.setBool('va_tts_hint_shown', true);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(t.vaNoTtsVoice),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
            label: t.vaInstall, onPressed: () => VaNative.openTtsSettings()),
      ));
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.base, curve: Curves.easeOut);
      }
    });
  }

  void _submitTyped() {
    final s = _typed.text.trim();
    if (s.isEmpty) return;
    _typed.clear();
    FocusScope.of(context).unfocus();
    _handle(s);
  }

  // ---- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final listening = _phase == _Phase.listening;
    return PopScope(
      canPop: !_locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
      backgroundColor: dark ? scheme.surface : scheme.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          tooltip: t.vaClose,
          icon: const Icon(Icons.close_rounded),
          onPressed: _close,
        ),
        title: Text(t.vaTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          // Voice language is AUTOMATIC (owner order); the manual override
          // lives only in Settings > Voice. No BN/EN chip here.
          if (!_locked)
          IconButton(
            tooltip: t.vaSettingsTitle,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () async {
              await _stopListening();
              if (!context.mounted) return;
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const VoiceAssistantSettingsScreen()));
              _ttsOn = await Settings.getBool(VaWake.ttsKey, true);
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: _turns.isEmpty && !listening
                ? _welcome(scheme)
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                        Gap.lg, Gap.sm, Gap.lg, Gap.lg),
                    children: [
                      for (final turn in _turns) ..._turnWidgets(turn, scheme),
                    ],
                  ),
          ),
          if (_locked)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Row(children: [
                Icon(Icons.lock_outline_rounded, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(t.vaLockedNote,
                        style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant))),
              ]),
            ),
          _bottom(scheme, listening),
        ]),
      ),
    ),
    );
  }

  Widget _welcome(ColorScheme scheme) {
    final examples = [
      t.vaExCall,
      t.vaExSong,
      t.vaExAlarm,
      t.vaExExpense,
      t.vaExTorch,
      t.vaExSms,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.lg),
      children: [
        Center(
          child: ShaderMask(
            shaderCallback: (r) => Brand.gradient.createShader(r),
            child: const Icon(Icons.graphic_eq_rounded, size: 56, color: Colors.white),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(t.vaWelcome,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(t.vaWelcomeSub,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xl),
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          alignment: WrapAlignment.center,
          children: [
            for (final e in examples)
              ActionChip(
                avatar: Icon(Icons.mic_none_rounded, size: 18, color: scheme.primary),
                label: Text(e, softWrap: true),
                onPressed: () => _handle(e),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _turnWidgets(VaTurn turn, ColorScheme scheme) {
    return [
      Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.8),
          margin: const EdgeInsets.only(top: Gap.md, bottom: Gap.sm),
          padding: const EdgeInsets.symmetric(
              horizontal: Gap.md + 2, vertical: Gap.sm + 2),
          decoration: BoxDecoration(
            // Solid primary (not the cyan gradient) keeps white text >= 4.5:1.
            color: scheme.primary,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Text(turn.said,
              style: AType.titleMedium.copyWith(color: scheme.onPrimary)),
        ),
      ),
      if (turn.outcome == null)
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Gap.md),
            Flexible(child: Text(t.vaThinking)),
          ]),
        )
      else
        _ResultCard(outcome: turn.outcome!),
    ];
  }

  Widget _bottom(ColorScheme scheme, bool listening) {
    final partial = _ctrl.text;
    final status = switch (_phase) {
      _Phase.listening => t.vaListening,
      _Phase.thinking => t.vaThinking,
      _Phase.idle => t.vaTapToTalk,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (listening && partial.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Text(partial,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
        if (_typing)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _typed,
                  autofocus: true,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submitTyped(),
                  decoration: InputDecoration(hintText: t.vaTypeHint),
                ),
              ),
              IconButton.filled(
                tooltip: t.vaSend,
                onPressed: _submitTyped,
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ]),
          ),
        Text(status,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: listening ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: Gap.md),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
            tooltip: t.vaTypeInstead,
            iconSize: 26,
            onPressed: () => setState(() => _typing = !_typing),
            icon: Icon(_typing ? Icons.keyboard_hide_rounded : Icons.keyboard_rounded,
                color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: Gap.xl),
          _MicOrb(
            animation: _pulse,
            listening: listening || widget.debugListening,
            busy: _phase == _Phase.thinking,
            label: listening ? t.vaStop : t.vaTapToTalk,
            onTap: () {
              if (listening) {
                _stopListening();
              } else if (_phase != _Phase.thinking) {
                _listen();
              }
            },
          ),
          const SizedBox(width: Gap.xl),
          IconButton(
            tooltip: t.vaStopSpeaking,
            iconSize: 26,
            onPressed: () => VaNative.stopSpeaking(),
            icon: Icon(Icons.volume_off_rounded,
                color: scheme.onSurfaceVariant),
          ),
        ]),
      ]),
    );
  }
}

/// The big gradient mic with pulse rings + a waveform while listening.
class _MicOrb extends StatelessWidget {
  final Animation<double> animation;
  final bool listening;
  final bool busy;
  final String label;
  final VoidCallback onTap;
  const _MicOrb({
    required this.animation,
    required this.listening,
    required this.busy,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 112,
          height: 112,
          child: AnimatedBuilder(
            animation: animation,
            builder: (_, __) {
              final v = reduce ? 0.5 : animation.value;
              return Stack(alignment: Alignment.center, children: [
                if (listening)
                  for (final k in [0.0, 0.5])
                    Opacity(
                      opacity: (1 - ((v + k) % 1)) * 0.35,
                      child: Container(
                        width: 84 + 28 * ((v + k) % 1),
                        height: 84 + 28 * ((v + k) % 1),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: Brand.gradient,
                        ),
                      ),
                    ),
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: listening
                        ? const LinearGradient(
                            colors: [Brand.dangerFill, Brand.purple])
                        : Brand.gradient,
                    boxShadow: [
                      BoxShadow(
                          color: Brand.blue.withValues(alpha: 0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 6)),
                    ],
                  ),
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(26),
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white))
                      : listening
                          ? _Wave(value: v)
                          : const Icon(Icons.mic_rounded, color: Colors.white, size: 36),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _Wave extends StatelessWidget {
  final double value;
  const _Wave({required this.value});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 5; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: Gap.xxs),
            width: 5,
            height: 10 +
                18 *
                    (0.5 +
                        0.5 * math.sin((value * 2 * math.pi) + i * 1.1)).abs(),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

/// A result: what Assisto did (or could not do), with follow-up buttons.
class _ResultCard extends StatefulWidget {
  final VaOutcome outcome;
  const _ResultCard({required this.outcome});
  @override
  State<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<_ResultCard> {
  final Set<int> _used = {};

  @override
  Widget build(BuildContext context) {
    final o = widget.outcome;
    final scheme = Theme.of(context).colorScheme;
    final accent = o.danger
        ? Brand.danger
        : (o.ok ? scheme.primary : scheme.onSurfaceVariant);
    // qa2: the spoken reply usually already names the title and time
    // ("Reminder set: Call Ammu — today, 5:00 PM"); repeating them as a
    // second block read as a stutter. Show the details only when they add
    // something the reply does not say.
    final detailsAddInfo = (o.title != null && !o.reply.contains(o.title!)) ||
        (o.subtitle != null && !o.reply.contains(o.subtitle!));
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md + 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    shape: BoxShape.circle),
                child: Icon(o.icon, color: accent, size: 22),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(o.reply,
                          style: Theme.of(context).textTheme.bodyLarge),
                      if (detailsAddInfo) ...[
                        const SizedBox(height: Gap.sm),
                        if (o.title != null)
                          Text(o.title!,
                              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                        if (o.subtitle != null)
                          Text(o.subtitle!,
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                      ],
                    ]),
              ),
            ]),
            for (final c in o.cards)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: ChatCard(c),
              ),
            if (o.buttons.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              // aligned under the reply text: icon 40 + gap 12, minus the
              // button's own 12dp start inset = 40
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                for (var i = 0; i < o.buttons.length; i++)
                  TextButton.icon(
                    onPressed: _used.contains(i)
                        ? null
                        : () async {
                            final b = o.buttons[i];
                            if (b.icon == Icons.undo_rounded) {
                              setState(() => _used.add(i));
                            }
                            await b.onTap();
                          },
                    icon: Icon(o.buttons[i].icon, size: 18),
                    label: Text(o.buttons[i].label),
                  ),
              ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
