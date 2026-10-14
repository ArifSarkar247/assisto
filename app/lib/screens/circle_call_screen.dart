import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_call_controls.dart';
import '../widgets/circle_relation.dart';

/// Connected Circle 1:1 voice/video call screen (M1 item 5).
///
/// WHAT WORKS NOW: WebRTC signalling runs via the server relay WHILE THE APP IS
/// OPEN. App-closed ring (FCM data / APNs PushKit + CallKit) and a production
/// TURN relay are KEY-GATED on infra the owner provisions — the transport
/// banner states this honestly (mirrors core/logic/circle_calls.transport_status).
///
/// THE VIDEO GATE IS SERVER-SIDE. Before this screen ever starts a video call,
/// the client asks the backend (POST /circle/<id>/call with kind), which calls
/// core/logic/circle_calls.can_place_call(caller, callee, kind). A FREE caller
/// requesting video gets `upgrade_required` back and we show the upgrade prompt
/// instead of starting media. The client cannot bypass this by setting
/// kind='video' locally — the server refuses to issue the WebRTC offer.
///
/// This screen renders the call UI + controls and drives the call-record state
/// machine through the relay. The actual RTCPeerConnection wiring (flutter_webrtc
/// renderers) is a platform package the integrator adds; the seam is marked.
class CircleCallScreen extends StatefulWidget {
  final Map<String, dynamic> member;

  /// 'voice' | 'video'. For video the server gate must pass first (see above).
  final String kind;

  /// true when THIS user placed the call (outgoing); false for incoming.
  final bool outgoing;

  const CircleCallScreen({
    super.key,
    required this.member,
    required this.kind,
    this.outgoing = true,
  });

  @override
  State<CircleCallScreen> createState() => _CircleCallScreenState();
}

class _CircleCallScreenState extends State<CircleCallScreen> {
  // Local mirror of core/logic/circle_calls default_controls().
  late bool _muted;
  late bool _speakerOn;
  late bool _cameraOn;
  late bool _lowData;

  // Call-record state mirror. Mirrors core/logic/circle_calls CALL_* states:
  // ringing -> connecting -> active (<-> reconnecting) -> ended, plus failed.
  String _state = 'ringing';
  String? _callId;
  bool _starting = true;
  bool _blockedByGate = false;

  // Live call duration (counts while active/reconnecting), mirrors the
  // server-side duration measured from answered_at.
  DateTime? _answeredAt;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  bool get _isVideo => widget.kind == 'video';
  bool get _isConnected => _state == 'active' || _state == 'reconnecting';

  @override
  void initState() {
    super.initState();
    _muted = false;
    _speakerOn = _isVideo;
    _cameraOn = _isVideo;
    _lowData = false;
    _start();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);
  int? get _memberId => widget.member['id'] as int?;
  String get _name => '${widget.member['name'] ?? ''}';

  /// Place / accept the call through the relay. The backend runs the SERVER-SIDE
  /// gate (can_place_call) and the incoming-call policy (allow_call) and returns
  /// either a signalling session or an upgrade/denied reason.
  Future<void> _start() async {
    try {
      final r = widget.outgoing
          ? await _api.postJson('/circle/$_memberId/call', {'kind': widget.kind})
          : await _api
              .postJson('/circle/$_memberId/call/answer', {'kind': widget.kind});
      // Server decision is authoritative.
      if (r['allowed'] == false || r['upgrade_required'] == true) {
        if (mounted) setState(() => _blockedByGate = true);
        return;
      }
      _callId = '${r['call_id'] ?? r['id'] ?? ''}';
      // SFU/TURN SEAM: here the integrator opens the RTCPeerConnection with
      // r['ice'] servers (core/logic/circle_calls.ice_config) and exchanges the
      // offer/answer through the relay; onIceConnectionState drives
      // _markConnecting / _markActive / _markReconnecting / _markFailed. Until
      // flutter_webrtc + the self-hosted SFU/TURN are wired, we model the
      // relay-connect flow so the UI + controls + call-record states are
      // exercisable WITHOUT faking a media stream.
      if (mounted) {
        setState(() {
          _starting = false;
          _state = widget.outgoing ? 'ringing' : 'connecting';
        });
      }
    } catch (_) {
      // Offline / relay unreachable — surface an honest failure the user can
      // retry, rather than pretending the call connected.
      if (mounted) {
        setState(() {
          _starting = false;
          _state = 'failed';
        });
      }
    }
  }

  Future<void> _event(String event) async {
    // Advance the server-side call record; mirrors circle_calls.finalize_call.
    try {
      if (_callId != null && _callId!.isNotEmpty) {
        await _api.postJson('/circle/calls/$_callId/event', {'event': event});
      }
    } catch (_) {}
  }

  /// Media connected (ICE connected) — start the live duration clock. Called by
  /// the integrator from onIceConnectionState==connected.
  void _markActive() {
    _event('connected');
    _answeredAt ??= DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _answeredAt == null) return;
      setState(() => _elapsed = DateTime.now().difference(_answeredAt!));
    });
    if (mounted) setState(() => _state = 'active');
  }

  /// ICE dropped mid-call — the clock keeps running while ICE restarts.
  void _markReconnecting() {
    _event('reconnect');
    if (mounted) setState(() => _state = 'reconnecting');
  }

  /// Transport/negotiation failure — stop the clock, offer a retry.
  void _markFailed() {
    _event('fail');
    _ticker?.cancel();
    if (mounted) setState(() => _state = 'failed');
  }

  void _retry() {
    setState(() {
      _starting = true;
      _state = 'ringing';
      _callId = null;
      _answeredAt = null;
      _elapsed = Duration.zero;
    });
    _start();
  }

  void _hangup() {
    _ticker?.cancel();
    _event(_isConnected ? 'hangup' : 'cancel');
    if (mounted) Navigator.of(context).pop();
  }

  String _fmtElapsed() {
    final s = _elapsed.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final relation = '${widget.member['relation'] ?? 'friend'}';

    if (_blockedByGate) {
      return _gateScreen(scheme);
    }

    return Scaffold(
      backgroundColor: scheme.surfaceContainerHighest,
      body: SafeArea(
        child: Column(
          children: [
            const CircleCallTransportBanner(),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 48,
                      child: Text(
                        _name.isEmpty
                            ? '?'
                            : _name.characters.first.toUpperCase(),
                        style: const TextStyle(fontSize: 36),
                      ),
                    ),
                    const SizedBox(height: Gap.lg),
                    Text(_name,
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: Gap.xs),
                    Text(
                      CircleRelation.labelFor(_t, relation,
                          custom: widget.member['custom_label'] as String?),
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: Gap.md),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_state == 'failed'
                                ? Icons.error_outline
                                : _isVideo
                                    ? Icons.videocam
                                    : Icons.call,
                            size: 16,
                            color: _state == 'failed'
                                ? scheme.error
                                : scheme.onSurfaceVariant),
                        const SizedBox(width: Gap.xs),
                        Text(_statusLabel(),
                            style: TextStyle(
                                color: _state == 'failed'
                                    ? scheme.error
                                    : scheme.onSurfaceVariant)),
                      ],
                    ),
                    // Live duration while media is flowing (counts through a
                    // mid-call reconnect, like the server-side record).
                    if (_isConnected && _answeredAt != null) ...[
                      const SizedBox(height: Gap.xs),
                      Text(_fmtElapsed(),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w600)),
                    ],
                    if (_state == 'failed') ...[
                      const SizedBox(height: Gap.lg),
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.refresh),
                        label: Text(_t.circleCallRetry),
                        onPressed: _retry,
                      ),
                    ],
                    // SFU/TURN SEAM (dev affordance): until flutter_webrtc +
                    // the self-hosted SFU/TURN are wired, these map the ICE
                    // connection-state callbacks the integrator will attach:
                    //   onIceConnectionState==connected    -> _markActive()
                    //   ==disconnected/checking (mid-call) -> _markReconnecting()
                    //   ==failed                           -> _markFailed()
                    // They drive the real call-record events server-side. The
                    // screen never fabricates a media stream; it only models the
                    // state the real transport will report.
                    if (!_starting &&
                        (_state == 'ringing' ||
                            _state == 'connecting' ||
                            _isConnected)) ...[
                      const SizedBox(height: Gap.lg),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: Gap.sm,
                        children: [
                          if (!_isConnected)
                            TextButton(
                                onPressed: _markActive,
                                child: Text(_t.circleCallRelayConnected)),
                          if (_state == 'active')
                            TextButton(
                                onPressed: _markReconnecting,
                                child: Text(_t.circleCallRelayDropped)),
                          if (_isConnected)
                            TextButton(
                                onPressed: _markFailed,
                                child: Text(_t.circleCallRelayFailed)),
                        ],
                      ),
                    ],
                    if (_isVideo && _state != 'failed') ...[
                      const SizedBox(height: Gap.lg),
                      Text(_t.circleCallVideoPlaceholder,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
            ),
            CircleCallControls(
              isVideo: _isVideo,
              muted: _muted,
              speakerOn: _speakerOn,
              cameraOn: _cameraOn,
              lowData: _lowData,
              onToggleMute: () => setState(() => _muted = !_muted),
              onToggleSpeaker: () => setState(() => _speakerOn = !_speakerOn),
              onToggleCamera: () => setState(() => _cameraOn = !_cameraOn),
              onSwitchCamera: () {
                // Integrator: RTCVideoRenderer switchCamera().
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(_t.circleCallSwitchCamera)));
              },
              onToggleLowData: () => setState(() => _lowData = !_lowData),
              onHangup: _hangup,
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel() {
    if (_starting) return _t.circleCallConnecting;
    switch (_state) {
      case 'ringing':
        return widget.outgoing
            ? _t.circleCallRinging
            : _t.circleCallIncoming;
      case 'connecting':
        return _t.circleCallConnecting;
      case 'active':
        return _t.circleCallActive;
      case 'reconnecting':
        return _t.circleCallReconnecting;
      case 'failed':
        return _t.circleCallFailed;
      default:
        return _t.circleCallEnded;
    }
  }

  /// Shown when the SERVER refused a video call for a free caller. We never
  /// start media; we offer the upgrade / points path (referral unlock).
  Widget _gateScreen(ColorScheme scheme) => Scaffold(
        appBar: AppBar(title: Text(_t.circleCallVideoPremiumTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.workspace_premium_outlined,
                    size: 56, color: scheme.primary),
                const SizedBox(height: Gap.lg),
                Text(_t.circleCallVideoPremiumTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: Gap.sm),
                Text(_t.circleCallVideoPremiumBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
                const SizedBox(height: Gap.xl),
                FilledButton.icon(
                  icon: const Icon(Icons.workspace_premium),
                  label: Text(_t.circleCallGetPremium),
                  onPressed: () => Navigator.of(context).pop('upgrade'),
                ),
                const SizedBox(height: Gap.sm),
                OutlinedButton.icon(
                  icon: const Icon(Icons.redeem_outlined),
                  label: Text(_t.circleCallUnlockWithPoints),
                  onPressed: () => Navigator.of(context).pop('points'),
                ),
                const SizedBox(height: Gap.md),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_t.close),
                ),
              ],
            ),
          ),
        ),
      );
}
