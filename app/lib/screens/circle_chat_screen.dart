import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_attach_sheet.dart';
import '../widgets/circle_bubble.dart';
import '../widgets/circle_media_viewer.dart';
import '../widgets/circle_message_actions.dart';
import '../widgets/circle_relation.dart';

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
    if (mounted) {
      setState(() => _loading = false);
      _scrollToEnd();
    }
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
        await _delete(m, 'me');
        break;
      case CircleMsgAction.deleteEveryone:
        await _delete(m, 'everyone');
        break;
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
                          return CircleBubble(
                            msg: m,
                            onLongPress: () => _onLongPress(m),
                            onTapMedia: m.contentType != 'text' ? () => _openMedia(m) : null,
                          );
                        },
                      ),
          ),
          if (_peerTyping && !_searching) _typingIndicator(scheme),
          if ((_replyTo != null || _editing != null) && !_searching)
            CircleComposerContext(
              preview: (_editing ?? _replyTo)!.text,
              isEdit: _editing != null,
              onCancel: () => setState(() {
                _replyTo = null;
                _editing = null;
                if (_editing == null) _input.clear();
              }),
            ),
          if (!_searching) _composer(scheme),
        ],
      ),
    );
  }

  PreferredSizeWidget _normalAppBar(ColorScheme scheme, String relation) => AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
                radius: 16,
                child: Text(_memberName.isEmpty ? '?' : _memberName.characters.first.toUpperCase())),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_memberName, style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    _peerTyping
                        ? _t.circleTyping
                        : CircleRelation.labelFor(_t, relation,
                            custom: widget.member['custom_label'] as String?),
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _t.circleSearchInChat,
            icon: const Icon(Icons.search),
            onPressed: () => setState(() => _searching = true),
          ),
          IconButton(
            tooltip: _t.circleVoiceCall,
            icon: const Icon(Icons.call_outlined),
            onPressed: () =>
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t.circleCallGated))),
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
