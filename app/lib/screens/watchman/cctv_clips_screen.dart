import 'package:flutter/material.dart';
import '../../widgets/fade_chip_row.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../billing/cctv_plan_screen.dart';
import '../../cashguard/cashguard_source.dart';
import '../../cctvx/cctvx_source.dart';
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../widgets/cv_empty.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/skeleton.dart';
import 'cash_guard_clip.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// gap-cctv D4: where the kept clips come from (server: shop/watchman/clips).
abstract class CctvClipsSource {
  Future<Map<String, dynamic>> clips(int siteId, {int? cameraId});
}

class ApiCctvClipsSource implements CctvClipsSource {
  final ApiClient api;
  ApiCctvClipsSource(this.api);
  @override
  Future<Map<String, dynamic>> clips(int siteId, {int? cameraId}) => api.getJson(
      '/shop/watchman/clips?site=$siteId${cameraId == null ? '' : '&camera=$cameraId'}');
}

/// gap-cctv D4: PAST CLIPS of one place — every clip the server still keeps,
/// newest first, grouped by day, filtered by camera, with the honest keep
/// time (24 hours by default, 30 days with Premium AI) and, for the owner
/// only, a quiet line to keep clips longer. Tapping a clip opens the same
/// clip sheet as an alert.
class CctvClipsScreen extends StatefulWidget {
  final CctvClipsSource? source;
  final int siteId;
  final String siteName;
  final bool owner;

  /// Tests: the clip sheet's source (else the app's API).
  final CashGuardSource? cash;
  const CctvClipsScreen(
      {super.key,
      this.source,
      required this.siteId,
      this.siteName = '',
      required this.owner,
      this.cash});

  @override
  State<CctvClipsScreen> createState() => _CctvClipsScreenState();
}

class _CctvClipsScreenState extends State<CctvClipsScreen> {
  late final CctvClipsSource _src =
      widget.source ?? ApiCctvClipsSource(context.read<AppState>().api);
  Map<String, dynamic>? _d;
  String? _error;
  bool _loading = true;
  int? _camera; // null = every camera

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await _src.clips(widget.siteId, cameraId: _camera);
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = wmError(e) ?? '';
        _loading = false;
      });
    }
  }

  Future<void> _open(Map<String, dynamic> c) async {
    CashGuardSource? cash = widget.cash;
    CctvxSource? extras;
    if (cash == null) {
      try {
        final api = context.read<AppState>().api;
        cash = ApiCashGuardSource(api);
        extras = widget.owner ? ApiCctvxSource(api) : null;
      } catch (_) {
        return;
      }
    }
    await CashClipSheet.show(context, cash, (c['id'] as num).toInt(), widget.owner,
        extras: extras,
        photoUrl: (c['snapshot_url'] ?? '').toString(),
        previewStatus: (wmMap(c['clip'])['status'] ?? '').toString());
    await _load(); // the owner watching it deletes the server copy
  }


  String _dayLabel(AppLocalizations t, String lang, String key) {
    final now = DateTime.now();
    String k(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    if (key == k(now)) return t.gcvReportToday;
    if (key == k(now.subtract(const Duration(days: 1)))) return t.gcvReportYesterday;
    final p = key.split('-');
    return p.length == 3 ? wmDigits(lang, '${p[2]}/${p[1]}/${p[0]}') : key;
  }

  String _time(String lang, String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    return wmDigits(lang, '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final d = _d;
    Widget body;
    if (_loading && d == null) {
      body = const SkeletonList();
    } else if (_error != null && d == null) {
      body = ListView(padding: const EdgeInsets.all(24), children: [
        Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
              key: const ValueKey('gcv-clips-retry'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _load,
              child: Text(t.wmRetry)),
        ),
      ]);
    } else {
      final clips = wmList(d?['clips']);
      final cams = wmList(d?['cameras']);
      final hours = (d?['default_hours'] as num?)?.toInt() ?? 24;
      final premium = (d?['premium_days'] as num?)?.toInt() ?? 30;
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final c in clips) {
        groups.putIfAbsent(gcvClipDayKey((c['created'] ?? '').toString()), () => []).add(c);
      }
      final longer = cams.where((c) => ((c['keep_days'] as num?)?.toInt() ?? 1) > 1).toList();
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
          children: [
            // the honest keep time, always
            Text(t.gcvClipsKeep(wmDigits(lang, hours), wmDigits(lang, premium)),
                key: const ValueKey('gcv-clips-keep')),
            for (final c in longer)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    t.gcvClipsCamKeep((c['name'] ?? '').toString(),
                        wmDigits(lang, (c['keep_days'] as num?)?.toInt() ?? 1)),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            if (widget.owner && d?['upsell'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DsCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    key: const ValueKey('gcv-clips-upsell'),
                    minVerticalPadding: 12,
                    leading: const Icon(Icons.workspace_premium_outlined),
                    title: Text(t.gcvClipsUpsell(wmDigits(lang, premium))),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const CctvPlanScreen())),
                  ),
                ),
              ),
            if (cams.length > 1) ...[
              const SizedBox(height: Gap.md),
              // design3: one scrolling row of camera chips (a Wrap broke into
              // two ragged rows at 360 dp), the end fades to show there is more
              FadeChipRow(padding: EdgeInsets.zero, children: [
                ChoiceChip(
                  key: const ValueKey('gcv-clips-cam-all'),
                  label: Text(t.gcvClipsAllCameras),
                  selected: _camera == null,
                  onSelected: (_) {
                    setState(() => _camera = null);
                    _load();
                  },
                ),
                for (final c in cams)
                  ChoiceChip(
                    key: ValueKey('gcv-clips-cam-${c['id']}'),
                    label: Text((c['name'] ?? '').toString()),
                    selected: _camera == (c['id'] as num?)?.toInt(),
                    onSelected: (_) {
                      setState(() => _camera = (c['id'] as num?)?.toInt());
                      _load();
                    },
                  ),
              ]),
            ],
            const SizedBox(height: 8),
            if (_loading) const LinearProgressIndicator(),
            if (clips.isEmpty)
              CvEmptyBlock(
                key: const ValueKey('gcv-clips-empty'),
                compact: true,
                icon: Icons.video_library_outlined,
                title: t.gcvClipsEmptyTitle,
                benefit: t.gcvClipsEmptyBenefit(wmDigits(lang, hours)),
                steps: [t.gcvClipsEmptyStep1, t.gcvClipsEmptyStep2],
              ),
            for (final g in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(_dayLabel(t, lang, g.key),
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              for (final c in g.value)
                DsCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    key: ValueKey('gcv-clip-${c['id']}'),
                    minTileHeight: 56,
                    leading: const Icon(Icons.play_circle_outline_rounded),
                    title: Text((c['camera_name'] ?? '').toString().isEmpty
                        ? t.gcvClipsCameraUnknown
                        : (c['camera_name'] ?? '').toString()),
                    subtitle: Text(_time(lang, (c['created'] ?? '').toString())),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(c),
                  ),
                ),
            ],
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.siteName.isEmpty
              ? t.gcvClipsTitle
              : '${t.gcvClipsTitle} · ${widget.siteName}')),
      body: body,
    );
  }
}

/// The day a clip belongs to, in the phone's local date (YYYY-MM-DD).
String gcvClipDayKey(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
