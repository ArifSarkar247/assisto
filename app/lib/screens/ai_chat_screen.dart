import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../growth/branded_share.dart'; // p5-growth
import '../chat_vision/chat_photo.dart';
import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../payments/credits_out_sheet.dart'; // credout
import '../widgets/chat_cards.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../widgets/voice_input.dart';
import '../services/action_feedback.dart'; // db1
import '../services/error_kind.dart' show honestFailText; // qa2

/// Part 3 — Assisto AI: the ChatGPT-like full-history chat.
///
/// This is the RICHER sibling of the home [AgentThreadScreen]: it adds
/// persistent sessions (history drawer with search, pin, rename, delete),
/// per-assistant-message actions (Copy / Share / Regenerate), edit-and-resend
/// of the last user message, and live token streaming with a Stop control.
///
/// REUSE: the rich reply cards are rendered by the SHARED [ChatCard] widget
/// (the same renderer the home chat uses — not duplicated here), and voice
/// input uses the SAME speech_to_text pattern as the home chat (tap mic →
/// dictate into the box; the plugin listens in the app's active language).
///
/// HONESTY: with no AI key the backend answers via Assisto Brain. Every reply
/// carries `meta.source`; a Brain answer shows a small "offline answer" chip
/// and we never claim AI/streaming for it.

class _Msg {
  String? id;
  final bool user;
  String text;
  final List<Map<String, dynamic>> cards;

  /// `meta.source` from the backend (e.g. 'brain' when answered without a key).
  final String? source;

  /// Transient: a streamed assistant message still receiving tokens.
  bool streaming;

  /// h1-home: an attached photo turn (this device only; never saved).
  final ChatPhotoRequest? photo;

  _Msg({
    this.id,
    required this.user,
    required this.text,
    this.cards = const [],
    this.source,
    this.streaming = false,
    this.photo,
  });

  bool get isBrain {
    final s = (source ?? '').toLowerCase();
    return s == 'brain' || s == 'offline' || s == 'assisto_brain';
  }
}

class _Session {
  final String id;
  String title;
  bool pinned;
  String snippet;
  String updated;
  _Session(this.id, this.title, this.pinned, this.snippet, this.updated);

  factory _Session.fromJson(Map<String, dynamic> j) => _Session(
        '${j['id']}',
        (j['title'] ?? '').toString(),
        j['pinned'] == true,
        (j['snippet'] ?? '').toString(),
        (j['updated'] ?? j['updated_at'] ?? '').toString(),
      );
}

class AiChatScreen extends StatefulWidget {
  /// A saved Assisto AI chat to open directly (sidebar history row JSON).
  final Map<String, dynamic>? initialSession;
  const AiChatScreen({super.key, this.initialSession});
  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();

  final List<_Msg> _msgs = [];
  _Session? _active;

  bool _loadingThread = false;
  bool _threadError = false;
  bool _sending = false;

  // Streaming control: a live subscription we can cancel with Stop.
  StreamSubscription<Map<String, dynamic>>? _streamSub;

  // Voice input (shared with the home chat): hold-to-talk, automatic language.
  late final VoiceDictation _voice = VoiceDictation();

  @override
  void initState() {
    super.initState();
    _voice.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _voice.loadMode();
      final init = widget.initialSession;
      if (init != null) _openSession(_Session.fromJson(init));
    });
  }

  AppLocalizations get t => AppLocalizations.of(context);
  ApiClient get _api => context.read<AppState>().api;

  @override
  void dispose() {
    _streamSub?.cancel();
    _voice.dispose();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.base, curve: Curves.easeOut);
      }
    });
  }

  // ---------------- sessions ----------------
  Future<void> _openHistory() async {
    final picked = await showModalBottomSheet<_Session?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _HistorySheet(activeId: _active?.id),
    );
    // A null result means "dismissed"; a sentinel with empty id means New chat.
    if (picked == null || !mounted) return;
    if (picked.id.isEmpty) {
      _newChat();
    } else {
      _openSession(picked);
    }
  }

  void _newChat() {
    _streamSub?.cancel();
    setState(() {
      _active = null;
      _msgs.clear();
      _sending = false;
      _threadError = false;
      _loadingThread = false;
    });
    _input.clear();
    _inputFocus.requestFocus();
  }

  Future<void> _openSession(_Session s) async {
    _streamSub?.cancel();
    setState(() {
      _active = s;
      _msgs.clear();
      _loadingThread = true;
      _threadError = false;
      _sending = false;
    });
    try {
      final rows = await _api.chatMessages(s.id);
      if (!mounted) return;
      setState(() {
        _loadingThread = false;
        for (final m in rows) {
          final role = (m['role'] ?? '').toString();
          final meta = m['meta'];
          _msgs.add(_Msg(
            id: m['id'] == null ? null : '${m['id']}',
            user: role == 'user',
            text: (m['text'] ?? '').toString(),
            cards: ((m['cards'] ?? (meta is Map ? meta['cards'] : null) ?? [])
                    as List)
                .cast<Map<String, dynamic>>(),
            source: meta is Map ? meta['source']?.toString() : null,
          ));
        }
      });
      _toBottom();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingThread = false;
          _threadError = true;
        });
      }
    }
  }

  /// Ensure a backend session exists for the current thread, creating one on
  /// the first send of a brand-new chat.
  Future<_Session?> _ensureSession() async {
    if (_active != null) return _active;
    try {
      final j = await _api.chatCreateSession();
      final s = _Session.fromJson(j);
      if (mounted) setState(() => _active = s);
      return s;
    } catch (_) {
      return null;
    }
  }

  // ---------------- send / stream ----------------
  // credout: the user turn of the send in flight (removed again when the
  // server says "out of credits" — its text goes back into the box).
  _Msg? _pendingUser;
  bool _creditsRetry = false;

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    // db1: Send on an empty box is never a dead tap — it opens the keyboard.
    if (text.isEmpty && preset == null && !_sending) {
      _inputFocus.requestFocus();
      return;
    }
    if (text.isEmpty || _sending) return;
    HapticFeedback.selectionClick();
    _input.clear();
    final mine = _Msg(user: true, text: text);
    _pendingUser = mine;
    setState(() {
      _msgs.add(mine);
      _sending = true;
    });
    _toBottom();

    final session = await _ensureSession();
    if (session == null) {
      _onSendError();
      return;
    }
    await _streamOrSend(session.id, text);
  }

  /// Try the SSE stream first (live tokens + Stop); if the stream can't start
  /// (not available / errors immediately), fall back to the non-stream /send
  /// with a typing indicator. Either way the reply is rendered honestly.
  Future<void> _streamOrSend(String sessionId, String text) async {
    // Placeholder assistant bubble we fill as tokens arrive.
    final assistant = _Msg(user: false, text: '', streaming: true);
    setState(() => _msgs.add(assistant));
    _toBottom();

    var gotToken = false;
    Object? streamErr;
    final completer = Completer<bool>(); // true = finished via stream
    try {
      _streamSub = _api.chatStream(sessionId, text).listen(
        (ev) {
          if (!mounted) return;
          if (ev['kind'] == 'token') {
            gotToken = true;
            setState(() => assistant.text += (ev['chunk'] ?? '').toString());
            _toBottom();
          } else if (ev['kind'] == 'done') {
            final cards =
                ((ev['cards'] ?? []) as List).cast<Map<String, dynamic>>();
            final doneText = (ev['text'] ?? '').toString();
            setState(() {
              assistant.streaming = false;
              if (assistant.text.isEmpty && doneText.isNotEmpty) {
                assistant.text = doneText;
              }
              assistant.id = ev['message_id']?.toString();
              assistant.cards
                ..clear()
                ..addAll(cards);
            });
            _applySource(assistant, ev['source'], ev['meta']);
          }
        },
        onError: (Object e) {
          streamErr = e;
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(true);
        },
        cancelOnError: true,
      );
      final ok = await completer.future;
      if (!mounted) return;
      if (!ok && !gotToken) {
        _msgs.remove(assistant);
        if (isOutOfCredits(streamErr)) {
          await _onCreditsOut(text);
          return;
        }
        // Stream never produced anything usable — fall back to /send.
        await _nonStreamSend(sessionId, text);
        return;
      }
      setState(() {
        assistant.streaming = false;
        _sending = false;
      });
      _syncData();
    } catch (_) {
      // Stream couldn't even start — honest fallback to /send.
      if (mounted) _msgs.remove(assistant);
      await _nonStreamSend(sessionId, text);
    } finally {
      _streamSub = null;
    }
  }

  Future<void> _nonStreamSend(String sessionId, String text) async {
    final assistant = _Msg(user: false, text: '', streaming: true);
    setState(() => _msgs.add(assistant));
    _toBottom();
    try {
      final r = await _api.chatSend(sessionId, text);
      if (!mounted) return;
      final cards = ((r['cards'] ?? []) as List).cast<Map<String, dynamic>>();
      setState(() {
        assistant.streaming = false;
        assistant.id = r['id']?.toString();
        assistant.text = (r['text'] ?? '').toString();
        assistant.cards
          ..clear()
          ..addAll(cards);
        _sending = false;
      });
      _applySource(assistant, r['source'], r['meta']);
      _syncData();
      _toBottom();
    } catch (e) {
      if (mounted) _msgs.remove(assistant);
      if (isOutOfCredits(e)) return _onCreditsOut(text);
      _onSendError();
    }
  }

  /// credout: the server saved nothing — the text goes back into the box
  /// (never lost), the buy-credits sheet opens at once, and after a verified
  /// purchase / reward the same text is sent again ONCE.
  Future<void> _onCreditsOut(String text) async {
    if (!mounted) return;
    final mine = _pendingUser;
    setState(() {
      if (mine != null) _msgs.remove(mine);
      if (_input.text.trim().isEmpty) _input.text = text;
      _sending = false;
      for (final m in _msgs) {
        m.streaming = false;
      }
    });
    _pendingUser = null;
    if (_creditsRetry) {
      _creditsRetry = false; // already retried once: keep the draft, stop
      return;
    }
    final ok = await CreditsOut.offer(context, screen: 'ai_chat', draftKept: true);
    if (!ok || !mounted || _input.text.trim() != text) return;
    _creditsRetry = true;
    try {
      await _send(text);
    } finally {
      _creditsRetry = false;
    }
  }

  // The _Msg.source is final, so swap in a fresh message carrying the resolved
  // source (keeps the honest "offline answer" chip accurate without a mutable
  // field just for this).
  void _applySource(_Msg assistant, dynamic source, dynamic meta) {
    final src =
        source?.toString() ?? (meta is Map ? meta['source']?.toString() : null);
    if (src == null) return;
    final idx = _msgs.indexOf(assistant);
    if (idx < 0) return;
    setState(() {
      _msgs[idx] = _Msg(
        id: assistant.id,
        user: false,
        text: assistant.text,
        cards: assistant.cards,
        source: src,
        streaming: false,
      );
    });
  }

  void _onSendError() {
    if (!mounted) return;
    setState(() {
      _msgs.add(_Msg(user: false, text: t.aichatSendFailed));
      _sending = false;
    });
    _toBottom();
  }

  void _syncData() {
    // A reply may have logged a reminder/expense/etc. — refresh the caches the
    // home chat also refreshes, so other screens stay current.
    final app = context.read<AppState>();
    app.reminders.sync();
    app.txns.sync();
    app.loans.sync();
  }

  Future<void> _stop() async {
    await _streamSub?.cancel();
    _streamSub = null;
    if (!mounted) return;
    setState(() {
      _sending = false;
      for (final m in _msgs) {
        m.streaming = false;
      }
    });
  }

  // ---------------- message actions ----------------
  void _copy(_Msg m) {
    Clipboard.setData(ClipboardData(text: m.text));
    _snack(t.aichatCopied);
  }

  Future<void> _share(_Msg m) async {
    try {
      // p5-growth: branded image + text, preview first; only this answer.
      await showBrandedShare(context, body: m.text);
    } catch (e) {
      showActionFailed(context, 'aichat.share', e, open: true); // db1
    }
  }

  Future<void> _regenerate(_Msg assistant,
      {String? edit, bool creditsRetry = false}) async {
    if (_sending || _active == null) return;
    HapticFeedback.selectionClick();
    // Drop the old assistant reply (and any trailing cards) before asking again.
    final at = _msgs.indexOf(assistant);
    setState(() {
      _msgs.remove(assistant);
      _sending = true;
    });
    final assistantNew = _Msg(user: false, text: '', streaming: true);
    setState(() => _msgs.add(assistantNew));
    _toBottom();
    try {
      final r = await _api.chatRegenerate(_active!.id, edit: edit);
      if (!mounted) return;
      final cards = ((r['cards'] ?? []) as List).cast<Map<String, dynamic>>();
      setState(() {
        assistantNew.streaming = false;
        assistantNew.id = r['id']?.toString();
        assistantNew.text = (r['text'] ?? '').toString();
        assistantNew.cards
          ..clear()
          ..addAll(cards);
        _sending = false;
      });
      _applySource(assistantNew, r['source'], r['meta']);
      _syncData();
      _toBottom();
    } catch (e) {
      if (mounted) _msgs.remove(assistantNew);
      if (isOutOfCredits(e) && mounted) {
        // credout: the server kept the old reply — show it again, offer
        // credits, then regenerate once.
        setState(() {
          _msgs.insert((at < 0 || at > _msgs.length) ? _msgs.length : at, assistant);
          _sending = false;
        });
        if (creditsRetry) return;
        final ok = await CreditsOut.offer(context, screen: 'ai_chat', draftKept: true);
        if (ok && mounted) {
          await _regenerate(assistant, edit: edit, creditsRetry: true);
        }
        return;
      }
      _onSendError();
    }
  }

  /// Edit the last user message, then regenerate with the edited text.
  Future<void> _editLastUser() async {
    final idx = _msgs.lastIndexWhere((m) => m.user);
    if (idx < 0) return;
    final userMsg = _msgs[idx];
    final edited = await _promptText(
      title: t.aichatEditMessage,
      initial: userMsg.text,
      hint: t.aichatInputHint,
    );
    if (edited == null || edited.trim().isEmpty || !mounted) return;
    setState(() => userMsg.text = edited.trim());
    // Regenerate against the trailing assistant reply if there is one.
    final after = idx + 1 < _msgs.length ? _msgs[idx + 1] : null;
    if (after != null && !after.user) {
      await _regenerate(after, edit: edited.trim());
    } else {
      // No assistant reply yet — just resend as a fresh turn.
      await _streamOrSend(_active!.id, edited.trim());
    }
  }

  // h1-home: attach a photo and ask about it (typed text = the question).
  void _attachPhoto(Uint8List bytes) {
    final q = _input.text.trim();
    _input.clear();
    setState(() => _msgs.add(
        _Msg(user: true, text: q, photo: ChatPhotoRequest(bytes, q))));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.base, curve: Curves.easeOut);
      }
    });
  }

  // ---------------- helpers ----------------
  void _snack(String msg) {
    final m = ScaffoldMessenger.of(context);
    m.clearSnackBars();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String?> _promptText(
      {required String title, String initial = '', String? hint}) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.aichatCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(t.aichatSave)),
        ],
      ),
    );
  }

  // ---------------- build ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_active == null
            ? t.aichatTitle
            : (_active!.title.isEmpty ? t.aichatUntitled : _active!.title)),
        actions: [
          IconButton(
            tooltip: t.aichatHistory,
            icon: const Icon(Icons.history_rounded),
            onPressed: _openHistory,
          ),
          IconButton(
            tooltip: t.aichatNewChat,
            icon: const Icon(Icons.add_comment_rounded),
            onPressed: _newChat,
          ),
        ],
      ),
      body: Column(children: [
        Expanded(child: _body()),
        _inputBar(),
      ]),
    );
  }

  Widget _body() {
    if (_loadingThread) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_threadError) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.aichatLoadFailed, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          FilledButton(
            onPressed: () => _active == null ? null : _openSession(_active!),
            child: Text(t.aichatRetry),
          ),
        ]),
      );
    }
    if (_msgs.isEmpty) return _welcome();
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
      itemCount: _msgs.length,
      itemBuilder: (_, i) => _bubble(_msgs[i], i),
    );
  }

  Widget _welcome() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.md),
      children: [
        Center(
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              gradient: Brand.gradient,
              borderRadius: BorderRadius.circular(20),
            ),
            child:
                const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 38),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.aichatWelcomeHeadline,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        Text(t.aichatWelcomeBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.xl),
        // Premium QA: welcome state offers real starting points (tap = send).
        for (final (icon, text) in [
          (Icons.edit_note_rounded, t.a1AiSugLeave),
          (Icons.summarize_rounded, t.a1AiSugWeek),
          (Icons.campaign_rounded, t.a1AiSugShop),
          (Icons.receipt_long_rounded, t.a1AiSugBill),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.md),
                onTap: _sending ? null : () => _send(text),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Gap.md, vertical: Gap.md),
                  child: Row(children: [
                    Icon(icon, size: 20, color: scheme.primary),
                    const SizedBox(width: Gap.md),
                    Expanded(
                        child: Text(text,
                            style: const TextStyle(height: 1.3))),
                  ]),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---------------- bubble ----------------
  Widget _bubble(_Msg m, int i) {
    final photo = m.photo;
    if (photo != null) return ChatPhotoTurn(request: photo);
    final scheme = Theme.of(context).colorScheme;
    final isLastAssistant = !m.user && i == _msgs.length - 1 && !m.streaming;
    final isLastUserEditable = m.user &&
        !_sending &&
        _msgs.skip(i + 1).every((x) => !x.user); // last user turn

    final bubble = Container(
      constraints:
          BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.80),
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
        if (m.streaming && m.text.isEmpty)
          _TypingDots(color: scheme.onSurfaceVariant)
        else
          _assistantText(m, scheme),
        for (final c in m.cards) ChatCard(c),
        if (!m.user && m.isBrain && !m.streaming) _offlineChip(scheme),
      ]),
    );

    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              bubble,
              if (isLastUserEditable)
                TextButton.icon(
                  onPressed: _editLastUser,
                  icon: const Icon(Icons.edit_rounded, size: 15),
                  label: Text(t.aichatEdit),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _avatar(scheme),
        const SizedBox(width: Gap.sm),
        Flexible(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            bubble,
            if (isLastAssistant && m.text.isNotEmpty) _assistantActions(m),
          ]),
        ),
      ]),
    );
  }

  Widget _avatar(ColorScheme scheme) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 16),
      );

  Widget _offlineChip(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Tooltip(
          message: t.aichatOfflineAnswerHint,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.cloud_off_rounded,
                  size: 13, color: scheme.onSecondaryContainer),
              const SizedBox(width: Gap.xs),
              Text(t.aichatOfflineAnswer,
                  style: AType.labelSmall.copyWith(fontWeight: FontWeight.w600,
                      color: scheme.onSecondaryContainer)),
            ]),
          ),
        ),
      );

  Widget _assistantActions(_Msg m) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        foregroundColor: scheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm));
    return Wrap(children: [
      TextButton.icon(
          onPressed: () => _copy(m),
          icon: const Icon(Icons.copy_rounded, size: 15),
          label: Text(t.aichatCopy),
          style: style),
      TextButton.icon(
          onPressed: () => _share(m),
          icon: const Icon(Icons.ios_share_rounded, size: 15),
          label: Text(t.aichatShare),
          style: style),
      TextButton.icon(
          onPressed: _sending ? null : () => _regenerate(m),
          icon: const Icon(Icons.refresh_rounded, size: 15),
          label: Text(t.aichatRegenerate),
          style: style),
    ]);
  }

  // Markdown/code: flutter_markdown is NOT a dependency (confirmed in
  // pubspec), so we render plain text with a light fenced-code-block style
  // rather than adding a native/heavy plugin. Fenced ``` blocks become a
  // monospace surface; everything else is plain body text.
  Widget _assistantText(_Msg m, ColorScheme scheme) {
    if (m.text.isEmpty && !m.user) return const SizedBox.shrink();
    if (m.user || !m.text.contains('```')) {
      return Text(m.text,
          style: TextStyle(
              color: m.user ? scheme.onPrimary : scheme.onSurface,
              height: 1.45));
    }
    // Split on fenced code blocks (``` ... ```), keeping text segments plain
    // and code segments in a mono surface.
    final parts = m.text.split('```');
    final widgets = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      final seg = parts[i];
      if (seg.isEmpty) continue;
      final isCode = i.isOdd;
      if (isCode) {
        // Drop a leading language token (e.g. "dart\n...").
        var code = seg;
        final nl = code.indexOf('\n');
        if (nl > 0 && !code.substring(0, nl).contains(' ')) {
          code = code.substring(nl + 1);
        }
        widgets.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: Gap.xs),
          padding: const EdgeInsets.all(Gap.sm),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(Radii.sm),
            border:
                Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: SelectableText(code.trimRight(),
              style: AType.bodyMedium.copyWith(fontFamily: 'monospace', height: 1.4)),
        ));
      } else {
        widgets.add(Text(seg.trim(),
            style: TextStyle(color: scheme.onSurface, height: 1.45)));
      }
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: widgets);
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
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText:
                    _voice.listening ? t.aichatListening : t.aichatInputHint,
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
          ChatPhotoAttachButton(onPicked: _attachPhoto, enabled: !_sending),
          VoiceMicButton(voice: _voice, input: _input),
          // While a reply is in flight, the send button becomes a Stop control.
          _sending
              ? IconButton.filled(
                  onPressed: _stop,
                  tooltip: t.aichatStop,
                  icon: const Icon(Icons.stop_rounded),
                )
              : IconButton.filled(
                  onPressed: () => _send(),
                  tooltip: t.aichatSend,
                  icon: const Icon(Icons.arrow_upward_rounded)),
        ]),
      ),
    );
  }
}

/// Animated "typing" dots shown while a streamed reply has no text yet.
class _TypingDots extends StatefulWidget {
  final Color color;
  const _TypingDots({required this.color});
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xxs),
              child: Opacity(
                opacity:
                    0.3 + 0.7 * ((((_c.value + i / 3) % 1) - 0.5).abs() * 2),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                      color: widget.color, shape: BoxShape.circle),
                ),
              ),
            ),
        ]);
      },
    );
  }
}

/// The sessions history sheet: search, New chat, and per-session rename / pin /
/// delete. Returns the chosen [_Session] (empty id = New chat), or null.
class _HistorySheet extends StatefulWidget {
  final String? activeId;
  const _HistorySheet({this.activeId});
  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  final _searchCtrl = TextEditingController();
  List<_Session> _sessions = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  String _q = '';
  Timer? _debounce;

  AppLocalizations get t => AppLocalizations.of(context);
  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final rows = await _api.chatSessions(query: _q.isEmpty ? null : _q);
      // Home-chat threads reopen on home (sidebar), not inside AI chat.
      final list = rows
          .where((r) => r['source'] != 'home')
          .map(_Session.fromJson)
          .toList();
      // Pinned first, then as the server ordered them.
      list.sort((a, b) => (b.pinned ? 1 : 0).compareTo(a.pinned ? 1 : 0));
      if (mounted) {
        setState(() {
          _sessions = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
          _failCause = e;
        });
      }
    }
  }

  void _onSearch(String v) {
    _q = v;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _rename(_Session s) async {
    final ctrl = TextEditingController(text: s.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.aichatRename),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: t.aichatRenameHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.aichatCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(t.aichatSave)),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await _api.chatUpdateSession(s.id, title: name.trim());
      if (mounted) setState(() => s.title = name.trim());
    } catch (e) {
      showActionFailed(context, 'aichat.rename', e); // db1
    }
  }

  Future<void> _togglePin(_Session s) async {
    try {
      await _api.chatUpdateSession(s.id, pinned: !s.pinned);
      if (mounted) {
        setState(() {
          s.pinned = !s.pinned;
          _sessions
              .sort((a, b) => (b.pinned ? 1 : 0).compareTo(a.pinned ? 1 : 0));
        });
      }
    } catch (e) {
      showActionFailed(context, 'aichat.pin', e); // db1
    }
  }

  Future<void> _delete(_Session s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t.aichatDeleteConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.aichatCancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: Brand.dangerButton(),
            child: Text(t.aichatDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.chatDeleteSession(s.id);
      if (mounted) setState(() => _sessions.remove(s));
    } catch (e) {
      showActionFailed(context, 'aichat.delete', e); // db1
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Row(children: [
              Expanded(
                  child: Text(t.aichatHistory,
                      style: Theme.of(context).textTheme.titleLarge)),
              FilledButton.tonalIcon(
                onPressed: () =>
                    Navigator.pop(context, _Session('', '', false, '', '')),
                icon: const Icon(Icons.add_comment_rounded, size: 18),
                label: Text(t.aichatNewChat),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearch,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: t.aichatSearchHint,
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Expanded(child: _list(scheme)),
        ]),
      ),
    );
  }

  Widget _list(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(honestFailText(t, _failCause, otherwise: t.aichatLoadFailed), textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          FilledButton(onPressed: _load, child: Text(t.aichatRetry)),
        ]),
      );
    }
    if (_sessions.isEmpty) {
      final searching = _q.trim().isNotEmpty;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(searching ? Icons.search_off_rounded : Icons.chat_bubble_outline_rounded,
                size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(searching ? t.aichatNoSearchResults : t.aichatNoChats,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            if (!searching) ...[
              const SizedBox(height: Gap.xs),
              Text(t.aichatNoChatsBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      );
    }
    return ListView.builder(
      itemCount: _sessions.length,
      itemBuilder: (_, i) {
        final s = _sessions[i];
        final active = s.id == widget.activeId;
        return ListTile(
          selected: active,
          selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.4),
          leading: Icon(s.pinned ? Icons.push_pin_rounded : Icons.chat_bubble_outline_rounded,
              color: s.pinned ? scheme.primary : scheme.onSurfaceVariant),
          title: Text(s.title.isEmpty ? t.aichatUntitled : s.title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: _subtitle(s, scheme),
          onTap: () => Navigator.pop(context, s),
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  _rename(s);
                  break;
                case 'pin':
                  _togglePin(s);
                  break;
                case 'delete':
                  _delete(s);
                  break;
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(t.aichatRename)),
              PopupMenuItem(
                  value: 'pin',
                  child: Text(s.pinned ? t.aichatUnpin : t.aichatPin)),
              PopupMenuItem(value: 'delete', child: Text(t.aichatDelete)),
            ],
          ),
        );
      },
    );
  }

  Widget? _subtitle(_Session s, ColorScheme scheme) {
    final parts = <String>[];
    if (s.snippet.isNotEmpty) parts.add(s.snippet);
    final rel = _relative(s.updated);
    if (rel.isNotEmpty) parts.add(t.aichatUpdatedRelative(rel));
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '),
        maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  // A compact relative time ("5m", "3h", "2d"), Bangla-digit aware.
  String _relative(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    int n;
    String unit;
    if (diff.inMinutes < 1) {
      return '';
    } else if (diff.inHours < 1) {
      n = diff.inMinutes;
      unit = 'm';
    } else if (diff.inDays < 1) {
      n = diff.inHours;
      unit = 'h';
    } else {
      n = diff.inDays;
      unit = 'd';
    }
    return '${fmtInt(context, n)}$unit';
  }
}
