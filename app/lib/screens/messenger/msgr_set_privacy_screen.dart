import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../widgets/msgr_avatar.dart';
import '../../widgets/msgr_set_tiles.dart';
import '../circle_privacy_screen.dart';

/// Privacy hub for the full-spec Settings. The field visibility toggles
/// (last seen / online / profile photo / about / status) plus read receipts and
/// who-can-call ALREADY live in [CirclePrivacyScreen] — this hub links to it
/// for those (no duplication) and EXTENDS it with the surfaces it lacks:
/// who-can-message (via message requests), the BLOCKED list, and message
/// requests. Those two lists are new honest screens backed by
/// [MessengerSettingsApi].
class MsgrSetPrivacyScreen extends StatelessWidget {
  const MsgrSetPrivacyScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetPrivacy)),
      body: ListView(
        children: [
          MsgrSetSection(t.msgrSetPrivacyVisibilitySection),
          MsgrSetRow(
            icon: Icons.visibility_outlined,
            title: t.msgrSetPrivacyWhoCanSee,
            // last seen / online / profile photo / about / status all live in
            // the existing circle privacy screen — no duplication here.
            subtitle: t.msgrSetPrivacyWhoCanSeeSub,
            onTap: () => _open(context, const CirclePrivacyScreen()),
          ),
          MsgrSetRow(
            icon: Icons.done_all,
            title: t.msgrSetPrivacyReadReceipts,
            subtitle: t.msgrSetPrivacyReadReceiptsSub,
            onTap: () => _open(context, const CirclePrivacyScreen()),
          ),
          MsgrSetRow(
            icon: Icons.call_outlined,
            title: t.msgrSetPrivacyWhoCanCall,
            subtitle: t.msgrSetPrivacyWhoCanCallSub,
            onTap: () => _open(context, const CirclePrivacyScreen()),
          ),
          const Divider(),
          MsgrSetSection(t.msgrSetPrivacyContactsSection),
          MsgrSetRow(
            icon: Icons.message_outlined,
            title: t.msgrSetPrivacyWhoCanMessage,
            subtitle: t.msgrSetPrivacyWhoCanMessageSub,
            onTap: () => _open(context, const MsgrSetMessageRequestsScreen()),
          ),
          MsgrSetRow(
            icon: Icons.block,
            title: t.msgrSetPrivacyBlocked,
            subtitle: t.msgrSetPrivacyBlockedSub,
            onTap: () => _open(context, const MsgrSetBlockedListScreen()),
          ),
          MsgrSetNote(t.msgrSetPrivacyServerNote,
              icon: Icons.verified_user_outlined),
        ],
      ),
    );
  }
}

/// Blocked list — people the user has blocked; each can be unblocked. Backed by
/// [MessengerSettingsApi.blockedList] + unblock (which reuses the existing
/// /circle/<member>/controls endpoint).
class MsgrSetBlockedListScreen extends StatefulWidget {
  const MsgrSetBlockedListScreen({super.key});

  @override
  State<MsgrSetBlockedListScreen> createState() =>
      _MsgrSetBlockedListScreenState();
}

class _MsgrSetBlockedListScreenState extends State<MsgrSetBlockedListScreen> {
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _items = [];

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.blockedList();
      final list = (r['blocked'] as List?) ?? const [];
      _items = list.map((e) => (e as Map).cast<String, dynamic>()).toList();
      _failed = false;
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _unblock(Map<String, dynamic> m) async {
    final id = int.tryParse('${m['id']}');
    if (id == null) return;
    try {
      await _api.unblock(id);
      setState(() => _items.remove(m));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.msgrSetUnblockedToast)));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetPrivacyBlocked)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_failed
              ? MsgrSetComingSoon(
                  title: t.msgrSetPrivacyBlocked,
                  requirement: t.msgrSetBlockedUnavailable,
                  icon: Icons.block)
              : (_items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(t.msgrSetBlockedEmpty,
                            textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = _items[i];
                        return ListTile(
                          leading: MsgrAvatar(
                              name: '${m['name'] ?? ''}',
                              photoUrl: '${m['photo'] ?? ''}',
                              radius: 20),
                          title: Text('${m['name'] ?? m['phone'] ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${m['phone'] ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: TextButton(
                              onPressed: () => _unblock(m),
                              child: Text(t.msgrSetUnblock)),
                        );
                      },
                    ))),
    );
  }
}

/// Message requests — people outside the circle who want to message when
/// "who can message" is restricted. Accept / decline / block, backed by
/// [MessengerSettingsApi.messageRequests].
class MsgrSetMessageRequestsScreen extends StatefulWidget {
  const MsgrSetMessageRequestsScreen({super.key});

  @override
  State<MsgrSetMessageRequestsScreen> createState() =>
      _MsgrSetMessageRequestsScreenState();
}

class _MsgrSetMessageRequestsScreenState
    extends State<MsgrSetMessageRequestsScreen> {
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _items = [];

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.messageRequests();
      final list = (r['requests'] as List?) ?? const [];
      _items = list.map((e) => (e as Map).cast<String, dynamic>()).toList();
      _failed = false;
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _act(Map<String, dynamic> m, String action) async {
    try {
      await _api.messageRequestAct('${m['id']}', action);
      setState(() => _items.remove(m));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetPrivacyWhoCanMessage)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_failed
              ? MsgrSetComingSoon(
                  title: t.msgrSetPrivacyWhoCanMessage,
                  requirement: t.msgrSetRequestsUnavailable,
                  icon: Icons.message_outlined)
              : (_items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(t.msgrSetRequestsEmpty,
                            textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = _items[i];
                        return ListTile(
                          leading: MsgrAvatar(
                              name: '${m['name'] ?? ''}',
                              photoUrl: '${m['photo'] ?? ''}',
                              radius: 20),
                          title: Text('${m['name'] ?? m['phone'] ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${m['preview'] ?? m['phone'] ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.check),
                                tooltip: t.msgrSetRequestAccept,
                                onPressed: () => _act(m, 'accept'),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: t.msgrSetRequestDecline,
                                onPressed: () => _act(m, 'decline'),
                              ),
                            ],
                          ),
                        );
                      },
                    ))),
    );
  }
}
