import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/media/video_ctl.dart';
import '../../state.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// gap-cctv3: the camera's OWN recordings (SD card, else Imou cloud storage)
/// through the brand cloud — server: POST cctv/connect/cameras/<id>/stream
/// {kind: playback, start, end} (epoch seconds, at most one hour).
abstract class CctvPlaybackSource {
  Future<Map<String, dynamic>> playback(int cameraId, int startEpoch, int endEpoch);
}

class ApiCctvPlaybackSource implements CctvPlaybackSource {
  final ApiClient api;
  ApiCctvPlaybackSource(this.api);
  @override
  Future<Map<String, dynamic>> playback(int cameraId, int startEpoch, int endEpoch) =>
      api.postJson('/cctv/connect/cameras/$cameraId/stream',
          {'kind': 'playback', 'start': startEpoch, 'end': endEpoch});
}

/// What one hour of the day turned out to hold (after the owner asked).
enum PbHour { unknown, recorded, empty }

/// The plain-language reason a playback could not start.
enum PbProblem { none, noRecording, sdkOnly, notConfigured, revoked, network }

PbProblem pbProblemOf(Object e) {
  if (e is ApiException) {
    final r = e.reason ?? '';
    if (r == 'vendor_no_stream') return PbProblem.noRecording;
    if (r == 'vendor_not_configured') return PbProblem.notConfigured;
    if (r == 'vendor_revoked') return PbProblem.revoked;
  }
  return PbProblem.network;
}

/// gap-cctv3: a day timeline (24 hours, Bangla digits in Bangla) — tap an
/// hour → the camera's recording list for it + a low-data HLS player.
/// Honest: no recording = "needs an SD card or an Imou cloud plan"; a camera
/// whose firmware can't stream to apps = "open it in Imou Life".
class CctvPlaybackScreen extends StatefulWidget {
  final int cameraId;
  final String cameraName;
  final CctvPlaybackSource? source;

  /// Tests: "now" (the timeline never offers the future).
  final DateTime Function()? clock;
  const CctvPlaybackScreen(
      {super.key, required this.cameraId, this.cameraName = '', this.source, this.clock});

  @override
  State<CctvPlaybackScreen> createState() => _CctvPlaybackScreenState();
}

class _CctvPlaybackScreenState extends State<CctvPlaybackScreen> {
  late final CctvPlaybackSource _src =
      widget.source ?? ApiCctvPlaybackSource(context.read<AppState>().api);
  int _daysBack = 0; // 0 today, 1 yesterday … 6
  int? _hour;
  final Map<String, PbHour> _hours = {}; // 'daysBack:hour' -> what it held
  bool _busy = false;
  PbProblem _problem = PbProblem.none;
  List<Map<String, dynamic>> _records = const [];
  String _source = '';
  VideoCtl? _ctl;
  bool _playErr = false;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  DateTime _dayStart(int back) {
    final n = _now;
    return DateTime(n.year, n.month, n.day - back);
  }

  @override
  void dispose() {
    _closePlayer();
    super.dispose();
  }

  void _closePlayer() {
    final c = _ctl;
    _ctl = null;
    if (c != null) {
      c.dispose().then((_) {}, onError: (Object _) {});
    }
  }

  Future<void> _open(int hour) async {
    final start = _dayStart(_daysBack).add(Duration(hours: hour));
    var end = start.add(const Duration(hours: 1));
    if (end.isAfter(_now)) end = _now;
    if (!end.isAfter(start)) return;
    _closePlayer();
    setState(() {
      _hour = hour;
      _busy = true;
      _problem = PbProblem.none;
      _records = const [];
      _playErr = false;
    });
    final key = '$_daysBack:$hour';
    Map<String, dynamic> r;
    try {
      r = await _src.playback(widget.cameraId, start.millisecondsSinceEpoch ~/ 1000,
          end.millisecondsSinceEpoch ~/ 1000);
    } catch (e) {
      if (!mounted) return;
      final p = pbProblemOf(e);
      setState(() {
        _busy = false;
        _problem = p;
        if (p == PbProblem.noRecording) _hours[key] = PbHour.empty;
      });
      return;
    }
    if (!mounted) return;
    final recs = wmList(r['records']);
    final proto = (r['proto'] ?? '').toString();
    final url = Uri.tryParse((r['url'] ?? '').toString());
    setState(() {
      _records = recs;
      _source = (r['source'] ?? '').toString();
      _hours[key] = recs.isNotEmpty || proto == 'hls' ? PbHour.recorded : PbHour.empty;
    });
    if (proto != 'hls' || url == null || !url.hasScheme) {
      setState(() {
        _busy = false;
        _problem = recs.isEmpty ? PbProblem.noRecording : PbProblem.sdkOnly;
      });
      return;
    }
    try {
      final ctl = await VideoCtls.networkFactory(url);
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      _ctl = ctl;
      await ctl.init();
      await ctl.setMuted(true);
      await ctl.play();
      if (ctl.state.value.error.isNotEmpty) throw StateError(ctl.state.value.error);
    } catch (_) {
      _closePlayer();
      if (mounted) setState(() => _playErr = true);
    }
    if (mounted) setState(() => _busy = false);
  }

  String _hhmm(String lang, int h) => wmDigits(lang, '${h.toString().padLeft(2, '0')}:00');

  /// "HH:MM" of a record time ("2026-11-17 10:05:00" from the camera).
  String _recTime(String lang, Object? v) {
    final s = (v ?? '').toString();
    final m = RegExp(r'(\d{2}):(\d{2})').firstMatch(s);
    return m == null ? wmDigits(lang, s) : wmDigits(lang, '${m.group(1)}:${m.group(2)}');
  }

  String _dayLabel(AppLocalizations t, String lang, int back) {
    if (back == 0) return t.gcvReportToday;
    if (back == 1) return t.gcvReportYesterday;
    final d = _dayStart(back);
    return wmDigits(lang, '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}');
  }

  String _problemText(AppLocalizations t) => switch (_problem) {
        PbProblem.noRecording => t.gcvPbNoRecording,
        PbProblem.sdkOnly => t.gcvPbSdkOnly,
        PbProblem.notConfigured => t.gcvPbNotConfigured,
        PbProblem.revoked => t.gcvPbRevoked,
        PbProblem.network => t.gcvPbNetwork,
        PbProblem.none => '',
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final scheme = Theme.of(context).colorScheme;
    final now = _now;
    final ctl = _ctl;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.cameraName.isEmpty
              ? t.gcvPbTitle
              : '${t.gcvPbTitle} · ${widget.cameraName}')),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
        children: [
          Text(t.gcvPbIntro),
          const SizedBox(height: 4),
          Text(t.gcvPbLowData, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          // the day: today, yesterday and the 5 days before (an SD card
          // usually holds about a week)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var b = 0; b < 7; b++)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ChoiceChip(
                    key: ValueKey('gcv-pb-day-$b'),
                    label: Text(_dayLabel(t, lang, b)),
                    selected: _daysBack == b,
                    onSelected: (_) {
                      _closePlayer();
                      setState(() {
                        _daysBack = b;
                        _hour = null;
                        _problem = PbProblem.none;
                        _records = const [];
                      });
                    },
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          Text(t.gcvPbPickHour, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          // the day timeline: 24 hour cells, 6 per row; the future is off
          GridView.count(
            key: const ValueKey('gcv-pb-timeline'),
            crossAxisCount: 6,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 1.0, // cells stay >= 48 dp at 360 dp
            children: [
              for (var h = 0; h < 24; h++)
                Builder(builder: (context) {
                  final future = _dayStart(_daysBack).add(Duration(hours: h)).isAfter(now);
                  final st = _hours['$_daysBack:$h'] ?? PbHour.unknown;
                  final sel = _hour == h;
                  final bg = sel
                      ? scheme.primary
                      : st == PbHour.recorded
                          ? scheme.ds.primarySoft
                          : scheme.surfaceContainerHighest;
                  final fg = sel ? scheme.onPrimary : scheme.onSurface;
                  return Semantics(
                    button: true,
                    enabled: !future,
                    label: '${_hhmm(lang, h)}'
                        '${st == PbHour.recorded ? ', ${t.gcvPbHasRec}' : st == PbHour.empty ? ', ${t.gcvPbNoRec}' : ''}',
                    child: Material(
                      color: future ? scheme.surface : bg,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        key: ValueKey('gcv-pb-hour-$h'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: future || _busy ? null : () => _open(h),
                        child: Center(
                          child: Text(wmDigits(lang, h.toString().padLeft(2, '0')),
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: future ? scheme.outline : fg,
                                  decoration: st == PbHour.empty
                                      ? TextDecoration.lineThrough
                                      : null)),
                        ),
                      ),
                    ),
                  );
                }),
            ],
          ),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(key: ValueKey('gcv-pb-busy')),
          if (ctl != null)
            ValueListenableBuilder<VideoCtlState>(
              valueListenable: ctl.state,
              builder: (_, st, __) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                    key: const ValueKey('gcv-pb-player'),
                    aspectRatio: st.aspect,
                    child: ctl.view()),
              ),
            ),
          if (ctl != null && _source.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_source == 'cloud' ? t.gcvPbFromCloud : t.gcvPbFromSd,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_playErr)
            _ProblemCard(
                key: const ValueKey('gcv-pb-play-error'),
                text: t.gcvPbPlayFailed,
                retry: t.wmRetry,
                onRetry: _hour == null ? null : () => _open(_hour!)),
          if (_problem != PbProblem.none)
            _ProblemCard(
                key: ValueKey('gcv-pb-problem-${_problem.name}'),
                text: _problemText(t),
                retry: _problem == PbProblem.network ? t.wmRetry : null,
                onRetry: _problem == PbProblem.network && _hour != null ? () => _open(_hour!) : null),
          if (_records.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(t.gcvPbRecordsTitle, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final r in _records)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${_recTime(lang, r['begin'])} – ${_recTime(lang, r['end'])}'),
              ),
          ],
          if (_hour == null && !_busy) ...[
            const SizedBox(height: 8),
            Text(t.gcvPbHint, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  final String text;
  final String? retry;
  final VoidCallback? onRetry;
  const _ProblemCard({super.key, required this.text, this.retry, this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: DsCard(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text),
            if (retry != null && onRetry != null) ...[
              const SizedBox(height: 8),
              FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: onRetry,
                  child: Text(retry!)),
            ],
          ]),
        ),
      );
}
