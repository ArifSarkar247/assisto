import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../screens/watchman/watchman_source.dart' show wmDigits, wmList;
import '../screens/watchman/watchman_widgets.dart' show wmLang, wmOk, wmWarn, wmBad, WmPill;
import '../shop_api.dart';
import '../state.dart';
import '../theme.dart';
import 'cctv_cap_section.dart'; // cctvcap: AI checks, 80/100 % notices, extra pack

typedef UsageLoader = Future<Map<String, dynamic>> Function();

/// cctvguard (owner CCTV order G) — "this month's use" on the cameras
/// screen: live minutes, relay MB (counts against the monthly allowance),
/// direct / same-Wi-Fi MB (free, never limited) and the Imou/EZVIZ cloud-live
/// ESTIMATE, per camera. Honest: when the owner has not switched limits on
/// it says the allowance is only counted. Hidden if it cannot load (the rest
/// of the screen never depends on it).
class CctvUsageCard extends StatefulWidget {
  final UsageLoader? load;

  /// cctvcap: buys an extra pack (tests / gallery inject a fake).
  final PackBuyer? buy;

  /// cctvcap: "get credits" when a pack is refused for credits (tests).
  final VoidCallback? onGetCredits;

  /// Gallery / tests: start with the per-camera rows open.
  final bool initiallyOpen;
  const CctvUsageCard(
      {super.key, this.load, this.initiallyOpen = false, this.buy, this.onGetCredits});

  @override
  State<CctvUsageCard> createState() => _CctvUsageCardState();
}

class _CctvUsageCardState extends State<CctvUsageCard> {
  Map<String, dynamic>? _d;
  late bool _open = widget.initiallyOpen;

  @override
  void initState() {
    super.initState();
    UsageLoader? loader = widget.load;
    if (loader == null) {
      try {
        loader = context.read<AppState>().api.cctvUsage;
      } catch (_) {
        return; // no app state (a test without one): stay hidden
      }
    }
    loader().then((d) {
      if (mounted) setState(() => _d = d);
    }, onError: (_) {});
  }

  Future<Map<String, dynamic>> _buy(String kind) {
    final b = widget.buy;
    if (b != null) return b(kind);
    return context.read<AppState>().api.cctvExtraPack(kind);
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    String n(Object? v) => wmDigits(lang, v ?? 0);
    final cams = wmList(d['cameras']);
    final level = (d['level'] ?? '').toString();
    final enforced = d['enforced'] == true;
    final msg = (d['message'] ?? '').toString();
    final scheme = Theme.of(context).colorScheme;
    final pillColor = level == 'paused' ? wmBad() : level == 'notice' ? wmWarn() : wmOk();
    return Card(
      key: const Key('cctvUsageCard'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: cams.isEmpty ? null : () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(children: [
                const Icon(Icons.data_usage_rounded),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.cgUsageTitle,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      enforced
                          ? t.cgUsagePool(n(d['relay_used_mb']), n(d['relay_cap_mb']))
                          : t.cgUsageCounting(n(d['relay_used_mb'])),
                      key: const Key('cctvUsageRelay'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ]),
                ),
                if (cams.isNotEmpty)
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      semanticLabel: _open ? t.cgUsageHide : t.cgUsageShow),
              ]),
            ),
          ),
          if (enforced && (level == 'notice' || level == 'paused')) ...[
            const SizedBox(height: Gap.xs),
            WmPill(
              label: level == 'paused' ? t.cgRelayPausedShort : t.cgRelayNoticeShort(n(d['relay_pct'])),
              icon: level == 'paused' ? Icons.pause_circle_rounded : Icons.info_rounded,
              color: pillColor,
            ),
          ],
          if (msg.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(msg, key: const Key('cctvUsageMsg'), style: Theme.of(context).textTheme.bodySmall),
          ],
          if (d['cap'] is Map)
            CctvCapSection(
              cap: Map<String, dynamic>.from(d['cap'] as Map),
              buy: _buy,
              onGetCredits: widget.onGetCredits,
              onBought: (u) {
                if (mounted) setState(() => _d = u);
              },
            ),
          if (_open)
            for (final c in cams) ...[
              const Divider(height: Gap.lg),
              Text((c['name'] ?? '').toString().isEmpty ? t.wmUnnamedCamera : c['name'].toString(),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(t.cgUsageCamLine(n(c['live_min']), n(c['relay_mb']), n(c['direct_mb'])),
                  style: Theme.of(context).textTheme.bodySmall),
              if (((c['vendor_min'] as num?) ?? 0) > 0)
                Text(t.cgUsageVendorLine(n(c['vendor_min']), n(c['vendor_est_mb'])),
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          const SizedBox(height: Gap.xs),
          Text(t.cgUsageFreeNote,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
        ]),
      ),
    );
  }
}
