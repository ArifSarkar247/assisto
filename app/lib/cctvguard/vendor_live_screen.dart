import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../messaging/media/video_ctl.dart';
import '../screens/watchman/watchman_source.dart' show wmDigits;
import '../shop_api.dart';
import '../state.dart';
import '../theme.dart';
import 'live_cost.dart';

/// The three server calls of a vendor live view (tests pass a fake).
abstract class VendorLiveApi {
  Future<Map<String, dynamic>> start(int cameraId, {required bool hd});
  Future<Map<String, dynamic>> touch(int cameraId, String id);
  Future<Map<String, dynamic>> end(int cameraId, String id, int seconds);
}

class ApiVendorLive implements VendorLiveApi {
  final ApiClient api;
  ApiVendorLive(this.api);
  @override
  Future<Map<String, dynamic>> start(int cameraId, {required bool hd}) =>
      api.vendorLiveStart(cameraId, hd: hd);
  @override
  Future<Map<String, dynamic>> touch(int cameraId, String id) =>
      api.vendorLiveTouch(cameraId, id);
  @override
  Future<Map<String, dynamic>> end(int cameraId, String id, int seconds) =>
      api.vendorLiveEnd(cameraId, id, seconds);
}

/// cctvguard (owner CCTV order G) — LIVE view of an Imou / EZVIZ camera
/// through the camera maker's cloud (HLS). Cost guards: SD by default, HD
/// only on tap, stops after 5 minutes without a touch, max live views per
/// account (server), and the data used is shown as an ESTIMATE. Sound is
/// off; nothing is recorded by Assisto.
class VendorLiveScreen extends StatefulWidget {
  final int cameraId;
  final String cameraName;
  final VendorLiveApi? api;
  const VendorLiveScreen(
      {super.key, required this.cameraId, required this.cameraName, this.api});

  @override
  State<VendorLiveScreen> createState() => _VendorLiveScreenState();
}

enum _VPhase { starting, live, idleStopped, ended, error }

class _VendorLiveScreenState extends State<VendorLiveScreen> {
  late final VendorLiveApi _api;
  _VPhase _phase = _VPhase.starting;
  String _error = '';
  String _note = '';
  String? _id;
  bool _hd = false;
  int _kbps = 512;
  VideoCtl? _ctl;
  Timer? _tick;
  VendorIdle _idle = VendorIdle();
  DateTime? _since;
  int _secs = 0;

  @override
  void initState() {
    super.initState();
    // captured here: dispose() must not look up the tree
    _api = widget.api ?? ApiVendorLive(context.read<AppState>().api);
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _close();
    super.dispose();
  }

  Future<void> _open({bool? hd}) async {
    final t = AppLocalizations.of(context);
    setState(() {
      _phase = _VPhase.starting;
      _error = '';
      if (hd != null) _hd = hd;
    });
    Map<String, dynamic> r;
    try {
      r = await _api.start(widget.cameraId, hd: _hd);
    } on ApiException catch (e) {
      _failed(e.message.isNotEmpty ? e.message : t.cgVendorFailed);
      return;
    } catch (_) {
      _failed(t.cgVendorFailed);
      return;
    }
    final url = Uri.tryParse((r['url'] ?? '').toString());
    _id = (r['id'] ?? '').toString();
    _kbps = (r['kbps'] as num?)?.toInt() ?? (_hd ? 2048 : 512);
    _note = (r['message'] ?? '').toString();
    _idle = VendorIdle(idleSeconds: (r['idle_seconds'] as num?)?.toInt() ?? 300);
    if (url == null || !url.hasScheme) {
      _failed(t.cgVendorFailed);
      return;
    }
    try {
      final ctl = await VideoCtls.networkFactory(url);
      _ctl = ctl;
      await ctl.init();
      await ctl.setMuted(true);
      await ctl.play();
      if (ctl.state.value.error.isNotEmpty) throw StateError(ctl.state.value.error);
    } catch (_) {
      await _close();
      _failed(t.cgVendorPlayFailed);
      return;
    }
    if (!mounted) return;
    _since = DateTime.now();
    _secs = 0;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    setState(() => _phase = _VPhase.live);
  }

  void _failed(String msg) {
    if (!mounted) return;
    setState(() {
      _phase = _VPhase.error;
      _error = msg;
    });
  }

  void _onTick() {
    if (!mounted || _phase != _VPhase.live) return;
    final stop = _idle.tick();
    setState(() => _secs = _since == null ? 0 : DateTime.now().difference(_since!).inSeconds);
    if (stop) _stop(idle: true);
  }

  void _touch() {
    final id = _id;
    if (_phase != _VPhase.live || id == null) return;
    final send = _idle.touch(DateTime.now());
    setState(() {});
    if (send) unawaited(_api.touch(widget.cameraId, id).then((_) {}, onError: (_) {}));
  }

  /// End the server session (seconds for the meter) and release the player.
  Future<void> _close() async {
    _tick?.cancel();
    final ctl = _ctl;
    _ctl = null;
    try {
      await ctl?.dispose();
    } catch (_) {}
    final id = _id;
    _id = null;
    if (id != null && id.isNotEmpty) {
      final secs = _since == null ? 0 : DateTime.now().difference(_since!).inSeconds;
      _since = null;
      try {
        await _api.end(widget.cameraId, id, secs);
      } catch (_) {} // the server clamps an unclosed view at the idle stop
    }
  }

  Future<void> _stop({bool idle = false}) async {
    await _close();
    if (mounted) setState(() => _phase = idle ? _VPhase.idleStopped : _VPhase.ended);
  }

  Future<void> _setHd(bool hd) async {
    if (hd == _hd) return;
    await _close();
    await _open(hd: hd);
  }

  String _mmss(BuildContext context, int s) => wmDigits(
      Localizations.localeOf(context).languageCode,
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.cameraName.isEmpty ? t.cgVendorLiveTitle : widget.cameraName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _touch(),
        child: SafeArea(
          child: Column(children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: Colors.black,
                alignment: Alignment.center,
                child: _phase == _VPhase.live
                    ? _video()
                    : SingleChildScrollView(child: _message(t)),
              ),
            ),
            _bottom(t, scheme),
          ]),
        ),
      ),
    );
  }

  Widget _video() {
    final ctl = _ctl;
    if (ctl == null) return const SizedBox.shrink();
    return ValueListenableBuilder<VideoCtlState>(
      valueListenable: ctl.state,
      builder: (_, st, __) => Stack(alignment: Alignment.center, children: [
        AspectRatio(aspectRatio: st.aspect, child: ctl.view()),
        if (st.buffering || !st.initialized)
          const CircularProgressIndicator(color: Colors.white),
      ]),
    );
  }

  Widget _message(AppLocalizations t) {
    final (IconData icon, String text) = switch (_phase) {
      _VPhase.starting => (Icons.hourglass_top_rounded, t.cgVendorStarting),
      _VPhase.idleStopped => (Icons.pan_tool_alt_rounded, t.cgVendorIdleStopped),
      _VPhase.ended => (Icons.videocam_off_rounded, t.shopLiveEnded),
      _ => (Icons.cloud_off_rounded, _error),
    };
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_phase == _VPhase.starting)
          const CircularProgressIndicator(color: Colors.white)
        else
          Icon(icon, color: Colors.white70, size: 48),
        const SizedBox(height: Gap.md),
        Text(text,
            key: const Key('vendorLiveMsg'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, height: 1.4)),
        if (_phase != _VPhase.starting) ...[
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, alignment: WrapAlignment.center, children: [
            FilledButton.icon(
              key: const Key('vendorLiveAgain'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _open(),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(_phase == _VPhase.error ? t.retry : t.shopLiveOpen),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white, minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context),
              child: Text(t.close),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _bottom(AppLocalizations t, ColorScheme scheme) {
    final live = _phase == _VPhase.live;
    final lang = Localizations.localeOf(context).languageCode;
    final estMb = LiveCost.mb(_secs * _kbps * 1000 / 8);
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, alignment: WrapAlignment.center, children: [
          if (live)
            Chip(
              key: const Key('vendorLivePath'),
              avatar: Icon(Icons.cloud_sync_rounded, size: 18, color: scheme.tertiary),
              label: Text(t.cgPathVendorCloud),
            ),
          if (live)
            FilterChip(
              key: const Key('vendorLiveHd'),
              avatar: const Icon(Icons.hd_rounded, size: 18),
              label: Text(_hd ? t.cgHdOn : t.cgSdOn),
              selected: _hd,
              onSelected: _setHd,
            ),
          if (live)
            Chip(
              key: const Key('vendorLiveIdle'),
              avatar: const Icon(Icons.timer_rounded, size: 18),
              label: Text(t.shopLiveTimeLeft(_mmss(context, _idle.left))),
            ),
          if (live)
            Chip(
              key: const Key('vendorLiveData'),
              avatar: const Icon(Icons.data_usage_rounded, size: 18),
              label: Text(t.cgDataEstimate(wmDigits(lang, estMb))),
            ),
        ]),
        const SizedBox(height: Gap.sm),
        if (_note.isNotEmpty)
          Text(_note,
              key: const Key('vendorLiveNote'),
              textAlign: TextAlign.center,
              style: AType.bodySmall.copyWith(color: scheme.onSurface, height: 1.35)),
        Text(t.cgVendorIdleNote(wmDigits(lang, _idle.idleSeconds ~/ 60)),
            textAlign: TextAlign.center,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
        Text(t.cgVendorNoRecording,
            textAlign: TextAlign.center,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
        const SizedBox(height: Gap.sm),
        if (live)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('vendorLiveStop'),
              style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  minimumSize: const Size(48, 48)),
              onPressed: () => _stop(),
              icon: const Icon(Icons.stop_circle_rounded),
              label: Text(t.shopLiveStop),
            ),
          ),
      ]),
    );
  }
}
