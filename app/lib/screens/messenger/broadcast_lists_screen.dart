import 'package:flutter/material.dart';
import '../../widgets/msgr_channel_common.dart' show MsgrEmptyState;
import '../../ds/ds.dart';
import '../../widgets/skeleton.dart' show SkeletonList;
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_hub_api.dart';
import '../../messaging/broadcast_send.dart'; // f6
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../circle_extras_broadcast_screen.dart';
import '../../services/error_kind.dart' show serverFailText; // qa2

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
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
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
    } catch (e) {
      _lists = [];
      _failed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _compose() {
    Navigator.of(context)
        .push(MaterialPageRoute(
          // f6: the compose screen gets the REAL sender (per-recipient E2E
          // seal + 1:1 post, outbox for keyless members). Before f6 it had
          // none, so every broadcast failed.
          builder: (_) => CircleExtrasBroadcastScreen(
            members: widget.members,
            onSend: widget.identity == null
                ? null
                : (ids, text) async {
                    final r = await sendBroadcastText(
                        _api, widget.identity!, ids, text,
                        members: widget.members);
                    if (r.delivered == 0) {
                      throw StateError('broadcast: nothing was sent');
                    }
                  },
          ),
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
        icon: const Icon(Icons.campaign_rounded),
        label: Text(t.msgrBroadcastNew),
      ),
      body: _loading
          ? const SkeletonList(count: 4)
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
                            // flat bordered DS rows; room for the FAB
                            child: ListView.separated(
                              padding: withNavBarInset(context,
                                  const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 96)),
                              itemCount: _lists.length,
                              separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
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
    final ds = Theme.of(context).colorScheme.ds;
    return DsSurface(
      flat: true,
      borderColor: ds.border,
      padding: EdgeInsets.zero,
      child: DsListRow(
        leading: DsAvatar(size: 40, child: Icon(Icons.campaign_rounded, size: 20, color: ds.primaryInk)),
        title: '${l['name'] ?? ''}',
        subtitle: '${t.msgrBroadcastRecipients}: ${_digits(count)}',
        trailing: Icon(Icons.chevron_right_rounded, color: ds.muted),
        onTap: _compose,
      ),
    );
  }

  Widget _noteFooter() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.ds.cardHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 18, color: scheme.ds.muted),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(_t.msgrBroadcastNote,
                style: AType.bodySmall.copyWith(color: scheme.ds.muted, height: 1.4)),
          ),
        ]),
      ),
    );
  }

  Widget _empty() => _centeredState(
      Icons.campaign_rounded, _t.msgrBroadcastEmptyTitle,
      _t.msgrBroadcastEmptyBody);

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
