import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Full-screen status viewer (M2 item 8) — WhatsApp/Messenger story viewer.
///
/// Walks an author's active statuses newest→oldest with a timed progress bar.
/// On each status:
///   - records a VIEW (server honours the reciprocal read-receipt rule),
///   - lets the viewer REPLY PRIVATELY (opens a 1:1 E2E chat message to the
///     author via POST /circle/status/{id}/reply — the reply body is ciphertext
///     sealed on-device; the server only sees a routing reference),
///   - lets the viewer MUTE the author's status.
///
/// When [mine] is true this is the AUTHOR'S own view: no reply/mute, but a
/// VIEWER LIST ("seen by N", with anonymous viewers counted but not named — the
/// reciprocal-receipt rule enforced server-side in circle_status.record_view).
///
/// TEXT status content is decrypted on-device. Because the software-fallback
/// E2E is pairwise, a text status I can read was sealed to a key my device can
/// derive (self for my own; the circle key-exchange seam for others). If a
/// status can't be decrypted it shows a neutral placeholder — never plaintext
/// from the server (the server never has it).
class CircleStatusViewerScreen extends StatefulWidget {
  final IdentityKeyPair identity;
  final int authorId;
  final String authorName;
  final String? authorPublicKeyB64;
  final bool mine;

  const CircleStatusViewerScreen({
    super.key,
    required this.identity,
    required this.authorId,
    required this.authorName,
    required this.authorPublicKeyB64,
    this.mine = false,
  });

  @override
  State<CircleStatusViewerScreen> createState() =>
      _CircleStatusViewerScreenState();
}

class _CircleStatusViewerScreenState extends State<CircleStatusViewerScreen> {
  final _e2e = SoftwareE2E();
  bool _loading = true;
  List<Map<String, dynamic>> _statuses = [];
  int _index = 0;
  Timer? _advance;
  bool _paused = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _advance?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = widget.mine
          ? await _api.myStatuses()
          : await _api.authorStatuses(widget.authorId);
      _statuses =
          ((r['statuses'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      _statuses = [];
    }
    if (mounted) {
      setState(() => _loading = false);
      if (_statuses.isNotEmpty) _onShow();
    }
  }

  void _onShow() {
    final st = _statuses[_index];
    if (!widget.mine) {
      final id = '${st['id']}';
      _api.viewStatus(id).catchError((_) {});
    }
    _scheduleAdvance();
  }

  void _scheduleAdvance() {
    _advance?.cancel();
    _advance = Timer(const Duration(seconds: 6), _next);
  }

  void _next() {
    if (_paused) return; // a timer that fired just before a pause must not advance
    if (_index < _statuses.length - 1) {
      setState(() => _index++);
      _onShow();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _prev() {
    if (_index > 0) {
      setState(() => _index--);
      _onShow();
    }
  }

  Uint8List? get _authorPub {
    final b64 = widget.authorPublicKeyB64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  /// Decrypt a text status. For my own status the sender key is me; for another
  /// author it is the author's published key. Returns null if undecryptable.
  String? _decryptText(Map<String, dynamic> st) {
    if ('${st['kind']}' != 'text') return null;
    final ctB64 = st['ciphertext'] as String?;
    final nonce = st['nonce'] as String?;
    final skid = st['sender_key_id'] as String?;
    final scheme = st['scheme'] as String?;
    if (ctB64 == null || nonce == null || scheme == null) return null;
    final peerPub = widget.mine ? widget.identity.publicKey : _authorPub;
    if (peerPub == null) return null;
    try {
      return _e2e.decrypt(
        self: widget.identity,
        senderPublicKey: peerPub,
        ct: Ciphertext(
          scheme: scheme,
          ciphertextB64: ctB64,
          nonceB64: nonce,
          senderKeyId: skid ?? '',
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _reply() async {
    _advance?.cancel();
    setState(() => _paused = true);
    final controller = TextEditingController();
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final s = AppLocalizations.of(ctx);
        return Padding(
          padding: EdgeInsets.only(
            left: Gap.lg,
            right: Gap.lg,
            top: Gap.sm,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: s.statusReplyPrivately,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Gap.sm),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  icon: const Icon(Icons.send),
                  label: Text(s.statusSendReply),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (sent == true && controller.text.trim().isNotEmpty) {
      await _sendReply(controller.text.trim());
    }
    if (mounted) {
      setState(() => _paused = false);
      _scheduleAdvance();
    }
  }

  Future<void> _sendReply(String body) async {
    final pub = _authorPub;
    if (pub == null) return;
    try {
      final ct = _e2e.encrypt(
        self: widget.identity,
        recipientPublicKey: pub,
        plaintext: body,
      );
      await _api.replyToStatus(
        statusId: '${_statuses[_index]['id']}',
        authorId: widget.authorId,
        ciphertext: ct,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).statusSendReply)),
        );
      }
    } catch (_) {}
  }

  Future<void> _mute() async {
    // Confirm gate (§21): muting is surprising — gate it, and be honest that the
    // author is never notified. Pause the auto-advance while the dialog is open.
    _advance?.cancel();
    setState(() => _paused = true);
    final s = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.statusMute),
        content: Text(s.statusMuteConfirm(widget.authorName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.statusMute),
          ),
        ],
      ),
    );
    if (ok != true) {
      if (mounted) {
        setState(() => _paused = false);
        _scheduleAdvance();
      }
      return;
    }
    try {
      await _api.muteStatusAuthor(widget.authorId, on: true);
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).statusMuted)),
      );
      Navigator.of(context).maybePop();
    }
  }

  void _showViewers() {
    _advance?.cancel();
    setState(() => _paused = true);
    final st = _statuses[_index];
    final views = ((st['views'] ?? []) as List).cast<Map<String, dynamic>>();
    final count = (st['viewer_count'] as int?) ?? views.length;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final s = AppLocalizations.of(ctx);
        final named = views.where((v) => v['anonymous'] != true).toList();
        final anon = count - named.length;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.remove_red_eye_outlined),
                    const SizedBox(width: Gap.sm),
                    Text(
                        count == 0
                            ? s.statusNoViewsYet
                            : s.statusSeenBy('$count'),
                        style: Theme.of(ctx).textTheme.titleMedium),
                  ],
                ),
                if (anon > 0) ...[
                  const SizedBox(height: Gap.xs),
                  Text(s.statusReceiptsOff,
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(ctx).colorScheme.onSurfaceVariant)),
                ],
                const SizedBox(height: Gap.sm),
                for (final v in named)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                        child: Icon(Icons.person_outline)),
                    title: Text('${v['viewer']}'),
                    subtitle: Text('${v['at'] ?? ''}'),
                  ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      if (mounted) {
        setState(() => _paused = false);
        _scheduleAdvance();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_statuses.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Text(s.statusNoUpdates,
              style: const TextStyle(color: Colors.white70)),
        ),
      );
    }

    final st = _statuses[_index];
    final text = _decryptText(st);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onTapUp: (d) {
            final w = MediaQuery.of(context).size.width;
            if (d.globalPosition.dx < w / 3) {
              _prev();
            } else {
              _next();
            }
          },
          onLongPress: () {
            _advance?.cancel();
            setState(() => _paused = true);
          },
          onLongPressUp: () {
            setState(() => _paused = false);
            _scheduleAdvance();
          },
          child: Stack(
            children: [
              // Content.
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(gradient: Brand.gradient),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(Gap.xxl),
                  child: Text(
                    text ?? '•••',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
              // Progress segments.
              Positioned(
                top: Gap.sm,
                left: Gap.sm,
                right: Gap.sm,
                child: Row(
                  children: [
                    for (var i = 0; i < _statuses.length; i++)
                      Expanded(
                        child: Container(
                          height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: i <= _index
                                ? Colors.white
                                : Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Header.
              Positioned(
                top: Gap.lg,
                left: Gap.lg,
                right: Gap.lg,
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.white24,
                      child: Text(
                        widget.authorName.isEmpty
                            ? '?'
                            : widget.authorName.characters.first.toUpperCase(),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                        widget.authorName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (!widget.mine)
                      PopupMenuButton<String>(
                        iconColor: Colors.white,
                        onSelected: (v) {
                          if (v == 'mute') _mute();
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'mute', child: Text(s.statusMute)),
                        ],
                      ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              // Footer: reply (viewer) or viewer-list (author).
              Positioned(
                bottom: Gap.lg,
                left: Gap.lg,
                right: Gap.lg,
                child: widget.mine
                    ? _viewerListButton(s)
                    : _replyButton(s),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _replyButton(AppLocalizations s) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white24,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
      ),
      onPressed: _authorPub == null ? null : _reply,
      icon: const Icon(Icons.reply),
      label: Text(s.statusReplyPrivately),
    );
  }

  Widget _viewerListButton(AppLocalizations s) {
    final st = _statuses[_index];
    final count = (st['viewer_count'] as int?) ??
        ((st['views'] ?? []) as List).length;
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white24,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
      ),
      onPressed: _showViewers,
      icon: const Icon(Icons.remove_red_eye_outlined),
      label: Text(count == 0 ? s.statusNoViewsYet : s.statusSeenBy('$count')),
    );
  }
}
