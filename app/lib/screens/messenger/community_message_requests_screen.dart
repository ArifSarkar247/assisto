import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_community_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_community_request_tile.dart';
import '../circle_chat_screen.dart';

/// Assisto Messenger — COMMUNITY message requests (Step 3, item 4).
///
/// Incoming community DMs from people OUTSIDE the viewer's circle never reach
/// the normal inbox — the server holds them here as requests. The viewer can:
///   Accept  -> the sender's row flips to accepted; this opens a NORMAL 1:1
///              chat (reuses CircleChatScreen) and calls become allowed.
///   Decline -> request closed; sender not told.
///   Block   -> silent block (apply_msgreq_event block).
///   Report  -> report_sender (optionally also block).
/// There is deliberately NO call button anywhere on this screen: the server
/// (can_call) refuses calls until the request is accepted.
///
/// Backend: a listing endpoint for pending requests (shell wires the exact
/// path; we read {results|requests}), plus
/// POST /community/message-request/<id>/accept|decline|block|report.
class CommunityMessageRequestsScreen extends StatefulWidget {
  final IdentityKeyPair identity;

  const CommunityMessageRequestsScreen({super.key, required this.identity});

  @override
  State<CommunityMessageRequestsScreen> createState() =>
      _CommunityMessageRequestsScreenState();
}

class _CommunityMessageRequestsScreenState
    extends State<CommunityMessageRequestsScreen> {
  bool _loading = true;
  bool _backendReady = true;
  bool _loadError = false;
  List<Map<String, dynamic>> _requests = [];
  final _e2e = SoftwareE2E();

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      // The listing is a plain GET; the server returns pending requests only.
      final r = await _api.getJson('/community/message-requests');
      _requests = ((r['results'] ?? r['requests'] ?? const []) as List)
          .cast<Map<String, dynamic>>();
      _backendReady = true;
      _loadError = false;
    } on ApiException {
      _backendReady = true;
      _loadError = true;
      _requests = [];
    } catch (_) {
      _backendReady = false;
      _loadError = false;
      _requests = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Decrypt the first-message envelope on-device for a preview line. Falls
  /// back to a generic label if we can't (no key / tamper).
  String _preview(Map<String, dynamic> req) {
    final env = (req['envelope'] as Map?)?.cast<String, dynamic>();
    final senderB64 = req['sender_public_key']?.toString();
    if (env != null && senderB64 != null && senderB64.isNotEmpty) {
      try {
        final ct = Ciphertext(
          scheme: '${env['scheme'] ?? ''}',
          ciphertextB64: '${env['ciphertext'] ?? ''}',
          nonceB64: '${env['nonce'] ?? ''}',
          senderKeyId: '${env['sender_key_id'] ?? ''}',
        );
        final text = _e2e.decrypt(
          self: widget.identity,
          senderPublicKey: Uint8List.fromList(base64Decode(senderB64)),
          ct: ct,
        );
        if (text != null && text.isNotEmpty) return text;
      } catch (_) {}
    }
    return _t.communityRequestGenericPreview;
  }

  Future<void> _accept(Map<String, dynamic> req) async {
    try {
      await _api.messageRequestAccept('${req['id']}');
      if (!mounted) return;
      // Accepted -> normal chat. Reuse the circle 1:1 chat screen.
      final member = (req['sender'] as Map?)?.cast<String, dynamic>() ??
          {
            'id': req['sender_id'],
            'member_id': req['sender_id'],
            'name': req['sender_name'],
            'public_key': req['sender_public_key'],
          };
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CircleChatScreen(
          member: member,
          identity: widget.identity,
        ),
      ));
    } catch (_) {
      _info(_t.communityActionFailed);
    }
    await _load();
  }

  Future<void> _decline(Map<String, dynamic> req) async {
    final name = '${req['sender_name'] ?? ''}';
    final ok = await _confirm(
      title: _t.communityDeclineTitle,
      message: _t.communityDeclineConfirm(name),
      confirmLabel: _t.communityRequestDecline,
    );
    if (ok != true) return;
    try {
      await _api.messageRequestDecline('${req['id']}');
    } catch (_) {
      _info(_t.communityActionFailed);
    }
    await _load();
  }

  Future<void> _block(Map<String, dynamic> req) async {
    final name = '${req['sender_name'] ?? ''}';
    final ok = await _confirm(
      title: _t.communityBlockTitle,
      message: _t.communityBlockConfirm(name),
      confirmLabel: _t.communityRequestBlock,
      destructive: true,
    );
    if (ok != true) return;
    try {
      await _api.messageRequestBlock('${req['id']}');
    } catch (_) {
      _info(_t.communityActionFailed);
    }
    await _load();
  }

  /// Shared §21 confirm gate for destructive / consequential request actions.
  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
            style: destructive
                ? Brand.dangerButton()
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _report(Map<String, dynamic> req) async {
    bool alsoBlock = true;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String selected = 'spam';
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text(_t.communityReportTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in const ['spam', 'harassment', 'scam', 'other'])
                  RadioListTile<String>(
                    value: r,
                    groupValue: selected,
                    dense: true,
                    title: Text(_reasonLabel(r)),
                    onChanged: (v) => setLocal(() => selected = v!),
                  ),
                CheckboxListTile(
                  value: alsoBlock,
                  dense: true,
                  title: Text(_t.communityReportAlsoBlock),
                  onChanged: (v) => setLocal(() => alsoBlock = v ?? true),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: Text(_t.cancel)),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, selected),
                  child: Text(_t.communityReportSubmit)),
            ],
          ),
        );
      },
    );
    if (reason == null) return;
    try {
      await _api.messageRequestReport('${req['id']}',
          reason: reason, alsoBlock: alsoBlock);
      _info(_t.communityReportThanks);
    } catch (_) {
      _info(_t.communityActionFailed);
    }
    await _load();
  }

  String _reasonLabel(String r) {
    switch (r) {
      case 'spam':
        return _t.communityReportSpam;
      case 'harassment':
        return _t.communityReportHarassment;
      case 'scam':
        return _t.communityReportScam;
      default:
        return _t.communityReportOther;
    }
  }

  void _info(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_t.communityRequestsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError
              ? _errorRetry(scheme)
              : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: Gap.xxl),
                children: [
                  if (_requests.isEmpty) _emptyState(scheme),
                  for (final req in _requests)
                    MsgrCommunityRequestTile(
                      senderName: '${req['sender_name'] ?? ''}',
                      senderPhoto: req['sender_photo']?.toString(),
                      communityName: '${req['community_name'] ?? ''}',
                      preview: _preview(req),
                      onAccept: () => _accept(req),
                      onDecline: () => _decline(req),
                      onBlock: () => _block(req),
                      onReport: () => _report(req),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _errorRetry(ColorScheme scheme) => ListView(
        children: [
          const SizedBox(height: Gap.xxl * 2),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_rounded,
                      size: 56, color: scheme.onSurfaceVariant),
                  const SizedBox(height: Gap.md),
                  Text(_t.communityLoadError,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.lg),
                  FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(_t.retry),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _emptyState(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          children: [
            const SizedBox(height: Gap.xxl),
            Icon(Icons.mark_email_read_rounded,
                size: 56, color: scheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: Gap.md),
            Text(_t.communityRequestsEmptyTitle,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: Gap.xs),
            Text(
              _backendReady
                  ? _t.communityRequestsEmptyBody
                  : _t.communityBackendPending,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      );
}
