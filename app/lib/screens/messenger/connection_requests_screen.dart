import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_api.dart';
import '../../state.dart';
import '../../widgets/msgr_avatar.dart';

/// Personal connection requests — the Sent/Cancel vs Requests/Accept-Decline
/// pattern (the circle 2b fix). A SENDER can only CANCEL their own outgoing
/// request; only the RECIPIENT may Accept/Decline an incoming one. Block +
/// report are surfaced here, and the daily-limit message is shown when the
/// server rejects a new send.
///
/// Relationship is mandatory before a request is sent — that form lives in
/// [showMsgrConnectSheet] (used by the contacts screen); this screen manages
/// the resulting request lifecycle.
class ConnectionRequestsScreen extends StatefulWidget {
  const ConnectionRequestsScreen({super.key});

  @override
  State<ConnectionRequestsScreen> createState() =>
      _ConnectionRequestsScreenState();
}

class _ConnectionRequestsScreenState extends State<ConnectionRequestsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  bool _loading = true;
  List<Map<String, dynamic>> _requests = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  bool _isIncoming(Map<String, dynamic> r) {
    final dir = '${r['direction'] ?? ''}';
    if (dir == 'incoming') return true;
    if (dir == 'outgoing') return false;
    final actions =
        ((r['actions'] as List?) ?? const []).map((e) => '$e').toList();
    return actions.contains('accept');
  }

  List<Map<String, dynamic>> get _incoming =>
      _requests.where(_isIncoming).toList();
  List<Map<String, dynamic>> get _outgoing =>
      _requests.where((r) => !_isIncoming(r)).toList();

  Future<void> _load() async {
    try {
      final r = await _api.getJson('/messenger/request');
      _requests = ((r['results'] ?? r['requests'] ?? []) as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      _requests = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _act(Map<String, dynamic> r, String event) async {
    final id = (r['id'] as num).toInt();
    try {
      final res = await _api.connectionAct(requestId: id, event: event);
      // Daily-limit (or other server guard) surfaces as {ok:false, error:...}.
      if (res['ok'] == false) {
        _handleGuard(res);
        return;
      }
      await _load();
    } catch (_) {
      _snack(_t.msgrSomethingWrong);
    }
  }

  void _handleGuard(Map<String, dynamic> res) {
    final err = '${res['error'] ?? ''}';
    if (err.contains('limit') || err.contains('daily')) {
      _snack(_t.msgrDailyLimitReached);
    } else if (err.contains('pre_accept') || err.contains('note')) {
      _snack(_t.msgrPreAcceptNote);
    } else {
      _snack(_t.msgrSomethingWrong);
    }
  }

  Future<void> _report(Map<String, dynamic> r) async {
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final t = _t;
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                title: Text(t.msgrReportSpam),
                onTap: () => Navigator.pop(ctx, ('report', 'spam'))),
            ListTile(
                title: Text(t.msgrReportHarassment),
                onTap: () =>
                    Navigator.pop(ctx, ('report', 'harassment'))),
            ListTile(
                title: Text(t.msgrReportOther),
                onTap: () => Navigator.pop(ctx, ('report', 'other'))),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.block,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text(t.msgrBlock,
                  style:
                      TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, ('block', 'block')),
            ),
          ]),
        );
      },
    );
    if (result == null || !mounted) return;
    final id = (r['id'] as num).toInt();
    try {
      await _api.connectionReport(
          requestId: id, action: result.$1, reason: result.$2);
      _snack(result.$1 == 'block'
          ? _t.msgrBlockedNotice
          : _t.msgrReportSubmitted);
      await _load();
    } catch (_) {
      _snack(_t.msgrSomethingWrong);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.msgrConnectTitle),
        bottom: TabBar(controller: _tabs, tabs: [
          Tab(child: Text(t.msgrRequestsIncomingTab, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          Tab(child: Text(t.msgrRequestsSentTab, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(controller: _tabs, children: [
              _list(_incoming, incoming: true),
              _list(_outgoing, incoming: false),
            ]),
    );
  }

  Widget _list(List<Map<String, dynamic>> items, {required bool incoming}) {
    final t = _t;
    if (items.isEmpty) {
      return Center(
        child: Text(
            incoming ? t.msgrNoIncomingRequests : t.msgrNoSentRequests,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) => _tile(items[i], incoming: incoming),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> r, {required bool incoming}) {
    final t = _t;
    final peer = (r['peer'] as Map?)?.cast<String, dynamic>() ??
        (r['requester'] as Map?)?.cast<String, dynamic>() ??
        (r['target'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final name = '${peer['name'] ?? r['name'] ?? ''}';
    final note = '${r['note'] ?? ''}';
    return ListTile(
      leading: MsgrAvatar(
          name: name,
          photoUrl: '${peer['photo_link'] ?? peer['photo'] ?? ''}',
          radius: 22),
      title: Text(name.isEmpty ? '?' : name),
      subtitle: note.isEmpty
          ? Text(t.msgrPending,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant))
          : Text(note, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: incoming
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: t.msgrReport,
                icon: const Icon(Icons.flag_outlined),
                onPressed: () => _report(r),
              ),
              TextButton(
                onPressed: () => _act(r, 'decline'),
                child: Text(t.msgrDecline),
              ),
              FilledButton(
                onPressed: () => _act(r, 'accept'),
                child: Text(t.msgrAccept),
              ),
            ])
          : OutlinedButton(
              onPressed: () => _act(r, 'cancel'),
              child: Text(t.msgrCancel),
            ),
    );
  }
}
