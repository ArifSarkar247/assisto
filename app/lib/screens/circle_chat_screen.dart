import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../messaging/badges_bus.dart';
import '../crypto/e2e.dart';
import '../crypto/key_service.dart';
import '../l10n/app_localizations.dart';
import '../messenger_chat_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/chat_menu_pickers.dart';
import '../widgets/chat_menu_sheet.dart';
import '../widgets/circle_attach_sheet.dart';
import '../widgets/circle_bubble.dart';
import '../widgets/msgr_avatar.dart';
import '../widgets/circle_media_viewer.dart';
import '../widgets/circle_message_actions.dart';
import 'circle_call_screen.dart';
import 'circle_extras_hub_screen.dart';
import 'messenger/contact_info_screen.dart';
import '../messaging/call_events.dart'; // a1-circle
import '../messaging/chat_header.dart'; // t1-ticks
import '../messaging/preview_cache.dart'; // a1-circle
import '../messaging/date_separators.dart'; // t1-ticks
import '../messaging/mc_version_gate.dart'; // t1-ticks
import '../messaging/c3_api.dart';
import '../messaging/msg_native.dart';
import '../messaging/msg_notify.dart';
import '../messaging/msg_prefs.dart';
import '../messaging/msg_request_widgets.dart'; // mr1
import '../messaging/msg_widgets.dart';
import '../messaging/outbox.dart';
import '../messaging/echo_reconcile.dart'; // md2
import '../messaging/forward.dart'; // md2
import '../services/action_feedback.dart';
import '../messaging/media/media_actions.dart'; // md1
import '../messaging/media/media_descriptor.dart';
import '../messaging/media/media_outbox.dart';
import '../messaging/media/media_send.dart';
import '../messaging/media/media_store.dart';
import '../messaging/presence_label.dart';
import '../messaging/receipt_bus.dart';
import '../messaging/unread_store.dart';
import '../realtime/realtime_channel.dart';
import '../widgets/robo_id.dart';
import '../p3/assisto_card.dart'; // p3
import '../p3/assisto_card_view.dart';
import '../p3/assisto_intent.dart';
import '../p3/assisto_sheet.dart';
import '../p3/scam_banner.dart';
import '../p3/scam_guard.dart';
import '../messaging/chat_decor/chat_control.dart'; // cde-chat
import '../messaging/chat_decor/chat_themes.dart';
import '../messaging/chat_decor/decor_chat.dart';
import '../messaging/chat_decor/decor_sheets.dart';
import '../messaging/chat_decor/decor_store.dart';
import '../messaging/chat_decor/system_line.dart';
import '../messaging/media/media_prep.dart' show pickPhoto, MediaDraft;
import '../widgets/paywall_sheet.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;

/// End-to-end-encrypted 1:1 chat with a circle member.
///
/// FLOW (text works now via the software fallback in crypto/e2e.dart):
///   send  -> E2E.encrypt(plaintext, peerPublicKey) -> ciphertext envelope
///         -> POST /circle/<member>/messages  (server stores CIPHERTEXT ONLY)
///   recv  -> GET /circle/<member>/messages    (ciphertext envelopes)
///         -> E2E.decrypt(envelope, peerPublicKey) on-device
/// The server never holds a key and cannot read these messages; nor can the
/// server AI (see core/logic/circle.py ai_redaction / validate_envelope).
///
/// M1 features wired here: reply, reactions, edit (time-limited), delete
/// (me/everyone), forward (+label), copy, star, pin-in-chat, in-chat search,
/// typing indicator, offline queue + retry, link-preview detection (SENDER
/// device only), and the media attach sheet (key-gated kinds show a reason).
///
/// Message edit/delete/reaction/star/pin semantics mirror
/// core/logic/circle_messaging.py exactly; media sizing/gating mirrors
/// core/logic/circle_media.py.
class CircleChatScreen extends StatefulWidget {
  final Map<String, dynamic> member;
  final IdentityKeyPair identity;

  /// When set, forwards this message into the chat on open (forward flow).
  final CircleMessage? forwarding;
  const CircleChatScreen({
    super.key,
    required this.member,
    required this.identity,
    this.forwarding,
  });

  @override
  State<CircleChatScreen> createState() => _CircleChatScreenState();
}

// Edit window (minutes) — mirrors circle_messaging.EDIT_WINDOW_MIN.
const int _kEditWindowMin = 15;
// Delete-for-everyone window — mirrors circle_messaging.DELETE_EVERYONE_WINDOW_MIN.
const int _kDeleteEveryoneWindowMin = 60 * 24 * 2;
// Pin cap per chat — mirrors circle_messaging.PIN_CAP_PER_CHAT.
const int _kPinCap = 3;

// Foreground live-refresh cadence while the thread is open (WhatsApp/Telegram
// benchmark). No background service, no push — we poll the existing
// GET /circle/<id>/messages every few seconds ONLY while the chat is open and
// in the foreground, mirroring lib/alerts_fg.dart. Cheap + fully cancellable.
const Duration _kPollInterval = Duration(seconds: 7);

class _CircleChatScreenState extends State<CircleChatScreen>
    with WidgetsBindingObserver {
  final _e2e = SoftwareE2E();
  final _input = TextEditingController();
  final _inputFocus = FocusNode(); // db1
  final _scroll = ScrollController();

  // Live foreground poll (see _kPollInterval). Null when not scheduled.
  Timer? _poll;
  // In-flight guard so a slow fetch never stacks with the next tick (and so we
  // never double-schedule). Mirrors AlertPoller._busy.
  bool _polling = false;

  List<CircleMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;

  // c3-msg: live presence / typing over the shared RealtimeChannel.
  final _rt = RealtimeChannel.instance;
  RtChatState get _live => _rt.stateOf('member', _memberId ?? 0);
  bool get _peerTyping => _live.active;
  String get _chatKey => 'member:${_memberId ?? 0}';

  // c3-msg: jump-to-original highlight + per-message keys.
  String? _highlightId;
  Timer? _hlTimer;
  final Map<String, GlobalKey> _msgKeys = {};
  bool? _bubbleOn;
  bool _seenInFlight = false;
  // x2-ticks: live ticks + visibility-gated seen.
  StreamSubscription<ReceiptUpdate>? _rcptSub;
  StreamSubscription<String>? _newSub;
  Timer? _visTimer;
  bool _wasVisible = true;
  bool _seenPending = false;
  bool _searching = false;
  String _searchQuery = '';

  // Chat-menu backed state (confirmed from the server on open).
  bool _favourite = false;
  int _disappearingSec = 0;

  // cde-chat (order 6 D + E): the chat's shared theme + nicknames, synced by
  // E2E control messages (+ the server copy for a reinstall).
  late final DecorChat _decor = DecorChat(
      api: _api, chatKey: _chatKey, chatId: _memberId ?? 0, group: false);
  final Map<String, ChatControl?> _ctrlCache = {};
  Future<AiThemeOffer?>? _aiOffer;

  // Multi-select mode (⋮ Select messages).
  bool _selecting = false;
  final Set<String> _selected = {};

  // Reply / edit context.
  CircleMessage? _replyTo;
  CircleMessage? _editing;

  // e2-keys item 1: the peer key is LIVE (re-fetched on open, before each
  // send and on key.published) — never only the list snapshot. Older keys
  // of this peer still decrypt history; a change adds a security note.
  String _peerB64 = '';
  List<Uint8List> _peerHistory = const [];
  // a1-circle: the peer's EARLIER keys from the server (key directory
  // history) — a new phone of mine still decrypts pre-change history.
  List<Uint8List> _serverHist = const [];
  // a1-circle: 1:1 call events shown inside the timeline (WhatsApp-style).
  List<CallEvent> _calls = const [];
  int _pollTick = 0;
  List<DateTime> _keyNotes = const [];
  List<OutboxItem> _queued = const [];
  StreamSubscription<Map<String, dynamic>>? _keySub;
  // md1: photo / voice / document sends of this chat still on their way.
  List<MediaJob> _mediaJobs = const [];
  StreamSubscription<MediaSent>? _mediaSentSub;
  // md2: sent bubbles held until their server copy is in the list.
  final SentEchoes _sentEchoes = SentEchoes();
  // md2: client_msg_ids of my rows in the last fetched page (a job / queued
  // item whose server copy is already listed is not drawn twice).
  Set<String> _serverCmids = const {};

  // e2-keys item 2: reversed, paged list that OPENS at the latest message
  // (or at the "N unread messages" divider) with no visible scroll.
  static const int _pageSize = 50;
  bool _hasMore = false;
  bool _loadingOlder = false;
  int _unreadAtOpen = 0;
  String? _firstUnreadId;
  bool _positioned = true; // false only while placing the unread divider
  final GlobalKey _dividerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // c3-msg: this chat is on screen → its notifications stop ringing, the
    // badges clear now, presence/typing go live.
    MsgActiveChat.current = _chatKey;
    UnreadStore.instance.clear(_chatKey);
    if (_memberId != null) unawaited(FlnMsgSink().cancel('member', _memberId!));
    _rt.acquire();
    _rt.states.addListener(_onRt);
    unawaited(_loadBubblePref());
    _peerB64 = '${widget.member['public_key'] ?? ''}';
    Outbox.instance.changes.addListener(_onOutbox);
    _keySub = KeyService.instance.keyEvents.stream.listen(_onKeyEvent);
    // md1: media sends (progress ring) + the decrypted-file directory.
    MediaOutbox.instance.identity ??= () async => widget.identity;
    MediaOutbox.instance.changes.addListener(_onMediaJobs);
    _mediaSentSub = MediaOutbox.instance.sent.listen((s) {
      if (s.chatKind == 'member' && s.chatId == _memberId) {
        ReceiptBus.instance.expect();
        unawaited(_pollMessages());
      }
    });
    unawaited(_onMediaJobsAsync());
    unawaited(MediaDirs.root().then((_) {
      if (mounted) setState(() {});
    }, onError: (Object e) => KeyService.instance.log.add('md1 dir ${e.runtimeType}')));
    _scroll.addListener(_onScroll);
    _load().then((_) {
      if (widget.forwarding != null) _doForwardInto(widget.forwarding!);
    });
    _startPolling();
    // x2-ticks: the server's receipt.update (✓✓ / blue ✓✓) lands here in
    // the next realtime poll; msg.new refreshes the thread at once.
    _rcptSub = ReceiptBus.instance.updates.listen(_onReceipt);
    _newSub = ReceiptBus.instance.newMessages.listen((chat) {
      if (chat == _chatKey) unawaited(_pollMessages());
    });
    _startVisWatch();
    // cde-chat: local theme/nicknames at once, then the server copy
    DecorStore.instance.revision.addListener(_onDecor);
    unawaited(DecorStore.instance.adoptMemberPayload(_chatKey, widget.member));
    if (_memberId != null) unawaited(_decor.load());
  }

  void _onDecor() {
    if (mounted) setState(() {});
  }

  /// x2-ticks: apply a live receipt (never downgrades a tick).
  void _onReceipt(ReceiptUpdate u) {
    if (!mounted || u.chat != _chatKey) return;
    var changed = false;
    final next = _messages.map((m) {
      final s = u.statuses[m.id];
      if (s == null || !m.mine) return m;
      final merged = mergeStatus(m.status, s);
      if (merged == m.status) return m;
      changed = true;
      return m.copyWith(status: merged);
    }).toList();
    if (changed) setState(() => _messages = next);
    _maybeExpectTicks();
  }

  /// x2-ticks: the chat is REALLY on the user's screen: app resumed, this
  /// route on top (nothing pushed over it) and not offstage.
  bool get _visibleNow {
    if (!mounted) return false;
    final ls = WidgetsBinding.instance.lifecycleState;
    if (ls != null && ls != AppLifecycleState.resumed) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    return TickerMode.valuesOf(context).enabled;
  }

  /// A covered chat (another screen on top) is not "read"; when it is
  /// uncovered again, the pending seen goes out at once.
  void _startVisWatch() {
    _visTimer?.cancel();
    _visTimer = Timer.periodic(const Duration(seconds: 1), (_) => _visTick());
  }

  void _visTick() {
    if (!mounted) return;
    final v = _visibleNow;
    if (v == _wasVisible) return;
    _wasVisible = v;
    if (v) {
      MsgActiveChat.current = _chatKey;
      if (_seenPending) unawaited(_markSeen());
      _maybeExpectTicks();
    } else if (MsgActiveChat.current == _chatKey) {
      MsgActiveChat.current = null; // covered → its notifications ring again
    }
  }

  /// Fast realtime polling while one of MY recent messages still waits for
  /// ✓✓ / blue ✓✓ in this open, visible chat.
  void _maybeExpectTicks() {
    if (!_visibleNow) return;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    if (_messages.any((m) =>
        m.mine && !m.pending && m.status != 'read' && m.status != 'failed' &&
        m.at.isAfter(cutoff))) {
      ReceiptBus.instance.expect();
    } else {
      ReceiptBus.instance.relax(); // everything read → idle cadence
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DecorStore.instance.revision.removeListener(_onDecor); // cde-chat
    if (MsgActiveChat.current == _chatKey) MsgActiveChat.current = null;
    _rt.states.removeListener(_onRt);
    if (_memberId != null) _rt.typing('member', _memberId!, 'stop');
    _rt.release();
    _hlTimer?.cancel();
    _rcptSub?.cancel(); // x2-ticks
    _newSub?.cancel();
    _visTimer?.cancel();
    ReceiptBus.instance.relax();
    _stopPolling();
    Outbox.instance.changes.removeListener(_onOutbox);
    MediaOutbox.instance.changes.removeListener(_onMediaJobs);
    _mediaSentSub?.cancel();
    _keySub?.cancel();
    _input.dispose();
    _inputFocus.dispose(); // db1
    _scroll.dispose();
    super.dispose();
  }

  /// Keep the open thread live without a background service: poll the existing
  /// message-fetch while foregrounded, and refresh immediately on resume — so
  /// incoming messages appear without a manual pull-to-refresh.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // x2-ticks: active (and seen) only if this route is really on top.
      _wasVisible = false;
      _visTick();
      _pollMessages(); // catch up on whatever arrived while backgrounded
      _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // Stop burning requests the moment we leave the foreground; while
      // backgrounded this chat's messages notify again.
      if (MsgActiveChat.current == _chatKey) MsgActiveChat.current = null;
      _wasVisible = false; // x2-ticks
      ReceiptBus.instance.relax();
      _stopPolling();
    }
  }

  void _startPolling() {
    if (_poll != null) return; // never double-schedule
    _poll = Timer.periodic(_kPollInterval, (_) => _pollMessages());
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// A cheap background tick: re-fetch + decrypt messages only (NOT the per-chat
  /// settings), swap them in only when something actually changed, and never
  /// yank the scroll unless the user is already at the bottom. Fully silent on
  /// failure (offline / not-wired), and guarded so ticks can't stack.
  Future<void> _pollMessages() async {
    if (_polling || _loading || _memberId == null) return;
    _polling = true;
    if (++_pollTick % 3 == 0) unawaited(_loadCalls()); // a1-circle
    try {
      final peer = _peerPub;
      final r = await _api.getJson('/circle/$_memberId/messages?limit=$_pageSize');
      final raw = ((r['results'] ?? r['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      final fetched = raw.map((e) => _decryptEnvelope(e, peer)).toList();
      _applyEdge(r['edge']); // mr1: request accepted while open
      // Preserve any optimistic local echoes the server hasn't confirmed yet.
      final serverIds = fetched.map((m) => m.id).toSet();
      final cmids = fetchedClientIds(raw);
      final pendingEchoes = _localEchoes(serverIds, cmids);
      _serverCmids = cmids;
      // e2-keys item 2: keep the OLDER pages already loaded (scroll-up).
      final oldest = fetched.isEmpty ? null : int.tryParse(fetched.first.id);
      final older = oldest == null
          ? const <CircleMessage>[]
          : _messages.where((m) {
              final n = int.tryParse(m.id);
              return n != null && n < oldest && !serverIds.contains(m.id);
            }).toList();
      final merged = [...older, ...fetched, ...pendingEchoes];
      if (!mounted || !_changed(_messages, merged)) return;
      // c3-msg: a new incoming message while the chat is open → seen now
      // (x2-ticks: only if it is really visible; else when uncovered).
      final known = _messages.map((m) => m.id).toSet();
      if (merged.any((m) => !m.mine && !known.contains(m.id))) {
        _seenPending = true;
        unawaited(_markSeen());
      }
      // Reversed list: offset 0 IS the bottom, so new messages appear in
      // place without any programmatic scroll.
      setState(() {
        _messages = merged;
        _resolveReplyPreviews();
      });
      _rememberPreview();
      _foldControls(); // cde-chat
    } catch (_) {
      // Silent: a failed poll just waits for the next tick.
    } finally {
      _polling = false;
    }
  }

  /// md2: the local bubbles a fetched page does not replace yet — still
  /// sending / failed, or SENT but the server copy is not in the page (the
  /// poll raced the send). A bubble whose server row (same id or same
  /// client_msg_id) IS in the page is dropped in that same frame: never
  /// missing, never twice.
  List<CircleMessage> _localEchoes(Set<String> serverIds, Set<String> cmids) {
    final waiting = _sentEchoes.awaiting(ids: serverIds, cmids: cmids);
    return _messages.where((m) {
      if (serverIds.contains(m.id) || cmids.contains(m.id)) return false;
      if (waiting.contains(m.id)) return true;
      return m.pending || m.status == 'failed';
    }).toList();
  }

  /// Shallow identity+state diff so a quiet poll never rebuilds the list for
  /// nothing (cheap: ids + the fields a bubble actually renders).
  bool _changed(List<CircleMessage> a, List<CircleMessage> b) {
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.id != y.id ||
          x.text != y.text ||
          x.status != y.status ||
          x.deleted != y.deleted ||
          x.edited != y.edited ||
          x.pinned != y.pinned ||
          x.starred != y.starred ||
          x.media?.ref != y.media?.ref ||
          x.reactions.length != y.reactions.length) {
        return true;
      }
    }
    return false;
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  String get _memberName => '${widget.member['name'] ?? ''}';
  int? get _memberId => widget.member['id'] as int?;

  /// The peer's published X25519 public key — LIVE (e2-keys): seeded from
  /// the member payload, then re-fetched from GET /circle/keys/peer/<id> on
  /// open, before each send and whenever key.published arrives.
  Uint8List? get _peerPub {
    final b64 = _peerB64;
    if (b64.isEmpty) return null;
    try {
      final k = base64Decode(b64);
      return k.isEmpty ? null : Uint8List.fromList(k);
    } catch (_) {
      return null;
    }
  }

  /// GET /circle/keys/peer/<id>. When the peer has no key yet the server
  /// queues a SILENT key_request push to them — nothing is shown here.
  Future<Uint8List?> _refreshPeerKey() async {
    final id = _memberId;
    if (id == null) return _peerPub;
    try {
      final k = await _api
          .getJson('/circle/keys/peer/$id')
          .timeout(const Duration(seconds: 6));
      final b64 = '${k['public_key'] ?? ''}';
      _adoptServerHistory(k['history']);
      if (b64.isNotEmpty) await _adoptPeerKey(b64);
    } catch (e) {
      KeyService.instance.log.add('peer key fetch failed ${e.runtimeType}');
    }
    return _peerPub;
  }

  void _adoptServerHistory(Object? hist) {
    if (hist is! List) return;
    final keys = <Uint8List>[];
    for (final h in hist) {
      if (h is! Map) continue;
      try {
        final k = base64Decode('${h['public_key'] ?? ''}');
        if (k.isNotEmpty) keys.add(Uint8List.fromList(k));
      } catch (_) {}
    }
    final was = _serverHist.length;
    _serverHist = keys;
    // newly learned old keys may decrypt what failed before
    if (keys.length != was && !_loading && mounted) {
      unawaited(_pollMessages());
    }
  }

  Future<void> _adoptPeerKey(String b64) async {
    final was = _peerB64;
    await PeerKeyBook.instance.observe(_chatKey, b64);
    final hist = await PeerKeyBook.instance.history(_chatKey);
    final notes = await PeerKeyBook.instance.notes(_chatKey);
    if (!mounted) return;
    setState(() {
      _peerB64 = b64;
      _peerHistory = [
        for (final h in hist)
          if (h != b64) ...[
            () {
              try {
                return Uint8List.fromList(base64Decode(h));
              } catch (_) {
                return Uint8List(0);
              }
            }()
          ]
      ].where((k) => k.isNotEmpty).toList();
      _keyNotes = notes;
    });
    // A new/changed key may decrypt what failed before — re-read.
    if (was != b64 && !_loading) unawaited(_pollMessages());
  }

  void _onKeyEvent(Map<String, dynamic> ev) {
    if ('${ev['chat'] ?? ''}' != _chatKey) return;
    unawaited(_refreshPeerKey());
    unawaited(_reloadQueued());
  }

  /// The outbox changed (queued, or flushed in this or another isolate).
  void _onOutbox() => unawaited(_reloadQueued());

  /// md1: the media outbox changed (queued / progress state / sent / failed).
  void _onMediaJobs() => unawaited(_onMediaJobsAsync());

  Future<void> _onMediaJobsAsync() async {
    final id = _memberId;
    if (id == null) return;
    final jobs = await MediaOutbox.instance.forChat('member', id);
    if (!mounted) return;
    final now = jobs.map((j) => j.id).toSet();
    setState(() {
      // md2: a job that finished becomes its final bubble in the SAME frame
      // (held until the poll brings the server copy) — no gap.
      final have = _messages.map((m) => m.id).toSet();
      for (final j in _mediaJobs) {
        if (now.contains(j.id)) continue;
        final s = MediaOutbox.instance.recentlySent[j.id];
        if (s == null || s.desc == null) continue; // cancelled: gone
        final lid = s.serverId.isNotEmpty ? s.serverId : j.id;
        if (have.contains(lid) || _serverCmids.contains(j.id)) continue;
        _sentEchoes.track(lid, j.id);
        // cde-chat: a finished photo THEME stays a system line
        final cc = s.control == null ? null : ChatControl.fromJson(s.control);
        if (cc != null) _ctrlCache[lid] = cc;
        _messages = [
          ..._messages,
          CircleMessage(
              id: lid,
              text: s.desc!.caption,
              mine: true,
              at: s.at ?? j.at,
              status: 'sent',
              replyToId: s.replyTo,
              contentType: s.desc!.kind,
              media: s.desc),
        ];
      }
      _mediaJobs = jobs;
    });
  }

  Future<void> _reloadQueued() async {
    final id = _memberId;
    if (id == null) return;
    final now = await Outbox.instance.forChat('member', id);
    if (!mounted) return;
    final nowIds = now.map((i) => i.id).toSet();
    final gone = _queued.where((i) => !nowIds.contains(i.id)).toList();
    setState(() {
      _queued = now;
      // A flushed item stays visible (sent) until the poll brings the
      // server copy — no flicker.
      if (gone.isNotEmpty) {
        final have = _messages.map((m) => m.id).toSet();
        for (final i in gone) {
          _sentEchoes.track(i.id, i.id); // md2: held until the server copy
        }
        _messages = [
          ..._messages,
          for (final i in gone)
            if (!have.contains(i.id))
              CircleMessage(
                  id: i.id,
                  text: i.text,
                  mine: true,
                  at: i.at,
                  status: 'sent',
                  replyToId: i.replyTo),
        ];
      }
    });
    if (gone.isNotEmpty) unawaited(_pollMessages());
  }

  Future<void> _load() async {
    // e2-keys: remember the snapshot key, then fetch the LIVE one in
    // parallel with the history (no extra wait before the first frame).
    final id = _memberId;
    if (_peerB64.isNotEmpty) {
      await PeerKeyBook.instance.observe(_chatKey, _peerB64);
    }
    final keyFetch = _refreshPeerKey();
    if (id != null) {
      _queued = await Outbox.instance.forChat('member', id);
      if (_queued.isNotEmpty) unawaited(Outbox.instance.kick(onlyChat: id));
    }
    _keyNotes = await PeerKeyBook.instance.notes(_chatKey);
    final peer = _peerPub;
    try {
      final r = await _api.getJson('/circle/$_memberId/messages?limit=$_pageSize');
      final raw = ((r['results'] ?? r['messages'] ?? []) as List).cast<Map<String, dynamic>>();
      final fetched = raw.map((e) => _decryptEnvelope(e, peer)).toList();
      // md2: a send that finished before this page was read keeps its bubble
      final cmids = fetchedClientIds(raw);
      final keep = _localEchoes(fetched.map((m) => m.id).toSet(), cmids);
      _serverCmids = cmids;
      _messages = [...fetched, ...keep];
      _applyEdge(r['edge']); // mr1
      _hasMore = r['has_more'] == true;
      // item 2: the first message I have not SEEN yet -> divider.
      final unseen = raw.where((e) => e['unseen'] == true).toList();
      _unreadAtOpen = unseen.length;
      _firstUnreadId = unseen.isEmpty ? null : '${unseen.first['id']}';
      _p3UnreadFrom ??= _firstUnreadId; // p3: "summarize unread" anchor
      _positioned = _unreadAtOpen <= 3;
      _resolveReplyPreviews();
      _seenPending = _messages.any((m) => !m.mine); // x2-ticks
      _maybeExpectTicks();
    } catch (_) {
      // Offline: keep any optimistic local echoes already shown, and SAY so
      // (seam audit: this used to be silent).
      if (mounted) _toast(_t.msgLoadFailed);
    }
    // Per-chat settings (disappearing is server-authoritative; favourite/theme
    // are opaque prefs). Failures just leave the honest defaults.
    try {
      final s = await _api.circleChatSettings(_memberId ?? 0);
      _disappearingSec = (s['disappearing_sec'] as int?) ?? 0;
      _favourite = s['favourite'] == true;
    } catch (_) {}
    if (mounted) {
      setState(() => _loading = false);
      if (!_positioned) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => unawaited(_placeAtDivider()));
      }
    }
    unawaited(_markSeen());
    unawaited(keyFetch);
    unawaited(_loadCalls());
    _rememberPreview();
    _foldControls(); // cde-chat
  }

  /// a1-circle: GET circle/calls?member=<id> -> the call events of this chat.
  Future<void> _loadCalls() async {
    final id = _memberId;
    if (id == null) return;
    try {
      final r = await _api.getJson('/circle/calls?member=$id');
      final next = parseCallEvents(r);
      if (!mounted) return;
      final sig = (List<CallEvent> l) =>
          l.map((e) => '${e.id}:${e.category}:${e.durationSec}').join(',');
      if (sig(next) != sig(_calls)) setState(() => _calls = next);
    } catch (_) {
      // Silent: the timeline simply shows no call chips this time.
    }
  }

  /// a1-circle: remember the newest message this phone could read, so the
  /// chat-list preview can show it even if it later can't be re-decrypted.
  void _rememberPreview() {
    for (final m in _messages.reversed) {
      if (m.pending || int.tryParse(m.id) == null) continue;
      if (m.deleted == 'everyone' || m.decryptFailed) return;
      if (m.contentType != 'text' || m.text.isEmpty) return;
      unawaited(PreviewCache.instance.put(
          _chatKey, m.id, isControlText(m.text) ? controlFallback(m.text) : m.text));
      return;
    }
  }

  /// Many unread: the first frame is laid out hidden, jumped (no
  /// animation) so the divider sits near the top, then shown — the user
  /// never sees a scroll. Few unread fit at the bottom, which is offset 0.
  Future<void> _placeAtDivider() async {
    try {
      for (var i = 0; i < 40 && mounted; i++) {
        final ctx = _dividerKey.currentContext;
        if (ctx != null) {
          final ro = ctx.findRenderObject();
          if (ro != null) {
            final vp = RenderAbstractViewport.of(ro);
            final target = vp.getOffsetToReveal(ro, 0.92).offset;
            final pos = _scroll.position;
            _scroll.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
          }
          break;
        }
        if (!_scroll.hasClients) break;
        final pos = _scroll.position;
        if (pos.pixels >= pos.maxScrollExtent) break;
        _scroll.jumpTo((pos.pixels + pos.viewportDimension)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent));
        await WidgetsBinding.instance.endOfFrame;
      }
    } catch (_) {}
    if (mounted) setState(() => _positioned = true);
  }

  /// Older history on scroll-up (reversed list: the top is maxScrollExtent).
  /// Appending at the END of a reversed list keeps the visible messages
  /// exactly where they are — no flicker, no jump.
  void _onScroll() {
    if (!_scroll.hasClients || _loadingOlder || !_hasMore) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) unawaited(_loadOlder());
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMore) return;
    final oldest = _messages
        .map((m) => int.tryParse(m.id))
        .whereType<int>()
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (oldest == null) return;
    setState(() => _loadingOlder = true);
    try {
      final r = await _api.getJson(
          '/circle/$_memberId/messages?limit=$_pageSize&before=$oldest');
      final raw = ((r['results'] ?? r['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      final peer = _peerPub;
      final have = _messages.map((m) => m.id).toSet();
      final older = raw
          .map((e) => _decryptEnvelope(e, peer))
          .where((m) => !have.contains(m.id))
          .toList();
      if (!mounted) return;
      setState(() {
        _messages = [...older, ..._messages];
        _hasMore = r['has_more'] == true && older.isNotEmpty;
        _resolveReplyPreviews();
      });
    } catch (_) {
      // Silent: the next scroll-up retries.
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _onRt() {
    if (mounted) setState(() {});
  }

  /// c3-msg: the chat is open and visible → server-side seen (receipts +
  /// read_by: the badge clears on every device, the sender gets blue ✓✓
  /// unless read receipts are off). Badges/notification clear locally too.
  Future<void> _markSeen() async {
    final id = _memberId;
    if (id == null || _seenInFlight) return;
    // x2-ticks: blue ✓✓ only when the chat is open AND visible.
    if (!_visibleNow) {
      _seenPending = true;
      return;
    }
    _seenPending = false;
    _seenInFlight = true;
    UnreadStore.instance.clear(_chatKey);
    try {
      await _api.c3ChatSeen('member', id);
      // b2-badges: the home My Circle badge re-fetches from the server.
      BadgesBus.instance.poke();
    } catch (_) {
    } finally {
      _seenInFlight = false;
    }
  }

  Future<void> _loadBubblePref() async {
    final id = _memberId;
    if (id == null) return;
    if (!await MsgNative.bubblesSupported()) return;
    final on = await MsgPrefs.isBubbleChat('member', id);
    if (mounted) setState(() => _bubbleOn = on);
  }

  Future<void> _toggleBubble() async {
    final id = _memberId;
    if (id == null || _bubbleOn == null) return;
    final next = !_bubbleOn!;
    await MsgPrefs.setBubbleChat('member', id, next);
    if (!next) unawaited(MsgNative.removeBubble('member', id));
    if (!mounted) return;
    setState(() => _bubbleOn = next);
    _toast(next ? _t.c3BubbleOnDone : _t.c3BubbleOffDone);
    if (next && await MsgNative.bubblesAllowed() == false && mounted) {
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_t.c3BubbleAllowTitle),
          content: Text(_t.c3BubbleAllowBody),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(_t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(_t.c3OpenSettings)),
          ],
        ),
      );
      if (open == true) await MsgNative.openBubbleSettings();
    }
  }

  /// Tap a quote → scroll to the original and flash it.
  Future<void> _jumpTo(String? id) async {
    if (id == null) return;
    final list = _visible;
    final idx = list.indexWhere((m) => m.id == id);
    if (idx < 0) {
      _toast(_t.c3QuoteGone);
      return;
    }
    final key = _msgKeys[id];
    if (key?.currentContext == null && _scroll.hasClients && list.length > 1) {
      // reversed list: index 0 (offset 0) is the NEWEST message
      final frac = (list.length - 1 - idx) / (list.length - 1);
      _scroll.jumpTo(frac * _scroll.position.maxScrollExtent);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    final ctx = _msgKeys[id]?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx,
          alignment: 0.4, duration: const Duration(milliseconds: 250));
    }
    if (!mounted) return;
    setState(() => _highlightId = id);
    _hlTimer?.cancel();
    _hlTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  void _startReply(CircleMessage m) {
    if (m.deleted == 'everyone') return;
    setState(() {
      _replyTo = m;
      _editing = null;
    });
  }

  /// Last five messages the user DECRYPTED on THIS device (newest last), used
  /// by Report. The server holds ciphertext only and cannot rebuild these.
  List<Map<String, dynamic>> _lastFiveDecrypted() {
    final usable = _messages
        .where((m) => m.deleted != 'everyone' && !m.decryptFailed && m.text.isNotEmpty)
        .toList();
    final slice = usable.length <= 5 ? usable : usable.sublist(usable.length - 5);
    return slice
        .map((m) => <String, dynamic>{
              'id': m.id,
              'text': m.text,
              'mine': m.mine,
              'at': m.at.toUtc().toIso8601String(),
            })
        .toList();
  }

  /// Resolve each reply's quoted preview from the LOCAL decrypted cache (never
  /// from the server — the server has no plaintext to quote).
  void _resolveReplyPreviews() {
    final byId = {for (final m in _messages) m.id: m};
    _messages = _messages.map((m) {
      if (m.replyToId == null || m.replyPreview != null) return m;
      final src = byId[m.replyToId];
      if (src == null) return m;
      return CircleMessage(
        id: m.id,
        text: m.text,
        mine: m.mine,
        at: m.at,
        status: m.status,
        decryptFailed: m.decryptFailed,
        replyToId: m.replyToId,
        replyPreview: src.text.isNotEmpty
            ? src.text
            : (src.media != null ? md1KindLabel(_t, src.media!) : null),
        reactions: m.reactions,
        edited: m.edited,
        deleted: m.deleted,
        forwarded: m.forwarded,
        forwardHops: m.forwardHops,
        starred: m.starred,
        pinned: m.pinned,
        contentType: m.contentType,
        mediaCaption: m.mediaCaption,
        mediaGated: m.mediaGated,
        media: m.media,
        mediaJob: m.mediaJob,
      );
    }).toList();
  }

  /// Turn a stored ciphertext envelope into a displayable (decrypted) bubble.
  /// Decryption happens ON-DEVICE; failure degrades gracefully to a "couldn't
  /// decrypt" bubble rather than ever showing ciphertext as text.
  CircleMessage _decryptEnvelope(Map<String, dynamic> env, Uint8List? peerPub) {
    final mine = (env['sender_id'] == context.read<AppState>().user?.id) || (env['mine'] == true);
    final at = DateTime.tryParse('${env['created_at'] ?? ''}')?.toLocal() ?? DateTime.now();
    final status = '${env['status'] ?? 'sent'}';
    final deleted = '${env['deleted'] ?? ''}';
    final contentType = '${env['content_type'] ?? 'text'}';
    final reactions = _reactionCounts(env['reactions']);
    var text = '';
    var failed = false;

    MediaDescriptor? media;
    final isMedia = kMd1Kinds.contains(contentType);
    if (deleted == 'everyone') {
      // Nothing to decrypt — the ciphertext was tombstoned server-side.
    } else if (contentType == 'text' || isMedia) {
      try {
        if (peerPub == null && _peerHistory.isEmpty && _serverHist.isEmpty) {
          failed = true;
        } else {
          final usePub = peerPub ??
              (_peerHistory.isNotEmpty ? _peerHistory.last : _serverHist.first);
          final ct = Ciphertext(
            scheme: '${env['scheme'] ?? _e2e.scheme}',
            ciphertextB64: '${env['ciphertext'] ?? ''}',
            nonceB64: '${env['nonce'] ?? ''}',
            senderKeyId: '${env['sender_key_id'] ?? ''}',
          );
          var pt = _e2e.decrypt(self: widget.identity, senderPublicKey: usePub, ct: ct);
          // e2-keys: history from before the peer's key change still
          // decrypts with the key it was sent under.
          for (final old in [..._peerHistory, ..._serverHist]) {
            if (pt != null) break;
            try {
              pt = _e2e.decrypt(self: widget.identity, senderPublicKey: old, ct: ct);
            } catch (_) {}
          }
          if (pt == null) {
            failed = true;
          } else if (isMedia) {
            // md1: the plaintext is the media descriptor (file key, sha…).
            media = MediaDescriptor.tryParse(pt);
            if (media == null) {
              failed = true;
            } else {
              text = media.caption;
              // cde-chat: a photo THEME (the descriptor carries `cc1`)
              final cc = controlInDescriptor(pt);
              if (cc != null) _ctrlCache['${env['id'] ?? ''}'] = cc;
            }
          } else {
            text = pt;
          }
        }
      } catch (_) {
        failed = true;
      }
    }

    return CircleMessage(
      id: '${env['id'] ?? ''}',
      text: text,
      mine: mine,
      at: at,
      status: status,
      decryptFailed: failed,
      replyToId: env['reply_to'] == null ? null : '${env['reply_to']}',
      reactions: reactions,
      edited: env['edited_at'] != null,
      deleted: deleted,
      forwarded: env['forwarded'] == true,
      forwardHops: (env['forward_hops'] as int?) ?? 0,
      starred: ((env['starred_by'] as List?) ?? const []).contains(context.read<AppState>().user?.id),
      pinned: env['pinned'] == true,
      contentType: contentType,
      // md1: photo / voice / document really work; other kinds stay gated
      mediaGated: contentType != 'text' && !isMedia,
      media: media,
    );
  }

  Map<String, int> _reactionCounts(dynamic raw) {
    if (raw is! Map) return const {};
    final counts = <String, int>{};
    raw.forEach((_, emoji) {
      final e = '$emoji';
      counts[e] = (counts[e] ?? 0) + 1;
    });
    return counts;
  }

  // -------------------------------------------------------------------------
  // Send (text), with reply + link-preview detection on the SENDER device.
  // -------------------------------------------------------------------------
  Future<void> _send() async {
    final plain = _input.text.trim();
    // db1: Send on an empty box opens the keyboard instead of doing nothing.
    if (plain.isEmpty && !_sending) {
      _inputFocus.requestFocus();
      return;
    }
    if (plain.isEmpty || _sending) return;
    if (_memberId != null) _rt.typing('member', _memberId!, 'stop');

    // p3: "@Assisto …" is a command to Assisto, never sent to the peer.
    final p3i = _editing == null ? parseAssisto(plain) : null;
    if (p3i != null) {
      setState(() => _input.clear());
      unawaited(_openAssisto(intent: p3i));
      return;
    }

    // Edit path: replace an existing message within the window.
    if (_editing != null) {
      await _applyEdit(_editing!, plain);
      return;
    }

    // e2-keys: the sender is NEVER blocked by encryption (owner PRODUCT
    // RULE). The bubble appears at once; the peer key is re-fetched before
    // the send; with no key yet the message waits in the persistent outbox
    // (clock icon) and goes out by itself once the peer's phone publishes.
    final clientMsgId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final replyId = _replyTo?.id;
    final replyPrev = _replyTo?.text;
    final sentAt = DateTime.now();

    // Link preview is built HERE (sender device). We detect the URL locally;
    // the real title/thumbnail fetch + encryption is the integrator's device
    // task — the server never fetches a URL.
    final firstUrl = _firstUrl(plain);

    // Optimistic local echo (decrypted locally — never shown as ciphertext),
    // marked pending until the relay confirms.
    final echo = CircleMessage(
      id: clientMsgId,
      text: plain,
      mine: true,
      at: sentAt,
      status: 'sent',
      pending: true,
      replyToId: replyId,
      replyPreview: (replyPrev ?? '').isEmpty ? null : replyPrev,
    );
    setState(() {
      _sending = true;
      _messages = [..._messages, echo];
      _input.clear();
      _replyTo = null;
      _unreadAtOpen = 0; // WhatsApp: replying clears the unread divider
      _firstUnreadId = null;
    });
    _scrollToEnd();

    final peer = await _refreshPeerKey();
    if (!mounted) return;
    if (peer == null) {
      final id = _memberId;
      if (id != null) {
        final item = OutboxItem(
            id: clientMsgId,
            chatId: id,
            text: plain,
            at: sentAt,
            replyTo: replyId);
        await Outbox.instance.add(item);
        KeyService.instance.log.add('queued in outbox chat=$_chatKey');
        if (!mounted) return;
        setState(() {
          _messages = _messages.where((m) => m.id != clientMsgId).toList();
          if (!_queued.any((q) => q.id == clientMsgId)) {
            _queued = [..._queued, item];
          }
          _sending = false;
        });
        unawaited(Outbox.instance.kick(onlyChat: id));
      } else if (mounted) {
        setState(() => _sending = false);
      }
      return;
    }
    final ct = _e2e.encrypt(self: widget.identity, recipientPublicKey: peer, plaintext: plain);

    try {
      final sent = await _api.postJson('/circle/$_memberId/messages', {
        'content_type': 'text',
        'client_msg_id': clientMsgId,
        if (replyId != null) 'reply_to': replyId,
        if (firstUrl != null) 'has_link': true, // integrator attaches encrypted preview
        ...ct.toEnvelopeFields(),
      });
      // Mark echo confirmed (no longer pending). x2-ticks: re-key it to the
      // SERVER id so live receipt.update events (by id) reach it at once.
      final sid = '${sent['id'] ?? ''}';
      // md2: the bubble stays until the poll holds its server copy
      _sentEchoes.track(sid.isEmpty ? clientMsgId : sid, clientMsgId);
      if (mounted) {
        setState(() {
          _messages = _messages.map((m) => m.id == clientMsgId
              ? (sid.isEmpty
                  ? m.copyWith(pending: false)
                  : CircleMessage(
                      id: sid, text: m.text, mine: true, at: m.at,
                      status: m.status, replyToId: m.replyToId,
                      replyPreview: m.replyPreview))
              : m).toList();
        });
      }
      ReceiptBus.instance.expect();
      if (mounted) _countRequestSend(); // mr1: pre-accept budget
    } catch (e) {
      // c3-msg: honest failure — the bubble shows a red "!" (not a clock that
      // never resolves); long-press it to resend.
      if (mounted) {
        setState(() {
          _messages = _messages
              .map((m) => m.id == clientMsgId
                  ? m.copyWith(pending: false, status: 'failed')
                  : m)
              .toList();
        });
        // mr1: a request refused by the server says why (limit reached /
        // they only take messages from their circle) — never a vague error.
        if (_reqOut && e is ApiException && e.status == 403) {
          setState(() => _reqInfo = {...?_reqInfo, 'can_send': false});
          _toast(e.message.isNotEmpty ? e.message : _t.c3SendFailed);
        } else {
          _toast(_t.c3SendFailed);
        }
      }
    }
    if (mounted) setState(() => _sending = false);
  }

  // -------------------------------------------------------------------------
  // p3: @Assisto + cards + scam warning (.phaseB/P3_DESIGN.md)
  // -------------------------------------------------------------------------
  String? _p3UnreadFrom;
  bool _p3HintShown = false;
  final Map<String, AssistoCard?> _p3Cards = {};
  final Map<String, ScamVerdict> _p3Scam = {};

  String get _p3MyName {
    final n = (context.read<AppState>().user?.name ?? '').trim();
    return n.isEmpty ? _t.p3You : n;
  }

  AssistoCard? _p3Card(CircleMessage m) {
    if (m.contentType != 'text' || m.decryptFailed || m.deleted == 'everyone') {
      return null;
    }
    final k = '${m.id}|${m.text.length}';
    return _p3Cards.putIfAbsent(k, () => isCardText(m.text) ? decodeCard(m.text) : null);
  }

  bool _p3Hidden(CircleMessage m) => _p3Card(m)?.hidden ?? false;

  CardLedger get _p3Ledger => CardLedger.fold([
        for (final m in _messages)
          if (_p3Card(m) case final c?) CardEvent(c, m.mine ? '' : _memberName, m.mine, m.at),
      ]);

  ScamVerdict _scamOf(CircleMessage m) {
    if (m.mine || m.contentType != 'text' || m.text.isEmpty || m.decryptFailed ||
        isControlText(m.text)) {
      return ScamVerdict.none;
    }
    // a chat I have never replied in counts as a NEW contact
    final fresh = !_messages.any((x) => x.mine);
    return _p3Scam.putIfAbsent('${m.id}|$fresh',
        () => checkScam(m.text, newContact: fresh));
  }

  Map<String, String> _p3Line(CircleMessage m) => {
        'from': m.mine ? _p3MyName : _memberName,
        'text': cardFallback(m.text),
      };

  bool _p3Readable(CircleMessage m) =>
      m.contentType == 'text' && !m.decryptFailed && m.text.isNotEmpty &&
      m.deleted != 'everyone' && _p3Card(m) == null && !isControlText(m.text);

  AssistoChatPort get _p3Port => AssistoChatPort(
        isGroup: false,
        chatName: _memberName,
        myName: _p3MyName,
        memberNames: [_memberName],
        unread: () {
          final from = _p3UnreadFrom;
          if (from == null) return const [];
          final i = _messages.indexWhere((m) => m.id == from);
          if (i < 0) return const [];
          return [
            for (final m in _messages.skip(i))
              if (!m.mine && _p3Readable(m)) _p3Line(m),
          ];
        },
        recent: () {
          final r = [for (final m in _messages) if (_p3Readable(m)) _p3Line(m)];
          return r.length > 30 ? r.sublist(r.length - 30) : r;
        },
        draft: () => _input.text,
        setDraft: (v) => setState(() {
          _input.text = v;
          _input.selection = TextSelection.collapsed(offset: v.length);
        }),
        lastIncoming: () {
          for (final m in _messages.reversed) {
            if (!m.mine && _p3Readable(m)) return m.text;
          }
          return '';
        },
        send: _sendCard,
      );

  Future<void> _openAssisto({AssistoIntent? intent}) async {
    if (_reqIn) return; // a request I have not accepted is read-only
    await showAssistoMenu(context, _p3Port, intent: intent);
  }

  /// Send an Assisto card / event: E2E-encrypted to the peer exactly like a
  /// text message (the plaintext never reaches the server). Keeps the draft.
  Future<bool> _sendCard(String plaintext) async {
    final id = _memberId;
    if (id == null) return false;
    final clientMsgId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final sentAt = DateTime.now();
    final echo = CircleMessage(
        id: clientMsgId, text: plaintext, mine: true, at: sentAt,
        status: 'sent', pending: true);
    setState(() => _messages = [..._messages, echo]);
    _scrollToEnd();
    final peer = await _refreshPeerKey();
    if (!mounted) return false;
    if (peer == null) {
      final item = OutboxItem(id: clientMsgId, chatId: id, text: plaintext, at: sentAt);
      await Outbox.instance.add(item);
      if (!mounted) return true;
      setState(() {
        _messages = _messages.where((m) => m.id != clientMsgId).toList();
        if (!_queued.any((q) => q.id == clientMsgId)) _queued = [..._queued, item];
      });
      unawaited(Outbox.instance.kick(onlyChat: id));
      return true;
    }
    final ct = _e2e.encrypt(self: widget.identity, recipientPublicKey: peer, plaintext: plaintext);
    try {
      final sent = await _api.postJson('/circle/$id/messages', {
        'content_type': 'text',
        'client_msg_id': clientMsgId,
        ...ct.toEnvelopeFields(),
      });
      final sid = '${sent['id'] ?? ''}';
      _sentEchoes.track(sid.isEmpty ? clientMsgId : sid, clientMsgId);
      if (mounted) {
        setState(() {
          _messages = _messages.map((m) => m.id == clientMsgId
              ? (sid.isEmpty
                  ? m.copyWith(pending: false)
                  : CircleMessage(id: sid, text: m.text, mine: true, at: m.at, status: m.status))
              : m).toList();
        });
      }
      ReceiptBus.instance.expect();
      return true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _messages = _messages
              .map((m) => m.id == clientMsgId ? m.copyWith(pending: false, status: 'failed') : m)
              .toList();
        });
      }
      return false;
    }
  }

  String? _firstUrl(String text) {
    final m = RegExp(r'https?://[^\s<>"]+', caseSensitive: false).firstMatch(text);
    return m?.group(0);
  }

  // -------------------------------------------------------------------------
  // Message actions (long-press)
  // -------------------------------------------------------------------------
  Future<void> _onLongPress(CircleMessage m) async {
    if (m.deleted == 'everyone') return;
    if (m.mine && m.status == 'failed') {
      // resend the failed message
      setState(() => _messages = _messages.where((x) => x.id != m.id).toList());
      _input.text = m.text;
      await _send();
      return;
    }
    final pinnedCount = _messages.where((x) => x.pinned).length;
    final canEdit = m.mine && m.contentType == 'text' && DateTime.now().difference(m.at).inMinutes < _kEditWindowMin;
    final canDeleteEveryone = m.mine && DateTime.now().difference(m.at).inMinutes < _kDeleteEveryoneWindowMin;

    final action = await showCircleMessageActions(
      context,
      reactions: _decor.themeDef?.reactions, // cde-chat
      mine: m.mine,
      canEdit: canEdit,
      isStarred: m.starred,
      isPinned: m.pinned,
      canDeleteEveryone: canDeleteEveryone,
      onReact: (emoji) => _react(m, emoji),
      showInfo: m.mine && !m.pending,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case CircleMsgAction.info:
        await showMessageInfoSheet(context, () => _api.c3MessageInfo(m.id));
        break;
      case CircleMsgAction.moreReactions:
        final e = await showMoreReactions(context);
        if (e != null && mounted) await _react(m, e);
        break;
      case CircleMsgAction.reply:
        setState(() {
          _replyTo = m;
          _editing = null;
        });
        break;
      case CircleMsgAction.react:
        break;
      case CircleMsgAction.copy:
        await Clipboard.setData(ClipboardData(text: cardFallback(m.text)));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t.circleCopied)));
        }
        break;
      case CircleMsgAction.forward:
        _startForward(m);
        break;
      case CircleMsgAction.star:
        await _toggleStar(m);
        break;
      case CircleMsgAction.pin:
        await _togglePin(m, pinnedCount);
        break;
      case CircleMsgAction.edit:
        setState(() {
          _editing = m;
          _replyTo = null;
          _input.text = m.text;
          _input.selection = TextSelection.collapsed(offset: m.text.length);
        });
        break;
      case CircleMsgAction.deleteMe:
        await _confirmAndDelete(m, 'me');
        break;
      case CircleMsgAction.deleteEveryone:
        await _confirmAndDelete(m, 'everyone');
        break;
    }
  }

  /// Confirm gate for a single-message delete (reviewer-pass #86: every
  /// destructive action confirms). 'everyone' is the stronger, irreversible
  /// tombstone — it uses the danger-coloured confirm + its own copy.
  Future<void> _confirmAndDelete(CircleMessage m, String scope) async {
    final everyone = scope == 'everyone';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(everyone
            ? _t.circleActionDeleteEveryone
            : _t.circleActionDeleteMe),
        content: Text(everyone
            ? _t.msgrMsgDeleteEveryoneConfirm
            : _t.msgrMsgDeleteMeConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
            style: everyone
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_t.delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await _delete(m, scope);
    if (mounted && done) {
      _toast(everyone ? _t.msgrMsgDeletedEveryone : _t.msgrMsgDeletedMe);
    }
  }

  Future<void> _react(CircleMessage m, String emoji) async {
    final me = context.read<AppState>().user?.id;
    final next = Map<String, int>.from(m.reactions);
    next[emoji] = (next[emoji] ?? 0) + 1;
    final before = _messages;
    setState(() {
      _messages = _messages.map((x) => x.id == m.id ? x.copyWith(reactions: next) : x).toList();
    });
    try {
      await _api.postJson('/circle/messages/${m.id}/react', {'emoji': emoji, 'member_id': me});
    } catch (_) {
      _undo(before); // m3-circle: never silent
    }
  }

  Future<void> _toggleStar(CircleMessage m) async {
    final before = _messages;
    setState(() {
      _messages = _messages.map((x) => x.id == m.id ? x.copyWith(starred: !x.starred) : x).toList();
    });
    try {
      await _api.postJson('/circle/messages/${m.id}/star', {'starred': !m.starred});
    } catch (_) {
      _undo(before);
    }
  }

  Future<void> _togglePin(CircleMessage m, int pinnedCount) async {
    if (!m.pinned && pinnedCount >= _kPinCap) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t.circlePinLimit)));
      return;
    }
    final before = _messages;
    setState(() {
      _messages = _messages.map((x) => x.id == m.id ? x.copyWith(pinned: !x.pinned) : x).toList();
    });
    try {
      await _api.postJson('/circle/messages/${m.id}/pin', {'pinned': !m.pinned});
    } catch (_) {
      _undo(before);
    }
  }

  Future<bool> _delete(CircleMessage m, String scope) async {
    final before = _messages;
    setState(() {
      _messages = scope == 'me'
          ? _messages.where((x) => x.id != m.id).toList()
          : _messages.map((x) => x.id == m.id ? x.copyWith(deleted: 'everyone', text: '') : x).toList();
    });
    try {
      await _api.postJson('/circle/messages/${m.id}/delete', {'scope': scope});
      return true;
    } catch (_) {
      _undo(before);
      return false;
    }
  }

  /// m3-circle: an optimistic change the server refused/never got is rolled
  /// back and the user is told (these used to fail silently).
  void _undo(List<CircleMessage> before) {
    if (!mounted) return;
    setState(() => _messages = before);
    _toast(_t.grpActionFailed);
  }

  Future<void> _applyEdit(CircleMessage m, String newText) async {
    final peer = _peerPub ?? await _refreshPeerKey();
    final before = _messages;
    setState(() {
      _messages = _messages.map((x) => x.id == m.id ? x.copyWith(text: newText, edited: true) : x).toList();
      _editing = null;
      _input.clear();
    });
    if (peer == null) {
      _undo(before); // can't encrypt without the peer key -> say so
      return;
    }
    final ct = _e2e.encrypt(self: widget.identity, recipientPublicKey: peer, plaintext: newText);
    try {
      await _api.postJson('/circle/messages/${m.id}/edit', {...ct.toEnvelopeFields()});
    } catch (_) {
      _undo(before);
    }
  }

  // -------------------------------------------------------------------------
  // Forward
  // -------------------------------------------------------------------------
  Future<void> _startForward(CircleMessage m) async {
    // c3-msg + md2: pick ANY My Circle member OR group (WhatsApp forward);
    // the text / media descriptor is sealed again for the new recipients.
    List<ForwardTarget> targets = const [];
    try {
      targets = await loadForwardTargets(_api);
    } catch (e) {
      if (mounted) showActionFailed(context, 'md2_fwd_targets', e);
    }
    if (!mounted) return;
    if (targets.isNotEmpty) {
      final pick = await pickForwardTarget(context, targets);
      if (pick == null || !mounted) return;
      if (pick.isGroup || pick.id != _memberId) {
        await _forwardTo(m, pick);
        return;
      }
      _doForwardInto(m);
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.circleActionForward),
        content: Text(_t.circleForwardConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t.close)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t.circleActionForward)),
        ],
      ),
    );
    if (confirm == true) _doForwardInto(m);
  }

  /// md2: a forward to another chat (member or group). Media reuses the
  /// same blob + key (no re-upload).
  Future<void> _forwardTo(CircleMessage m, ForwardTarget target) async {
    final payload = ForwardPayload(
        plaintext: m.media?.encode() ?? m.text,
        contentType: m.media?.kind ?? 'text',
        blobRef: m.media?.ref,
        hops: m.forwardHops + 1);
    try {
      if (target.isGroup) {
        await forwardToGroup(_api, widget.identity, target.id, payload, e2e: _e2e);
      } else {
        await forwardToMember(_api, widget.identity, target, payload, e2e: _e2e);
      }
      if (mounted) _toast(_t.c3Forwarded(target.name));
    } catch (e) {
      if (mounted) showActionFailed(context, 'md2_forward', e);
    }
  }

  Future<void> _doForwardInto(CircleMessage m) async {
    final peer = _peerPub ?? await _refreshPeerKey();
    if (peer == null) {
      final id = _memberId;
      if (id == null) return;
      final item = OutboxItem(
          id: 'local-${DateTime.now().microsecondsSinceEpoch}',
          chatId: id,
          text: m.media?.encode() ?? m.text,
          at: DateTime.now(),
          forwarded: true,
          forwardHops: m.forwardHops + 1,
          contentType: m.media?.kind ?? 'text',
          blobRef: m.media?.ref);
      await Outbox.instance.add(item);
      if (mounted) setState(() => _queued = [..._queued, item]);
      unawaited(Outbox.instance.kick(onlyChat: id));
      return;
    }
    final ct = _e2e.encrypt(
        self: widget.identity,
        recipientPublicKey: peer,
        plaintext: m.media?.encode() ?? m.text);
    final clientMsgId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final echo = CircleMessage(
      id: clientMsgId,
      text: m.text,
      mine: true,
      at: DateTime.now(),
      status: 'sent',
      pending: true,
      forwarded: true,
      forwardHops: m.forwardHops + 1,
      contentType: m.media?.kind ?? 'text',
      media: m.media,
    );
    setState(() => _messages = [..._messages, echo]);
    _scrollToEnd();
    try {
      await _api.postJson('/circle/$_memberId/messages', {
        'content_type': m.media?.kind ?? 'text',
        if (m.media != null) 'blob_ref': m.media!.ref,
        'client_msg_id': clientMsgId,
        'forwarded': true,
        'forward_hops': m.forwardHops + 1,
        ...ct.toEnvelopeFields(),
      });
      _sentEchoes.track(clientMsgId, clientMsgId); // md2
      setState(() {
        _messages = _messages.map((x) => x.id == clientMsgId ? x.copyWith(pending: false) : x).toList();
      });
    } catch (_) {
      if (mounted) {
        setState(() => _messages = _messages.where((x) => x.id != clientMsgId).toList());
        _toast(_t.grpActionFailed);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Media attach. mr1 NO SHOWPIECES: the "+" button only exists when at least
  // one kind REALLY sends (circleAttachKinds); today that list is empty
  // (encrypted media storage not built — .phaseB/proposals/mr1-media.md), so
  // the button is hidden instead of answering "available when encrypted
  // storage is enabled". The storage build wires each kind's picker here.
  // -------------------------------------------------------------------------
  // md1: photo / voice / document really send (E2E, see messaging/media/).
  // A message request carries text only until it is accepted (server rule).
  bool get _canAttach =>
      circleAttachKinds().isNotEmpty && _edgeState == 'accepted' && _memberId != null;

  Future<void> _attach() async {
    final kind = await showCircleAttachSheet(context);
    if (kind == null || !mounted) return;
    final id = _memberId;
    if (id == null) return;
    final draft = await pickMediaDraft(context, _api, kind);
    if (draft == null || !mounted) return;
    final job = await confirmAndQueueMedia(context, draft,
        chatKind: 'member', chatId: id, replyTo: _replyTo?.id);
    if (job == null || !mounted) return;
    setState(() {
      _mediaJobs = [..._mediaJobs.where((j) => j.id != job.id), job];
      _replyTo = null;
      _unreadAtOpen = 0;
      _firstUnreadId = null;
    });
    _scrollToEnd();
  }

  /// md1: open a decrypted photo (viewer) or document (open / save / share).
  void _openFile(File f, MediaDescriptor d) {
    if (d.kind == 'photo') {
      unawaited(openPhotoViewer(context, f, d));
    } else if (d.kind == 'document') {
      unawaited(openDocumentSheet(context, f, d));
    }
  }

  String _previewOf(CircleMessage m) =>
      m.text.isNotEmpty ? m.text : (m.media != null ? md1KindLabel(_t, m.media!) : m.text);

  void _openMedia(CircleMessage m) {
    // When storage is enabled, decrypted bytes flow here. For now, show the
    // gated placeholder viewer so the full-screen path exists end-to-end.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleMediaViewer(
        items: [MediaViewerItem(id: m.id, caption: m.mediaCaption ?? '', gated: true)],
      ),
    ));
  }

  /// Reversed list: the latest message is offset 0. Only my OWN send
  /// animates back down (if I had scrolled up); opening never scrolls.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _scroll.position.pixels > 0) {
        _scroll.animateTo(0, duration: Motion.base, curve: Curves.easeOut);
      }
    });
  }

  // -------------------------------------------------------------------------
  // In-chat search (client-side over decrypted text)
  // -------------------------------------------------------------------------
  List<CircleMessage> get _visible {
    if (!_searching || _searchQuery.trim().isEmpty) return _messages;
    final terms = _searchQuery.toLowerCase().trim().split(RegExp(r'\s+'));
    return _messages.where((m) {
      if (m.deleted == 'everyone') return false;
      final hay = m.text.toLowerCase();
      return terms.every((tk) => hay.contains(tk));
    }).toList();
  }

  // -------------------------------------------------------------------------
  // Top-bar: calls (video is Premium-gated SERVER-SIDE — caller pays)
  // -------------------------------------------------------------------------
  Future<void> _placeCall(String kind) async {
    // x1-calls ROOT CAUSE FIX: this used to POST /circle/<id>/call as a
    // "gate check" and then the call screen POSTed it AGAIN — two live
    // records 0–1 s apart; the server ended the second as "busy" (caller saw
    // Busy, callee got Missed rows) while the callee answered the first one
    // nobody was on (stuck "Connecting…"). The call screen's ONE placement
    // runs the same server gate (can_place_call) and shows the upgrade
    // screen for a free video caller, so we just open it — once.
    if (_callOpening) return;
    _callOpening = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CircleCallScreen(
            member: {...widget.member, 'nickname': _decor.state.nick('peer')}, // cde-chat
            kind: kind),
      ));
    } finally {
      _callOpening = false;
    }
    unawaited(_loadCalls()); // a1-circle: the call appears in the chat
  }

  /// A second tap while the call screen is opening never stacks a 2nd call.
  bool _callOpening = false;

  // -------------------------------------------------------------------------
  // Chat ⋮ menu dispatch
  // -------------------------------------------------------------------------
  Future<void> _openChatMenu() async {
    final action = await showChatMenu(context,
        isFavourite: _favourite, bubbleOn: _bubbleOn);
    if (action == null || !mounted) return;
    switch (action) {
      case ChatMenuAction.bubble:
        await _toggleBubble();
        break;
      case ChatMenuAction.contactInfo:
        _openContactInfo();
        break;
      case ChatMenuAction.search:
        setState(() => _searching = true);
        break;
      case ChatMenuAction.selectMessages:
        setState(() {
          _selecting = true;
          _selected.clear();
        });
        break;
      case ChatMenuAction.mute:
        await _muteFlow();
        break;
      case ChatMenuAction.disappearing:
        await _disappearingFlow();
        break;
      case ChatMenuAction.chatTheme:
        await _chatThemeFlow();
        break;
      case ChatMenuAction.nicknames:
        await _nicknamesFlow();
        break;
      case ChatMenuAction.addFavourite:
        await _toggleFavourite();
        break;
      case ChatMenuAction.addToList:
        await _addToListFlow();
        break;
      case ChatMenuAction.exportChat:
        await _exportChat();
        break;
      case ChatMenuAction.closeChat:
        await _closeChat();
        break;
      case ChatMenuAction.sendCallLink:
        await _sendCallLink();
        break;
      case ChatMenuAction.scheduleCall:
        await _scheduleCall();
        break;
      case ChatMenuAction.newGroupCall:
        await _newGroupCall();
        break;
      case ChatMenuAction.summarise: // p3: real @Assisto actions
        await _openAssisto(intent: const AssistoIntent(AssistoAction.summarize));
        break;
      case ChatMenuAction.makeReminder:
        await _openAssisto(intent: const AssistoIntent(AssistoAction.remind));
        break;
      case ChatMenuAction.translate:
        await _openAssisto(intent: const AssistoIntent(AssistoAction.translate));
        break;
      case ChatMenuAction.report:
        await _reportFlow();
        break;
      case ChatMenuAction.block:
        await _blockFlow();
        break;
      case ChatMenuAction.clearChat:
        await _clearChatFlow();
        break;
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  /// Honest failure: the server's own reason, else "couldn't do that".
  void _fail(Object e) => _toast(e is ApiException && e.message.isNotEmpty
      ? e.message
      : _t.grpActionFailed);

  void _openContactInfo() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ContactInfoScreen(
        member: widget.member,
        decryptedLastFive: _lastFiveDecrypted,
      ),
    )).then((_) => _load());
  }

  // ---- Mute ---------------------------------------------------------------
  Future<void> _muteFlow() async {
    final d = await showMutePicker(context);
    if (d == null || !mounted) return;
    final until = d == Duration.zero
        ? DateTime.utc(2099).toIso8601String()
        : DateTime.now().toUtc().add(d).toIso8601String();
    try {
      await _api.setChatMute(_memberId ?? 0, until);
      _toast(_t.msgrChatMuted);
    } catch (e) {
      _fail(e);
    }
  }

  // ---- Disappearing (server + device enforced) ----------------------------
  Future<void> _disappearingFlow() async {
    final sec = await showDisappearingPicker(context, _disappearingSec);
    if (sec == null || !mounted) return;
    setState(() => _disappearingSec = sec);
    try {
      await _api.setDisappearing(_memberId ?? 0, sec);
    } catch (e) {
      _fail(e);
    }
  }

  // ---- Chat theme + nicknames (cde-chat, order 6 D + E) ------------------
  /// The control message inside a decrypted message (theme / nickname).
  ChatControl? _controlOf(CircleMessage m) {
    if (m.deleted == 'everyone' || m.decryptFailed) return null;
    if (m.contentType == 'photo') return _ctrlCache[m.id];
    if (m.contentType != 'text' || !isControlText(m.text)) return null;
    return _ctrlCache.putIfAbsent('t:${m.id}', () => decodeControl(m.text));
  }

  /// Fold every control in the loaded history into the chat state (newest
  /// server stamp wins, so the order never matters).
  void _foldControls() {
    for (final m in _messages) {
      if (m.pending) continue;
      final c = _controlOf(m);
      if (c == null) continue;
      unawaited(_decor.fold(m.id, c, mine: m.mine, photo: m.media));
    }
  }

  String get _myRealName {
    final n = (context.read<AppState>().user?.name ?? '').trim();
    return n.isEmpty ? _t.p3You : n;
  }

  String _describe(CircleMessage m, ChatControl c) => describeControl(_t, c,
      mine: m.mine, actor: _memberName, peerName: _memberName);

  /// Send a control as an ordinary E2E message (outbox / no-key safe).
  Future<void> _sendControl(ChatControl c) async {
    await _sendCard(encodeControl(
        c, controlFallbackLine(_t, c, myName: _myRealName)));
  }

  void _decorFailed(DecorFailure f, String fallback) {
    if (!mounted) return;
    if (f.premium) {
      unawaited(PaywallSheet.show(context, PaywallReason.generic));
      return;
    }
    _toast(f.message.isNotEmpty ? f.message : fallback);
  }

  Future<void> _chatThemeFlow() async {
    _aiOffer ??= _decor.aiOffer();
    AiThemeOffer? ai;
    try {
      ai = await _aiOffer!.timeout(const Duration(seconds: 3));
    } catch (_) {
      ai = null;
    }
    if (!mounted) return;
    final cur = _decor.state.themeId;
    final pick = await showChatThemeSheet(context,
        currentId: cur,
        premium: _decor.premium,
        currentPhoto: _decor.photoFile(),
        aiAvailable: ai != null,
        aiCredits: ai == null ? '' : notifLocalizeDigits(context, '${ai.credits}'));
    if (pick == null || !mounted) return;
    if (pick.locked) {
      await PaywallSheet.show(context, PaywallReason.generic);
      return;
    }
    try {
      if (pick.id == 'custom') {
        final d = await pickPhoto(context, camera: false);
        if (d == null || !mounted) return;
        await _sendPhotoTheme(d, 'custom');
      } else if (pick.id == 'ai') {
        if (ai == null) return;
        await _aiThemeFlow(ai);
      } else {
        if (pick.id == cur) return;
        final c = await _decor.setPreset(pick.id);
        if (mounted) setState(() {});
        await _sendControl(c);
      }
    } on DecorFailure catch (f) {
      _decorFailed(f, _t.cdeThemeFailed);
    } catch (e) {
      if (mounted) _toast(_t.cdeThemeFailed);
    }
  }

  Future<void> _sendPhotoTheme(MediaDraft d, String id) async {
    final job = await _decor.setPhoto(d, id: id);
    if (!mounted) return;
    setState(() => _mediaJobs = [..._mediaJobs.where((j) => j.id != job.id), job]);
  }

  Future<void> _aiThemeFlow(AiThemeOffer ai) async {
    final prompt = await showAiThemePrompt(context,
        credits: notifLocalizeDigits(context, '${ai.credits}'));
    if (prompt == null || prompt.trim().isEmpty || !mounted) return;
    final nav = Navigator.of(context);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: Gap.lg),
          Expanded(child: Text(_t.cdeThemeAiMaking)),
        ]),
      ),
    ));
    try {
      final d = await _decor.makeAiPicture(prompt, ai);
      nav.pop();
      if (!mounted) return;
      await _sendPhotoTheme(d, 'ai');
    } on DecorFailure catch (f) {
      nav.pop();
      _decorFailed(f, _t.cdeThemeAiFailed);
    } catch (_) {
      nav.pop();
      if (mounted) _toast(_t.cdeThemeAiFailed);
    }
  }

  Future<void> _nicknamesFlow() async {
    final st = _decor.state;
    final edit = await showNicknamesSheet(context, [
      NickRow(slot: 'peer', realName: _memberName, nick: st.nick('peer')),
      NickRow(slot: 'me', realName: _myRealName, nick: st.nick('me'), isMe: true),
    ]);
    if (edit == null || !mounted) return;
    final (row, name) = edit;
    if (name == row.nick) return;
    try {
      final c = await _decor.setNick(slot: row.slot, name: name);
      if (mounted) setState(() {});
      await _sendControl(c);
    } on DecorFailure catch (f) {
      _decorFailed(f, _t.cdeNickFailed);
    } catch (_) {
      if (mounted) _toast(_t.cdeNickFailed);
    }
  }

  // ---- Favourites ---------------------------------------------------------
  Future<void> _toggleFavourite() async {
    setState(() => _favourite = !_favourite);
    try {
      await _api.setFavourite(_memberId ?? 0, _favourite);
      _toast(_favourite ? _t.msgrChatFavouriteAdded : _t.msgrChatFavouriteRemoved);
    } catch (e) {
      _fail(e);
    }
  }

  // ---- Add to list --------------------------------------------------------
  Future<void> _addToListFlow() async {
    List<Map<String, dynamic>> lists = const [];
    try {
      final r = await _api.chatLists();
      lists = ((r['lists'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      if (mounted) _toast(_t.msgLoadFailed);
    }
    if (!mounted) return;
    final controller = TextEditingController();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
              left: Gap.lg,
              right: Gap.lg,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_t.msgrChatAddToList,
                  style: Theme.of(ctx).textTheme.titleMedium),
              for (final l in lists)
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: Text('${l['name'] ?? ''}'),
                  onTap: () => Navigator.pop(ctx, 'id:${l['id']}'),
                ),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: _t.msgrChatNewListHint,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => Navigator.pop(ctx, 'new:${controller.text.trim()}'),
                  ),
                ),
                onSubmitted: (v) => Navigator.pop(ctx, 'new:${v.trim()}'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      if (choice.startsWith('new:')) {
        final name = choice.substring(4);
        if (name.isEmpty) return;
        await _api.setChatList(_memberId ?? 0, name: name);
      } else {
        await _api.setChatList(_memberId ?? 0, listId: int.tryParse(choice.substring(3)));
      }
      _toast(_t.msgrChatAddedToList);
    } catch (e) {
      _fail(e);
    }
  }

  // ---- Export chat (.txt from DECRYPTED msgs, client-side share sheet) -----
  Future<void> _exportChat() async {
    final buf = StringBuffer();
    buf.writeln('Assisto — ${_memberName}');
    for (final m in _messages) {
      if (m.deleted == 'everyone' || m.text.isEmpty) continue;
      final who = m.mine ? '→' : '←';
      buf.writeln('[${m.at.toIso8601String()}] $who ${m.text}');
    }
    // The transcript is built ON-DEVICE from already-decrypted text (never from
    // the server). Hand it to the extras hub, which owns the OS share sheet +
    // optional media attach.
    // seam audit: no "export ready" toast before anything is exported — the
    // extras hub really shares the transcript.
    if (!mounted) return;
    _openExtrasHub();
  }

  void _openExtrasHub() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleExtrasHubScreen(
        member: widget.member,
        decryptedMessages: () => _messages
            .where((m) => m.deleted != 'everyone' && m.text.isNotEmpty)
            .map((m) => <String, dynamic>{
                  'id': m.id,
                  'text': m.text,
                  'mine': m.mine,
                  'at': m.at.toIso8601String(),
                })
            .toList(),
      ),
    ));
  }

  // ---- Close chat (keeps the entry, archives) -----------------------------
  Future<void> _closeChat() async {
    try {
      await _api.closeChat(_memberId ?? 0);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _fail(e);
    }
  }

  // ---- Send call link (expiring) ------------------------------------------
  Future<void> _sendCallLink() async {
    try {
      final r = await _api.createCallLink(_memberId ?? 0, kind: 'voice');
      final link = '${r['link'] ?? ''}';
      if (!mounted) return;
      if (link.isEmpty) {
        _toast(_t.grpActionFailed);
        return;
      }
      // The expiring link is built server-side; share via the OS sheet (a chat
      // message carrying the link is the user's choice).
      _input.text = link;
      _toast(_t.msgrChatCallLinkReady);
    } catch (e) {
      _fail(e);
    }
  }

  // ---- Schedule call (time + reminder for invitees) -----------------------
  Future<void> _scheduleCall() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      initialDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null || !mounted) return;
    final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    try {
      await _api.scheduleCall(_memberId ?? 0, atIso: at.toUtc().toIso8601String());
      _toast(_t.msgrChatCallScheduled);
    } catch (e) {
      _fail(e);
    }
  }

  // ---- New group call -----------------------------------------------------
  Future<void> _newGroupCall() async {
    // Starting a group call from a 1:1 means adding more circle members; the
    // group-call launch reuses circle_calls. The picker is the group screen's
    // job, so from here we open the call screen with this member (x1-calls:
    // no pre-check POST — the screen places the ONE call itself).
    await _placeCall('voice');
  }

  // p3: the old MOCK "Assisto extras" and in-chat AI helper are replaced by
  // the real @Assisto actions (_openAssisto; credits + consent, P3_DESIGN.md).

  // ---- Report (sends the LAST 5 decrypted messages to moderation) ---------
  Future<void> _reportFlow() async {
    final res = await showChatReportPicker(context);
    if (res == null || !mounted) return;
    try {
      await _api.reportLast5(
        peerId: _memberId ?? 0,
        reason: res.reason,
        decryptedLastFive: _lastFiveDecrypted(),
      );
      if (res.alsoBlock) {
        await _api.blockContact(_memberId ?? 0, on: true);
      }
      if (mounted) _toast(_t.msgrChatReportSent);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _blockFlow() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.circleBlock),
        content: Text(_t.msgrChatBlockConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t.circleBlock)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.blockContact(_memberId ?? 0, on: true);
      _toast(_t.msgrChatBlocked);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _clearChatFlow() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.msgrChatClear),
        content: Text(_t.msgrChatClearConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t.msgrChatClear)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      // Per-user marker on the server: hidden for me only, the peer keeps theirs.
      await _api.clearChat(_memberId ?? 0);
      if (mounted) setState(() => _messages = []);
    } catch (e) {
      _toast(e is ApiException && e.message.isNotEmpty
          ? e.message
          : _t.grpActionFailed);
    }
  }

  // -------------------------------------------------------------------------
  // Multi-select bulk actions (⋮ Select messages)
  // -------------------------------------------------------------------------
  void _toggleSelect(CircleMessage m) {
    setState(() {
      if (_selected.contains(m.id)) {
        _selected.remove(m.id);
      } else {
        _selected.add(m.id);
      }
    });
  }

  List<CircleMessage> get _selectedMsgs =>
      _messages.where((m) => _selected.contains(m.id)).toList();

  Future<void> _bulkStar() async {
    for (final m in _selectedMsgs) {
      if (!m.starred) await _toggleStar(m);
    }
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _bulkCopy() async {
    final text = _selectedMsgs.map((m) => cardFallback(m.text)).where((t) => t.isNotEmpty).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast(_t.circleCopied);
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _bulkForward() async {
    final toForward = _selectedMsgs.toList();
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    for (final m in toForward) {
      await _doForwardInto(m);
    }
  }

  Future<void> _bulkDelete() async {
    // Delete-for-everyone only within the window AND only my own messages;
    // otherwise delete-for-me. Honest choice dialog.
    final now = DateTime.now();
    final canEveryone = _selectedMsgs.every((m) =>
        m.mine && now.difference(m.at).inMinutes < _kDeleteEveryoneWindowMin);
    final scope = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.delete),
        content: Text(_t.msgrChatDeleteConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'me'),
              child: Text(_t.circleActionDeleteMe)),
          if (canEveryone)
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'everyone'),
                child: Text(_t.circleActionDeleteEveryone)),
        ],
      ),
    );
    if (scope == null || !mounted) return;
    final toDelete = _selectedMsgs.toList();
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    for (final m in toDelete) {
      await _delete(m, scope);
    }
  }

  /// cde-chat: the message area in the chat's shared theme (wallpaper,
  /// bubble colours, chips) — the composer and header keep the app look.
  Widget _themed(Widget child) {
    final d = _decor.themeDef;
    if (d == null) return child;
    return ChatThemeScope(
      def: d,
      child: Theme(
        data: themedChatArea(Theme.of(context), d),
        child: ChatWallpaper(
            def: d, photo: d.isPhoto ? _decor.photoFile() : null, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final relation = '${widget.member['relation'] ?? 'friend'}';
    final pinned = _messages.where((m) => m.pinned).toList();
    final rows = _rows; // computed once per build
    // t1-ticks: date chips (+ the E2E notice as the OLDEST item once the
    // whole history is loaded) interleaved into e2's newest-first rows.
    final dated = insertDateSeparators<_ChatRow>(rows, (r) => r.at,
        newestFirst: true, e2eNotice: !_searching && !_hasMore);
    return Scaffold(
      appBar: _searching ? _searchAppBar(scheme) : _normalAppBar(scheme, relation),
      body: Column(
        children: [
          // t1-ticks (owner B2): the E2E notice is no longer pinned — it is
          // the first history item (insertDateSeparators e2eNotice).
          // t1-ticks: min-version gate (my build / peer's build) — never blocks.
          if (!_searching && int.tryParse('${widget.member['id']}') != null)
            McVersionBanner(
                api: _api,
                kind: 'member',
                chatId: int.parse('${widget.member['id']}')),
          if (pinned.isNotEmpty && !_searching) _pinnedStrip(pinned, scheme),
          Expanded(
            child: _themed(_loading
                ? const Center(child: CircularProgressIndicator())
                : rows.isEmpty
                    ? Column(children: [ // t1-ticks: E2E notice first
                        if (!_searching) const E2eNoticeChip(),
                        Expanded(child: _chatEmpty(scheme)),
                      ])
                    // t1-ticks: date chips + floating date while scrolling,
                    // over e2's REVERSED paged list (rows are newest first).
                    : Opacity(
                       // hidden only while the unread divider is placed
                       opacity: _positioned ? 1 : 0,
                       child: ChatDateScope(child: ListView.builder(
                        key: const Key('e2-chat-list'),
                        controller: _scroll,
                        // e2-keys item 2: REVERSED — offset 0 is the latest
                        // message, so the chat opens there with no scroll.
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                        itemCount: dated.length + (_hasMore ? 1 : 0),
                        itemBuilder: (_, ri) {
                          if (ri >= dated.length) return _olderLoader(scheme);
                          return buildChatRow<_ChatRow>(dated[ri], (row) {
                          if (row.divider) return _unreadDivider(scheme);
                          if (row.note != null) return _securityNote(scheme, row.note!);
                          final call = row.call;
                          if (call != null) {
                            return CallEventChip(
                              event: call,
                              // a1-circle: tap = call back, same kind; no
                              // tap at all while calls aren't open.
                              onCallBack: _callsOpen && !_selecting
                                  ? () => _placeCall(call.kind)
                                  : null,
                            );
                          }
                          final m = row.msg!;
                          final key =
                              _msgKeys.putIfAbsent(m.id, () => GlobalKey());
                          // cde-chat: a theme / nickname change is a centred
                          // system line, never a bubble
                          if (m.mediaJob?.control != null) {
                            return KeyedSubtree(
                                key: key,
                                child: ChatSystemLine(
                                    text: _t.cdeThemeSending,
                                    icon: Icons.palette_outlined));
                          }
                          final cc = _controlOf(m);
                          if (cc != null) {
                            return KeyedSubtree(
                                key: key,
                                child: ChatSystemLine(
                                    text: _describe(m, cc),
                                    icon: cc.isTheme
                                        ? Icons.palette_outlined
                                        : Icons.badge_outlined));
                          }
                          // p3: an Assisto card (E2E like any message)
                          final p3c = _p3Card(m);
                          if (p3c != null) {
                            return AssistoCardView(
                              key: key,
                              card: p3c,
                              mine: m.mine,
                              senderName: _memberName,
                              ledger: _p3Ledger,
                              onAddReminder: _reqIn
                                  ? null
                                  : (c) => acceptReminderCard(
                                      context, c, _p3MyName, _sendCard),
                              onTick: _reqIn
                                  ? null
                                  : (c, i, on) => sendTick(
                                      c, i, on, _p3MyName, _sendCard, _t),
                              onLongPress: _selecting ? null : () => _onLongPress(m),
                            );
                          }
                          final scam = _scamOf(m);
                          final bubble0 = CircleBubble(
                            key: key,
                            msg: m,
                            highlighted: _highlightId == m.id,
                            onTapReply: () => _jumpTo(m.replyToId),
                            // mr1: a request I have not accepted is read-only
                            onLongPress: (_selecting || _reqIn || m.mediaJob != null)
                                ? null
                                : () => _onLongPress(m),
                            onTapMedia: (!_selecting &&
                                    m.contentType != 'text' &&
                                    m.media == null)
                                ? () => _openMedia(m)
                                : null,
                            onOpenFile: _selecting ? null : _openFile,
                          );
                          // p3: on-device scam warning under an incoming message
                          final Widget bubble = scam.flagged
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [bubble0, ScamWarningBanner(verdict: scam)])
                              : bubble0;
                          if (!_selecting) {
                            return SwipeToReply(
                              key: ValueKey('c3-swipe-${m.id}'),
                              mine: m.mine,
                              enabled: m.deleted != 'everyone' && !m.pending &&
                                  !_reqIn,
                              onReply: () => _startReply(m),
                              child: bubble,
                            );
                          }
                          final sel = _selected.contains(m.id);
                          return InkWell(
                            onTap: () => _toggleSelect(m),
                            child: Container(
                              color: sel
                                  ? scheme.primary.withValues(alpha: 0.12)
                                  : null,
                              child: Row(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(left: Gap.sm),
                                    child: Icon(
                                      sel
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked,
                                      color: sel
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                      size: 20,
                                    ),
                                  ),
                                  Expanded(child: IgnorePointer(child: bubble)),
                                ],
                              ),
                            ),
                          );
                          });
                        },
                      )), // t1-ticks: /ChatDateScope
                    )),
          ),
          if (_peerTyping && !_searching) _typingIndicator(scheme),
          if ((_replyTo != null || _editing != null) && !_searching && !_selecting)
            CircleComposerContext(
              preview: _previewOf((_editing ?? _replyTo)!),
              isEdit: _editing != null,
              onCancel: () => setState(() {
                _replyTo = null;
                _editing = null;
                if (_editing == null) _input.clear();
              }),
            ),
          // mr1: message requests — the sender's neutral waiting line (and
          // the pre-accept limit note instead of a dead composer); the
          // recipient's read-only Accept / Block / Report / Delete bar.
          if (_reqOut && !_searching && !_selecting)
            MsgRequestWaitingLine(name: _memberName),
          if (_reqIn && !_searching && !_selecting)
            MsgRequestActionBar(
              name: _memberName,
              phone: '${widget.member['request_phone'] ?? ''}',
              busy: _reqBusy,
              onAccept: _acceptRequest,
              onBlock: () => _requestAct('block'),
              onReport: () => _requestAct('report'),
              onDelete: () => _requestAct('delete'),
            )
          else if (_reqOutFull && !_searching && !_selecting)
            MsgRequestLimitNote(name: _memberName)
          else if (!_searching && !_selecting)
            _composer(scheme),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // mr1: message requests
  // -------------------------------------------------------------------------
  late String _edgeState = '${widget.member['state'] ?? 'accepted'}';
  late String _edgeDir = '${widget.member['direction'] ?? 'outgoing'}';
  late Map<String, dynamic>? _reqInfo =
      (widget.member['request'] as Map?)?.cast<String, dynamic>();
  bool _reqBusy = false;

  /// Someone I don't know messaged me and I have not accepted yet.
  bool get _reqIn => _edgeState == 'pending' && _edgeDir == 'incoming';

  /// I messaged someone who has not accepted yet.
  bool get _reqOut => _edgeState == 'pending' && _edgeDir != 'incoming';

  /// No calls (and nothing tappable for them) until the request is accepted.
  bool get _callsOpen => _edgeState == 'accepted';

  bool get _reqOutFull => _reqOut && _reqInfo?['can_send'] == false;

  /// The server's `edge` block on every message fetch keeps this live: the
  /// moment the other person accepts, the waiting line goes and calls appear.
  void _applyEdge(Object? e) {
    if (e is! Map) return;
    final st = '${e['state'] ?? _edgeState}';
    final dir = '${e['direction'] ?? _edgeDir}';
    final info = (e['request'] as Map?)?.cast<String, dynamic>();
    if (st == _edgeState && dir == _edgeDir &&
        '${info?['can_send']}' == '${_reqInfo?['can_send']}') {
      return;
    }
    if (!mounted) return;
    setState(() {
      _edgeState = st;
      _edgeDir = dir;
      _reqInfo = info;
    });
  }

  /// One of my request messages went out: count it against the budget.
  void _countRequestSend() {
    final info = _reqInfo;
    if (!_reqOut || info == null) return;
    final sent = ((info['sent'] as num?)?.toInt() ?? 0) + 1;
    final limit = (info['limit'] as num?)?.toInt() ?? 5;
    setState(() => _reqInfo = {...info, 'sent': sent, 'can_send': sent < limit});
  }

  Future<void> _acceptRequest() async {
    final id = _memberId;
    if (id == null || _reqBusy) return;
    setState(() => _reqBusy = true);
    try {
      await _api.postJson('/circle/request/$id/act', {'event': 'accept'});
      if (!mounted) return;
      setState(() {
        _edgeState = 'accepted';
        _reqInfo = null;
      });
      _toast(_t.mr1AcceptedToast(_memberName));
      unawaited(_markSeen()); // now it really is read
    } catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _reqBusy = false);
    }
  }

  Future<void> _requestAct(String action) async {
    final id = _memberId;
    if (id == null || _reqBusy) return;
    final ok = await showMsgRequestConfirm(context, action, _memberName);
    if (ok != true || !mounted) return;
    setState(() => _reqBusy = true);
    try {
      await _api.postJson('/circle/request/$id/msgreq', {
        'action': action,
        if (action == 'report') 'reason': 'spam',
      });
      if (!mounted) return;
      _toast(switch (action) {
        'block' => _t.mr1BlockedToast,
        'report' => _t.mr1ReportedToast,
        _ => _t.mr1DeletedToast,
      });
      Navigator.of(context).pop(true);
    } catch (e) {
      _fail(e);
      if (mounted) setState(() => _reqBusy = false);
    }
  }

  // mr1: the full WhatsApp last-seen line, in the phone's 12/24-hour format.
  String? get _presence => presenceLabel(_t, _live,
      lang: Localizations.localeOf(context).languageCode,
      use24h: MediaQuery.of(context).alwaysUse24HourFormat);

  PreferredSizeWidget _normalAppBar(ColorScheme scheme, String relation) {
    if (_selecting) return _selectionAppBar(scheme);
    return AppBar(
      titleSpacing: 0,
      // t1-ticks: WhatsApp-standard header (name line 1 full width, status
      // line 2, tap -> contact info). Presence hidden by privacy -> no line.
      title: ChatHeaderTitle(
        // cde-chat: the nickname (the real name stays in contact info)
        name: DecorStore.instance.peerName(_chatKey, _memberName),
        status: _presence,
        statusActive: _peerTyping,
        // mr1: a request I have not accepted shows no contact info
        onTap: _reqIn ? null : _openContactInfo,
        // x2-ticks (A3): the contact's real photo (cached, refreshed on
        // change); initials when there is none.
        avatar: MsgrAvatar(
            key: const Key('x2-header-avatar'),
            name: _memberName,
            radius: 18,
            photoUrl:
                '${widget.member['photo_link'] ?? widget.member['photo'] ?? ''}',
            photoV: '${widget.member['photo_v'] ?? ''}'),
      ),
      actions: [
        // mr1: calls open the moment a message request is accepted — until
        // then there is nothing tappable for them (no dead buttons).
        if (_callsOpen) ...[
          IconButton(
            tooltip: _t.circleVideo,
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => _placeCall('video'),
          ),
          RoboId(id: 'tl_chat_voice_call', // tl1: Test Lab Robo target
            child: IconButton(
              tooltip: _t.circleVoiceCall,
              icon: const Icon(Icons.call_outlined),
              onPressed: () => _placeCall('voice'),
            ),
          ),
        ],
        // t1-ticks: Search moved into the ⋮ menu (ChatMenuAction.search).
        if (!_reqIn)
          IconButton(
            tooltip: _t.msgrChatMore,
            icon: const Icon(Icons.more_vert),
            onPressed: _openChatMenu,
          ),
      ],
    );
  }

  PreferredSizeWidget _selectionAppBar(ColorScheme scheme) => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() {
            _selecting = false;
            _selected.clear();
          }),
        ),
        title: Text('${_selected.length}'),
        actions: [
          IconButton(
            tooltip: _t.circleActionStar,
            icon: const Icon(Icons.star_outline),
            onPressed: _selected.isEmpty ? null : _bulkStar,
          ),
          IconButton(
            tooltip: _t.msgrChatCopy,
            icon: const Icon(Icons.copy_outlined),
            onPressed: _selected.isEmpty ? null : _bulkCopy,
          ),
          IconButton(
            tooltip: _t.circleActionForward,
            icon: const Icon(Icons.forward_outlined),
            onPressed: _selected.isEmpty ? null : _bulkForward,
          ),
          IconButton(
            tooltip: _t.delete,
            icon: const Icon(Icons.delete_outline),
            onPressed: _selected.isEmpty ? null : _bulkDelete,
          ),
        ],
      );

  PreferredSizeWidget _searchAppBar(ColorScheme scheme) => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _searching = false;
            _searchQuery = '';
          }),
        ),
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(hintText: _t.circleSearchInChat, border: InputBorder.none),
          onChanged: (v) => setState(() => _searchQuery = v),
        ),
      );

  Widget _pinnedStrip(List<CircleMessage> pinned, ColorScheme scheme) => Container(
        width: double.infinity,
        color: scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        child: Row(
          children: [
            Icon(Icons.push_pin, size: 14, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(pinned.last.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
            Text('${pinned.length}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _typingIndicator(ColorScheme scheme) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xs),
          child: Text(_live.recording ? _t.c3Recording : _t.c3Typing,
              style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant, fontSize: 12)),
        ),
      );

  /// Display rows NEWEST FIRST (the list is reversed): server messages,
  /// queued outbox items (clock), "security code changed" notes and the
  /// "N unread messages" divider just above the first unread message.
  List<_ChatRow> get _rows {
    final vis = _visible;
    final searching = _searching && _searchQuery.trim().isNotEmpty;
    final items = <_ChatRow>[
      for (final m in vis)
        if (!_p3Hidden(m)) _ChatRow.msg(m), // p3: tick / ack events fold into their card
      if (!searching)
        for (final q in _queued)
          if (!vis.any((m) => m.id == q.id) && !_serverCmids.contains(q.id))
            _ChatRow.msg(CircleMessage(
                id: q.id,
                text: q.text,
                mine: true,
                at: q.at,
                status: 'sent',
                pending: true,
                replyToId: q.replyTo,
                forwarded: q.forwarded,
                forwardHops: q.forwardHops)),
      if (!searching)
        for (final j in _mediaJobs)
          if (!vis.any((m) => m.id == j.id) && !_serverCmids.contains(j.id))
            _ChatRow.msg(CircleMessage(
                id: j.id,
                text: j.caption,
                mine: true,
                at: j.at,
                status: 'sent',
                pending: true,
                replyToId: j.replyTo,
                contentType: j.kind,
                mediaJob: j)),
      if (!searching)
        for (final n in _keyNotes) _ChatRow.note(n),
      // a1-circle: call events by time; with older pages not loaded yet,
      // only calls inside the loaded window (no out-of-order gap).
      if (!searching)
        for (final c in _calls)
          if (!_hasMore || vis.isEmpty || !c.at.isBefore(vis.first.at))
            _ChatRow.call(c),
    ];
    // stable chronological order (server order kept for equal stamps)
    final indexed = items.asMap().entries.toList()
      ..sort((a, b) {
        final c = a.value.at.compareTo(b.value.at);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final chrono = indexed.map((e) => e.value).toList();
    if (!searching && _firstUnreadId != null && _unreadAtOpen > 0) {
      final i = chrono.indexWhere((r) => r.msg?.id == _firstUnreadId);
      if (i >= 0) chrono.insert(i, _ChatRow.divider(chrono[i].at));
    }
    return chrono.reversed.toList();
  }

  Widget _unreadDivider(ColorScheme scheme) => Padding(
        key: _dividerKey,
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Container(
          width: double.infinity,
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: Gap.md),
          child: Text(
            localDigits(_t.e2UnreadDivider(_unreadAtOpen),
                Localizations.localeOf(context).languageCode), // qa2
            key: const Key('e2-unread-divider'),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant),
          ),
        ),
      );

  Widget _securityNote(ColorScheme scheme, DateTime at) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: Gap.xs, horizontal: Gap.lg),
          child: Material(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _explainSecurityChange,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.md, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 14, color: scheme.onSecondaryContainer),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _t.e2SecurityCodeChanged(_memberName),
                        key: const Key('e2-security-note'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSecondaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  void _explainSecurityChange() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.e2SecurityCodeTitle),
        content: Text(_t.e2SecurityCodeBody(_memberName)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
        ],
      ),
    );
  }

  Widget _olderLoader(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Center(
          child: _loadingOlder
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const SizedBox(height: 20),
        ),
      );

  Widget _chatEmpty(ColorScheme scheme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 48, color: scheme.primary.withValues(alpha: 0.7)),
              const SizedBox(height: Gap.md),
              Text(_searching ? _t.circleSearchNoResults : _t.circleChatEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            ],
          ),
        ),
      );

  Widget _composer(ColorScheme scheme) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // p3: typing "@Assisto" offers the Assisto actions (never sent)
          if (_p3HintShown)
            AssistoMentionHint(onTap: () {
              final i = parseAssisto(_input.text);
              setState(() {
                _input.clear();
                _p3HintShown = false;
              });
              unawaited(_openAssisto(intent: i));
            }),
          Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.sm),
          child: Row(
            children: [
              if (_canAttach)
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: _t.circleAttach,
                  onPressed: _attach,
                )
              else
                const SizedBox(width: Gap.sm),
              Expanded(
                child: RoboId(id: 'tl_chat_input', // tl1: Test Lab Robo target
                  child: TextField(
                  controller: _input,
                  focusNode: _inputFocus, // db1
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  // c3-msg: throttled "typing…" (≤ 1 event / 3 s) + stop.
                  onChanged: (v) {
                    final id = _memberId;
                    // p3: show / hide the @Assisto hint as the user types
                    final hint = hasAssistoMention(v) || isTypingMention(v);
                    if (hint != _p3HintShown) setState(() => _p3HintShown = hint);
                    if (id == null || v.trimLeft().startsWith('@')) return;
                    _rt.typing('member', id, v.trim().isEmpty ? 'stop' : 'typing');
                  },
                  decoration: InputDecoration(hintText: _t.circleMessageHint),
                ),
                ),
              ),
              // p3: the Assisto button (same actions as typing "@Assisto")
              IconButton(
                key: const ValueKey('p3-assisto-btn'),
                icon: const Icon(Icons.auto_awesome_outlined),
                tooltip: _t.p3Assisto,
                onPressed: _reqIn ? null : () => _openAssisto(),
              ),
              RoboId(id: 'tl_chat_send',
                child: IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: Icon(_editing != null ? Icons.check : Icons.send),
                ),
              ),
            ],
          ),
        ),
        ]),
      );
}

/// One row of the reversed chat list.
class _ChatRow {
  final CircleMessage? msg;
  final DateTime? note; // "security code changed" at
  final bool divider;
  final CallEvent? call; // a1-circle
  final DateTime _at;
  _ChatRow.msg(CircleMessage m)
      : msg = m,
        note = null,
        divider = false,
        call = null,
        _at = m.at;
  _ChatRow.note(DateTime at)
      : msg = null,
        note = at,
        divider = false,
        call = null,
        _at = at;
  _ChatRow.divider(DateTime at)
      : msg = null,
        note = null,
        divider = true,
        call = null,
        _at = at;
  _ChatRow.call(CallEvent c)
      : msg = null,
        note = null,
        divider = false,
        call = c,
        _at = c.at;
  DateTime get at => _at;
}
