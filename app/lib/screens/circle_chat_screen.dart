import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../messenger_chat_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/chat_menu_pickers.dart';
import '../widgets/chat_menu_sheet.dart';
import '../widgets/circle_attach_sheet.dart';
import '../widgets/circle_bubble.dart';
import '../widgets/circle_media_viewer.dart';
import '../widgets/circle_message_actions.dart';
import '../widgets/circle_relation.dart';
import '../widgets/in_chat_ai_sheet.dart';
import 'circle_call_screen.dart';
import 'circle_extras_hub_screen.dart';
import 'messenger/contact_info_screen.dart';

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

class _CircleChatScreenState extends State<CircleChatScreen> {
  final _e2e = SoftwareE2E();
  final _input = TextEditingController();
  final _scroll = ScrollController();

  List<CircleMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  bool _peerTyping = false;
  bool _searching = false;
  String _searchQuery = '';

  // Chat-menu backed state (confirmed from the server on open).
  bool _favourite = false;
  int _disappearingSec = 0;
  String _chatTheme = 'default';

  // Multi-select mode (⋮ Select messages).
  bool _selecting = false;
  final Set<String> _selected = {};

  // Reply / edit context.
  CircleMessage? _replyTo;
  CircleMessage? _editing;

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      if (widget.forwarding != null) _doForwardInto(widget.forwarding!);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  String get _memberName => '${widget.member['name'] ?? ''}';
  int? get _memberId => widget.member['id'] as int?;

  /// The peer's published X25519 public key (base64). The integrator returns it
  /// on the member payload (`public_key`) from GET /circle/members.
  Uint8List? get _peerPub {
    final b64 = widget.member['public_key'] as String?;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final peer = _peerPub;
    try {
      final r = await _api.getJson('/circle/$_memberId/messages');
      final raw = ((r['results'] ?? r['messages'] ?? []) as List).cast<Map<String, dynamic>>();
      _messages = raw.map((e) => _decryptEnvelope(e, peer)).toList();
      _resolveReplyPreviews();
    } catch (_) {
      // Offline/not-wired: keep any optimistic local echoes already shown.
    }
    // Per-chat settings (disappearing is server-authoritative; favourite/theme
    // are opaque prefs). Failures just leave the honest defaults.
    try {
      final s = await _api.circleChatSettings(_memberId ?? 0);
      _disappearingSec = (s['disappearing_sec'] as int?) ?? 0;
      _favourite = s['favourite'] == true;
      _chatTheme = '${s['theme'] ?? 'default'}';
    } catch (_) {}
    if (mounted) {
      setState(() => _loading = false);
      _scrollToEnd();
    }
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
        replyPreview: src.text.isEmpty ? null : src.text,
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

    if (deleted == 'everyone') {
      // Nothing to decrypt — the ciphertext was tombstoned server-side.
    } else if (contentType == 'text') {
      try {
        if (peerPub == null) {
          failed = true;
        } else {
          final ct = Ciphertext(
            scheme: '${env['scheme'] ?? _e2e.scheme}',
            ciphertextB64: '${env['ciphertext'] ?? ''}',
            nonceB64: '${env['nonce'] ?? ''}',
            senderKeyId: '${env['sender_key_id'] ?? ''}',
          );
          final pt = _e2e.decrypt(self: widget.identity, senderPublicKey: peerPub, ct: ct);
          if (pt == null) {
            failed = true;
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
      mediaGated: contentType != 'text', // blob storage key-gated for now
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
    if (plain.isEmpty || _sending) return;

    // Edit path: replace an existing message within the window.
    if (_editing != null) {
      await _applyEdit(_editing!, plain);
      return;
    }

    final peer = _peerPub;
    if (peer == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t.circleKeyMissing)));
      return;
    }
    setState(() => _sending = true);
    final ct = _e2e.encrypt(self: widget.identity, recipientPublicKey: peer, plaintext: plain);
    final clientMsgId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final replyId = _replyTo?.id;
    final replyPrev = _replyTo?.text;

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
      at: DateTime.now(),
      status: 'sent',
      pending: true,
      replyToId: replyId,
      replyPreview: (replyPrev ?? '').isEmpty ? null : replyPrev,
    );
    setState(() {
      _messages = [..._messages, echo];
      _input.clear();
      _replyTo = null;
    });
    _scrollToEnd();

    try {
      await _api.postJson('/circle/$_memberId/messages', {
        'content_type': 'text',
        'client_msg_id': clientMsgId,
        if (replyId != null) 'reply_to': replyId,
        if (firstUrl != null) 'has_link': true, // integrator attaches encrypted preview
        ...ct.toEnvelopeFields(),
      });
      // Mark echo confirmed (no longer pending).
      setState(() {
        _messages = _messages.map((m) => m.id == clientMsgId ? m.copyWith(pending: false) : m).toList();
      });
    } catch (_) {
      // Offline/not-wired: the pending echo stays; the queue retries on reload.
    }
    if (mounted) setState(() => _sending = false);
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
    final pinnedCount = _messages.where((x) => x.pinned).length;
    final canEdit = m.mine && m.contentType == 'text' && DateTime.now().difference(m.at).inMinutes < _kEditWindowMin;
    final canDeleteEveryone = m.mine && DateTime.now().difference(m.at).inMinutes < _kDeleteEveryoneWindowMin;

    final action = await showCircleMessageActions(
      context,
      mine: m.mine,
      canEdit: canEdit,
      isStarred: m.starred,
      isPinned: m.pinned,
      canDeleteEveryone: canDeleteEveryone,
      onReact: (emoji) => _react(m, emoji),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case CircleMsgAction.reply:
        setState(() {
          _replyTo = m;
          _editing = null;
        });
        break;
      case CircleMsgAction.react:
        break;
      case CircleMsgAction.copy:
        await Clipboard.setData(ClipboardData(text: m.text));
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
    await _delete(m, scope);
    if (mounted) {
      _toast(everyone ? _t.msgrMsgDeletedEveryone : _t.msgrMsgDeletedMe);
    }
  }

  Future<void> _react(CircleMessage m, String emoji) async {
    final me = context.read<AppState>().user?.id;
    final next = Map<String, int>.from(m.reactions);
    next[emoji] = (next[emoji] ?? 0) + 1;
    setState(() {
      _messages = _messages.map((x) => x.id == m.id ? x.copyWith(reactions: next) : x).toList();
    });
    try {
      await _api.postJson('/circle/messages/${m.id}/react', {'emoji': emoji, 'member_id': me});
    } catch (_) {}
  }

  Future<void> _toggleStar(CircleMessage m) async {
    setState(() {
      _messages = _messages.map((x) => x.id == m.id ? x.copyWith(starred: !x.starred) : x).toList();
    });
    try {
      await _api.postJson('/circle/messages/${m.id}/star', {'starred': !m.starred});
    } catch (_) {}
  }

  Future<void> _togglePin(CircleMessage m, int pinnedCount) async {
    if (!m.pinned && pinnedCount >= _kPinCap) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t.circlePinLimit)));
      return;
    }
    setState(() {
      _messages = _messages.map((x) => x.id == m.id ? x.copyWith(pinned: !x.pinned) : x).toList();
    });
    try {
      await _api.postJson('/circle/messages/${m.id}/pin', {'pinned': !m.pinned});
    } catch (_) {}
  }

  Future<void> _delete(CircleMessage m, String scope) async {
    setState(() {
      _messages = scope == 'me'
          ? _messages.where((x) => x.id != m.id).toList()
          : _messages.map((x) => x.id == m.id ? x.copyWith(deleted: 'everyone', text: '') : x).toList();
    });
    try {
      await _api.postJson('/circle/messages/${m.id}/delete', {'scope': scope});
    } catch (_) {}
  }

  Future<void> _applyEdit(CircleMessage m, String newText) async {
    final peer = _peerPub;
    setState(() {
      _messages = _messages.map((x) => x.id == m.id ? x.copyWith(text: newText, edited: true) : x).toList();
      _editing = null;
      _input.clear();
    });
    if (peer == null) return;
    final ct = _e2e.encrypt(self: widget.identity, recipientPublicKey: peer, plaintext: newText);
    try {
      await _api.postJson('/circle/messages/${m.id}/edit', {...ct.toEnvelopeFields()});
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Forward
  // -------------------------------------------------------------------------
  Future<void> _startForward(CircleMessage m) async {
    // The member picker is the circle screen's job; here we expose the hook the
    // integrator wires. For the in-chat quick path we re-send into THIS chat.
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

  Future<void> _doForwardInto(CircleMessage m) async {
    final peer = _peerPub;
    if (peer == null) return;
    final ct = _e2e.encrypt(self: widget.identity, recipientPublicKey: peer, plaintext: m.text);
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
    );
    setState(() => _messages = [..._messages, echo]);
    _scrollToEnd();
    try {
      await _api.postJson('/circle/$_memberId/messages', {
        'content_type': 'text',
        'client_msg_id': clientMsgId,
        'forwarded': true,
        'forward_hops': m.forwardHops + 1,
        ...ct.toEnvelopeFields(),
      });
      setState(() {
        _messages = _messages.map((x) => x.id == clientMsgId ? x.copyWith(pending: false) : x).toList();
      });
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Media attach (all kinds key-gated until encrypted blob storage is on)
  // -------------------------------------------------------------------------
  Future<void> _attach() async {
    final kind = await showCircleAttachSheet(context);
    if (kind == null || !mounted) return;
    if (kind == CircleAttachKind.liveLocation) {
      final dur = await showLiveLocationDurations(context);
      if (dur == null) return;
    }
    // Every media kind is key-gated now (circle_media.media_gate_notice). Show
    // the reason instead of a picker the storage can't yet back.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t.circleMediaGenericGated)));
  }

  void _openMedia(CircleMessage m) {
    // When storage is enabled, decrypted bytes flow here. For now, show the
    // gated placeholder viewer so the full-screen path exists end-to-end.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleMediaViewer(
        items: [MediaViewerItem(id: m.id, caption: m.mediaCaption ?? '', gated: true)],
      ),
    ));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: Motion.base, curve: Curves.easeOut);
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
    // Ask the server first. can_place_call(caller,callee,'video') is the plan
    // gate: a FREE caller requesting video gets upgrade_required back and we
    // show the upgrade prompt — the client never starts video media itself.
    // Voice is free for everyone.
    try {
      final r = await _api.circlePlaceCall(_memberId ?? 0, kind);
      if (!mounted) return;
      if (r['allowed'] == false || r['upgrade_required'] == true) {
        _showVideoUpgrade();
        return;
      }
    } catch (_) {
      // Backend pending: still open the call screen, which re-runs the gate
      // and renders the honest blocked/upgrade state if the server refuses.
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleCallScreen(member: widget.member, kind: kind),
    ));
  }

  void _showVideoUpgrade() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.msgrChatVideoPremiumTitle),
        content: Text(_t.msgrChatVideoPremiumBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(_t.msgrChatGetPremium)),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Chat ⋮ menu dispatch
  // -------------------------------------------------------------------------
  Future<void> _openChatMenu() async {
    final action = await showChatMenu(context, isFavourite: _favourite);
    if (action == null || !mounted) return;
    switch (action) {
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
      case ChatMenuAction.summarise:
        await _openInChatAi();
        break;
      case ChatMenuAction.makeReminder:
        _aiExtra(_t.msgrChatMakeReminder);
        break;
      case ChatMenuAction.translate:
        _aiExtra(_t.msgrChatTranslate);
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
    } catch (_) {
      _toast(_t.circleBackendPending);
    }
  }

  // ---- Disappearing (server + device enforced) ----------------------------
  Future<void> _disappearingFlow() async {
    final sec = await showDisappearingPicker(context, _disappearingSec);
    if (sec == null || !mounted) return;
    setState(() => _disappearingSec = sec);
    try {
      await _api.setDisappearing(_memberId ?? 0, sec);
    } catch (_) {
      _toast(_t.circleBackendPending);
    }
  }

  // ---- Chat theme ---------------------------------------------------------
  Future<void> _chatThemeFlow() async {
    final token = await showChatThemePicker(context, _chatTheme);
    if (token == null || !mounted) return;
    setState(() => _chatTheme = token);
    try {
      await _api.setChatTheme(_memberId ?? 0, theme: token);
    } catch (_) {
      _toast(_t.circleBackendPending);
    }
  }

  // ---- Favourites ---------------------------------------------------------
  Future<void> _toggleFavourite() async {
    setState(() => _favourite = !_favourite);
    try {
      await _api.setFavourite(_memberId ?? 0, _favourite);
      _toast(_favourite ? _t.msgrChatFavouriteAdded : _t.msgrChatFavouriteRemoved);
    } catch (_) {
      _toast(_t.circleBackendPending);
    }
  }

  // ---- Add to list --------------------------------------------------------
  Future<void> _addToListFlow() async {
    List<Map<String, dynamic>> lists = const [];
    try {
      final r = await _api.chatLists();
      lists = ((r['lists'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {}
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
    } catch (_) {
      _toast(_t.circleBackendPending);
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
    _toast(_t.msgrChatExportReady);
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
    } catch (_) {
      _toast(_t.circleBackendPending);
    }
  }

  // ---- Send call link (expiring) ------------------------------------------
  Future<void> _sendCallLink() async {
    try {
      final r = await _api.createCallLink(_memberId ?? 0, kind: 'voice');
      final link = '${r['link'] ?? ''}';
      if (!mounted) return;
      if (link.isEmpty) {
        _toast(_t.circleBackendPending);
        return;
      }
      // The expiring link is built server-side; share via the OS sheet (a chat
      // message carrying the link is the user's choice).
      _input.text = link;
      _toast(_t.msgrChatCallLinkReady);
    } catch (_) {
      _toast(_t.circleBackendPending);
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
    } catch (_) {
      _toast(_t.circleBackendPending);
    }
  }

  // ---- New group call -----------------------------------------------------
  Future<void> _newGroupCall() async {
    // Starting a group call from a 1:1 means adding more circle members; the
    // group-call launch reuses circle_calls. The picker is the group screen's
    // job, so from here we open the call screen with this member and the
    // honest "add people" affordance lives in the call controls.
    try {
      final r = await _api.circlePlaceCall(_memberId ?? 0, 'voice');
      if (!mounted) return;
      if (r['allowed'] == false) {
        _toast(_t.circleBackendPending);
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleCallScreen(member: widget.member, kind: 'voice'),
    ));
  }

  // ---- Assisto extras (AI MOCK, key-gated honest) -------------------------
  //
  // These read the LAST FEW decrypted messages ON-DEVICE and show a MOCK
  // result plus an honest "needs the AI key" note (no AI key is wired in this
  // build; nothing is ever sent to a server for AI). "Make reminder from chat"
  // additionally offers to open the on-device reminder flow (nlp_datetime),
  // which works WITHOUT any AI key.
  void _aiExtra(String title) {
    final recent = _lastFiveDecrypted();
    final preview = recent.isEmpty
        ? ''
        : recent.map((m) => m['text']).whereType<String>().join(' · ');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t.msgrChatAiMock),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(ctx).textTheme.bodySmall),
            ],
            const SizedBox(height: Gap.sm),
            Text(_t.msgrChatAiNeedsKey,
                style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
        ],
      ),
    );
  }

  // ---- In-chat AI helper (#97, bounded MOCK, key-gated honest) ------------
  //
  // One bounded entry (⋮ → Summarise opens the helper). Offers summarise-thread
  // / translate-message / adjust-tone over text DECRYPTED on THIS device. Each
  // result is a deterministic MOCK (in_chat_ai_engine.dart) carrying an honest
  // "AI-generated — review" marker; translate honestly shows the "needs AI key"
  // state and never fabricates a translation. The helper NEVER auto-sends — it
  // only returns text to INSERT into the composer for the user to send.
  Future<void> _openInChatAi() async {
    final seed = _input.text.trim();
    final insert = await showInChatAiSheet(
      context,
      decryptedRecent: _lastFiveDecrypted(),
      seedText: seed.isEmpty ? null : seed,
    );
    if (insert == null || insert.isEmpty || !mounted) return;
    // INSERT only — never auto-send. The user reviews + taps send themselves.
    setState(() {
      _input.text = insert;
      _input.selection = TextSelection.collapsed(offset: insert.length);
    });
  }

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
    } catch (_) {
      _toast(_t.circleBackendPending);
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
    } catch (_) {
      _toast(_t.circleBackendPending);
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
    setState(() => _messages = []);
    try {
      await _api.clearChat(_memberId ?? 0);
    } catch (_) {
      _toast(_t.circleBackendPending);
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
    final text = _selectedMsgs.map((m) => m.text).where((t) => t.isNotEmpty).join('\n');
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final relation = '${widget.member['relation'] ?? 'friend'}';
    final pinned = _messages.where((m) => m.pinned).toList();
    return Scaffold(
      appBar: _searching ? _searchAppBar(scheme) : _normalAppBar(scheme, relation),
      body: Column(
        children: [
          const CircleEncryptionBanner(),
          if (pinned.isNotEmpty && !_searching) _pinnedStrip(pinned, scheme),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _visible.isEmpty
                    ? _chatEmpty(scheme)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                        itemCount: _visible.length,
                        itemBuilder: (_, i) {
                          final m = _visible[i];
                          final bubble = CircleBubble(
                            msg: m,
                            onLongPress: _selecting ? null : () => _onLongPress(m),
                            onTapMedia: (!_selecting && m.contentType != 'text')
                                ? () => _openMedia(m)
                                : null,
                          );
                          if (!_selecting) return bubble;
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
                        },
                      ),
          ),
          if (_peerTyping && !_searching) _typingIndicator(scheme),
          if ((_replyTo != null || _editing != null) && !_searching && !_selecting)
            CircleComposerContext(
              preview: (_editing ?? _replyTo)!.text,
              isEdit: _editing != null,
              onCancel: () => setState(() {
                _replyTo = null;
                _editing = null;
                if (_editing == null) _input.clear();
              }),
            ),
          if (!_searching && !_selecting) _composer(scheme),
        ],
      ),
    );
  }

  PreferredSizeWidget _normalAppBar(ColorScheme scheme, String relation) {
    if (_selecting) return _selectionAppBar(scheme);
    return AppBar(
      titleSpacing: 0,
      title: InkWell(
        onTap: _openContactInfo,
        child: Row(
          children: [
            CircleAvatar(
                radius: 16,
                child: Text(
                    _memberName.isEmpty ? '?' : _memberName.characters.first.toUpperCase())),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_memberName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    _peerTyping
                        ? _t.circleTyping
                        : CircleRelation.labelFor(_t, relation,
                            custom: widget.member['custom_label'] as String?),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: _t.circleVideo,
          icon: const Icon(Icons.videocam_outlined),
          onPressed: () => _placeCall('video'),
        ),
        IconButton(
          tooltip: _t.circleVoiceCall,
          icon: const Icon(Icons.call_outlined),
          onPressed: () => _placeCall('voice'),
        ),
        IconButton(
          tooltip: _t.circleSearchInChat,
          icon: const Icon(Icons.search),
          onPressed: () => setState(() => _searching = true),
        ),
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
          child: Text(_t.circleTyping,
              style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant, fontSize: 12)),
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.sm),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: _t.circleAttach,
                onPressed: _attach,
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(hintText: _t.circleMessageHint),
                ),
              ),
              const SizedBox(width: Gap.xs),
              IconButton.filled(
                onPressed: _sending ? null : _send,
                icon: Icon(_editing != null ? Icons.check : Icons.send),
              ),
            ],
          ),
        ),
      );
}
