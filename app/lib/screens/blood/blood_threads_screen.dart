import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../ds/ds.dart';
import '../../widgets/app_sheet.dart';
import 'blood_thread_screen.dart';
import 'bp_common.dart';
import 'package:assisto/ads/ad_block_context.dart' show AdBlockedState;

/// blood (owner 2 Nov) — my private blood-panel conversations (as donor and
/// as seeker). First names + blood group only; no numbers.
class BloodThreadsScreen extends StatefulWidget {
  const BloodThreadsScreen({super.key});

  @override
  State<BloodThreadsScreen> createState() => _BloodThreadsScreenState();
}

class _BloodThreadsScreenState extends State<BloodThreadsScreen>
    with AdBlockedState<BloodThreadsScreen> {
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.bpThreads();
      if (!mounted) return;
      setState(() {
        _rows = bpRows(r, 'threads');
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.bpMessages)),
      body: _loading
          ? ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: [for (var i = 0; i < 3; i++) Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm), child: DsSkeleton.card(lines: 2))])
          : _failed
              ? Center(child: BpError(onRetry: _load))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
                    children: [
                      if (_rows.isEmpty)
                        BpEmpty(
                          icon: Icons.forum_outlined,
                          title: t.bpThreadsEmpty,
                          steps: [t.bpThreadsStep1, t.bpThreadsStep2, t.bpThreadsStep3],
                          cta: t.bpBack,
                          ctaKey: const ValueKey('bp-threads-back'),
                          onCta: () => Navigator.of(context).maybePop(),
                        ),
                      // designv2: one grouped card, unread count as a primary badge
                      if (_rows.isNotEmpty)
                        DsGroup(margin: EdgeInsets.zero, children: [
                          for (final th in _rows)
                            DsListRow(
                              key: ValueKey('bp-thread-${th['id']}'),
                              leading: BpGroupBadge('${th['blood_group'] ?? ''}', size: 44),
                              title: '${th['other_name'] ?? ''}',
                              subtitle: th['side'] == 'donor' ? t.bpThreadAsDonor : t.bpThreadAsSeeker,
                              trailing: (th['unread'] is int && (th['unread'] as int) > 0)
                                  ? Badge(
                                      backgroundColor: ds.primaryInk,
                                      label: Text(bpD(context, '${th['unread']}')))
                                  : Icon(Icons.chevron_right_rounded, color: ds.muted),
                              onTap: () async {
                                await Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => BloodThreadScreen(threadId: th['id'] as int)));
                                if (mounted) unawaited(_load());
                              },
                            ),
                        ]),
                    ],
                  ),
                ),
    );
  }
}
