import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../calls/api_group_calls.dart';
import '../calls/call_avatar.dart';
import '../calls/call_log.dart';
import '../calls/call_native.dart';
import '../calls/call_runtime.dart';
import '../calls/group_call.dart';
import '../l10n/app_localizations.dart';
import '../screens/group_call_screen.dart';
import '../state.dart';
import '../theme.dart';
import 'lock_screen_guard.dart';

/// b3-group: "Nadia invites you to a group call" — full-screen ring while
/// Assisto is open (real-time queue, foreground push, or the incoming check
/// after a notification tap). Join opens the group call; Decline tells the
/// server (the others see you are not coming). Rings 60 s at most.
class GroupIncomingScreen extends StatefulWidget {
  const GroupIncomingScreen(
      {super.key, required this.row, this.ring = true, this.debugController});

  /// circle/calls/group/incoming row: room, kind, host_name, host_photo,
  /// group_name, present.
  final Map<String, dynamic> row;
  final bool ring;

  /// Gallery / widget tests: Join opens the call with this pre-built
  /// controller (no server, no LiveKit).
  final GroupCallController Function()? debugController;

  @override
  State<GroupIncomingScreen> createState() => _GroupIncomingScreenState();
}

class _GroupIncomingScreenState extends State<GroupIncomingScreen> {
  Timer? _timeout;
  bool _joined = false;

  String get _room => '${widget.row['room'] ?? ''}';
  bool get _video =>
      widget.row['video'] == true || widget.row['kind'] == 'video';

  @override
  void initState() {
    super.initState();
    CallRuntime.instance.markShown('g:$_room');
    if (widget.ring) {
      unawaited(CallNative.startRingtone(null).catchError((Object e) {
        callLog('group_ring#start', e);
        return null;
      }));
    }
    _timeout = Timer(const Duration(seconds: 60), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    unawaited(CallNative.stopRingtone());
    if (!_joined) LockScreenGuard.release();
    super.dispose();
  }

  void _join() {
    _joined = true;
    unawaited(CallNative.stopRingtone());
    final dbg = widget.debugController;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => GroupCallScreen(
            controller: dbg?.call(),
            room: _room,
            video: _video,
            title: '${widget.row['group_name'] ?? ''}'.isNotEmpty
                ? '${widget.row['group_name']}'
                : '${widget.row['host_name'] ?? ''}')));
  }

  void _decline() {
    unawaited(CallNative.stopRingtone());
    try {
      final app = context.read<AppState>();
      unawaited(ApiGroupCalls(app.api, null)
          .event(_room, 'decline')
          .then<void>((_) {}, onError: (Object e) {
        callLog('group_ring#decline', e);
      }));
    } catch (e) {
      callLog('group_ring#decline2', e);
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final host = '${widget.row['host_name'] ?? ''}';
    final group = '${widget.row['group_name'] ?? ''}';
    return Scaffold(
      backgroundColor: Brand.ink,
      body: Container(
        decoration: const BoxDecoration(gradient: Brand.heroDark),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.xl, vertical: Gap.xxl),
            child: Column(
              children: [
                const Spacer(),
                CallAvatar(
                    name: group.isNotEmpty ? group : host,
                    photoUrl: '${widget.row['host_photo'] ?? ''}',
                    radius: 64),
                const SizedBox(height: Gap.lg),
                Text(group.isNotEmpty ? group : host,
                    key: const Key('group-incoming-title'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 26,
                        color: Colors.white,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.sm),
                Text(t.b3Incoming(host),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 16,
                        color: Colors.white.withValues(alpha: 0.85))),
                const SizedBox(height: Gap.xs),
                Text(_video ? t.b3GroupVideo : t.b3GroupVoice,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.75))),
                const Spacer(flex: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Round(
                      key: const Key('group-incoming-decline'),
                      color: Brand.danger,
                      icon: Icons.call_end,
                      label: t.pushCallDecline,
                      onTap: _decline,
                    ),
                    _Round(
                      key: const Key('group-incoming-join'),
                      color: Brand.success,
                      icon: _video ? Icons.videocam : Icons.call,
                      label: t.b3Join,
                      onTap: _join,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({
    super.key,
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Semantics(
            button: true,
            label: label,
            child: Material(
              color: color,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(
                    width: 72,
                    height: 72,
                    child: Icon(icon, color: Colors.white, size: 32)),
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
        ]),
      );
}
