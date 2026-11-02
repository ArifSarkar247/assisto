import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../feature_flags.dart';
import '../../state.dart';
import 'blood_hub_screen.dart';

/// Test seam: replaces GET /blood-panel/me.
Future<Map<String, dynamic>> Function()? bloodDonorEntryLoaderOverride;

/// finish1 (owner final 2 Nov): "I am a blood donor" switch, reachable from
/// the profile (Settings) and the Family card (Emergency card), besides the
/// blood panel itself. ON opens the donor's own page (separate consent there
/// — the Family card's blood group never leaves the phone); OFF stops being
/// listed at once (never gated). Hidden while the `blood_donors` flag is off.
class BloodDonorSwitchTile extends StatefulWidget {
  const BloodDonorSwitchTile({super.key});

  @override
  State<BloodDonorSwitchTile> createState() => _BloodDonorSwitchTileState();
}

class _BloodDonorSwitchTileState extends State<BloodDonorSwitchTile> {
  Map<String, dynamic>? _me;
  bool _busy = false;

  bool get _on => FeatureFlags.instance.isOn('blood_donors');

  @override
  void initState() {
    super.initState();
    if (_on) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = bloodDonorEntryLoaderOverride != null
          ? await bloodDonorEntryLoaderOverride!()
          : await context.read<AppState>().api.bpMe();
      if (mounted) setState(() => _me = r);
    } catch (_) {
      if (mounted) setState(() => _me = const {});
    }
  }

  Future<void> _openMine() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const BloodHubScreen(initialTab: 2)));
    if (mounted) unawaited(_load());
  }

  Future<void> _toggle(bool v) async {
    if (v) return _openMine(); // consent + group + area live on the donor page
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.bpSaveMe({'enabled': false});
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (r['me'] is Map) _me = Map<String, dynamic>.from(r['me'] as Map);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.bpErrGeneric)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_on) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final me = _me ?? const {};
    final listed = me['enabled'] == true;
    final paused = listed && me['available'] == false;
    return SwitchListTile(
      key: const ValueKey('bp-donor-switch'),
      secondary: const Icon(Icons.bloodtype_rounded),
      title: Text(t.bpIAmDonor),
      subtitle: Text(!listed
          ? t.bpIAmDonorOffSub
          : (paused ? t.bpPaused : t.bpListed)),
      value: listed,
      onChanged: (_me == null || _busy) ? null : _toggle,
    );
  }
}
