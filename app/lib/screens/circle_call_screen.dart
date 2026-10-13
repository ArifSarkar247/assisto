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

  // Call-record state mirror (ringing -> connecting -> active -> ended).
  String _state = 'ringing';
  String? _callId;
  bool _starting = true;
  bool _blockedByGate = false;
  DateTime? _answeredAt;

  bool get _isVideo => widget.kind == 'video';

  @override
  void initState() {
    super.initState();
    _muted = false;
    _speakerOn = _isVideo;
    _cameraOn = _isVideo;
    _lowData = false;
    _start();
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
      // Integrator: here, open the RTCPeerConnection with r['ice'] servers
      // (core/logic/circle_calls.ice_config) and exchange offer/answer via the
      // relay. Until flutter_webrtc is wired, we simulate a connecting state so
      // the UI + controls + call-record flow are exercisable.
      if (mounted) {
        setState(() {
          _starting = false;
          _state = widget.outgoing ? 'ringing' : 'connecting';
        });
      }
    } catch (_) {
      // Offline / not wired — show ringing so the UI is navigable; a real call
      // would surface a failure after a timeout.
      if (mounted) {
        setState(() {
          _starting = false;
          _state = 'ringing';
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

  void _hangup() {
    _event(_state == 'active' ? 'hangup' : 'cancel');
    if (mounted) Navigator.of(context).pop();
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
                        Icon(_isVideo ? Icons.videocam : Icons.call,
                            size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: Gap.xs),
                        Text(_statusLabel(),
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                    if (_isVideo) ...[
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
