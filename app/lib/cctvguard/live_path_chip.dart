import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'live_cost.dart';

/// cctvguard / cctvcap: the live view's "which way is the video going" chip.
/// Same Wi-Fi and direct (P2P) are free and never limited; relay is the only
/// path that uses the monthly allowance. Once a session went through the
/// relay it stays "relay" (latched — its bytes count as relay).
class LivePathChip extends StatelessWidget {
  final LivePath path;
  final bool relayed;
  const LivePathChip({super.key, required this.path, this.relayed = false});

  @override
  Widget build(BuildContext context) {
    final p = LiveCost.badge(relayed: relayed, path: path);
    if (p == LivePath.unknown) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final free = p != LivePath.relay;
    final label = switch (p) {
      LivePath.lan => t.cgPathLan,
      LivePath.direct => t.cgPathDirect,
      _ => t.cgPathRelay,
    };
    return Semantics(
      label: label,
      child: Chip(
        key: const Key('shopLivePath'),
        avatar: Icon(
            p == LivePath.relay
                ? Icons.cloud_sync_rounded
                : p == LivePath.lan
                    ? Icons.wifi_rounded
                    : Icons.bolt_rounded,
            size: 18,
            color: free ? AssistoTokens.of(context).success : scheme.tertiary),
        label: Text(label),
      ),
    );
  }
}
