import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_bubble.dart';
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
/// Voice note / photo / short video + voice call are KEY-GATED ("Available
/// when encrypted media storage / the call server is enabled") — mirrors
/// core.logic.circle.media_gate_reason.
class CircleChatScreen extends StatefulWidget {
  final Map<String, dynamic> member;
  final IdentityKeyPair identity;
  const CircleChatScreen(
      {super.key, required this.member, required this.identity});

  @override
  State<CircleChatScreen> createState() => _CircleChatScreenState();
}

class _CircleChatScreenState extends State<CircleChatScreen> {
  final _e2e = SoftwareE2E();
  final _input = TextEditingController();
  final _scroll = ScrollController();

  List<CircleMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
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
      final raw = ((r['results'] ?? r['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      _messages = raw.map((e) => _decryptEnvelope(e, peer)).toList();
    } catch (_) {
      _messages = [];
    }
    if (mounted) {
      setState(() => _loading = false);
      _scrollToEnd();
    }
  }

  /// Turn a stored ciphertext envelope into a displayable (decrypted) bubble.
  /// Decryption happens ON-DEVICE; failure degrades gracefully to a "couldn't
  /// decrypt" bubble rather than ever showing ciphertext as text.
  CircleMessage _decryptEnvelope(Map<String, dynamic> env, Uint8List? peerPub) {
    final mine = (env['sender_id'] == context.read<AppState>().user?.id) ||
        (env['mine'] == true);
    final at = DateTime.tryParse('${env['created_at'] ?? ''}')?.toLocal() ??
        DateTime.now();
    final status = '${env['status'] ?? 'sent'}';
    var text = '';
    var failed = false;
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
        final pt = _e2e.decrypt(
          self: widget.identity,
          senderPublicKey: peerPub,
          ct: ct,
        );
        if (pt == null) {
          failed = true;
        } else {
          text = pt;
        }
      }
    } catch (_) {
      failed = true;
    }
    return CircleMessage(
      id: '${env['id'] ?? ''}',
      text: text,
      mine: mine,
      at: at,
      status: status,
      decryptFailed: failed,
    );
  }

  Future<void> _send() async {
    final plain = _input.text.trim();
    if (plain.isEmpty || _sending) return;
    final peer = _peerPub;
    if (peer == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t.circleKeyMissing)));
      return;
    }
    setState(() => _sending = true);
    final ct = _e2e.encrypt(
      self: widget.identity,
      recipientPublicKey: peer,
      plaintext: plain,
    );
    // Optimistic local echo (decrypted locally — never shown as ciphertext).
    final echo = CircleMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      text: plain,
      mine: true,
      at: DateTime.now(),
      status: 'sent',
    );
    setState(() {
      _messages = [..._messages, echo];
      _input.clear();
    });
    _scrollToEnd();
    try {
      await _api.postJson('/circle/$_memberId/messages', {
        'content_type': 'text',
        ...ct.toEnvelopeFields(),
      });
    } catch (_) {
      // Offline/not-wired: the echo stays; a real send retries on reload.
    }
    if (mounted) setState(() => _sending = false);
  }

  void _mediaGated(String type) {
    // Mirror media_gate_reason(): text is live, the rest is key-gated.
    final reason = () {
      switch (type) {
        case 'voice':
          return _t.circleMediaVoiceGated;
        case 'photo':
          return _t.circleMediaPhotoGated;
        case 'video':
          return _t.circleMediaVideoGated;
        case 'call':
          return _t.circleCallGated;
        default:
          return _t.circleComingSoon;
      }
    }();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason)));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.base, curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final relation = '${widget.member['relation'] ?? 'friend'}';
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
                radius: 16,
                child: Text(_memberName.isEmpty
                    ? '?'
                    : _memberName.characters.first.toUpperCase())),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_memberName,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    CircleRelation.labelFor(_t, relation,
                        custom: widget.member['custom_label'] as String?),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _t.circleVoiceCall,
            icon: const Icon(Icons.call_outlined),
            onPressed: () => _mediaGated('call'),
          ),
        ],
      ),
      body: Column(
        children: [
          const CircleEncryptionBanner(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? _chatEmpty(scheme)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) =>
                            CircleBubble(msg: _messages[i]),
                      ),
          ),
          _composer(scheme),
        ],
      ),
    );
  }

  Widget _chatEmpty(ColorScheme scheme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline,
                  size: 48, color: scheme.primary.withValues(alpha: 0.7)),
              const SizedBox(height: Gap.md),
              Text(_t.circleChatEmpty,
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
              PopupMenuButton<String>(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: _t.circleAttach,
                onSelected: _mediaGated,
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'photo',
                      child: _gatedRow(Icons.photo_outlined, _t.circlePhoto)),
                  PopupMenuItem(
                      value: 'voice',
                      child: _gatedRow(Icons.mic_none_outlined, _t.circleVoiceNote)),
                  PopupMenuItem(
                      value: 'video',
                      child: _gatedRow(Icons.videocam_outlined, _t.circleVideo)),
                ],
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
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      );

  Widget _gatedRow(IconData icon, String label) => Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: Gap.sm),
          Text(label),
          const SizedBox(width: Gap.sm),
          Icon(Icons.lock_clock_outlined,
              size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ],
      );
}
