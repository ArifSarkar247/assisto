import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/circle_status_audience.dart';

/// Compose a 24-hour status (M2 item 8).
///
/// TEXT status works NOW: the text is encrypted on-device (SoftwareE2E) and the
/// server stores CIPHERTEXT ONLY. Because a status is visible to MANY viewers
/// but the software-fallback E2E is pairwise, the text is sealed to the author's
/// OWN key (self-encrypt); the backend fans the ciphertext out and each allowed
/// viewer's client gets the key via the normal circle key-exchange (MLS seam).
/// The status payload the server sees is opaque either way.
///
/// PHOTO/VIDEO status is KEY-GATED exactly like M1 media — the tabs show
/// "Available when encrypted media storage is enabled" until the encrypted blob
/// bucket is provisioned (backend circle_status.status_media_available).
///
/// Visibility (circle / family / chosen / exclude) is chosen here and POSTed as
/// a request; the server RE-RESOLVES it per viewer, so it cannot be spoofed.
class CircleStatusComposerScreen extends StatefulWidget {
  final IdentityKeyPair identity;
  final List<Map<String, dynamic>> members;

  const CircleStatusComposerScreen({
    super.key,
    required this.identity,
    required this.members,
  });

  @override
  State<CircleStatusComposerScreen> createState() =>
      _CircleStatusComposerScreenState();
}

class _CircleStatusComposerScreenState
    extends State<CircleStatusComposerScreen> {
  final _e2e = SoftwareE2E();
  final _text = TextEditingController();
  Map<String, dynamic> _visibility = StatusAudience.defaultVisibility();
  bool _posting = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickAudience() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CircleStatusAudienceSheet(
        members: widget.members,
        initial: _visibility,
      ),
    );
    if (result != null) setState(() => _visibility = result);
  }

  Future<void> _post() async {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    setState(() => _posting = true);
    try {
      // Self-encrypt: seal to our own identity. The server stays blind; the
      // relay fans the ciphertext to allowed viewers (see composer header).
      final ct = _e2e.encrypt(
        self: widget.identity,
        recipientPublicKey: widget.identity.publicKey,
        plaintext: body,
      );
      await _api.postTextStatus(ciphertext: ct, visibility: _visibility);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => _posting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).statusNoUpdates)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.statusAdd),
          bottom: TabBar(
            tabs: [
              Tab(child: Text(s.statusText, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis), icon: const Icon(Icons.text_fields)),
              Tab(child: Text(s.statusPhoto, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis), icon: const Icon(Icons.photo_outlined)),
              Tab(child: Text(s.statusVideo, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis), icon: const Icon(Icons.videocam_outlined)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _textTab(s, scheme),
            _gatedTab(s, scheme, Icons.photo_outlined),
            _gatedTab(s, scheme, Icons.videocam_outlined),
          ],
        ),
      ),
    );
  }

  Widget _textTab(AppLocalizations s, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _text,
              maxLines: null,
              maxLength: 700,
              expands: false,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: s.statusTypeSomething,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Row(
            children: [
              CircleStatusAudienceChip(
                visibility: _visibility,
                onTap: _pickAudience,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _posting ? null : _post,
                icon: _posting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: Text(s.statusPost),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          _footerNote(Icons.schedule, s.statusExpiresIn24h, scheme),
          const SizedBox(height: Gap.xs),
          _footerNote(Icons.lock_outline, s.statusEncrypted, scheme),
        ],
      ),
    );
  }

  Widget _gatedTab(AppLocalizations s, ColorScheme scheme, IconData icon) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.outline),
            const SizedBox(height: Gap.md),
            Text(
              s.statusMediaGated,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footerNote(IconData icon, String text, ColorScheme scheme) {
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant, height: 1.3),
          ),
        ),
      ],
    );
  }
}
