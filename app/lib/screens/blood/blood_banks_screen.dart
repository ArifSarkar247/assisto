import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'bp_common.dart';

/// blood (owner 2 Nov) — blood banks: ONLY from an official / verified
/// published list, shown with its source + date. No licensed list is
/// available offline yet, so this is an honest "source pending" state (no
/// invented entries) with what the person can do right now.
class BloodBanksScreen extends StatefulWidget {
  const BloodBanksScreen({super.key});

  @override
  State<BloodBanksScreen> createState() => _BloodBanksScreenState();
}

class _BloodBanksScreenState extends State<BloodBanksScreen> {
  bool _loading = true;
  bool _failed = false;
  Map<String, dynamic> _d = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.bpBanks();
      if (!mounted) return;
      setState(() {
        _d = r;
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
    final banks = bpRows(_d, 'banks');
    final src = bpMap(_d['source']);
    return Scaffold(
      appBar: AppBar(title: Text(t.bpBanksTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: BpError(onRetry: _load))
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
                  children: [
                    if (banks.isEmpty)
                      BpEmpty(
                        icon: Icons.local_hospital_outlined,
                        title: t.bpBanksPending,
                        steps: [t.bpBanksStep1, t.bpBanksStep2, t.bpBanksStep3],
                        cta: t.bpBanksFindDonors,
                        ctaKey: const ValueKey('bp-banks-find'),
                        onCta: () => Navigator.of(context).maybePop(),
                      ),
                    if (banks.isNotEmpty) ...[
                      Text(t.bpBanksSource('${src['name'] ?? ''}', '${src['date'] ?? ''}'),
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: Gap.sm),
                      for (final b in banks)
                        Card(
                          margin: const EdgeInsets.only(bottom: Gap.sm),
                          child: ListTile(
                            minVerticalPadding: Gap.md,
                            title: Text('${b['name'] ?? ''}'),
                            subtitle: Text('${b['area'] ?? ''}'),
                            trailing: '${b['phone'] ?? ''}'.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: t.bpCall,
                                    onPressed: () => bpLaunch(context, 'tel', '${b['phone']}'),
                                    icon: const Icon(Icons.call_rounded),
                                  ),
                          ),
                        ),
                    ],
                  ],
                ),
    );
  }
}
