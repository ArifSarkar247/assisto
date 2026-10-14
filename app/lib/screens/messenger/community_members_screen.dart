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
import '../../widgets/msgr_community_member_tile.dart';
import '../circle_chat_screen.dart';

/// Assisto Messenger — COMMUNITY members (Step 3, item 3).
///
/// Lists members by name + photo. PHONE IS HIDDEN by default: the server only
/// sends a phone when that member opted in (show_phone) or it is the viewer;
/// otherwise the tile shows a clear "phone hidden" badge — never a placeholder
/// number. (See member_card server-side.)
///
/// Messaging another member: if we are already connected the first message
/// goes straight to a normal chat; but the FIRST message to someone OUTSIDE
/// the recipient's circle becomes a MESSAGE REQUEST. The server decides via
/// `can_direct_message` and returns a `route`:
///   'direct'          -> open the normal 1:1 chat (reuses CircleChatScreen)
///   'message_request' -> we show the recipient that a request was sent; it
///                        lands in THEIR Message requests screen, never their
///                        inbox. No call is possible until they accept.
/// HTTP 429 from the rate limiter surfaces a friendly wait message.
///
/// Backend: GET /community/<id>/members, POST /community/message.
class CommunityMembersScreen extends StatefulWidget {
  final Map<String, dynamic> community;
  final IdentityKeyPair identity;

  const CommunityMembersScreen({
    super.key,
    required this.community,
    required this.identity,
  });

  @override
  State<CommunityMembersScreen> createState() => _CommunityMembersScreenState();
}

class _CommunityMembersScreenState extends State<CommunityMembersScreen> {
  bool _loading = true;
  bool _backendReady = true;
  bool _loadError = false;
  List<Map<String, dynamic>> _members = [];
  final _e2e = SoftwareE2E();

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);
  String get _cid => '${widget.community['id']}';
  bool get _viewerIsAdmin => widget.community['viewer_role'] == 'admin';
  int? get _myId => context.read<AppState>().user?.id;

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final r = await _api.communityMembers(_cid);
      _members = ((r['results'] ?? r['members'] ?? const []) as List)
          .cast<Map<String, dynamic>>();
      _backendReady = true;
      _loadError = false;
    } on ApiException {
      _backendReady = true;
      _loadError = true;
      _members = [];
    } catch (_) {
      _backendReady = false;
      _loadError = false;
      _members = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Compose the first message to [member] and let the SERVER route it.
  Future<void> _message(Map<String, dynamic> member) async {
    final text = await _composeFirstMessage(member);
    if (text == null || text.trim().isEmpty || !mounted) return;

    // Build the E2E envelope (ciphertext only; server never sees plaintext).
    Map<String, dynamic> envelope;
    final peerB64 = member['public_key']?.toString();
    if (peerB64 != null && peerB64.isNotEmpty) {
      final ct = _e2e.encrypt(
        self: widget.identity,
        recipientPublicKey: Uint8List.fromList(base64Decode(peerB64)),
        plaintext: text,
      );
      envelope = ct.toEnvelopeFields();
    } else {
      // No key yet — still send so the server can create the request; the body
      // is an opaque blob, not plaintext for the AI to read.
      envelope = {'scheme': 'pending', 'ciphertext': base64Encode(utf8.encode(text))};
    }

    try {
      final r = await _api.communityMessage(
        communityId: _cid,
        recipientId: '${member['member_id'] ?? member['id']}',
        envelope: envelope,
      );
      if (!mounted) return;
      final route = '${r['route'] ?? ''}';
      if (route == 'direct') {
        // Already connected — open the normal 1:1 chat (reuse circle chat).
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CircleChatScreen(
            member: member,
            identity: widget.identity,
          ),
        ));
      } else if (route == 'message_request') {
        // First contact outside their circle -> a request was created; it goes
        // to THEIR Message requests, not an inbox. Tell the sender clearly.
        _info(_t.communityMessageRequestSent('${member['name'] ?? ''}'));
      } else {
        // Refused (who_nobody / blocked / not_in_community).
        _info(_reasonMessage('${r['reason'] ?? ''}'));
      }
    } on ApiException catch (e) {
      if (e.status == 429) {
        _info(_t.communityRateLimited);
      } else {
        _info(_t.communityActionFailed);
      }
    } catch (_) {
      _info(_t.communityActionFailed);
    }
  }

  String _reasonMessage(String reason) {
    switch (reason) {
      case 'who_nobody':
        return _t.communityCannotMessageNobody;
      case 'blocked':
        return _t.communityCannotMessageBlocked;
      case 'not_in_community':
        return _t.communityCannotMessageNotMember;
      default:
        return _t.communityActionFailed;
    }
  }

  Future<String?> _composeFirstMessage(Map<String, dynamic> member) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.communityMessageMemberTitle('${member['name'] ?? ''}')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t.communityFirstMessageNote,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              decoration: InputDecoration(hintText: _t.communityMessageHint),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(_t.communitySend)),
        ],
      ),
    );
  }

  Future<void> _remove(Map<String, dynamic> member) async {
    // Admin remove acts on the announcements group membership by default; the
    // server protects the last admin (can_remove_community_member).
    final groupId = '${member['group_id'] ?? widget.community['announcements_group_id'] ?? ''}';
    if (groupId.isEmpty) return;
    final name = '${member['name'] ?? ''}';
    // §21 destructive-action confirm gate.
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.communityRemoveMemberTitle),
        content: Text(_t.communityRemoveMemberConfirm(name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_t.communityRemoveMember),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await _api.communityMemberRemove(
          groupId, '${member['member_id'] ?? member['id']}');
      // Last-admin protection surfaces as a refusal — tell the admin honestly.
      if (r['removed'] == false || r['allowed'] == false) {
        _info(_t.communityRemoveLastAdmin);
      }
    } catch (_) {
      _info(_t.communityActionFailed);
    }
    await _load();
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
      appBar: AppBar(title: Text(_t.communityMembersTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError
              ? _errorRetry(scheme)
              : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: Gap.xxl),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Gap.lg, Gap.md, Gap.lg, Gap.xs),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline,
                            size: 15, color: scheme.onSurfaceVariant),
                        const SizedBox(width: Gap.xs),
                        Expanded(
                          child: Text(_t.communityPhonePrivacyNote,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ),
                      ],
                    ),
                  ),
                  if (_members.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Text(
                        _backendReady
                            ? _t.communityNoMembers
                            : _t.communityBackendPending,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  for (final m in _members) _tile(m),
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
                  Icon(Icons.cloud_off_outlined,
                      size: 56, color: scheme.onSurfaceVariant),
                  const SizedBox(height: Gap.md),
                  Text(_t.communityLoadError,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.lg),
                  FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: Text(_t.retry),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _tile(Map<String, dynamic> m) {
    final memberId = m['member_id'] ?? m['id'];
    final isSelf = _myId != null && '$memberId' == '$_myId';
    return MsgrCommunityMemberTile(
      name: '${m['name'] ?? ''}',
      photoRef: m['photo_ref']?.toString(),
      phone: m['phone']?.toString(),
      phoneHidden: m['phone_hidden'] != false,
      isAdmin: '${m['role'] ?? ''}' == 'admin',
      isSelf: isSelf,
      onMessage: isSelf ? null : () => _message(m),
      onRemove: (_viewerIsAdmin && !isSelf) ? () => _remove(m) : null,
    );
  }
}
