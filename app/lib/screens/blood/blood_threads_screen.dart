import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'blood_thread_screen.dart';
import 'bp_common.dart';

/// blood (owner 2 Nov) — my private blood-panel conversations (as donor and
/// as seeker). First names + blood group only; no numbers.
class BloodThreadsScreen extends StatefulWidget {
  const BloodThreadsScreen({super.key});

  @override
  State<BloodThreadsScreen> createState() => _BloodThreadsScreenState();
}

class _BloodThreadsScreenState extends State<BloodThreadsScreen> {
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
    return Scaffold(
      appBar: AppBar(title: Text(t.bpMessages)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
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
                      for (final th in _rows)
                        Card(
                          key: ValueKey('bp-thread-${th['id']}'),
                          margin: const EdgeInsets.only(bottom: Gap.sm),
                          child: ListTile(
                            minVerticalPadding: Gap.md,
                            leading: BpGroupBadge('${th['blood_group'] ?? ''}', size: 44),
                            title: Text('${th['other_name'] ?? ''}'),
                            subtitle: Text(th['side'] == 'donor' ? t.bpThreadAsDonor : t.bpThreadAsSeeker),
                            trailing: (th['unread'] is int && (th['unread'] as int) > 0)
                                ? Badge(label: Text(bpD(context, '${th['unread']}')))
                                : const Icon(Icons.chevron_right_rounded),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => BloodThreadScreen(threadId: th['id'] as int)));
                              if (mounted) unawaited(_load());
                            },
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}
