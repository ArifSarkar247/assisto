import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/circle_status_ring.dart';
import 'circle_status_composer_screen.dart';
import 'circle_status_viewer_screen.dart';

/// Connected Circle STATUS / STORIES tray (M2 item 8).
///
/// WhatsApp Status + Messenger Stories equivalent. Shows "My status" plus one
/// tile per author whose active (<24h) status I'm allowed to see — grouped and
/// ranked by the backend (circle_status.group_by_author): unseen first.
///
/// EVERYTHING is E2E / ciphertext-only on the server and SERVER-ENFORCED:
/// visibility is resolved per viewer (circle_status.can_view_status), so a
/// hidden status is never sent to me; expiry (24h) is stamped and purged
/// server-side (circle_status.cleanup_plan).
///
/// Backend seam (integrator wires — see MIGRATION NOTE in the report):
///   GET  /circle/status            -> {mine?, entries:[{author_id, author{},
///                                       count, has_unseen, latest_at}]}
///   GET  /circle/status/mine       -> {statuses:[...], viewer_count}
///   POST /circle/status            -> post a 24h status (ciphertext only)
///   POST /circle/status/{id}/view  -> record a view (reciprocal receipts)
///   POST /circle/status/mute       -> mute/unmute an author
class CircleStatusScreen extends StatefulWidget {
  /// The caller's on-device identity (private key never leaves the device).
  final IdentityKeyPair identity;

  /// The caller's circle members [{id, name, relation, public_key}] — used for
  /// the audience picker and to decrypt/encrypt per peer. Passed in by the
  /// circle screen so we don't refetch.
  final List<Map<String, dynamic>> members;

  const CircleStatusScreen({
    super.key,
    required this.identity,
    required this.members,
  });

  @override
  State<CircleStatusScreen> createState() => _CircleStatusScreenState();
}

class _CircleStatusScreenState extends State<CircleStatusScreen> {
  bool _loading = true;
  bool _errored = false; // honest state: a load failure is NOT shown as "empty"
  List<Map<String, dynamic>> _entries = [];
  Map<String, dynamic>? _mine;

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;

  Map<String, dynamic>? _memberById(int id) {
    for (final m in widget.members) {
      if (m['id'] == id) return m;
    }
    return null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errored = false;
    });
    try {
      final r = await _api.statusTray();
      _entries = ((r['entries'] ?? []) as List).cast<Map<String, dynamic>>();
      _mine = (r['mine'] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      // HONEST state (§21): a fetch failure is an ERROR, never a silent "no
      // updates" — the empty tray must mean "genuinely nothing", not "offline".
      _entries = [];
      _mine = null;
      _errored = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openComposer() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CircleStatusComposerScreen(
          identity: widget.identity,
          members: widget.members,
        ),
      ),
    );
    if (posted == true) _load();
  }

  Future<void> _openAuthor(int authorId) async {
    final member = _memberById(authorId);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CircleStatusViewerScreen(
          identity: widget.identity,
          authorId: authorId,
          authorName: '${member?['name'] ?? ''}',
          authorPublicKeyB64: member?['public_key'] as String?,
        ),
      ),
    );
    _load(); // refresh unseen rings
  }

  Future<void> _openMine() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CircleStatusViewerScreen(
          identity: widget.identity,
          authorId: context.read<AppState>().user?.id ?? -1,
          authorName: AppLocalizations.of(context).statusMine,
          authorPublicKeyB64: null,
          mine: true,
        ),
      ),
    );
    _load();
  }

  String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return parts.first.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(s.statusTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openComposer,
        icon: const Icon(Icons.add),
        label: Text(s.statusAdd),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errored
              ? _ErrorRetry(message: s.statusLoadFailed, onRetry: _load)
              : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  // My status tile.
                  ListTile(
                    leading: CircleStatusRing(
                      label: _initials(
                          '${context.read<AppState>().user?.name ?? '?'}'),
                      hasUnseen: false,
                      segments: (_mine?['count'] as int?) ?? 1,
                      icon: (_mine == null) ? Icons.add : null,
                    ),
                    title: Text(s.statusMine),
                    subtitle:
                        Text(_mine == null ? s.statusTapToAdd : s.statusViewers),
                    onTap: _mine == null ? _openComposer : _openMine,
                    trailing: IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: _openComposer,
                    ),
                  ),
                  const Divider(),
                  if (_entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Gap.xxl),
                      child: Column(
                        children: [
                          Icon(Icons.auto_awesome_outlined,
                              size: 48, color: scheme.outline),
                          const SizedBox(height: Gap.md),
                          Text(s.statusNoUpdates,
                              style:
                                  TextStyle(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          Gap.lg, Gap.sm, Gap.lg, Gap.xs),
                      child: Text(s.statusRecentUpdates,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                    for (final e in _entries)
                      _TrayTile(
                        name: '${_memberById(e['author_id'] as int)?['name'] ?? '?'}',
                        initials: _initials(
                            '${_memberById(e['author_id'] as int)?['name'] ?? '?'}'),
                        count: (e['count'] as int?) ?? 1,
                        hasUnseen: e['has_unseen'] == true,
                        onTap: () => _openAuthor(e['author_id'] as int),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

/// Honest error state with a Retry (§21): shown when the tray failed to load,
/// so an empty tray is never confused with an offline/error one.
class _ErrorRetry extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: Gap.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Gap.lg),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(s.retry),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrayTile extends StatelessWidget {
  final String name;
  final String initials;
  final int count;
  final bool hasUnseen;
  final VoidCallback onTap;

  const _TrayTile({
    required this.name,
    required this.initials,
    required this.count,
    required this.hasUnseen,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleStatusRing(
        label: initials,
        hasUnseen: hasUnseen,
        segments: count,
      ),
      title: Text(name),
      onTap: onTap,
    );
  }
}
