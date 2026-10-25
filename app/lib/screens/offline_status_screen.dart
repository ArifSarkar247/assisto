import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/offline_cache.dart';
import '../widgets/offline_strings.dart';
import '../widgets/offline_module_tile.dart';

/// "Offline & data" screen (feature #12, SPEC v2.1 §21 — good -> advanced).
///
/// A single honest place that answers: am I online right now? which modules
/// work offline? how fresh is each saved copy? how much space does it use? and
/// lets the user clear any one module's cache, or all of them, with the server
/// copy never touched.
///
/// It reads ONLY shared, already-public surfaces (AppState.online, the
/// [OfflineModules] registry) — it does not reach into any module's screen, and
/// no Bangla glyph literal appears here (SPEC §21). All strings resolve through
/// [oStr] and are mirrored to .phaseB/up_offline_arb.json for the ARB sync.
class OfflineStatusScreen extends StatefulWidget {
  const OfflineStatusScreen({super.key});
  @override
  State<OfflineStatusScreen> createState() => _OfflineStatusScreenState();
}

class _OfflineStatusScreenState extends State<OfflineStatusScreen> {
  List<OfflineModuleStatus> _statuses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final out = <OfflineModuleStatus>[];
    for (final m in OfflineModules.all()) {
      out.add(await OfflineModuleStatus.of(m));
    }
    if (!mounted) return;
    setState(() {
      _statuses = out;
      _loading = false;
    });
  }

  int get _totalBytes =>
      _statuses.fold(0, (sum, s) => sum + s.sizeBytes);

  bool get _anyClearable =>
      _statuses.any((s) => s.module.cache != null && s.hasData);

  Future<void> _clearOne(OfflineModuleStatus s) async {
    final cache = s.module.cache;
    if (cache == null) return;
    final ok = await _confirm(oStr(context, 'offClearQ'));
    if (ok != true) return;
    await cache.clear();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(oStr(context, 'offCleared'))));
    }
  }

  Future<void> _clearAll() async {
    if (!_anyClearable) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(oStr(context, 'offNothingToClear'))));
      return;
    }
    final ok = await _confirm(oStr(context, 'offClearAllQ'));
    if (ok != true) return;
    for (final s in _statuses) {
      await s.module.cache?.clear();
    }
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(oStr(context, 'offClearedAll'))));
    }
  }

  Future<bool?> _confirm(String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(oStr(context, 'offClear'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(oStr(context, 'offTitle')),
        actions: [
          IconButton(
            tooltip: oStr(context, 'offClearAll'),
            onPressed: _loading ? null : _clearAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(Gap.lg),
                children: [
                  const _LiveStatusCard(),
                  const SizedBox(height: Gap.lg),
                  Text(oStr(context, 'offAvailableOffline'),
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.sm),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Gap.lg, vertical: Gap.sm),
                      child: Column(
                        children: [
                          for (var i = 0; i < _statuses.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            OfflineModuleTile(
                              status: _statuses[i],
                              onClear: () => _clearOne(_statuses[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.lg),
                  _DataUsageCard(
                    totalLabel: offlineSizeLabel(context, _totalBytes),
                    onClearAll: _anyClearable ? _clearAll : null,
                  ),
                  const SizedBox(height: Gap.md),
                  Row(children: [
                    Icon(Icons.lock_outline,
                        size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(oStr(context, 'offServerSafeNote'),
                          style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  ]),
                ],
              ),
            ),
    );
  }
}

/// Live online/offline card that rebuilds from [AppState.online]. Honest: it
/// reflects the real connectivity state the app last observed on a sync.
class _LiveStatusCard extends StatelessWidget {
  const _LiveStatusCard();
  @override
  Widget build(BuildContext context) {
    final online = context.select<AppState, bool>((s) => s.online);
    final scheme = Theme.of(context).colorScheme;
    final good = online;
    final bg = good ? scheme.secondaryContainer : scheme.tertiaryContainer;
    final fg = good ? scheme.onSecondaryContainer : scheme.onTertiaryContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(good ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: fg),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                oStr(context, good ? 'offStatusOnline' : 'offStatusOffline'),
                style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
            const SizedBox(height: Gap.xxs),
            Text(
                oStr(context,
                    good ? 'offStatusOnlineSub' : 'offStatusOfflineSub'),
                style: AType.bodySmall.copyWith(color: fg)),
          ]),
        ),
      ]),
    );
  }
}

class _DataUsageCard extends StatelessWidget {
  final String totalLabel;
  final VoidCallback? onClearAll;
  const _DataUsageCard({required this.totalLabel, this.onClearAll});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.data_usage_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Text(oStr(context, 'offDataUsage'),
                style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: Gap.sm),
          Text(oStrS(context, 'offTotalCached', totalLabel),
              style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const SizedBox(height: Gap.xs),
          Text(oStr(context, 'offDataUsageNote'),
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onClearAll,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(oStr(context, 'offClearAll')),
            ),
          ),
        ]),
      ),
    );
  }
}
