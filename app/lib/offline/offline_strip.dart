import 'package:flutter/material.dart';

import '../widgets/offline_strings.dart';
import 'net_status.dart';

/// offline1st — the small app-wide "Offline" strip (owner order 10 Nov).
///
/// Sits above every screen (MaterialApp.builder) while [NetStatus] says the
/// server cannot be reached; draws NOTHING while online. It takes the status
/// bar inset itself and removes it from the screen below, so app bars stay
/// tappable and nothing is clipped. Text + icon (never colour-only), wraps at
/// 200% font, theme tertiaryContainer pair (AA in light and dark), TalkBack
/// live region. Not interactive: the app keeps working on its saved copies
/// and syncs by itself when the network is back.
class OfflineStrip extends StatelessWidget {
  const OfflineStrip({super.key, required this.child, this.status});

  final Widget child;

  /// Tests inject their own; the app uses [NetStatus.instance].
  final NetStatus? status;

  @override
  Widget build(BuildContext context) {
    final ns = status ?? NetStatus.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: ns.online,
      child: child,
      builder: (context, online, child) {
        // The tree shape NEVER changes with the status (the Navigator below
        // keeps every open screen): only the strip's slot and the top inset.
        final scheme = Theme.of(context).colorScheme;
        final mq = MediaQuery.of(context);
        return Column(
          children: [
            if (online) const SizedBox.shrink() else Semantics(
              key: const Key('offline-strip'),
              container: true,
              liveRegion: true,
              label: oStr(context, 'offStatusOfflineSub'),
              excludeSemantics: true,
              child: Material(
                color: scheme.tertiaryContainer,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      12 + mq.padding.left, mq.padding.top + 4, 12 + mq.padding.right, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cloud_off_rounded,
                          size: 16, color: scheme.onTertiaryContainer),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          oStr(context, 'offStatusOfflineSub'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: scheme.onTertiaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: !online,
                child: child!,
              ),
            ),
          ],
        );
      },
    );
  }
}
