import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_hub_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../circle_chat_screen.dart';

/// MY CIRCLE HUB ⋮ → Starred messages (SPEC §2).
///
/// All starred messages across every chat in one place. Tapping a row jumps to
/// the conversation it lives in (opens the peer's E2E thread — the thread owns
/// the scroll). Degrades to honest loading / empty / error states while the
/// backend agent lands `/circle/starred` — never a dead tap.
class StarredMessagesScreen extends StatefulWidget {
  final IdentityKeyPair? identity;

  /// Accepted circle members, used to resolve a starred row's peer into the
  /// member map [CircleChatScreen] expects.
  final List<Map<String, dynamic>> members;
  const StarredMessagesScreen(
      {super.key, this.identity, this.members = const []});

  @override
  State<StarredMessagesScreen> createState() => _StarredMessagesScreenState();
}

class _StarredMessagesScreenState extends State<StarredMessagesScreen> {
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      _items = await _api.hubStarredMessages();
      _failed = false;
    } catch (_) {
      _items = [];
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic>? _memberFor(Map<String, dynamic> row) {
    final peerId = '${row['peer_id'] ?? row['peer'] ?? ''}';
    if (peerId.isEmpty) return null;
    for (final m in widget.members) {
      if ('${m['id']}' == peerId) return m;
    }
    // Fall back to a minimal member map so the thread can still open.
    return {'id': row['peer_id'] ?? row['peer'], 'name': row['peer_name'] ?? ''};
  }

  void _jump(Map<String, dynamic> row) {
    final identity = widget.identity;
    final member = _memberFor(row);
    if (identity == null || member == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleChatScreen(member: member, identity: identity),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrStarredTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? _error()
              : _items.isEmpty
                  ? _empty()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: Gap.lg),
                        itemBuilder: (_, i) => _row(_items[i]),
                      ),
                    ),
    );
  }

  Widget _row(Map<String, dynamic> row) {
    final t = _t;
    final peer = '${row['peer_name'] ?? ''}';
    final preview = '${row['preview'] ?? row['text'] ?? ''}';
    return ListTile(
      leading: const Icon(Icons.star, color: Colors.amber),
      title: Text(peer.isEmpty ? '?' : peer,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(preview.isEmpty ? t.msgrStarredJump : preview,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _jump(row),
    );
  }

  Widget _empty() => _centeredState(
      Icons.star_outline, _t.msgrStarredEmptyTitle, _t.msgrStarredEmptyBody);

  Widget _error() {
    final t = _t;
    return ListView(children: [
      const SizedBox(height: 96),
      _centeredState(Icons.cloud_off_outlined, t.msgrHubLoadFailed, ''),
      const SizedBox(height: Gap.md),
      Center(
        child: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text(t.msgrRetry),
        ),
      ),
    ]);
  }

  Widget _centeredState(IconData icon, String title, String body) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 52, color: scheme.primary.withValues(alpha: 0.7)),
          const SizedBox(height: Gap.md),
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          if (body.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
        ]),
      ),
    );
  }
}
