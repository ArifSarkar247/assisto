import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../shop_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'shop_live_rtc.dart' deferred as rtc;

/// SHOP BOX LIVE VIEW (owner side). Opens a WebRTC session to the shop device:
/// peer-to-peer when possible (free), through our TURN relay otherwise (uses
/// credits per started minute). The server only passes the SDP/ICE text — the
/// video never touches it and NOTHING is recorded, here or there.
///
/// Hard cap: the server ends a session after `max_seconds` (10 min default);
/// the countdown below mirrors it. When the device is offline the server says
/// so and we show that message as-is (honest — no fake "connecting" spinner).
class ShopLiveScreen extends StatefulWidget {
  final int cameraId;
  final String cameraName;
  const ShopLiveScreen({super.key, required this.cameraId, required this.cameraName});

  @override
  State<ShopLiveScreen> createState() => _ShopLiveScreenState();
}

enum _Phase { starting, connecting, live, ended, error }

class _ShopLiveScreenState extends State<ShopLiveScreen> {
  _Phase _phase = _Phase.starting;
  String _error = '';
  int? _sid;
  int _after = 0;
  int _maxSeconds = 600;
  int _left = 600;
  bool _relayed = false;
  bool _relayAllowed = true;
  int _relayPerMin = 1;
  DateTime? _liveSince;
  int _charged = 0;
  dynamic _peer; // rtc.LivePeer (deferred type)
  Timer? _poll;
  Timer? _tick;
  bool _ending = false;

  late final ApiClient _api;

  @override
  void initState() {
    super.initState();
    _api = context.read<AppState>().api; // captured: dispose() must not use context
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    if (!_ending) _end(silent: true);
    super.dispose();
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    Map<String, dynamic> s;
    try {
      s = await _api.shopLiveStart(widget.cameraId);
    } on ApiException catch (e) {
      _fail(e.message);
      return;
    } catch (_) {
      _fail(t.shopLiveStartFailed);
      return;
    }
    _sid = (s['id'] as num?)?.toInt();
    _maxSeconds = (s['max_seconds'] as num?)?.toInt() ?? 600;
    _left = _maxSeconds;
    _relayAllowed = s['relay_allowed'] == true;
    _relayPerMin = (s['relay_credits_per_min'] as num?)?.toInt() ?? 1;
    final ice = ((s['ice']?['ice_servers'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    if (!mounted) return;
    setState(() => _phase = _Phase.connecting);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    try {
      await rtc.loadLibrary();
      final peer = await rtc.LivePeer.create(ice,
          sender: false,
          onCandidate: (c) => _send('candidate', c),
          onRemoteVideo: () {
            if (!mounted) return;
            setState(() {
              _phase = _Phase.live;
              _liveSince ??= DateTime.now();
            });
          },
          onState: (st) {
            if (st.contains('Failed') && mounted && _phase != _Phase.ended) {
              _fail(AppLocalizations.of(context).shopLiveConnectFailed);
            }
          });
      _peer = peer;
      final offer = await peer.createOffer();
      await _send('offer', offer);
    } catch (_) {
      _fail(t.shopLiveConnectFailed);
      return;
    }
    _poll = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pollOnce());
  }

  Future<void> _send(String kind, Object? payload) async {
    final sid = _sid;
    if (sid == null) return;
    try {
      await _api.shopLiveSignal(sid, kind, payload);
    } catch (_) {}
  }

  bool _polling = false;
  Future<void> _pollOnce() async {
    final sid = _sid;
    if (sid == null || _polling) return;
    _polling = true;
    try {
      final r = await _api.shopLivePoll(sid, _after);
      _after = (r['seq'] as num?)?.toInt() ?? _after;
      final status = (r['status'] ?? '').toString();
      for (final m in ((r['messages'] ?? const []) as List).whereType<Map>()) {
        final kind = m['kind'];
        final p = m['payload'];
        if (kind == 'answer' && p is Map) {
          await _peer?.setRemote(p.cast<String, dynamic>());
        } else if (kind == 'candidate' && p is Map) {
          try {
            await _peer?.addCandidate(p.cast<String, dynamic>());
          } catch (_) {}
        } else if (kind == 'bye') {
          _endedBy();
        }
      }
      if (status == 'expired' || status == 'ended') _endedBy();
    } catch (_) {
      // transient network error — keep polling until the cap
    } finally {
      _polling = false;
    }
  }

  void _onTick() {
    if (!mounted) return;
    setState(() => _left = (_left - 1).clamp(0, _maxSeconds));
    if (_left <= 0) _end();
    // check the selected ICE pair every 3 s; once relayed, latch it
    if (_left % 3 == 0 && !_relayed && _peer != null && _phase == _Phase.live) {
      () async {
        try {
          final r = await _peer.isRelayed() as bool;
          if (r && mounted) setState(() => _relayed = true);
        } catch (_) {}
      }();
    }
  }

  void _endedBy() {
    if (_phase == _Phase.ended) return;
    _end();
  }

  void _fail(String msg) {
    _poll?.cancel();
    _tick?.cancel();
    if (_sid != null && !_ending) _end(silent: true);
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _error = msg;
    });
  }

  Future<void> _end({bool silent = false}) async {
    if (_ending) return;
    _ending = true;
    _poll?.cancel();
    _tick?.cancel();
    final secs = _liveSince == null ? 0 : DateTime.now().difference(_liveSince!).inSeconds;
    try {
      await _peer?.dispose();
    } catch (_) {} // best-effort: WebRTC teardown
    _peer = null;
    final sid = _sid;
    if (sid != null) {
      try {
        await _send('bye', const {});
        final r = await _api.shopLiveEnd(sid, relayed: _relayed, seconds: secs);
        _charged = (r['charged_credits'] as num?)?.toInt() ?? 0;
      } catch (_) {} // best-effort: the server closes a silent session by timeout
    }
    if (!silent && mounted) setState(() => _phase = _Phase.ended);
  }

  String _mmss(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.cameraName.isEmpty ? t.shopLiveTitle : widget.cameraName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: Colors.black,
              alignment: Alignment.center,
              child: _videoArea(t, scheme),
            ),
          ),
          _bottomBar(t, scheme),
        ]),
      ),
    );
  }

  Widget _videoArea(AppLocalizations t, ColorScheme scheme) {
    switch (_phase) {
      case _Phase.live:
        return _peer == null ? const SizedBox.shrink() : _peer.view() as Widget;
      case _Phase.starting:
      case _Phase.connecting:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: Gap.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: Text(
                _phase == _Phase.starting ? t.shopLiveStarting : t.shopLiveConnecting,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white)),
          ),
        ]);
      case _Phase.ended:
        return Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_off_outlined, color: Colors.white70, size: 48),
            const SizedBox(height: Gap.md),
            Text(t.shopLiveEnded,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            if (_charged > 0) ...[
              const SizedBox(height: Gap.sm),
              Text(t.shopLiveCharged(fmtInt(context, _charged)),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
            ],
          ]),
        );
      case _Phase.error:
        return Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.portable_wifi_off, color: Colors.white70, size: 48),
            const SizedBox(height: Gap.md),
            Text(_error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, height: 1.4)),
            const SizedBox(height: Gap.md),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context),
              child: Text(t.close),
            ),
          ]),
        );
    }
  }

  Widget _bottomBar(AppLocalizations t, ColorScheme scheme) {
    final active = _phase == _Phase.live || _phase == _Phase.connecting;
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, alignment: WrapAlignment.center, children: [
          if (_phase == _Phase.live)
            Chip(
              avatar: Icon(_relayed ? Icons.cloud_sync_outlined : Icons.bolt_outlined,
                  size: 18, color: _relayed ? scheme.tertiary : AssistoTokens.of(context).success),
              label: Text(_relayed ? t.shopLiveRelayed : t.shopLiveP2p),
            ),
          if (active)
            Chip(
              avatar: const Icon(Icons.timer_outlined, size: 18),
              label: Text(t.shopLiveTimeLeft(_mmss(_left))),
            ),
        ]),
        const SizedBox(height: Gap.sm),
        Text(
          _relayAllowed
              ? t.shopLiveCostNote(fmtInt(context, _relayPerMin))
              : t.shopLiveNoRelayNote,
          textAlign: TextAlign.center,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
        ),
        Text(t.shopLiveNoRecording,
            textAlign: TextAlign.center,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
        const SizedBox(height: Gap.sm),
        if (active)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: scheme.error,
                  foregroundColor: scheme.onError),
              onPressed: () => _end(),
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(t.shopLiveStop),
            ),
          ),
      ]),
    );
  }
}
