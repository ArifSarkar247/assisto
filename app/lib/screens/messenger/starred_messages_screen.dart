import 'package:flutter/material.dart';
import '../../widgets/msgr_channel_common.dart' show MsgrEmptyState;
import '../../ds/ds.dart';
import '../../widgets/skeleton.dart' show SkeletonList;
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_hub_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../circle_chat_screen.dart';
import '../../services/error_kind.dart' show serverFailText; // qa2

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
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
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
    } catch (e) {
      _items = [];
      _failed = true;
      _failCause = e;
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
          ? const SkeletonList(count: 4)
          : _failed
              ? _error()
              : _items.isEmpty
                  ? _empty()
                  : RefreshIndicator(
                      onRefresh: _load,
                      // flat bordered DS rows (GPU-light for long lists)
                      child: ListView.separated(
                        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                        itemBuilder: (_, i) => _row(_items[i]),
                      ),
                    ),
    );
  }

  Widget _row(Map<String, dynamic> row) {
    final t = _t;
    final peer = '${row['peer_name'] ?? ''}';
    final preview = '${row['preview'] ?? row['text'] ?? ''}';
    final ds = Theme.of(context).colorScheme.ds;
    return DsSurface(
      flat: true,
      borderColor: ds.border,
      padding: EdgeInsets.zero,
      child: DsListRow(
        leading: DsAvatar(
            size: 40,
            color: AssistoTokens.of(context).warning,
            child: Icon(Icons.star_rounded, size: 20,
                color: Brand.onTint(context, AssistoTokens.of(context).warning))),
        title: peer.isEmpty ? '?' : peer,
        // the message preview (two lines is a preview, the chat has it all)
        subtitle: preview.isEmpty ? t.msgrStarredJump : preview,
        trailing: Icon(Icons.chevron_right_rounded, color: ds.muted),
        onTap: () => _jump(row),
      ),
    );
  }

  Widget _empty() => _centeredState(
      Icons.star_outline_rounded, _t.msgrStarredEmptyTitle, _t.msgrStarredEmptyBody);

  Widget _error() {
    final t = _t;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      const SizedBox(height: Gap.xl),
      MsgrEmptyState(
        icon: Icons.cloud_off_rounded,
        title: t.msgrHubLoadFailed,
        body: serverFailText(t, _failCause) ?? '',
        action: DsButton(onPressed: _load, icon: Icons.refresh_rounded, label: t.msgrRetry),
      ),
    ]);
  }

  Widget _centeredState(IconData icon, String title, String body) =>
      MsgrEmptyState(icon: icon, title: title, body: body);
}
