import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_relation.dart';
import '../widgets/circle_sharing.dart';
import 'circle_chat_screen.dart';

/// Connected Circle — a relationship-scoped family/friends circle with
/// end-to-end-encrypted messaging. This screen is the hub: it lists accepted
/// members, pending requests, and the add flows (invite by phone / QR). Every
/// chat is E2E (crypto/e2e.dart); the server only ever relays ciphertext.
///
/// Backend seam (integrator wires these — see MIGRATION NOTE in the report):
///   GET  /circle/members          -> accepted + pending members
///   GET  /circle/requests         -> incoming requests
///   POST /circle/request          -> send a request (phone or token)
///   POST /circle/request/<id>/act -> accept|decline|block (relationship FSM)
///   POST /circle/<id>/sharing     -> update who-sees-what policy
///   POST /circle/<id>/report      -> report (+auto-block)
///   GET  /circle/invite?relation= -> {token, qr} signed invite
/// Until live, the screen shows a friendly empty state (no crash).
class CircleScreen extends StatefulWidget {
  const CircleScreen({super.key});
  @override
  State<CircleScreen> createState() => _CircleScreenState();
}

class _CircleScreenState extends State<CircleScreen> {
  static const _secure = FlutterSecureStorage();
  final _e2e = SoftwareE2E();

  bool _loading = true;
  bool _backendReady = true;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _requests = [];
  IdentityKeyPair? _identity;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _bootstrap() async {
    await _ensureIdentity();
    await _load();
  }

  /// Load (or lazily create) the on-device identity key. The PRIVATE key never
  /// leaves the device except as an optional backup sealed under a recovery
  /// code (see KeyBackup). Here we only publish the PUBLIC key to the server so
  /// others can encrypt to us.
  Future<void> _ensureIdentity() async {
    try {
      final stored = await _secure.read(key: 'circle_identity_v1');
      if (stored != null) {
        final j = jsonDecode(stored) as Map<String, dynamic>;
        _identity = IdentityKeyPair(
          base64Decode(j['priv'] as String),
          base64Decode(j['pub'] as String),
          j['kid'] as String,
        );
        return;
      }
      final id = _e2e.generateIdentity();
      await _secure.write(
        key: 'circle_identity_v1',
        value: jsonEncode({
          'priv': base64Encode(id.privateKey),
          'pub': base64Encode(id.publicKey),
          'kid': id.keyId,
        }),
      );
      _identity = id;
      // Best-effort publish of the PUBLIC key (never the private key).
      try {
        await _api.postJson('/circle/keys', {
          'public_key': id.publicKeyB64,
          'key_id': id.keyId,
          'scheme': _e2e.scheme,
        });
      } catch (_) {}
    } catch (_) {
      // Secure storage unavailable (e.g. preview) — keep a volatile identity so
      // the UI still renders.
      _identity = _e2e.generateIdentity();
    }
  }

  Future<void> _load() async {
    try {
      final m = await _api.getJson('/circle/members');
      final r = await _api.getJson('/circle/requests');
      _members = ((m['results'] ?? m['members'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      _requests = ((r['results'] ?? r['requests'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      _backendReady = true;
    } catch (_) {
      _backendReady = false;
      _members = [];
      _requests = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _act(Map<String, dynamic> req, String event) async {
    try {
      await _api.postJson('/circle/request/${req['id']}/act', {'event': event});
    } catch (_) {}
    await _load();
  }

  Future<void> _report(Map<String, dynamic> member) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in const ['spam', 'harassment', 'scam', 'impersonation', 'other'])
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: Text(_reportLabel(r)),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
      ),
    );
    if (reason == null) return;
    try {
      await _api.postJson('/circle/${member['id']}/report', {'reason': reason});
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t.circleReported)));
    }
    await _load();
  }

  String _reportLabel(String r) {
    switch (r) {
      case 'spam':
        return _t.circleReportSpam;
      case 'harassment':
        return _t.circleReportHarassment;
      case 'scam':
        return _t.circleReportScam;
      case 'impersonation':
        return _t.circleReportImpersonation;
      default:
        return _t.circleReportOther;
    }
  }

  Future<void> _openSharing(Map<String, dynamic> member) async {
    var policy = Map<String, bool>.from(
        (member['sharing'] as Map?)?.map((k, v) => MapEntry('$k', v == true)) ??
            {});
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleSharingEditor(
                policy: policy,
                onChanged: (p) => setM(() => policy = p),
              ),
              Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: FilledButton(
                  onPressed: () async {
                    try {
                      await _api.postJson(
                          '/circle/${member['id']}/sharing', {'sharing': policy});
                    } catch (_) {}
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: Text(_t.save),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await _load();
  }

  Future<void> _addFlow() async {
    String relation = 'friend';
    String custom = '';
    final phoneCtrl = TextEditingController();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.sm,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg,
        ),
        child: StatefulBuilder(
          builder: (ctx, setM) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_t.circleAddTitle,
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.md),
              Text(_t.circleRelationQuestion,
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: Gap.sm),
              CircleRelationPicker(
                selected: relation,
                onSelected: (c) => setM(() => relation = c),
              ),
              if (relation == 'custom') ...[
                const SizedBox(height: Gap.sm),
                TextField(
                  decoration:
                      InputDecoration(hintText: _t.circleCustomRelationHint),
                  onChanged: (v) => custom = v,
                ),
              ],
              const SizedBox(height: Gap.lg),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: _t.circlePhoneLabel,
                  prefixIcon: const Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: Gap.md),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.send_outlined),
                      label: Text(_t.circleSendRequest),
                      onPressed: () async {
                        final phone = phoneCtrl.text.trim();
                        if (phone.isEmpty) return;
                        try {
                          await _api.postJson('/circle/request', {
                            'phone': phone,
                            'relation': relation,
                            if (relation == 'custom') 'custom_label': custom,
                          });
                        } catch (_) {}
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.qr_code_2_outlined),
                    label: Text(_t.circleQrInvite),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showInviteQr(relation, custom);
                    },
                  ),
                ],
              ),
              const SizedBox(height: Gap.sm),
              Text(_t.circleNoContactUpload,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
    await _load();
  }

  Future<void> _showInviteQr(String relation, String custom) async {
    String? token;
    String? link;
    try {
      final r = await _api.getJson('/circle/invite?relation=$relation');
      token = r['token'] as String?;
      link = r['qr'] as String? ?? r['link'] as String?;
    } catch (_) {}
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.circleQrInvite),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A real QR image is drawn by the integrator with a qr widget; here
            // we present the deep link + token so it works before that lands.
            const Icon(Icons.qr_code_2, size: 96),
            const SizedBox(height: Gap.md),
            SelectableText(
              link ?? token ?? _t.circleInviteUnavailable,
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          if (link != null || token != null)
            TextButton.icon(
              icon: const Icon(Icons.copy_outlined),
              label: Text(_t.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link ?? token!));
                Navigator.pop(ctx);
              },
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
        ],
      ),
    );
  }

  void _openChat(Map<String, dynamic> member) {
    final id = _identity;
    if (id == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleChatScreen(member: member, identity: id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_t.circleTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addFlow,
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: Text(_t.circleAdd),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  if (_requests.isNotEmpty) ...[
                    _sectionHeader(_t.circlePendingRequests),
                    for (final r in _requests) _requestTile(r),
                  ],
                  _sectionHeader(_t.circleYourCircle),
                  if (_members.isEmpty) _emptyState(scheme),
                  for (final m in _members) _memberTile(m),
                ],
              ),
            ),
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _emptyState(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          children: [
            Icon(Icons.diversity_1_outlined,
                size: 56, color: scheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: Gap.md),
            Text(_t.circleEmptyTitle,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: Gap.xs),
            Text(
              _backendReady ? _t.circleEmptyBody : _t.circleBackendPending,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      );

  Widget _requestTile(Map<String, dynamic> r) {
    final name = '${r['name'] ?? r['sender_name'] ?? ''}';
    final relation = '${r['relation'] ?? 'friend'}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(
          children: [
            CircleAvatar(child: Text(_initial(name))),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Theme.of(context).textTheme.titleMedium),
                  Text(CircleRelation.labelFor(_t, relation,
                      custom: r['custom_label'] as String?)),
                ],
              ),
            ),
            IconButton(
              tooltip: _t.circleAccept,
              icon: const Icon(Icons.check_circle_outline),
              color: Brand.success,
              onPressed: () => _act(r, 'accept'),
            ),
            IconButton(
              tooltip: _t.circleDecline,
              icon: const Icon(Icons.cancel_outlined),
              onPressed: () => _act(r, 'decline'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _memberTile(Map<String, dynamic> m) {
    final name = '${m['name'] ?? ''}';
    final relation = '${m['relation'] ?? 'friend'}';
    final accepted = '${m['state'] ?? 'accepted'}' == 'accepted';
    return ListTile(
      leading: CircleAvatar(child: Text(_initial(name))),
      title: Text(name),
      subtitle: Text(CircleRelation.labelFor(_t, relation,
          custom: m['custom_label'] as String?)),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'sharing':
              _openSharing(m);
              break;
            case 'block':
              _act(m, 'block');
              break;
            case 'report':
              _report(m);
              break;
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'sharing', child: Text(_t.circleSharingTitle)),
          PopupMenuItem(value: 'block', child: Text(_t.circleBlock)),
          PopupMenuItem(value: 'report', child: Text(_t.circleReport)),
        ],
      ),
      onTap: accepted ? () => _openChat(m) : null,
    );
  }

  String _initial(String name) =>
      name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
}
