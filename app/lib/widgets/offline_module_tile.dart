import 'package:flutter/material.dart';
import '../theme.dart';
import 'offline_cache.dart';
import 'offline_strings.dart';

/// Resolved, display-ready status for one offline module. Computed off the UI
/// thread-free (just SharedPreferences reads) so the screen can await a batch
/// and render honest states with no spinners-per-row.
class OfflineModuleStatus {
  final OfflineModule module;
  final bool hasData;
  final DateTime? lastSynced;
  final bool stale;
  final int sizeBytes;

  const OfflineModuleStatus({
    required this.module,
    required this.hasData,
    required this.lastSynced,
    required this.stale,
    required this.sizeBytes,
  });

  static Future<OfflineModuleStatus> of(OfflineModule m) async {
    final c = m.cache;
    if (c == null) {
      return OfflineModuleStatus(
          module: m,
          hasData: false,
          lastSynced: null,
          stale: false,
          sizeBytes: 0);
    }
    return OfflineModuleStatus(
      module: m,
      hasData: await c.hasData(),
      lastSynced: await c.lastSynced(),
      stale: await c.isStale(),
      sizeBytes: await c.sizeBytes(),
    );
  }
}

/// One row on the "Offline & data" screen: module name, a "works offline"
/// badge, an honest cached / not-cached / pure-local state, last-synced time,
/// and (when there's a payload) a per-module clear button.
class OfflineModuleTile extends StatelessWidget {
  final OfflineModuleStatus status;
  final VoidCallback? onClear;

  const OfflineModuleTile({super.key, required this.status, this.onClear});

  String _nameKey(String id) =>
      'offMod${id[0].toUpperCase()}${id.substring(1)}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = status.module;
    final pureLocal = m.cache == null;
    final name = oStr(context, _nameKey(m.id));

    // Honest secondary line.
    final String stateLine;
    final Color stateColor;
    if (pureLocal) {
      stateLine = oStr(context, 'offPureLocal');
      stateColor = scheme.onSurfaceVariant;
    } else if (!status.hasData) {
      stateLine = oStr(context, 'offNotCached');
      stateColor = scheme.onSurfaceVariant;
    } else {
      final synced = offlineSyncedLabel(context, status.lastSynced);
      stateLine = status.stale
          ? '$synced • ${oStr(context, 'offStale')}'
          : synced;
      stateColor =
          status.stale ? Brand.warning : scheme.onSurfaceVariant;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
          pureLocal
              ? Icons.offline_bolt_outlined
              : (status.hasData
                  ? Icons.offline_pin_outlined
                  : Icons.cloud_queue_outlined),
          size: 22,
          color: status.hasData || pureLocal
              ? scheme.secondary
              : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (m.worksOffline) ...[
                const SizedBox(width: Gap.sm),
                _Badge(label: oStr(context, 'offWorksOffline'), scheme: scheme),
              ],
            ]),
            const SizedBox(height: 2),
            Text(stateLine,
                style: TextStyle(fontSize: 12, color: stateColor)),
            if (!pureLocal && status.hasData && status.sizeBytes > 0) ...[
              const SizedBox(height: 2),
              Text(offlineSizeLabel(context, status.sizeBytes),
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ]),
        ),
        if (!pureLocal && status.hasData && onClear != null)
          TextButton(
            onPressed: onClear,
            child: Text(oStr(context, 'offClear')),
          ),
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final ColorScheme scheme;
  const _Badge({required this.label, required this.scheme});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: scheme.onSecondaryContainer)),
    );
  }
}
