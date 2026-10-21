import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_hub_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../circle_extras_broadcast_screen.dart';

/// MY CIRCLE HUB ⋮ → Broadcast lists (SPEC §2).
///
/// A broadcast list sends ONE message to many chosen circle members as
/// SEPARATE private 1:1 messages — recipients never see each other and are
/// never linked server-side (that would be a group). Only recipients who have
/// YOU in their circle receive it; we surface that honestly as a footer note.
///
/// This screen lists the user's saved lists and lets them compose a new
/// broadcast via the existing [CircleExtrasBroadcastScreen] compose/fan-out.
/// It degrades to an honest empty / error state until the list endpoint is
/// live — never a dead tap.
class BroadcastListsScreen extends StatefulWidget {
  final IdentityKeyPair? identity;
  final List<Map<String, dynamic>> members;
  const BroadcastListsScreen(
      {super.key, this.identity, this.members = const []});

  @override
  State<BroadcastListsScreen> createState() => _BroadcastListsScreenState();
}

class _BroadcastListsScreenState extends State<BroadcastListsScreen> {
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _lists = [];

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
      // Broadcast lists are a flavour of custom list; reuse the list endpoint.
      _lists = await _api.hubCustomLists();
      _failed = false;
    } catch (_) {
      _lists = [];
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _compose() {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => CircleExtrasBroadcastScreen(members: widget.members),
        ))
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrBroadcastTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _compose,
        icon: const Icon(Icons.campaign_outlined),
        label: Text(t.msgrBroadcastNew),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          // QA a6: the note sat at the bottom where the FAB covered it —
          // now a header strip.
          : Column(children: [
              _noteFooter(),
              Expanded(
                child: _failed
                    ? _error()
                    : _lists.isEmpty
                        ? _empty()
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              itemCount: _lists.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, indent: Gap.lg),
                              itemBuilder: (_, i) => _row(_lists[i]),
                            ),
                          ),
              ),
            ]),
    );
  }

  Widget _row(Map<String, dynamic> l) {
    final t = _t;
    final count = (l['count'] as int?) ?? (l['recipients'] as List?)?.length ?? 0;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.campaign_outlined)),
      title: Text('${l['name'] ?? ''}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${t.msgrBroadcastRecipients}: ${_digits(count)}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: _compose,
    );
  }

  Widget _noteFooter() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(_t.msgrBroadcastNote,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant, height: 1.3)),
          ),
        ]),
      ),
    );
  }

  Widget _empty() => _centeredState(
      Icons.campaign_outlined, _t.msgrBroadcastEmptyTitle,
      _t.msgrBroadcastEmptyBody);

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
                style:
                    TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
        ]),
      ),
    );
  }

  String _digits(int n) {
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    if (!bn) return '$n';
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final cu in '$n'.codeUnits) {
      b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? bnZero + (cu - 0x30) : cu);
    }
    return b.toString();
  }
}
