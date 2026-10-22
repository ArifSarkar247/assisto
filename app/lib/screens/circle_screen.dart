import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/identity_vault.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_relation.dart';
import '../widgets/circle_sharing.dart';
import '../widgets/loading_gate.dart';
import '../widgets/m3_circle_widgets.dart';
import 'messenger/m3_add_to_circle_screen.dart';
import 'circle_chat_screen.dart';
import 'circle_group_list_screen.dart';
import 'circle_search_screen.dart';
import 'circle_status_screen.dart';

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

  bool _isIncoming(Map<String, dynamic> r) {
    final dir = '${r['direction'] ?? ''}';
    if (dir == 'incoming') return true;
    if (dir == 'outgoing') return false;
    // Fallback for older payloads: only incoming exposes an accept action.
    final actions =
        ((r['actions'] as List?) ?? const []).map((e) => '$e').toList();
    return actions.contains('accept');
  }

  // Pending requests sent TO me (accept/decline) vs sent BY me (cancel only).
  List<Map<String, dynamic>> get _incoming =>
      _requests.where(_isIncoming).toList();
  List<Map<String, dynamic>> get _outgoing =>
      _requests.where((r) => !_isIncoming(r)).toList();
  // Defence-in-depth: only accepted edges are circle members (server already
  // returns accepted-only, but never render a pending row as a member).
  List<Map<String, dynamic>> get _acceptedMembers => _members
      .where((m) => '${m['state'] ?? 'accepted'}' == 'accepted')
      .toList();

  Future<void> _bootstrap() async {
    try {
      await loadGuard(_ensureIdentity(), timeout: const Duration(seconds: 8));
    } catch (_) {
      // Timed out: keep waiting on the SAME vault load (single-flight) — never
      // a second throw-away key.
      _identity ??= await IdentityVault.instance.get();
    }
    await _load();
  }

  /// Load (or lazily create) the on-device identity key. The PRIVATE key never
  /// leaves the device except as an optional backup sealed under a recovery
  /// code (see KeyBackup). Here we only publish the PUBLIC key to the server so
  /// others can encrypt to us.
  Future<void> _ensureIdentity() async {
    // IdentityVault: secure storage with retry + encrypted app-private
    // fallback; never null, so the chat always opens and the key always
    // publishes even when the Keystore fails (ColorOS / MIUI).
    final id = await IdentityVault.instance.get();
    _identity = id;
    // Publish the PUBLIC key on every open (fire-and-forget; the key service
    // also retries with backoff): new connections only learn our key this way.
    unawaited(_api.postJson('/circle/keys', {
      'public_key': id.publicKeyB64,
      'key_id': id.keyId,
      'scheme': _e2e.scheme,
    }).then((_) {}, onError: (_) {}));
  }

  Future<void> _load() async {
    try {
      final m = await loadGuard(_api.getJson('/circle/members'));
      final r = await loadGuard(_api.getJson('/circle/requests'));
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
    // m3-circle: a failed accept/decline/block used to be swallowed.
    try {
      await _api.postJson('/circle/request/${req['id']}/act', {'event': event});
    } catch (e) {
      if (mounted) m3Snack(context, m3ErrorText(_t, e), error: true);
    }
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
    // m2-reality: a failed report used to show "Reported" anyway.
    var ok = true;
    try {
      await _api.postJson('/circle/${member['id']}/report', {'reason': reason});
    } catch (_) {
      ok = false;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? _t.circleReported : _t.grpActionFailed)));
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
                    } catch (e) {
                      // m3-circle: say so and keep the sheet open to retry.
                      if (ctx.mounted) {
                        m3Snack(ctx, m3ErrorText(_t, e), error: true);
                      }
                      return;
                    }
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

  /// m3-circle: the one "Add to My Circle" flow (any number format, lookup
  /// first, honest not-on-Assisto + invite, QR / link). The old composer sent
  /// the request blind and swallowed every error.
  Future<void> _addFlow() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const M3AddToCircleScreen()));
    await _load();
  }

  Future<void> _openChat(Map<String, dynamic> member) async {
    // Never a silent no-op (see IdentityVault).
    final id = _identity ?? await IdentityVault.instance.get();
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleChatScreen(member: member, identity: id),
    ));
  }

  /// Open the Status/Stories tray, reusing the loaded identity + members
  /// (members carry public_key for per-peer encryption).
  void _openStatus() {
    final id = _identity;
    if (id == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleStatusScreen(identity: id, members: _members),
    ));
  }

  /// Open the Groups list, reusing the loaded identity + circle members.
  void _openGroups() {
    final id = _identity;
    if (id == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          CircleGroupListScreen(identity: id, circleMembers: _members),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_t.circleTitle),
        actions: [
          IconButton(
            tooltip: _t.statusTitle,
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: _openStatus,
          ),
          IconButton(
            tooltip: _t.circleGroupsTitle,
            icon: const Icon(Icons.groups_outlined),
            onPressed: _openGroups,
          ),
          IconButton(
            tooltip: _t.circleSearchAll,
            icon: const Icon(Icons.search),
            onPressed: _members.isEmpty
                ? null
                : () {
                    final id = _identity;
                    if (id == null) return;
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          CircleSearchScreen(members: _members, identity: id),
                    ));
                  },
          ),
        ],
      ),
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
                  // INCOMING requests (sent to me) — accept/decline here.
                  if (_incoming.isNotEmpty) ...[
                    _sectionHeader(_t.circleRequestsSection),
                    for (final r in _incoming) _requestTile(r),
                  ],
                  // OUTGOING requests (I sent) — status "Sent" + cancel only.
                  if (_outgoing.isNotEmpty) ...[
                    _sectionHeader(_t.circleSentRequests),
                    for (final r in _outgoing) _requestTile(r),
                  ],
                  _sectionHeader(_t.circleYourCircle),
                  if (_acceptedMembers.isEmpty) _emptyState(scheme),
                  for (final m in _acceptedMembers) _memberTile(m),
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
            // QA a6: a failed load used to read "Your circle is empty";
            // now it says it couldn't load and offers Retry.
            Text(_backendReady ? _t.circleEmptyTitle : _t.loadFailed,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: Gap.xs),
            Text(
              _backendReady ? _t.circleEmptyBody : _t.qaLoadFailedRetry,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            if (!_backendReady) ...[
              const SizedBox(height: Gap.md),
              FilledButton.tonalIcon(
                onPressed: () {
                  setState(() => _loading = true);
                  _load();
                },
                icon: const Icon(Icons.refresh),
                label: Text(_t.retry),
              ),
            ],
          ],
        ),
      );

  Widget _requestTile(Map<String, dynamic> r) {
    // Resolve the OTHER party's display name/photo (sender for incoming,
    // recipient for outgoing) — the server sends display_name so it never "?".
    final name =
        '${r['display_name'] ?? r['name'] ?? r['sender_name'] ?? ''}'.trim();
    final relation = '${r['relation'] ?? 'friend'}';
    final photo = '${r['photo'] ?? ''}';
    final note = '${r['note'] ?? ''}'.trim();
    // The server tells us the direction + allowed actions; the UI is a pure
    // function of that — the sender NEVER gets accept/decline.
    final direction = '${r['direction'] ?? 'outgoing'}';
    final actions = ((r['actions'] as List?) ?? const [])
        .map((e) => '$e')
        .toList();
    final isIncoming = direction == 'incoming' || actions.contains('accept');
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundImage:
                      photo.isNotEmpty ? NetworkImage(photo) : null,
                  child: photo.isEmpty ? Text(_initial(name)) : null,
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? _t.circleSomeone : name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(CircleRelation.labelFor(_t, relation,
                          custom: r['custom_label'] as String?)),
                    ],
                  ),
                ),
                // Status chip: outgoing reads "Sent", incoming reads "Request".
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    '${r['status_label'] ?? (isIncoming ? _t.circleRequestLabel : _t.circleSent)}',
                  ),
                ),
              ],
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text('"$note"',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            ],
            const SizedBox(height: Gap.sm),
            if (isIncoming)
              // INCOMING (sent to me): Accept / Decline.
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => _act(r, 'decline'),
                    child: Text(_t.circleDecline),
                  ),
                  const SizedBox(width: Gap.sm),
                  FilledButton.icon(
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(_t.circleAccept),
                    style: FilledButton.styleFrom(
                        backgroundColor: Brand.success),
                    onPressed: () => _act(r, 'accept'),
                  ),
                ],
              )
            else
              // OUTGOING (I sent it): Cancel only — NEVER accept/decline.
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.close, size: 18),
                    label: Text(_t.circleCancelRequest),
                    onPressed: () => _act(r, 'cancel'),
                  ),
                ],
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
