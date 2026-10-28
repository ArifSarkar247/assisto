import 'package:flutter/material.dart';

import '../../cctvx/cctvx_source.dart';
import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvx — PLACEMENT HELPER during setup: is the cash zone clearly visible,
/// is the light enough, is the zone a sensible size and away from the frame
/// edge? Deterministic image statistics on the camera's latest still (no AI,
/// 0 credits) with Bangla tips. "Take a new photo" re-runs the gateway's
/// camera check (the password stays on the gateway) and checks again.
class PlacementSheet extends StatefulWidget {
  final CctvxSource source;
  final int cameraId;
  final WatchmanSource? watchman;

  /// Tests / gallery: show this report without the network.
  final Map<String, dynamic>? preview;
  const PlacementSheet(
      {super.key, required this.source, required this.cameraId, this.watchman, this.preview});

  static Future<void> show(BuildContext context, CctvxSource source, int cameraId,
          {WatchmanSource? watchman}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => PlacementSheet(source: source, cameraId: cameraId, watchman: watchman),
      );

  @override
  State<PlacementSheet> createState() => _PlacementSheetState();
}

class _PlacementSheetState extends State<PlacementSheet> {
  Map<String, dynamic>? _r;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _r = widget.preview;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      _r = await widget.source.placement(widget.cameraId);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _newPhoto() async {
    final w = widget.watchman;
    if (w == null) return;
    setState(() => _busy = true);
    try {
      final task = await w.queueCheck(widget.cameraId, const {});
      final id = (task['id'] as num).toInt();
      for (var i = 0; i < 30 && mounted; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final s = await w.task(id);
        if (const ['done', 'failed', 'expired'].contains(s['status'])) break;
      }
    } catch (_) {}
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final r = _r;
    final children = <Widget>[
      Text(t.cxPlacementTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(t.cxPlacementBody, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
    ];
    if (_busy && r == null) {
      children.add(const Center(child: CircularProgressIndicator()));
    } else if (_error != null) {
      children.add(Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!));
    } else if (r != null) {
      final score = (r['score'] as num?)?.toInt() ?? 0;
      final ok = r['ok'] == true;
      children.addAll([
        Semantics(
          label: t.cxPlacementScore(wmDigits(lang, score)),
          child: Row(children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.tips_and_updates_rounded,
                color: ok ? wmOk() : wmWarn(), size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(t.cxPlacementScore(wmDigits(lang, score)),
                  style: Theme.of(context).textTheme.titleSmall),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        for (final c in wmList(r['checks']))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(c['ok'] == true ? Icons.check_rounded : Icons.error_outline_rounded,
                  color: c['ok'] == true ? wmOk() : wmWarn()),
              const SizedBox(width: 8),
              Expanded(
                child: Text(c['ok'] == true
                    ? _checkName(t, (c['key'] ?? '').toString())
                    : (c['tip'] ?? '').toString()),
              ),
            ]),
          ),
        if (ok && (r['tips'] as List? ?? const []).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text((r['tips'] as List).first.toString()),
          ),
        const SizedBox(height: 8),
        Text((r['honest'] ?? t.cxPlacementHonest).toString(),
            style: Theme.of(context).textTheme.bodySmall),
      ]);
    }
    children.addAll([
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (widget.watchman != null)
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.photo_camera_rounded),
            label: Text(t.cxPlacementNewPhoto),
            onPressed: _busy ? null : _newPhoto,
          ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.cxPlacementAgain),
          onPressed: _busy
              ? null
              : () async {
                  await _load();
                  if (mounted && _error == null) {
                    ScaffoldMessenger.maybeOf(context)
                        ?.showSnackBar(SnackBar(content: Text(t.cxPlacementChecked)));
                  }
                },
        ),
      ]),
    ]);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }

  String _checkName(AppLocalizations t, String key) => switch (key) {
        'light' => t.cxCheckLight,
        'glare' => t.cxCheckGlare,
        'clear' => t.cxCheckClear,
        'size_small' || 'size_large' => t.cxCheckSize,
        'edge' => t.cxCheckEdge,
        _ => t.cxCheckZone,
      };
}
