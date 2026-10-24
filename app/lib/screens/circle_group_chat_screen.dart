import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../p3/assisto_card.dart'; // p3
import '../p3/assisto_card_view.dart';
import '../p3/assisto_intent.dart';
import '../p3/assisto_sheet.dart';
import '../p3/scam_banner.dart';
import '../p3/scam_guard.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../config.dart';
import '../crypto/e2e.dart';
import '../widgets/circle_bubble.dart' show e2rWaitingText; // e2e-recover
import '../crypto/identity_vault.dart'; // e2e-recover
import '../crypto/plain_cache.dart'; // e2e-recover
import '../crypto/key_service.dart';
import '../l10n/app_localizations.dart';
import '../messenger_admin_api.dart';
import '../messenger_group_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_group_poll.dart';
import '../messaging/receipt_bus.dart';
import '../messaging/echo_reconcile.dart'; // md2
import '../messaging/disappear_sweep.dart'; // e-gaps
import '../messaging/chat_lock.dart'; // e-gaps
import '../messaging/forward.dart'; // md2
import '../services/action_feedback.dart';
import '../messaging/media/media_actions.dart'; // md1
import '../messaging/media/media_bubble.dart';
import '../messaging/media/media_descriptor.dart';
import '../messaging/media/media_outbox.dart';
import '../messaging/media/media_send.dart';
import '../messaging/media/media_store.dart';
import '../widgets/circle_attach_sheet.dart';
import '../messaging/badges_bus.dart';
import '../messaging/chat_header.dart'; // t1-ticks
import '../messaging/date_separators.dart'; // t1-ticks
import '../messaging/mc_version_gate.dart'; // t1-ticks
import '../messaging/c3_api.dart';
import '../messaging/msg_notify.dart';
import '../messaging/msg_ticks.dart';
import '../messaging/msg_widgets.dart';
import '../messaging/presence_label.dart';
import '../messaging/unread_store.dart';
import '../realtime/realtime_channel.dart';
import '../widgets/group_menu_media.dart';
import '../widgets/group_export.dart';
import '../widgets/group_menu_sheet.dart';
import '../widgets/msgr_mod_report_sheet.dart';
import 'circle_group_info_screen.dart';
import '../widgets/paywall_sheet.dart'; // p2-money
import '../messaging/chat_decor/chat_control.dart'; // cde-chat
import '../messaging/chat_decor/chat_themes.dart';
import '../messaging/chat_decor/decor_chat.dart';
import '../messaging/chat_decor/decor_sheets.dart';
import '../messaging/chat_decor/decor_store.dart';
import '../messaging/chat_decor/system_line.dart';
import '../messaging/media/media_prep.dart' show pickPhoto, MediaDraft;
import '../widgets/notif_models.dart' show notifLocalizeDigits;

/// End-to-end-encrypted GROUP chat (M2 item 7).
///
/// E2E FAN-OUT (software fallback): a group message is encrypted ONCE PER
/// RECIPIENT with crypto/e2e.dart (the pairwise fallback) and relayed as a
/// single envelope carrying a {recipient_id: {ciphertext,nonce}} map
/// (per_recipient). The server stores ciphertext only and never holds a group
/// key — exactly like 1:1. When OpenMLS lands it replaces fan-out with one
/// group ciphertext; the envelope shape is unchanged (see
/// core/logic/circle_groups.build_group_fanout + the E2E/GROUP-KEY statement).
///
/// Features wired here: post (announcements-only gate for members), @mentions,
/// reply, reactions, polls, pinned, leave, report, and the group voice/video
/// call launch (video requires a Premium initiator — reuses
/// core/logic/circle_calls.can_place_call via can_place_group_call).
///
/// Backend seam (integrator wires these — see MIGRATION NOTE in the report):
///   GET  /circle/groups/<id>/messages        -> ciphertext envelopes
///   POST /circle/groups/<id>/messages         -> send (per_recipient fan-out)
///   POST /circle/groups/<id>/messages/<m>/react
///   POST /circle/groups/<id>/messages/<m>/pin  (admin)
///   POST /circle/groups/<id>/leave
///   POST /circle/groups/<id>/report
///   POST /circle/groups/<id>/call              -> {kind: voice|video}
///   GET  /circle/groups/<id>/members           -> members (+role, +public_key)
class CircleGroupChatScreen extends StatefulWidget {
  final Map<String, dynamic> group;
  final IdentityKeyPair identity;
  final List<Map<String, dynamic>> circleMembers;
  const CircleGroupChatScreen({
    super.key,
    required this.group,
    required this.identity,
    this.circleMembers = const [],
  });

  @override
  State<CircleGroupChatScreen> createState() => _CircleGroupChatScreenState();
}

class _CircleGroupChatScreenState extends State<CircleGroupChatScreen> {
  final _e2e = SoftwareE2E();
  final _input = TextEditingController();
  final _inputFocus = FocusNode(); // db1
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _loadFailed = false; // §21 honest load error + retry
  bool _sending = false;
  // §21 failed-send: the last text that could not be sent, kept so the user can
  // resend without retyping. Null when the last send succeeded.
  String? _failedText;
  Map<String, dynamic>? _replyTo;

  // Group ⋮ driven UI modes.
  bool _searching = false;
  String _searchQuery = '';
  bool _selecting = false;
  final Set<String> _selected = {};
  bool get _isFavourite => widget.group['favourite'] == true;

  // c3-msg: live typing (RealtimeChannel), seen on open, light poll while
  // open so ticks and new messages update without a manual refresh.
  final _rt = RealtimeChannel.instance;
  Timer? _poll;
  int get _gid => int.tryParse(_groupId) ?? 0;
  String get _chatKey => 'group:$_gid';

  // e2-keys item 2: reversed + paged, opens at the latest message or at the
  // "N unread messages" divider — never renders from the top.
  static const int _pageSize = 50;
  bool _hasMore = false;
  bool _loadingOlder = false;
  bool _loadedOnce = false;
  int _unreadAtOpen = 0;
  String? _firstUnreadId;
  bool _positioned = true;
  final GlobalKey _dividerKey = GlobalKey();

  // cde-chat (order 6 D + E): the group's shared theme + nicknames.
  late final DecorChat _decor =
      DecorChat(api: _api, chatKey: _chatKey, chatId: _gid, group: true);
  final Map<String, ChatControl?> _ctrlCache = {};
  Future<AiThemeOffer?>? _aiOffer;

  void _onDecor() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    DecorStore.instance.revision.addListener(_onDecor); // cde-chat
    if (_gid > 0) unawaited(_decor.load());
    MsgActiveChat.current = _chatKey;
    UnreadStore.instance.clear(_chatKey);
    unawaited(FlnMsgSink().cancel('group', _gid));
    _rt.acquire();
    _rt.states.addListener(_onRt);
    _scroll.addListener(_onScroll);
    _load().then((_) => _markSeen());
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _pollMessages());
    // md1: media sends of this group (progress ring) + decrypted-file dir.
    MediaOutbox.instance.identity ??= () async => widget.identity;
    MediaOutbox.instance.changes.addListener(_onMediaJobs);
    _mediaSentSub = MediaOutbox.instance.sent.listen((s) {
      if (s.chatKind == 'group' && s.chatId == _gid) unawaited(_pollMessages());
    });
    unawaited(_onMediaJobsAsync());
    unawaited(MediaDirs.root().then((_) {
      if (mounted) setState(() {});
    }, onError: (Object e) => KeyService.instance.log.add('md1 dir ${e.runtimeType}')));
    // x2-ticks: live ticks + instant refresh on a new message.
    _rcptSub = ReceiptBus.instance.updates.listen(_onReceipt);
    _newSub = ReceiptBus.instance.newMessages.listen((c) {
      if (c == _chatKey) unawaited(_pollMessages());
    });
  }

  // ---- md1: E2E media ----
  List<MediaJob> _mediaJobs = const [];
  StreamSubscription<MediaSent>? _mediaSentSub;
  // md2: my SENT messages whose server copy is not in the list yet (text
  // and finished media). Drawn until the row with the same id /
  // client_msg_id is listed, then dropped in that same frame — no flicker.
  List<Map<String, dynamic>> _echoes = const [];
  final SentEchoes _sentEchoes = SentEchoes();
  // decrypted plaintext per message (BigInt X25519 is slow on low-end
  // phones; never re-decrypt the same envelope on every frame)
  final Map<String, String> _ptCache = {};

  void _onMediaJobs() => unawaited(_onMediaJobsAsync());

  Future<void> _onMediaJobsAsync() async {
    final jobs = await MediaOutbox.instance.forChat('group', _gid);
    if (!mounted) return;
    final now = jobs.map((j) => j.id).toSet();
    setState(() {
      // md2: a finished job becomes its final bubble in the SAME frame.
      final have = _listedIds();
      for (final j in _mediaJobs) {
        if (now.contains(j.id)) continue;
        final s = MediaOutbox.instance.recentlySent[j.id];
        if (s == null || s.desc == null) continue; // cancelled: gone
        final lid = s.serverId.isNotEmpty ? s.serverId : j.id;
        if (have.contains(lid) || have.contains(j.id)) continue;
        if (s.control != null) _ctrlCache[lid] = ChatControl.fromJson(s.control); // cde-chat
        _addEcho({
          'id': lid,
          'client_msg_id': j.id,
          'mine': true,
          'content_type': s.desc!.kind,
          'md1_desc': s.desc,
          'sender_id': _myUserId,
          'status': 'sent',
          'created_at': (s.at ?? j.at).toUtc().toIso8601String(),
        });
      }
      _mediaJobs = jobs;
    });
  }

  /// md2: forward a text / photo / voice / document to any chat (member or
  /// group). Media reuses the same blob + key — no re-upload.
  Future<void> _forward(Map<String, dynamic> msg) async {
    final media = _mediaOf(msg);
    final plain = media != null ? media.encode() : _decryptForMe(msg);
    if (plain == null || plain.isEmpty) return;
    List<ForwardTarget> targets;
    try {
      targets = await loadForwardTargets(_api);
    } catch (e) {
      if (mounted) showActionFailed(context, 'md2_fwd_targets', e);
      return;
    }
    if (!mounted) return;
    if (targets.isEmpty) {
      _toast(_t.grpActionFailed);
      return;
    }
    final pick = await pickForwardTarget(context, targets);
    if (pick == null || !mounted) return;
    final hops = (msg['forward_hops'] is int ? msg['forward_hops'] as int : 0) + 1;
    final payload = ForwardPayload(
        plaintext: plain,
        contentType: media?.kind ?? 'text',
        blobRef: media?.ref,
        hops: hops);
    final cmid = 'fwd-${DateTime.now().microsecondsSinceEpoch}';
    try {
      if (pick.isGroup) {
        final sid = await forwardToGroup(_api, widget.identity, pick.id, payload,
            e2e: _e2e, clientMsgId: cmid);
        if (pick.id == _gid && mounted) {
          setState(() => _addEcho({
                'id': sid.isEmpty ? cmid : sid,
                'client_msg_id': cmid,
                'mine': true,
                'content_type': payload.contentType,
                if (media != null) 'md1_desc': media else 'md2_plain': plain,
                'sender_id': _myUserId,
                'forwarded': true,
                'forward_hops': hops,
                'status': 'sent',
                'created_at': DateTime.now().toUtc().toIso8601String(),
              }));
          unawaited(_pollMessages());
        }
      } else {
        await forwardToMember(_api, widget.identity, pick, payload,
            e2e: _e2e, clientMsgId: cmid);
      }
      if (mounted) _toast(_t.c3Forwarded(pick.name));
    } catch (e) {
      if (mounted) showActionFailed(context, 'md2_forward', e);
    }
  }

  /// Every id AND client_msg_id in the fetched list.
  Set<String> _listedIds() => {
        for (final m in _messages) ...[
          '${m['id']}',
          if ('${m['client_msg_id'] ?? ''}'.isNotEmpty) '${m['client_msg_id']}',
        ]
      };

  void _addEcho(Map<String, dynamic> e) {
    _sentEchoes.track('${e['id']}', '${e['client_msg_id'] ?? ''}');
    _echoes = [..._echoes.where((x) => x['id'] != e['id']), e];
  }

  /// Drop the echoes whose server copy is now in [_messages].
  void _pruneEchoes() {
    if (_echoes.isEmpty) return;
    final ids = {for (final m in _messages) '${m['id']}'};
    final cmids = fetchedClientIds(_messages);
    final waiting = _sentEchoes.awaiting(ids: ids, cmids: cmids);
    _echoes = _echoes.where((e) => waiting.contains('${e['id']}')).toList();
  }

  bool get _canAttach => circleAttachKinds().isNotEmpty;

  Future<void> _attach() async {
    final kind = await showCircleAttachSheet(context);
    if (kind == null || !mounted) return;
    // calls-presence: "<name> is recording audio…" for the group
    final draft = await pickMediaDraft(context, _api, kind,
        onRecording: (on) => on
            ? _rt.recordingStarted('group', _gid)
            : _rt.recordingStopped('group', _gid));
    if (draft == null || !mounted) return;
    final job = await confirmAndQueueMedia(context, draft,
        chatKind: 'group',
        chatId: _gid,
        replyTo: _replyTo == null ? null : '${_replyTo!['id']}');
    if (job == null || !mounted) return;
    setState(() {
      _mediaJobs = [..._mediaJobs.where((j) => j.id != job.id), job];
      _replyTo = null;
    });
  }

  /// The media descriptor of a photo / voice / document message, decrypted
  /// on this phone (null for text or when it can't be decrypted here).
  MediaDescriptor? _mediaOf(Map<String, dynamic> msg) {
    final local = msg['md1_desc']; // md2: my finished send (local bubble)
    if (local is MediaDescriptor) return local;
    if (!kMd1Kinds.contains('${msg['content_type'] ?? 'text'}')) return null;
    final raw = _decryptRaw(msg);
    return raw == null ? null : MediaDescriptor.tryParse(raw);
  }

  void _openFile(File f, MediaDescriptor d) {
    if (d.kind == 'photo') {
      unawaited(openPhotoViewer(context, f, d));
    } else if (d.kind == 'document') {
      unawaited(openDocumentSheet(context, f, d));
    }
  }

  // ---- x2-ticks ----
  StreamSubscription<ReceiptUpdate>? _rcptSub;
  StreamSubscription<String>? _newSub;
  bool _seenPending = false;

  void _onReceipt(ReceiptUpdate u) {
    if (!mounted || u.chat != _chatKey) return;
    var changed = false;
    final next = [
      for (final m in _messages)
        if (m['mine'] == true && u.statuses['${m['id']}'] != null)
          () {
            final merged = mergeStatus(
                '${m['status'] ?? 'sent'}', u.statuses['${m['id']}']!);
            if (merged == '${m['status'] ?? 'sent'}') return m;
            changed = true;
            return {...m, 'status': merged};
          }()
        else
          m
    ];
    if (changed) setState(() => _messages = next);
  }

  /// Blue ✓✓ only when this chat is really on screen (route on top).
  bool get _visibleNow {
    if (!mounted) return false;
    final ls = WidgetsBinding.instance.lifecycleState;
    if (ls != null && ls != AppLifecycleState.resumed) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }
  // ---- /x2-ticks ----

  @override
  void dispose() {
    unawaited(PlainCache.instance.persist()); // e2e-recover
    DecorStore.instance.revision.removeListener(_onDecor); // cde-chat
    if (MsgActiveChat.current == _chatKey) MsgActiveChat.current = null;
    _poll?.cancel();
    MediaOutbox.instance.changes.removeListener(_onMediaJobs);
    _mediaSentSub?.cancel();
    _rcptSub?.cancel(); // x2-ticks
    _newSub?.cancel();
    _rt.states.removeListener(_onRt);
    _rt.typing('group', _gid, 'stop');
    _rt.release();
    _input.dispose();
    _inputFocus.dispose(); // db1
    _scroll.dispose();
    super.dispose();
  }

  void _onRt() {
    if (mounted) setState(() {});
  }

  Future<void> _markSeen() async {
    // e-gaps: never "seen" behind the chat lock
    if (ChatLockStore.instance.isLockedSync(_chatKey) &&
        !ChatLockSession.isChatOpen(_chatKey)) {
      return;
    }
    if (!_visibleNow) {
      _seenPending = true; // x2-ticks: covered / backgrounded → not read yet
      return;
    }
    _seenPending = false;
    UnreadStore.instance.clear(_chatKey);
    try {
      await _api.c3ChatSeen('group', _gid);
      BadgesBus.instance.poke(); // b2-badges: home badge re-fetch
    } catch (_) {
      // Retried on the next poll tick / reopen; the local badge is already 0.
    }
  }

  bool _pollBusy = false;
  Future<void> _pollMessages() async {
    if (_pollBusy || _loading || !mounted) return;
    final ls = WidgetsBinding.instance.lifecycleState;
    if (ls != null && ls != AppLifecycleState.resumed) return;
    _pollBusy = true;
    try {
      final msg = await _api
          .getJson('/circle/groups/$_groupId/messages?limit=$_pageSize');
      final next = _withOlder(((msg['results'] ?? msg['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>());
      final known = _messages.map((m) => '${m['id']}').toSet();
      final fresh = next.any((m) => m['mine'] != true && !known.contains('${m['id']}'));
      final changed = next.length != _messages.length ||
          fresh ||
          [for (var i = 0; i < next.length && i < _messages.length; i++) i]
              .any((i) => '${next[i]['status']}' != '${_messages[i]['status']}');
      if (changed && mounted) {
        setState(() {
          _messages = next;
          _pruneEchoes(); // md2: same frame as the server copy appearing
        });
        _foldControls(); // cde-chat
      }
      if (fresh || _seenPending) unawaited(_markSeen());
    } catch (_) {
    } finally {
      _pollBusy = false;
    }
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  String get _groupId => '${widget.group['id']}';

  /// The current user's role in this group (admin|member). Defaults to member.
  String get _myRole => '${widget.group['my_role'] ?? 'member'}';

  bool get _announcementsOnly => widget.group['announcements_only'] == true;

  /// In announcements-only mode only admins may post (mirrors
  /// core/logic/circle_groups.can_post).
  bool get _canPost => !_announcementsOnly || _myRole == 'admin';

  /// Keep the older pages already loaded (scroll-up) when the newest page
  /// is re-read.
  List<Map<String, dynamic>> _withOlder(List<Map<String, dynamic>> page) {
    if (page.isEmpty) return page;
    final oldest = int.tryParse('${page.first['id']}');
    if (oldest == null) return page;
    final ids = page.map((m) => '${m['id']}').toSet();
    final older = _messages.where((m) {
      final n = int.tryParse('${m['id']}');
      return n != null && n < oldest && !ids.contains('${m['id']}');
    }).toList();
    return [...older, ...page];
  }

  Future<void> _load() async {
    // e2e-recover: key ring + local plaintext cache, in parallel (never
    // delays the first frame); a rebuild re-opens what they unlock.
    final uid = context.read<AppState>().user?.id;
    unawaited(() async {
      try {
        final r = await IdentityVault.instance.ring();
        await PlainCache.instance.warm(uid);
        if (!mounted) return;
        setState(() => _ring = r);
      } catch (_) {} // best-effort: key ring is optional, chat still opens
    }());
    // Spinner only on the very first load — a reload after send/react/pin
    // keeps the list on screen (no flash, no jump).
    if (mounted && !_loading && !_loadedOnce) setState(() => _loading = true);
    try {
      final mem = await _api.getJson('/circle/groups/$_groupId/members');
      _members = ((mem['results'] ?? mem['members'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      final msg = await _api
          .getJson('/circle/groups/$_groupId/messages?limit=$_pageSize');
      final page = ((msg['results'] ?? msg['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      if (!_loadedOnce) {
        _messages = page;
        _hasMore = msg['has_more'] == true;
        final unseen = page.where((m) => m['unseen'] == true).toList();
        _unreadAtOpen = unseen.length;
        _firstUnreadId = unseen.isEmpty ? null : '${unseen.first['id']}';
        _p3UnreadFrom ??= _firstUnreadId; // p3: "summarize unread" anchor
        _positioned = _unreadAtOpen <= 3;
      } else {
        _messages = _withOlder(page);
      }
      _loadedOnce = true;
      _loadFailed = false;
      _pruneEchoes(); // md2
      _foldControls(); // cde-chat
    } catch (_) {
      // Keep any already-loaded messages visible; only flag the error so the
      // UI can offer Retry instead of silently showing an empty chat.
      _loadFailed = _messages.isEmpty;
    }
    if (mounted) {
      setState(() => _loading = false);
      if (!_positioned) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => unawaited(_placeAtDivider()));
      }
    }
  }

  /// My member id in this group, resolved from the roster (is_self) and falling
  /// back to the group-level my_member_id the backend attaches per viewer.
  String get _myMemberId {
    for (final m in _members) {
      if (m['is_self'] == true) return '${_idOf(m)}';
    }
    return '${widget.group['my_member_id'] ?? ''}';
  }

  /// Recipients = every ACTIVE member except me. Excludes my own roster row
  /// (is_self / my_member_id) rather than guessing by key_id, so I never
  /// encrypt a copy addressed to myself.
  List<Map<String, dynamic>> get _recipients {
    return _others
        .where((m) => '${m['public_key'] ?? ''}'.isNotEmpty)
        .toList();
  }

  /// Every other active member, with or without a published key.
  List<Map<String, dynamic>> get _others {
    final mine = _myMemberId;
    return _members
        .where((m) => m['is_self'] != true && '${_idOf(m)}' != mine)
        .toList();
  }

  /// e2-keys: re-read the roster (keys are LIVE from the per-user directory)
  /// and silently ask every keyless co-member's phone to publish. Never
  /// shown to the user.
  Future<void> _refreshRosterKeys() async {
    try {
      final mem = await _api
          .getJson('/circle/groups/$_groupId/members')
          .timeout(const Duration(seconds: 6));
      final next = ((mem['results'] ?? mem['members'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      if (next.isNotEmpty) _members = next;
    } catch (_) {}
    for (final m in _others.where((m) => '${m['public_key'] ?? ''}'.isEmpty)) {
      final uid = m['user_id'];
      if (uid == null) continue;
      unawaited(_api
          .postJson('/circle/keys/request', {'user_id': uid})
          .then((_) {}, onError: (_) {}));
      KeyService.instance.log.add('group $_gid: asked member $uid for key');
    }
  }

  /// Encrypt [plaintext] ONCE PER RECIPIENT (fallback fan-out) and POST a single
  /// envelope with a per_recipient ciphertext map. The server stores ciphertext
  /// only. Mirrors core/logic/circle_groups.build_group_fanout.
  Future<bool> _send({String? resendText, bool asCard = false}) async {
    final text = resendText ?? _input.text.trim();
    // db1: Send on an empty box opens the keyboard instead of doing nothing.
    if (text.isEmpty && resendText == null && !_sending && _canPost) {
      _inputFocus.requestFocus();
      return false;
    }
    if (text.isEmpty || _sending || !_canPost) return false;
    _rt.typing('group', _gid, 'stop');
    // p3: "@Assisto …" is a command to Assisto, never sent to the group.
    final p3i = (resendText == null && !asCard) ? parseAssisto(text) : null;
    if (p3i != null) {
      setState(() {
        _input.clear();
        _p3HintShown = false;
      });
      unawaited(_openAssisto(intent: p3i));
      return false;
    }
    setState(() {
      _sending = true;
      _failedText = null;
      _unreadAtOpen = 0;
      _firstUnreadId = null;
    });
    // e2-keys: keys re-read before each send; keyless members are asked
    // silently. If NOBODY can be encrypted to yet, wait briefly for the
    // background publish instead of showing a key error.
    await _refreshRosterKeys();
    for (var i = 0; i < 3 && _recipients.isEmpty && _others.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted) return false;
      await _refreshRosterKeys();
    }
    if (!mounted) return false;
    // §21: if there is no one to encrypt to, say so instead of a silent no-op.
    if (_others.isEmpty) {
      setState(() => _sending = false);
      _toast(_t.grpNoRecipients);
      return false;
    }
    if (_recipients.isEmpty) {
      // Still no key after the wait: the honest generic failed-send banner
      // (keeps the text, Retry) — never a key error.
      setState(() {
        _sending = false;
        if (!asCard) _failedText = text;
      });
      return false;
    }
    final perRecipient = <String, dynamic>{};
    final recipientIds = <int>[];
    var skipped = 0;
    for (final r in _recipients) {
      try {
        final pub = base64Decode('${r['public_key']}');
        final ct = _e2e.encrypt(
          self: widget.identity,
          recipientPublicKey: Uint8List.fromList(pub),
          plaintext: text,
        );
        final id = _idOf(r);
        recipientIds.add(id);
        perRecipient['$id'] = {
          'ciphertext': ct.ciphertextB64,
          'nonce': ct.nonceB64,
        };
      } catch (_) {
        skipped++;
      }
    }
    // e2-keys: a member whose key is broken/missing is asked silently (see
    // _refreshRosterKeys) — logged, never a toast.
    if (skipped > 0) {
      KeyService.instance.log.add('group $_gid: skipped $skipped recipient(s)');
    }
    final mentions = asCard ? const <int>[] : _parseMentions(text);
    var ok = true;
    final cmid = 'local-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final res = await _api.postJson('/circle/groups/$_groupId/messages', {
        'recipient_ids': recipientIds,
        'per_recipient': perRecipient,
        'sender_key_id': widget.identity.keyId,
        'scheme': _e2e.scheme,
        if (mentions.isNotEmpty) 'mentions': mentions,
        if (_replyTo != null && !asCard) 'reply_to': '${_replyTo!['id']}',
        'client_msg_id': cmid,
      });
      // md2: the sent text stays on screen (my bubble) until the reload /
      // poll lists its server copy — never a frame where it is missing.
      final sid = '${res['id'] ?? ''}';
      if (mounted) {
        _addEcho({
          'id': sid.isEmpty ? cmid : sid,
          'client_msg_id': cmid,
          'mine': true,
          'content_type': 'text',
          'md2_plain': text,
          'sender_id': _myUserId,
          'status': 'sent',
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
    } catch (_) {
      ok = false;
    }
    if (ok && !asCard) {
      _input.clear();
      _replyTo = null;
      _failedText = null;
    } else if (asCard) {
      // p3: a card never touches the draft / reply context
    } else {
      // §21 honest failed-send: keep the text so the user can resend, and
      // surface a failure banner (rendered above the composer).
      _failedText = text;
    }
    if (mounted) setState(() => _sending = false);
    if (ok) await _load();
    return ok;
  }

  /// Parse @mentions into MEMBER IDS (never names leave the device as plaintext
  /// routing — the server only gets ids).
  ///
  /// A token is resolved only on an EXACT (case-insensitive) name match against
  /// the roster — never a startsWith prefix, which could mention the wrong
  /// member (e.g. "@Sa" hitting "Sabrina" instead of "Sadia"). If a token is
  /// ambiguous (matches >1 member) or matches none, it is left as plain text.
  ///
  /// Works today from typed "@Name" text. Later UX upgrade (not a stub): an
  /// inline @-picker that inserts the member id directly, removing name
  /// collisions.
  List<int> _parseMentions(String text) {
    final out = <int>[];
    final re = RegExp(r'@([^\s@]+)');
    for (final match in re.allMatches(text)) {
      final token = match.group(1)!.toLowerCase();
      if (token.isEmpty) continue;
      final matches = _members
          .where((m) => '${m['name'] ?? ''}'.toLowerCase() == token)
          .toList();
      if (matches.length != 1) continue; // skip ambiguous / unmatched
      final id = _idOf(matches.first);
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }

  Future<void> _react(Map<String, dynamic> msg, String emoji) async {
    try {
      await _api.postJson(
          '/circle/groups/$_groupId/messages/${msg['id']}/react',
          {'emoji': emoji});
    } catch (e) {
      _fail(e);
    }
    await _load();
  }

  Future<void> _togglePin(Map<String, dynamic> msg) async {
    if (_myRole != 'admin') return; // admin-only (server re-enforces)
    final pinned = msg['pinned'] == true;
    try {
      await _api.postJson('/circle/groups/$_groupId/messages/${msg['id']}/pin',
          {'pin': !pinned});
    } catch (e) {
      _fail(e);
    }
    await _load();
  }

  Future<void> _call(String kind) async {
    // Group VOICE is free; group VIDEO requires a Premium initiator. The server
    // is the authority (can_place_group_call); the client shows the result.
    try {
      final r = await _api
          .postJson('/circle/groups/$_groupId/call', {'kind': kind});
      if (!mounted) return;
      if (r['allowed'] == false &&
          (r['upgrade_required'] == true || r['needs_video_plan'] == true)) {
        _showVideoUpgrade();
        return;
      }
      if (r['allowed'] == false) {
        _toast(_t.grpActionFailed);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t.circleGroupCallStarting)));
    } catch (e) {
      _fail(e);
    }
  }

  void _showVideoUpgrade() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.circleGroupVideoPremiumTitle),
        content: Text(_t.circleGroupVideoPremiumBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
          FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                // p2-money: paywall at the moment of need, with the reason
                PaywallSheet.show(context, PaywallReason.videoCall);
              },
              child: Text(_t.circleGroupGetPremium)),
        ],
      ),
    );
  }

  Future<void> _createPoll() async {
    final poll = await showCircleGroupPollComposer(context);
    if (poll == null || !mounted) return;
    // The question + option labels are USER TEXT -> encrypted per recipient,
    // like a message. The server tallies by option INDEX only (never reads a
    // label). Backend contract (core/logic/circle_groups.new_poll): a
    // per-recipient map keyed by member id —
    //   question_ct : { "<member_id>": {ciphertext,nonce} }
    //   options_ct  : { "<member_id>": [ {ciphertext,nonce}, ... ] }  (index-aligned)
    // which the backend stores as the GroupPoll question_ct / options_ct JSON.
    final questionCt = <String, dynamic>{};
    final optionsCt = <String, dynamic>{};
    final recipientIds = <int>[];
    for (final r in _recipients) {
      try {
        final pub = Uint8List.fromList(base64Decode('${r['public_key']}'));
        final id = _idOf(r);
        recipientIds.add(id);
        final q = _e2e.encrypt(
            self: widget.identity,
            recipientPublicKey: pub,
            plaintext: poll.question);
        questionCt['$id'] = {'ciphertext': q.ciphertextB64, 'nonce': q.nonceB64};
        final opts = <Map<String, dynamic>>[];
        for (var i = 0; i < poll.options.length; i++) {
          final o = _e2e.encrypt(
              self: widget.identity,
              recipientPublicKey: pub,
              plaintext: poll.options[i]);
          opts.add({'ciphertext': o.ciphertextB64, 'nonce': o.nonceB64});
        }
        optionsCt['$id'] = opts;
      } catch (_) {} // best-effort: a member whose key cannot encrypt is skipped, same as the message fan-out
    }
    try {
      await _api.postJson('/circle/groups/$_groupId/polls', {
        'recipient_ids': recipientIds,
        'option_count': poll.options.length,
        'multi': poll.multi,
        'question_ct': questionCt,
        'options_ct': optionsCt,
        'sender_key_id': widget.identity.keyId,
      });
    } catch (e) {
      _fail(e);
    }
    await _load();
  }

  Future<void> _vote(Map<String, dynamic> poll, List<int> choices) async {
    try {
      await _api.postJson('/circle/groups/$_groupId/polls/${poll['id']}/vote',
          {'choices': choices});
    } catch (e) {
      _fail(e);
    }
    await _load();
  }

  int _idOf(Map<String, dynamic> m) {
    final raw = m['id'] ?? m['member_id'] ?? 0;
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  void _openInfo() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleGroupInfoScreen(
        group: widget.group,
        identity: widget.identity,
        circleMembers: widget.circleMembers,
      ),
    )).then((_) => _load());
  }

  // -------------------------------------------------------------------------
  // GROUP CHAT ⋮ menu (group-flavoured mirror of the 1:1 chat ⋮). Every item
  // routes to a real handler below — no dead taps.
  // -------------------------------------------------------------------------
  Future<void> _openMenu() async {
    final action =
        await showGroupMenuSheet(context,
            isFavourite: _isFavourite,
            locked: ChatLockStore.instance.isLockedSync(_chatKey));
    if (action == null || !mounted) return;
    switch (action) {
      case GroupMenuAction.groupInfo:
        _openInfo();
      case GroupMenuAction.groupMedia:
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => GroupMediaScreen(groupId: _groupId)));
      case GroupMenuAction.search:
        setState(() => _searching = true);
      case GroupMenuAction.selectMessages:
        setState(() {
          _selecting = true;
          _selected.clear();
        });
      case GroupMenuAction.mute:
        await _chooseMute();
      case GroupMenuAction.disappearing:
        await _chooseDisappearing();
      case GroupMenuAction.chatTheme:
        await _chooseTheme();
      case GroupMenuAction.nicknames:
        await _nicknamesFlow();
      case GroupMenuAction.addToFavourites:
        await _toggleFavourite();
      case GroupMenuAction.exportChat:
        await _exportChat();
      case GroupMenuAction.lockChat:
        await toggleChatLock(context, _chatKey); // e-gaps
      case GroupMenuAction.sendCallLink:
        await _sendCallLink();
      case GroupMenuAction.scheduleCall:
        await _scheduleCall();
      case GroupMenuAction.newGroupCall:
        await _call('video'); // group video = Premium-gated at placement
      // p3: the E2E-safe @Assisto flow — shows exactly what is sent + its
      // credit cost and asks first (the old path sent every decrypted
      // message to the server without a notice).
      case GroupMenuAction.summarise:
        await _openAssisto(intent: const AssistoIntent(AssistoAction.summarize));
      case GroupMenuAction.makeReminder:
        await _openAssisto(intent: const AssistoIntent(AssistoAction.remind));
      case GroupMenuAction.translate:
        await _openAssisto(intent: const AssistoIntent(AssistoAction.translate));
      case GroupMenuAction.addMembers:
        _openInfo(); // add-members lives in Group info (circle-only, admin)
      case GroupMenuAction.exitGroup:
        await _exitGroup();
      case GroupMenuAction.reportGroup:
        await _reportGroup();
      case GroupMenuAction.clearChat:
        await _clearChat();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Honest failure: the server's own reason when it gave one, else a
  /// generic "couldn't do that". Never a fake "pending".
  void _fail(Object e) =>
      _toast(e is ApiException && e.message.isNotEmpty
          ? e.message
          : _t.grpActionFailed);

  Future<void> _chooseMute() async {
    final v = await showGroupOptionPicker(
      context,
      title: _t.grpMenuMute,
      current: '${widget.group['mute'] ?? 'off'}',
      options: [
        ('8h', _t.grpMute8h),
        ('1w', _t.grpMute1Week),
        ('always', _t.grpMuteAlways),
        if ('${widget.group['mute'] ?? 'off'}' != 'off')
          ('off', _t.msgGrpUnmute),
      ],
    );
    if (v == null) return;
    try {
      final r = await _api.groupSetMute(_groupId, v);
      setState(() => widget.group['mute'] = '${r['mute'] ?? v}');
      _toast(v == 'off' ? _t.msgGrpUnmuted : _t.grpMuted);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _chooseDisappearing() async {
    final v = await showGroupOptionPicker(
      context,
      title: _t.grpMenuDisappearing,
      current: '${widget.group['disappearing'] ?? 'off'}',
      options: [
        ('off', _t.grpDisappearOff),
        ('24h', _t.grpDisappear24h),
        ('7d', _t.grpDisappear7d),
        ('90d', _t.grpDisappear90d),
      ],
    );
    if (v == null || v == '${widget.group['disappearing'] ?? 'off'}') return;
    try {
      await _api.groupSetDisappearing(_groupId, v);
      setState(() {
        widget.group['disappearing'] = v;
        widget.group['disappearing_since'] =
            v == 'off' ? null : DateTime.now().toUtc().toIso8601String();
      });
      // e-gaps: every member's phone shows "X turned on ..." (E2E line)
      await _sendControl(ChatControl.timer(_timerSecOf(v),
          at: DateTime.now().millisecondsSinceEpoch));
      _toast(_t.grpDisappearingSet);
    } catch (e) {
      _fail(e);
    }
  }

  // ---- e-gaps: the group's disappearing timer on THIS phone --------------
  static const _kTimerTokens = {'off': 0, '24h': 86400, '7d': 604800, '90d': 7776000};
  static int _timerSecOf(String token) => _kTimerTokens[token] ?? 0;
  static String _timerTokenOf(int sec) => sec <= 0
      ? 'off'
      : sec <= 86400
          ? '24h'
          : sec <= 604800
              ? '7d'
              : '90d';

  /// Register what this chat shows under the timer (its decrypted files /
  /// preview are wiped on this phone at expiry) and sweep what is due.
  Future<void> _trackDisappearing() async {
    final sec = _timerSecOf('${widget.group['disappearing'] ?? 'off'}');
    final since = DateTime.tryParse('${widget.group['disappearing_since'] ?? ''}');
    if (sec > 0 && since != null) {
      for (final m in _messages) {
        final id = '${m['id'] ?? ''}';
        final at = DateTime.tryParse('${m['created_at'] ?? ''}');
        if (int.tryParse(id) == null || at == null || at.isBefore(since)) continue;
        await DisappearSweep.instance.track(
            _chatKey, id, at.add(Duration(seconds: sec)), media: _mediaOf(m));
      }
    }
    await DisappearSweep.instance.sweep();
  }

  // ---- cde-chat: shared theme + nicknames ---------------------------------
  /// The theme / nickname control inside a message (null for normal ones).
  ChatControl? _controlOf(Map<String, dynamic> msg) {
    final id = '${msg['id']}';
    if (_ctrlCache.containsKey(id)) return _ctrlCache[id];
    if ('${msg['deleted'] ?? ''}' == 'everyone' || msg['md1_job'] != null) return null;
    final ct = '${msg['content_type'] ?? 'text'}';
    if (ct != 'text' && ct != 'photo') return null;
    final raw = msg['md2_plain'] != null ? '${msg['md2_plain']}' : _decryptRaw(msg);
    if (raw == null) return null; // not decrypted (yet) — ask again later
    return _ctrlCache[id] = ct == 'photo'
        ? controlInDescriptor(raw)
        : (isControlText(raw) ? decodeControl(raw) : null);
  }

  void _foldControls() {
    ChatControl? newestTimer;
    for (final m in _messages) {
      final c = _controlOf(m);
      if (c == null) continue;
      if (c.isTimer) {
        // e-gaps: the newest timer line is the group's timer now
        if (newestTimer == null || c.at > newestTimer.at) newestTimer = c;
        continue;
      }
      unawaited(_decor.fold('${m['id']}', c,
          mine: m['mine'] == true, photo: _mediaOf(m)));
    }
    final tok = newestTimer == null ? null : _timerTokenOf(newestTimer.sec);
    if (tok != null && tok != '${widget.group['disappearing'] ?? 'off'}' && mounted) {
      setState(() => widget.group['disappearing'] = tok);
    }
    unawaited(_trackDisappearing()); // e-gaps
  }

  /// A member's REAL name by user id (roster), for system lines.
  String _realNameOf(int uid) {
    for (final m in _members) {
      if ((m['user_id'] as num?)?.toInt() == uid) return '${m['name'] ?? ''}';
    }
    return '';
  }

  String _myRealName() {
    final n = (context.read<AppState>().user?.name ?? '').trim();
    return n.isEmpty ? _t.p3You : n;
  }

  String _describe(Map<String, dynamic> msg, ChatControl c) {
    final sid = (msg['sender_id'] as num?)?.toInt();
    final real = sid == null ? '' : _realNameOf(sid);
    return describeControl(_t, c,
        mine: msg['mine'] == true,
        actor: real.isNotEmpty ? real : '${msg['sender_name'] ?? ''}',
        myUid: _myUserId,
        senderUid: sid,
        nameOf: _realNameOf);
  }

  Future<void> _sendControl(ChatControl c, {String target = ''}) async {
    await _sendCard(encodeControl(
        c, controlFallbackLine(_t, c, myName: _myRealName(), targetName: target)));
  }

  void _decorFailed(DecorFailure f, String fallback) {
    if (!mounted) return;
    if (f.premium) {
      unawaited(PaywallSheet.show(context, PaywallReason.generic));
      return;
    }
    _toast(f.message.isNotEmpty ? f.message : fallback);
  }

  /// cde-chat: the REAL shared theme (replaces the old per-user colour
  /// picker that nothing ever drew — see .phaseB/CDE_NOTES.md).
  Future<void> _chooseTheme() async {
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
        group: true,
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
        MediaDraft d;
        try {
          d = await _decor.makeAiPicture(prompt, ai);
        } finally {
          nav.pop();
        }
        if (!mounted) return;
        await _sendPhotoTheme(d, 'ai');
      } else {
        if (pick.id == cur) return;
        final c = await _decor.setPreset(pick.id);
        if (mounted) setState(() {});
        await _sendControl(c);
      }
    } on DecorFailure catch (f) {
      _decorFailed(f, pick.id == 'ai' ? _t.cdeThemeAiFailed : _t.cdeThemeFailed);
    } catch (_) {
      if (mounted) _toast(pick.id == 'ai' ? _t.cdeThemeAiFailed : _t.cdeThemeFailed);
    }
  }

  Future<void> _sendPhotoTheme(MediaDraft d, String id) async {
    final job = await _decor.setPhoto(d, id: id);
    if (!mounted) return;
    setState(() => _mediaJobs = [..._mediaJobs.where((j) => j.id != job.id), job]);
  }

  Future<void> _nicknamesFlow() async {
    final st = _decor.state;
    final rows = <NickRow>[
      for (final m in _members)
        if (m['user_id'] is num)
          NickRow(
            slot: groupSlot((m['user_id'] as num).toInt()),
            uid: (m['user_id'] as num).toInt(),
            realName: '${m['name'] ?? ''}',
            nick: st.nick(groupSlot((m['user_id'] as num).toInt())),
            isMe: m['is_self'] == true,
          ),
    ];
    if (rows.isEmpty) return;
    final edit = await showNicknamesSheet(context, rows);
    if (edit == null || !mounted) return;
    final (row, name) = edit;
    if (name == row.nick) return;
    try {
      final c = await _decor.setNick(uid: row.uid, name: name);
      if (mounted) setState(() {});
      await _sendControl(c, target: row.isMe ? '' : row.realName);
    } on DecorFailure catch (f) {
      _decorFailed(f, _t.cdeNickFailed);
    } catch (_) {
      if (mounted) _toast(_t.cdeNickFailed);
    }
  }

  /// The message area in the group's shared theme.
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

  Future<void> _toggleFavourite() async {
    final next = !_isFavourite;
    try {
      await _api.groupSetFavourite(_groupId, next);
      setState(() => widget.group['favourite'] = next);
      _toast(next ? _t.grpFavouriteAdded : _t.grpFavouriteRemoved);
    } catch (e) {
      _fail(e);
    }
  }

  /// Export: the server returns a SIGNED link to a JSON file of what it holds
  /// (metadata + my own ciphertext envelopes); this device decrypts it and
  /// shares the readable .txt. Plaintext never goes back to the server.
  Future<void> _exportChat() async {
    try {
      final r = await _api.groupExport(_groupId);
      final url = '${r['url'] ?? ''}';
      if (url.isEmpty) {
        _toast(_t.grpActionFailed);
        return;
      }
      final res = await http.get(Uri.parse(
          url.startsWith('http') ? url : '${AppConfig.apiBase}$url'));
      if (res.statusCode != 200) {
        _toast(_t.grpActionFailed);
        return;
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final text = buildGroupExportText(
        data,
        myUserId: _myUserId,
        decrypt: _decryptExportEnvelope,
        labels: GroupExportLabels(
          header: _t.msgExportHeader,
          unreadable: _t.msgExportUnreadable,
          deleted: _t.msgExportDeleted,
          media: _t.msgExportMedia,
          you: _t.msgExportYou,
        ),
      );
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/${exportFileName('${widget.group['name'] ?? ''}')}');
      await f.writeAsString(text);
      await Share.shareXFiles([XFile(f.path)]);
    } catch (e) {
      _fail(e);
    }
  }

  /// My User id (the roster row flagged is_self).
  int get _myUserId {
    for (final m in _members) {
      if (m['is_self'] == true) return (m['user_id'] as num?)?.toInt() ?? -1;
    }
    return -1;
  }

  String? _decryptExportEnvelope(
      Map<String, dynamic> env, int senderId, String senderKeyId) {
    try {
      // My own message: opened with MY key + the recipient's public key.
      final peerMember = env['peer_member_id'];
      Uint8List? pub;
      if (peerMember != null) {
        for (final m in _members) {
          if ('${m['member_id']}' == '$peerMember' && m['public_key'] != null) {
            pub = Uint8List.fromList(base64Decode('${m['public_key']}'));
          }
        }
      } else {
        pub = _senderPublicKey({'sender_id': senderId});
      }
      if (pub == null || env['ciphertext'] == null) return null;
      return _e2e.decrypt(
        self: widget.identity,
        senderPublicKey: pub,
        ct: Ciphertext(
          scheme: _e2e.scheme,
          ciphertextB64: '${env['ciphertext']}',
          nonceB64: '${env['nonce']}',
          senderKeyId: senderKeyId,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendCallLink() async {
    try {
      final r = await _api.groupCallLink(_groupId);
      final url = '${r['url'] ?? ''}';
      if (url.isNotEmpty) {
        await Share.share(url);
      } else {
        _toast(_t.grpActionFailed);
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _scheduleCall() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      initialDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    final at = DateTime(
        date.year, date.month, date.day, time.hour, time.minute);
    try {
      await _api.groupScheduleCall(_groupId, at: at.toUtc().toIso8601String());
      _toast(_t.grpCallScheduled);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _exitGroup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.grpMenuExitGroup),
        content: Text(_t.circleGroupLeaveConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.grpMenuExitGroup)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await _api.postJson('/circle/groups/$_groupId/leave', {});
      if (r['allowed'] == false || r['left'] == false) {
        _toast(_t.grpExitLastAdmin);
        return;
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      // LAST-ADMIN protection: the server answers 403 promote_before_leaving.
      if (e.status == 403) {
        _toast(_t.grpExitLastAdmin);
      } else {
        _fail(e);
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _reportGroup() async {
    // Funnels into the ONE moderation engine (/moderation/report) — no private
    // report path. The sheet collects categories + note and submits.
    await MsgrReportSheet.show(
      context,
      targetKind: ModTargets.group,
      targetId: _groupId,
    );
  }

  Future<void> _clearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.grpMenuClearChat),
        content: Text(_t.grpClearChatConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.grpMenuClearChat)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // Per-user marker on the server: hidden for me, kept for the others.
      await _api.groupClear(_groupId);
      if (mounted) setState(() => _messages = []);
    } catch (e) {
      _fail(e);
    }
  }

  // -------------------------------------------------------------------------
  // Select messages — multi-select then delete / forward / star / copy.
  // -------------------------------------------------------------------------
  void _toggleSelect(Map<String, dynamic> msg) {
    final id = '${msg['id']}';
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _exitSelect() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    // §21 confirm gate: deleting messages is destructive.
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.grpConfirmDeleteMsgsTitle),
        content: Text(_t.grpConfirmDeleteMsgsBody('$count')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.grpConfirmDelete)),
        ],
      ),
    );
    if (ok != true) return;
    var failed = 0;
    for (final id in _selected) {
      try {
        await _api
            .postJson('/circle/groups/$_groupId/messages/$id/delete', {});
      } catch (_) {
        failed++;
      }
    }
    _exitSelect();
    if (failed > 0) _toast(_t.grpActionFailed);
    await _load();
  }

  void _copySelected() {
    final text = _messages
        .where((m) => _selected.contains('${m['id']}'))
        .map((m) => _decryptForMe(m) ?? '')
        .where((s) => s.isNotEmpty)
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    _exitSelect();
    _toast(_t.copy);
  }

  Future<void> _starSelected() async {
    var failed = 0;
    for (final id in _selected) {
      try {
        await _api.postJson(
            '/circle/groups/$_groupId/messages/$id/star', {'starred': true});
      } catch (_) {
        failed++;
      }
    }
    _exitSelect();
    _toast(failed > 0 ? _t.grpActionFailed : _t.grpStarred);
  }

  // In-chat search over already-decrypted text (client-side).
  List<Map<String, dynamic>> get _visible {
    if (!_searching || _searchQuery.trim().isEmpty) return _messages;
    final terms = _searchQuery.toLowerCase().trim().split(RegExp(r'\s+'));
    return _messages.where((m) {
      final hay = (_decryptForMe(m) ?? '').toLowerCase();
      return terms.every((tk) => hay.contains(tk));
    }).toList();
  }

  PreferredSizeWidget _normalAppBar() => AppBar(
        titleSpacing: 0,
        // t1-ticks: WhatsApp-standard header — name line 1, line 2 = member
        // names ("Rahim, Karim, You") or "Rahim is typing…"; tap -> info.
        title: GroupHeaderTitle(
          name: '${widget.group['name'] ?? ''}',
          memberNames: [
            for (final m in _members)
              if (m['is_self'] != true && '${_idOf(m)}' != _myMemberId)
                '${m['name'] ?? ''}'
          ],
          activity: presenceLabel(_t, _rt.stateOf('group', _gid),
              lang: Localizations.localeOf(context).languageCode,
              isGroup: true),
          avatar: HeaderInitialAvatar(
              name: '${widget.group['name'] ?? ''}', group: true),
          onTap: _openInfo,
        ),
        actions: [
          IconButton(
            tooltip: _t.circleGroupVoiceCall,
            icon: const Icon(Icons.call_outlined),
            onPressed: () => _call('voice'),
          ),
          IconButton(
            tooltip: _t.circleGroupVideoCall,
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => _call('video'),
          ),
          IconButton(
            tooltip: _t.grpMenuMore,
            icon: const Icon(Icons.more_vert),
            onPressed: _openMenu,
          ),
        ],
      );

  PreferredSizeWidget _searchAppBar() => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _searching = false;
            _searchQuery = '';
          }),
        ),
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(
              hintText: _t.grpMenuSearch, border: InputBorder.none),
          onChanged: (v) => setState(() => _searchQuery = v),
        ),
      );

  PreferredSizeWidget _selectAppBar() => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelect,
        ),
        title: Text(_t.grpSelectedCount('${_selected.length}')),
        actions: [
          IconButton(
            tooltip: _t.copy,
            icon: const Icon(Icons.copy_outlined),
            onPressed: _selected.isEmpty ? null : _copySelected,
          ),
          IconButton(
            tooltip: _t.grpStar,
            icon: const Icon(Icons.star_border),
            onPressed: _selected.isEmpty ? null : _starSelected,
          ),
          IconButton(
            tooltip: _t.grpDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: _selected.isEmpty ? null : _deleteSelected,
          ),
        ],
      );

  /// e-gaps: a locked chat opened from outside its folder asks first.
  @override
  Widget build(BuildContext context) =>
      ChatLockGate(chatKey: _chatKey, child: Builder(builder: _buildChat));

  Widget _buildChat(BuildContext context) {
    final pinned =
        _messages.where((m) => m['pinned'] == true).toList();
    return Scaffold(
      appBar: _selecting
          ? _selectAppBar()
          : _searching
              ? _searchAppBar()
              : _normalAppBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? _errorRetry()
              : Column(
                  children: [
                    // t1-ticks: min-version gate (never blocks sending).
                    if (!_searching && _gid > 0)
                      McVersionBanner(api: _api, kind: 'group', chatId: _gid),
                    if (pinned.isNotEmpty && !_searching && !_selecting)
                      _pinnedBar(pinned),
                    Expanded(child: _themed(_messageList())), // cde-chat
                    if (_failedText != null && !_searching && !_selecting)
                      _failedSendBanner(),
                    if (_replyTo != null && !_searching && !_selecting)
                      _replyPreview(),
                    if (!_searching && !_selecting) _composer(),
                  ],
                ),
    );
  }

  /// §21 load error: honest message + Retry (keeps any messages already shown).
  Widget _errorRetry() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(_t.msgLoadFailed,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              onPressed: _load,
              label: Text(_t.grpRetry),
            ),
          ],
        ),
      ),
    );
  }

  /// §21 failed-send banner: shown when the last send failed. Offers Resend
  /// (re-encrypts + re-posts the kept text) so a transient failure is recoverable.
  Widget _failedSendBanner() {
    final scheme = Theme.of(context).colorScheme;
    final text = _failedText ?? '';
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.lg, vertical: Gap.sm),
        child: Row(
          children: [
            Icon(Icons.error_outline,
                size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(_t.grpSendFailed,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
            TextButton(
              onPressed: _sending
                  ? null
                  : () => _send(resendText: text),
              child: Text(_t.grpSendRetry),
            ),
            IconButton(
              tooltip: _t.close,
              icon: Icon(Icons.close,
                  size: 18, color: scheme.onErrorContainer),
              onPressed: () => setState(() => _failedText = null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pinnedBar(List<Map<String, dynamic>> pinned) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        children: [
          const Icon(Icons.push_pin_outlined, size: 16),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              _t.circleGroupPinnedCount('${pinned.length}'),
              style: Theme.of(context).textTheme.labelLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageList() {
    final searching = _searching && _searchQuery.trim().isNotEmpty;
    final have = _listedIds();
    final echoes = [
      for (final e in _echoes)
        if (!have.contains('${e['id']}') && !have.contains('${e['client_msg_id']}')) e
    ];
    final echoed = {for (final e in echoes) '${e['client_msg_id']}'};
    final items = [
      ..._visible,
      if (!searching) ...echoes,
      if (!searching)
        for (final j in _mediaJobs)
          if (!have.contains(j.id) && !echoed.contains(j.id))
            <String, dynamic>{
              'id': j.id,
              'md1_job': j,
              'mine': true,
              'created_at': j.at.toUtc().toIso8601String(),
            },
    ];
    if (items.isEmpty) {
      if (!_searching) {
        // t1-ticks: the E2E notice is the first history item, even when empty
        return Column(children: [
          const E2eNoticeChip(),
          Expanded(child: _emptyState()),
        ]);
      }
      return _emptyState();
    }
    return _historyList(items);
  }

  Widget _emptyState() {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          // QA a6: match the 1:1 chat's empty state (icon + text).
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_searching ? Icons.search_off : Icons.forum_outlined,
                size: 44,
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.7)),
            const SizedBox(height: Gap.md),
            Text(
                _searching ? _t.grpSearchNoResults : _t.circleGroupNoMessages,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
  }

  Widget _historyList(List<Map<String, dynamic>> items) {
    // e2-keys item 2: REVERSED — index 0 / offset 0 is the latest message,
    // so the group opens there without any scroll. Older pages are appended
    // at the end (= the top) on scroll-up, which keeps the position.
    final searching = _searching && _searchQuery.trim().isNotEmpty;
    final showDivider = !searching && _firstUnreadId != null && _unreadAtOpen > 0;
    final rev = items.where((m) => !_p3Hidden(m)).toList().reversed.toList(); // p3
    // t1-ticks: date chips + floating date while scrolling, interleaved into
    // the newest-first rows; the E2E notice is the OLDEST item once the whole
    // history is loaded.
    final rows = insertDateSeparators<Map<String, dynamic>>(rev,
        (m) => DateTime.tryParse('${m['created_at'] ?? m['at'] ?? ''}'),
        newestFirst: true, e2eNotice: !_searching && !_hasMore);
    return Opacity(
      opacity: _positioned ? 1 : 0,
      child: ChatDateScope(child: ListView.builder(
        key: const Key('e2-group-list'),
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.all(Gap.md),
        itemCount: rows.length + (_hasMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= rows.length) {
            return Padding(
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
          }
          return buildChatRow<Map<String, dynamic>>(rows[i], (msg) {
            final item = _messageItem(msg);
            if (showDivider && '${msg['id']}' == _firstUnreadId) {
              // reversed: the divider sits ABOVE the first unread message
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [_unreadDivider(), item],
              );
            }
            return item;
          });
        },
      )), // t1-ticks: /ChatDateScope
    );
  }

  Widget _unreadDivider() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: _dividerKey,
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Container(
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
  }

  /// Many unread: laid out hidden, jumped (no animation) so the divider is
  /// near the top, then shown — the user never sees a scroll.
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

  void _onScroll() {
    if (!_scroll.hasClients || _loadingOlder || !_hasMore) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) unawaited(_loadOlder());
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMore) return;
    final oldest = _messages
        .map((m) => int.tryParse('${m['id']}'))
        .whereType<int>()
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (oldest == null) return;
    setState(() => _loadingOlder = true);
    try {
      final r = await _api.getJson(
          '/circle/groups/$_groupId/messages?limit=$_pageSize&before=$oldest');
      final raw = ((r['results'] ?? r['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      final have = _messages.map((m) => '${m['id']}').toSet();
      final older = raw.where((m) => !have.contains('${m['id']}')).toList();
      if (!mounted) return;
      setState(() {
        _messages = [...older, ..._messages];
        _hasMore = r['has_more'] == true && older.isNotEmpty;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Widget _messageItem(Map<String, dynamic> msg) {
    final job = msg['md1_job'];
    // cde-chat: theme / nickname changes are centred system lines
    if (job is MediaJob && job.control != null) {
      return ChatSystemLine(text: _t.cdeThemeSending, icon: Icons.palette_outlined);
    }
    final cc = _controlOf(msg);
    if (cc != null) {
      return ChatSystemLine(
          text: _describe(msg, cc),
          icon: cc.isTheme
              ? Icons.palette_outlined
              : cc.isTimer
                  ? Icons.timer_outlined
                  : Icons.badge_outlined);
    }
    if (job is MediaJob) {
      // md1: a send still on its way (progress ring + cancel / retry)
      return Align(
        alignment: Alignment.centerRight,
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                MediaBubbleBody(
                    key: ValueKey('md1-job-${job.id}'),
                    job: job,
                    mine: true,
                    fg: Theme.of(context).colorScheme.onSurface),
                if (job.caption.isNotEmpty) Text(job.caption),
              ],
            ),
          ),
        ),
      );
    }
    // A poll message renders the poll widget; otherwise a decrypted text bubble.
    if (msg['kind'] == 'poll' || msg['poll'] != null) {
      final poll = (msg['poll'] as Map?)?.cast<String, dynamic>() ?? msg;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: CircleGroupPollCard(
          poll: poll,
          onVote: (choices) => _vote(poll, choices),
        ),
      );
    }
    final dec = _decryptForMe(msg);
    final text = dec ?? '';
    // p3: an Assisto card (E2E like any message)
    final p3c = _p3Card(msg);
    if (p3c != null) {
      return AssistoCardView(
        card: p3c,
        mine: msg['mine'] == true,
        senderName: _senderName(msg),
        ledger: _p3Ledger,
        onAddReminder: (c) => acceptReminderCard(context, c, _p3MyName, _sendCard),
        onTick: (c, i, on) => sendTick(c, i, on, _p3MyName, _sendCard, _t),
        onLongPress: _selecting ? null : () => _showActions(msg),
      );
    }
    final media = _mediaOf(msg); // md1
    // e2-keys: honest bubble when this device cannot decrypt it.
    final undecryptable = dec == null && '${msg['deleted'] ?? ''}' != 'everyone';
    final senderName = _senderName(msg);
    final announcement = msg['announcement'] == true;
    final selected = _selecting && _selected.contains('${msg['id']}');
    // p3: on-device scam warning under an incoming message
    final scam = (msg['mine'] == true || media != null || text.isEmpty)
        ? ScamVerdict.none
        : _p3Scam.putIfAbsent('${msg['id']}', () => checkScam(text));
    final bubble = GestureDetector(
      onLongPress: _selecting ? null : () => _showActions(msg),
      onTap: _selecting ? () => _toggleSelect(msg) : null,
      child: Card(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : announcement
                ? Theme.of(context).colorScheme.tertiaryContainer
                : null,
        margin: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (announcement) ...[
                    const Icon(Icons.campaign_outlined, size: 16),
                    const SizedBox(width: Gap.xs),
                  ],
                  Text(senderName,
                      style: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(
                              color: Theme.of(context).colorScheme.primary)),
                  if (msg['pinned'] == true) ...[
                    const SizedBox(width: Gap.xs),
                    const Icon(Icons.push_pin, size: 12),
                  ],
                ],
              ),
              const SizedBox(height: Gap.xs),
              if (msg['forwarded'] == true && '${msg['deleted'] ?? ''}' != 'everyone')
                Padding(
                  // md2: the WhatsApp "Forwarded" label in groups too
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.forward_outlined,
                        size: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 3),
                    Text(
                        ((msg['forward_hops'] as int?) ?? 0) >= 5
                            ? _t.circleForwardedMany
                            : _t.circleForwarded,
                        style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ]),
                ),
              if (media != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: MediaBubbleBody(
                    key: ValueKey('md1-${media.ref}'),
                    desc: media,
                    mine: msg['mine'] == true,
                    fg: Theme.of(context).colorScheme.onSurface,
                    onOpen: _selecting ? null : _openFile,
                  ),
                ),
              if (undecryptable)
                Text(e2rWaitingText(_t, msg['mine'] == true ? '' : senderName),
                    key: const Key('e2-cant-decrypt'),
                    style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context).colorScheme.onSurfaceVariant))
              else
                _highlightMentions(text),
              _reactionRow(msg),
              // c3-msg: ticks on my own messages (all members delivered /
              // read → ✓✓ / blue ✓✓; long-press → Info per member).
              if (msg['mine'] == true)
                Align(
                  alignment: Alignment.centerRight,
                  child: TickIcon(
                      tick: tickFrom('${msg['status'] ?? 'sent'}'),
                      baseColor: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
    if (!scam.flagged) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [bubble, ScamWarningBanner(verdict: scam)],
    );
  }

  /// Render @mentions with emphasis (over already-decrypted text).
  Widget _highlightMentions(String text) {
    final spans = <TextSpan>[];
    final re = RegExp(r'(@[^\s@]+)');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(TextSpan(
        text: m.group(0),
        style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return RichText(
      text: TextSpan(
        style: Theme.of(context).textTheme.bodyMedium,
        children: spans,
      ),
    );
  }

  Widget _reactionRow(Map<String, dynamic> msg) {
    final reactions =
        (msg['reactions'] as Map?)?.cast<String, dynamic>() ?? {};
    if (reactions.isEmpty) return const SizedBox.shrink();
    final counts = <String, int>{};
    for (final v in reactions.values) {
      counts['$v'] = (counts['$v'] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Wrap(
        spacing: Gap.xs,
        children: [
          for (final e in counts.entries)
            Chip(
              label: Text('${e.key} ${e.value}'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
    );
  }

  void _showActions(Map<String, dynamic> msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Wrap(
                spacing: Gap.md,
                children: [
                  for (final e in _decor.themeDef?.reactions ??
                      const ['👍', '❤️', '😂', '😮', '😢', '🙏'])
                    InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _react(msg, e);
                      },
                      child: Text(e, style: const TextStyle(fontSize: 28)),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.reply_outlined),
              title: Text(_t.circleReply),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyTo = msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: Text(_t.copy),
              onTap: () {
                Clipboard.setData(
                    ClipboardData(text: _decryptForMe(msg) ?? ''));
                Navigator.pop(ctx);
              },
            ),
            if ('${msg['deleted'] ?? ''}' != 'everyone' &&
                (_mediaOf(msg) != null || (_decryptForMe(msg) ?? '').isNotEmpty))
              ListTile(
                key: const Key('md2-group-forward'),
                leading: const Icon(Icons.forward_outlined),
                title: Text(_t.circleActionForward),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_forward(msg));
                },
              ),
            if (msg['mine'] == true)
              ListTile(
                key: const Key('c3-group-info'),
                leading: const Icon(Icons.info_outline),
                title: Text(_t.c3InfoTitle),
                onTap: () {
                  Navigator.pop(ctx);
                  showMessageInfoSheet(
                      context, () => _api.c3MessageInfo('${msg['id']}'));
                },
              ),
            if (_myRole == 'admin')
              ListTile(
                leading: Icon(msg['pinned'] == true
                    ? Icons.push_pin
                    : Icons.push_pin_outlined),
                title: Text(msg['pinned'] == true
                    ? _t.circleGroupUnpin
                    : _t.circleGroupPin),
                onTap: () {
                  Navigator.pop(ctx);
                  _togglePin(msg);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _replyPreview() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        children: [
          const Icon(Icons.reply, size: 16),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              _decryptForMe(_replyTo!) ?? _t.circleReply,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    if (!_canPost) {
      return SafeArea(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.lg),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.campaign_outlined, size: 18),
              const SizedBox(width: Gap.sm),
              Flexible(
                child: Text(_t.circleGroupOnlyAdminsPost,
                    style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
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
        padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.xs),
        child: Row(
          children: [
            if (_canAttach)
              IconButton(
                key: const Key('md1-group-attach'),
                tooltip: _t.circleAttach,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: _attach,
              ),
            IconButton(
              tooltip: _t.circleGroupCreatePoll,
              icon: const Icon(Icons.poll_outlined),
              onPressed: _createPoll,
            ),
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus, // db1
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                onChanged: (v) {
                  // p3: show / hide the @Assisto hint as the user types
                  final hint = hasAssistoMention(v) || isTypingMention(v);
                  if (hint != _p3HintShown) setState(() => _p3HintShown = hint);
                  if (v.trimLeft().toLowerCase().startsWith('@assisto')) return;
                  _rt.typing('group', _gid, v.trim().isEmpty ? 'stop' : 'typing');
                },
                decoration: InputDecoration(
                  hintText: _t.circleGroupMessageHint,
                  border: const OutlineInputBorder(
                      borderRadius:
                          BorderRadius.all(Radius.circular(Radii.pill))),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: Gap.lg, vertical: Gap.sm),
                ),
              ),
            ),
            // p3: the Assisto button (same actions as typing "@Assisto")
            IconButton(
              key: const ValueKey('p3-assisto-btn'),
              icon: const Icon(Icons.auto_awesome_outlined),
              tooltip: _t.p3Assisto,
              onPressed: () => _openAssisto(),
            ),
            IconButton.filled(
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
      ]),
    );
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

  AssistoCard? _p3Card(Map<String, dynamic> msg) {
    if ('${msg['deleted'] ?? ''}' == 'everyone' || _mediaOf(msg) != null) return null;
    final id = '${msg['id']}';
    if (_p3Cards.containsKey(id)) return _p3Cards[id];
    final dec = _decryptForMe(msg);
    if (dec == null) return null; // not decryptable yet: decide again later
    return _p3Cards[id] = isCardText(dec) ? decodeCard(dec) : null;
  }

  bool _p3Hidden(Map<String, dynamic> msg) => _p3Card(msg)?.hidden ?? false;

  DateTime _p3At(Map<String, dynamic> m) =>
      DateTime.tryParse('${m['created_at'] ?? m['at'] ?? ''}') ?? DateTime.now();

  CardLedger get _p3Ledger => CardLedger.fold([
        for (final m in _messages)
          if (_p3Card(m) case final c?)
            CardEvent(c, _senderName(m), m['mine'] == true, _p3At(m)),
      ]);

  bool _p3Readable(Map<String, dynamic> m) {
    if (_mediaOf(m) != null || '${m['deleted'] ?? ''}' == 'everyone') return false;
    final d = _decryptForMe(m);
    return d != null && d.isNotEmpty && _p3Card(m) == null;
  }

  Map<String, String> _p3Line(Map<String, dynamic> m) => {
        'from': m['mine'] == true ? _p3MyName : _senderName(m),
        'text': _decryptForMe(m) ?? '',
      };

  AssistoChatPort get _p3Port => AssistoChatPort(
        isGroup: true,
        chatName: '${widget.group['name'] ?? ''}',
        myName: _p3MyName,
        memberNames: [
          for (final m in _members)
            if (m['is_self'] != true && '${_idOf(m)}' != _myMemberId &&
                '${m['name'] ?? ''}'.trim().isNotEmpty)
              '${m['name']}'
        ],
        unread: () {
          final from = _p3UnreadFrom;
          if (from == null) return const [];
          final i = _messages.indexWhere((m) => '${m['id']}' == from);
          if (i < 0) return const [];
          return [
            for (final m in _messages.skip(i))
              if (m['mine'] != true && _p3Readable(m)) _p3Line(m),
          ];
        },
        recent: () {
          final r = [for (final m in _messages) if (_p3Readable(m)) _p3Line(m)];
          return r.length > 40 ? r.sublist(r.length - 40) : r;
        },
        draft: () => _input.text,
        setDraft: (v) => setState(() {
          _input.text = v;
          _input.selection = TextSelection.collapsed(offset: v.length);
        }),
        lastIncoming: () {
          for (final m in _messages.reversed) {
            if (m['mine'] != true && _p3Readable(m)) return _decryptForMe(m) ?? '';
          }
          return '';
        },
        send: _sendCard,
      );

  Future<void> _openAssisto({AssistoIntent? intent}) async {
    if (!_canPost) return;
    await showAssistoMenu(context, _p3Port, intent: intent);
  }

  /// Send an Assisto card / event to the group: the same per-recipient E2E
  /// fan-out as a text message. The draft and reply context are untouched.
  Future<bool> _sendCard(String plaintext) =>
      _send(resendText: plaintext, asCard: true);

  String _senderName(Map<String, dynamic> msg) {
    final sid = '${msg['sender_id'] ?? ''}';
    // cde-chat: the group's nickname for this person first
    final uid = int.tryParse(sid);
    if (uid != null) {
      final nick = _decor.state.nick(groupSlot(uid));
      if (nick.isNotEmpty) return nick;
      final real = _realNameOf(uid);
      if (real.isNotEmpty) return real;
    }
    for (final m in _members) {
      if ('${_idOf(m)}' == sid) return '${m['name'] ?? ''}';
    }
    return '${msg['sender_name'] ?? ''}';
  }

  /// Decrypt the per-recipient blob addressed to me. The fallback fan-out ships
  /// a per_recipient map; my entry is keyed by my member id. On MLS this would
  /// be a single group ciphertext decrypted with the group key.
  /// Text of a message for display / copy / search: for md1 media the
  /// caption (never the descriptor with its file key).
  String? _decryptForMe(Map<String, dynamic> msg) {
    final local = msg['md1_desc']; // md2: local bubbles of my own sends
    if (local is MediaDescriptor) return local.caption;
    if (msg['md2_plain'] != null) return '${msg['md2_plain']}';
    final raw = _decryptRaw(msg);
    if (raw == null) return null;
    if (kMd1Kinds.contains('${msg['content_type'] ?? 'text'}')) {
      final d = MediaDescriptor.tryParse(raw);
      return d?.caption;
    }
    return raw;
  }

  // e2e-recover: every private key of this phone (current first).
  List<IdentityKeyPair> _ring = const [];

  String? _decryptRaw(Map<String, dynamic> msg) {
    final ck = '${msg['id']}|${msg['deleted'] ?? ''}';
    final hit = _ptCache[ck];
    if (hit != null) return hit;
    // e2e-recover: every key of my key ring (old keys after a restore),
    // then this phone's cache of what it already opened once.
    String? pt;
    for (final me in [
      widget.identity,
      ..._ring.where((k) => k.keyId != widget.identity.keyId),
    ]) {
      pt = _decryptUncached(msg, me);
      if (pt != null) break;
    }
    final mid = '${msg['id'] ?? ''}';
    final gone = '${msg['deleted'] ?? ''}' == 'everyone' ||
        msg['view_once'] == true;
    if (pt == null && !gone) pt = PlainCache.instance.get(mid);
    if (pt != null && !gone && !descriptorIsViewOnce(pt)) {
      PlainCache.instance.put(mid, pt);
    }
    if (pt != null) _ptCache[ck] = pt;
    return pt;
  }

  String? _decryptUncached(Map<String, dynamic> msg, IdentityKeyPair me) {
    try {
      final per = (msg['per_recipient'] as Map?)?.cast<String, dynamic>();
      // Resolve MY entry only: prefer the per-message my_member_id, else the
      // roster-derived id. NEVER fall back to another recipient's blob — that
      // is sealed to a different key and can only fail (and would be a privacy
      // smell). Fail to null loudly in debug so a mis-keyed fan-out is visible.
      final myId = '${msg['my_member_id'] ?? _myMemberId}';
      Map<String, dynamic>? blob;
      // c3-msg: MY OWN group message has no blob addressed to me (I never
      // encrypt to myself) — it used to render blank. ECDH is symmetric, so
      // any recipient's blob decrypts with THAT recipient's public key.
      if (msg['mine'] == true && per != null && per.isNotEmpty) {
        for (final e in per.entries) {
          final r = _members.firstWhere(
              (m) => '${_idOf(m)}' == e.key && '${m['public_key'] ?? ''}'.isNotEmpty,
              orElse: () => const {});
          if (r.isEmpty || e.value is! Map) continue;
          final b = (e.value as Map).cast<String, dynamic>();
          final pt = _e2e.decrypt(
            self: me,
            senderPublicKey: Uint8List.fromList(base64Decode('${r['public_key']}')),
            ct: Ciphertext(
              scheme: '${msg['scheme'] ?? _e2e.scheme}',
              ciphertextB64: '${b['ciphertext']}',
              nonceB64: '${b['nonce']}',
              senderKeyId: '${msg['sender_key_id'] ?? ''}',
            ),
          );
          if (pt != null) return pt;
        }
        return null;
      }
      if (per != null && per.isNotEmpty) {
        blob = (per[myId] as Map?)?.cast<String, dynamic>();
        if (blob == null && kDebugMode) {
          debugPrint(
              'circle_group_chat: no per_recipient blob for my_member_id=$myId '
              '(keys=${per.keys.toList()}) — dropping to null, not decrypting '
              "another recipient's envelope.");
        }
      } else {
        blob = {
          'ciphertext': msg['ciphertext'],
          'nonce': msg['nonce'],
        };
      }
      if (blob == null || blob['ciphertext'] == null) return null;
      final senderPub = _senderPublicKey(msg);
      if (senderPub == null) return null;
      final pt = _e2e.decrypt(
        self: me,
        senderPublicKey: senderPub,
        ct: Ciphertext(
          scheme: '${msg['scheme'] ?? _e2e.scheme}',
          ciphertextB64: '${blob['ciphertext']}',
          nonceB64: '${blob['nonce']}',
          senderKeyId: '${msg['sender_key_id'] ?? ''}',
        ),
      );
      return pt;
    } catch (_) {
      return null;
    }
  }

  Uint8List? _senderPublicKey(Map<String, dynamic> msg) {
    final sid = '${msg['sender_id'] ?? ''}';
    for (final m in _members) {
      // sender_id is a USER id; the roster carries it as user_id.
      if ('${m['user_id'] ?? _idOf(m)}' == sid && '${m['public_key'] ?? ''}'.isNotEmpty) {
        try {
          return Uint8List.fromList(base64Decode('${m['public_key']}'));
        } catch (_) {}
      }
    }
    return null;
  }
}
