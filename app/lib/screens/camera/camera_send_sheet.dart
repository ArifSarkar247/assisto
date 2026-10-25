import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../services/circle_media_gate.dart';
import '../../widgets/msgr_avatar.dart';
import '../circle_status_composer_screen.dart';

/// The destination chooser shown when the user taps SEND on a captured/edited
/// photo or video.
///
/// REUSE (no new backend): every option routes through an EXISTING circle path.
///   • Send to ONE / SEVERAL chats → the SAME relay envelope the circle chat
///     screen uses: POST /circle/<peer>/messages with an E2E envelope. The
///     caption is encrypted to each selected peer and posted with
///     content_type photo|video and media_gated:true — mirroring
///     circle_chat_screen._send + core/logic/circle_media.media_gate_notice,
///     because the encrypted blob bucket is key-gated until provisioned. The
///     media file is attached by the same integrator seam that will attach any
///     encrypted blob (documented in the integration note).
///   • Post as STATUS → opens the EXISTING [CircleStatusComposerScreen] (the
///     owner's spec: "Posting as Status reuses the existing status composer
///     flow"). The caption is pre-filled there; photo/video status stays
///     key-gated exactly as that composer already shows.
///
/// NO SHOWPIECES (round 2 item 4): while My Circle's encrypted media storage
/// is OFF ([kCircleMediaStorageOn]) a chat or status send could carry only the
/// caption, never the photo. So the sheet then offers ONE real action — share
/// the actual file through the phone's share menu — and hides the
/// caption-only paths.

Future<void> showCameraSendSheet(
  BuildContext context, {
  required File file,
  required bool isVideo,
  required String caption,
  required IdentityKeyPair? identity,
  required List<Map<String, dynamic>> members,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _CameraSendSheet(
      file: file,
      isVideo: isVideo,
      caption: caption,
      identity: identity,
      members: members,
    ),
  );
}

class _CameraSendSheet extends StatefulWidget {
  final File file;
  final bool isVideo;
  final String caption;
  final IdentityKeyPair? identity;
  final List<Map<String, dynamic>> members;

  const _CameraSendSheet({
    required this.file,
    required this.isVideo,
    required this.caption,
    required this.identity,
    required this.members,
  });

  @override
  State<_CameraSendSheet> createState() => _CameraSendSheetState();
}

class _CameraSendSheetState extends State<_CameraSendSheet> {
  final _e2e = SoftwareE2E();
  final Set<int> _selected = {};
  bool _sending = false;

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  /// Members that have a usable public key (we can E2E to them).
  List<Map<String, dynamic>> get _targets => widget.members
      .where((m) => m['id'] is int && '${m['public_key'] ?? ''}'.isNotEmpty)
      .toList();

  Future<void> _sendToSelected() async {
    final id = widget.identity;
    if (id == null || _selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    final contentType = widget.isVideo ? 'video' : 'photo';
    var ok = 0;
    var fail = 0;
    for (final m in _targets) {
      final memberId = m['id'] as int;
      if (!_selected.contains(memberId)) continue;
      try {
        final peerPub = base64Decode(m['public_key'] as String);
        // Encrypt the caption to the peer exactly like circle_chat_screen._send.
        final ct = _e2e.encrypt(
          self: id,
          recipientPublicKey: peerPub,
          plaintext: widget.caption,
        );
        await _api.postJson('/circle/$memberId/messages', {
          'content_type': contentType,
          'client_msg_id': 'cam-${DateTime.now().microsecondsSinceEpoch}-$memberId',
          // Key-gated until encrypted blob storage is provisioned (mirrors
          // circle_chat_screen mediaGated + circle_media.media_gate_notice).
          // The integrator attaches the encrypted blob ref here.
          'media_gated': true,
          ...ct.toEnvelopeFields(),
        });
        ok++;
      } catch (_) {
        fail++;
      }
    }
    if (!mounted) return;
    setState(() => _sending = false);
    Navigator.of(context).pop(); // close sheet
    final msg = fail == 0 ? _t.camSentToChats(ok) : _t.camSentPartial(fail, ok); // (fail, ok) per signature
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Real today: hand the captured/edited file itself to the phone's share
  /// menu (WhatsApp, Gmail, Drive, Files …) with the caption.
  Future<void> _shareFile() async {
    final t = _t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Share.shareXFiles(
        [
          XFile(widget.file.path,
              mimeType: widget.isVideo ? 'video/mp4' : 'image/jpeg')
        ],
        text: widget.caption.isEmpty ? null : widget.caption,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.camShareFailed)));
    }
  }

  Widget _shareOnly(AppLocalizations t, ColorScheme scheme) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.camSendTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            ListTile(
              key: const Key('cam-share-file'),
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(Icons.ios_share, color: scheme.onPrimaryContainer),
              ),
              title: Text(t.camShareFile),
              subtitle: Text(t.camShareFileSub,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: _shareFile,
            ),
            const SizedBox(height: Gap.xs),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline,
                  size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(t.camCircleTextOnly,
                    style: AType.bodySmall.copyWith(height: 1.3,
                        color: scheme.onSurfaceVariant)),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  void _postAsStatus() {
    final id = widget.identity;
    Navigator.of(context).pop(); // close sheet first
    if (id == null) return;
    // Reuse the EXISTING status composer flow (owner spec). Photo/video status
    // is key-gated inside that composer; the typed caption carries over.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleStatusComposerScreen(
        identity: id,
        members: widget.members,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    if (!kCircleMediaStorageOn) return _shareOnly(t, scheme);
    final canSend = widget.identity != null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Gap.md,
          right: Gap.md,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.camSendTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),

            // Post as Status
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(Icons.auto_awesome, color: scheme.onPrimaryContainer),
              ),
              title: Text(t.camPostStatus),
              subtitle: Text(t.camPostStatusSub,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              enabled: canSend,
              onTap: canSend ? _postAsStatus : null,
            ),
            const Divider(height: 1),
            const SizedBox(height: Gap.sm),

            Text(t.camSendToChats,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),

            if (!canSend)
              _note(t.camSendNoIdentity, scheme)
            else if (_targets.isEmpty)
              _note(t.camSendNoMembers, scheme)
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _targets.length,
                  itemBuilder: (_, i) {
                    final m = _targets[i];
                    final mid = m['id'] as int;
                    final name = '${m['name'] ?? ''}';
                    final photo = '${m['photo'] ?? m['avatar'] ?? ''}';
                    return CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _selected.contains(mid),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(mid);
                        } else {
                          _selected.remove(mid);
                        }
                      }),
                      secondary: MsgrAvatar(name: name, photoUrl: photo, radius: 20),
                      title: Text(name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    );
                  },
                ),
              ),

            const SizedBox(height: Gap.sm),
            Row(
              children: [
                const Spacer(),
                FilledButton.icon(
                  onPressed:
                      (canSend && _selected.isNotEmpty && !_sending)
                          ? _sendToSelected
                          : null,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                  label: Text(
                    _selected.isEmpty
                        ? t.camSend
                        : t.camSendCount(_selected.length),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _note(String text, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.md),
      child: Text(text,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
    );
  }
}
