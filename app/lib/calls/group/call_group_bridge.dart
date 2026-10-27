import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../realtime/realtime_transport.dart';
import '../../theme.dart';
import '../call_controller.dart';
import '../call_log.dart';
import '../media_ext.dart';
import '../screen_share.dart';
import 'add_person_sheet.dart';
import 'group_call.dart';
import 'group_call_api.dart';
import 'group_stage.dart';
import 'group_wiring.dart';

/// callsB: everything the 1:1 call screen ([CircleCallScreen]) needs for
/// screen sharing and for growing into a group call, kept in one object so
/// the screen itself changes in a few marked lines only:
///
///   * "Share screen" (video) + "Add person" under the 1:1 controls,
///   * the red sharing bar, and the other side's shared screen uncropped,
///   * the first "Add person" creates the room; a `call.roster` event for
///     this call (someone else added a person) does too — from then on the
///     screen shows the group grid when 3+ people are ringing / in it,
///   * the 1:1 call ending while others are still in the group keeps the
///     screen (the group goes on).
/// Plain 1:1 calls: no room, no session, nothing else changes.
class CallGroupBridge implements GroupCallSessionLike {
  CallGroupBridge({required VoidCallback onChange}) : _onChange = onChange;

  /// A call minimized to the mini bar keeps its bridge (a running screen
  /// share, the group) until the call is over; the re-opened screen takes
  /// it back with [forCall].
  static final Map<int, CallGroupBridge> _parked = {};
  static CallGroupBridge? forCall(int? callId, VoidCallback onChange) {
    final b = callId == null ? null : _parked.remove(callId);
    if (b != null) {
      b._onChange = onChange;
      b._parkedNow = false;
    }
    return b;
  }

  VoidCallback _onChange;
  bool _parkedNow = false;

  /// The screen's rebuild hook (a no-op while parked).
  void onChange() {
    if (!_parkedNow) _onChange();
  }

  CallController? _c;
  ApiClient? _api;
  PollRealtimeTransport? _transport;
  GroupCallSession? group;
  ScreenShareController? share;
  StreamSubscription<RealtimeEvent>? _rosterSub;
  bool _checkedRoom = false;
  bool _disposed = false;
  int _peerMemberId = -1;

  /// Gallery / tests: a pre-built session / share controller.
  void preview({GroupCallSession? group, ScreenShareController? share}) {
    _preview = true;
    this.group = group;
    this.share = share;
    group?.addListener(onChange);
    share?.addListener(onChange);
  }

  /// A real call: watch for a room around it and offer screen share.
  void attach(CallController c,
      {required ApiClient api,
      required PollRealtimeTransport transport,
      required AppLocalizations Function() texts,
      int? peerMemberId}) {
    if (_c != null) return;
    _c = c;
    _api = api;
    _transport = transport;
    _peerMemberId = peerMemberId ?? -1;
    final media = c.media;
    if (media is ScreenShareMedia) {
      share = ScreenShareController(
        media: media,
        service: NativeScreenShareService(),
        links: () => group?.controllers ?? [c],
        texts: () {
          final t = texts();
          return (t.ssNotifTitle, t.ssNotifBody, t.ssNotifStop);
        },
      )..addListener(_onShare);
    }
    c.addListener(_onCall);
    // a minimized call re-opened from the mini bar finds its group again
    final known = GroupCalls.instance.forCall(c.callId);
    if (known != null) {
      _adopt(known);
      return;
    }
    if (media is! MeshHost) return;
    _rosterSub = transport.events
        .where((e) => e.topic == 'call.roster')
        .listen((e) => _onRoster(e.payload), onError: (Object err) {
      callLog('group_bridge#1', err);
    });
  }

  /// Already attached to [c] (a parked bridge taken back).
  bool attachedTo(CallController c) => identical(_c, c);

  void _onShare() {
    final g = group;
    if (g != null) g.setScreenSharing(share?.sharing ?? false);
    onChange();
  }

  void _onCall() {
    final c = _c;
    if (c == null || _disposed) return;
    // an ANSWERED call can already be in a room (I was added by someone):
    // ask once when it connects. Placed calls learn it from call.roster.
    if (!_checkedRoom && c.isLive && !c.outgoing && group == null) {
      _checkedRoom = true;
      unawaited(_checkRoom());
    }
    if (c.isEnded && group == null) unawaited(share?.stop());
    if (_parkedNow && c.isEnded && !alive) {
      // the minimized call is over: clean up for real
      _parked.removeWhere((_, v) => identical(v, this));
      _parkedNow = false;
      dispose(handedOff: false);
    }
  }

  Future<void> _checkRoom() async {
    final c = _c, api = _api, tr = _transport;
    if (c?.callId == null || api == null || tr == null) return;
    try {
      final j = await ApiGroupCallApi(api, tr).roomOfCall(c!.callId!);
      if (j != null && group == null && !_disposed) {
        _create(GroupRoster.fromJson(j));
      }
    } catch (e) {
      callLog('group_bridge#2', e);
    }
  }

  void _onRoster(Map<String, dynamic> p) {
    final c = _c;
    if (c == null || group != null || _disposed) return;
    final links = (p['links'] as List?) ?? const [];
    final ours = links
        .whereType<Map>()
        .any((l) => (l['call_id'] as num?)?.toInt() == c.callId);
    if (ours) _create(GroupRoster.fromJson(p));
  }

  void _create(GroupRoster r) {
    final c = _c, api = _api, tr = _transport;
    if (c == null || api == null || tr == null) return;
    final Object media = c.media;
    if (media is! MeshHost) return;
    final g = newGroupSession(
        api: api, transport: tr, host: media, primary: c, roster: r);
    g.muted = c.muted;
    g.cameraOn = c.cameraOn;
    g.screenSharing = share?.sharing ?? false;
    if (c.callId != null) GroupCalls.instance.register(c.callId!, g);
    _adopt(g);
  }

  void _adopt(GroupCallSession g) {
    group = g;
    g.addListener(onChange);
    _rosterSub?.cancel();
    _rosterSub = null;
    onChange();
  }

  // ------------------------------------------------------------ state
  /// The group goes on (the 1:1 call may have ended).
  bool get alive => group?.alive ?? false;

  /// Show the grid instead of the 1:1 stage.
  bool get groupView => group?.isGroupView ?? false;

  // ------------------------------------------- GroupCallSessionLike (1:1)
  @override
  Set<int> get inCallMemberIds =>
      group?.inCallMemberIds ?? {if (_peerMemberId >= 0) _peerMemberId};

  @override
  int get seatsLeft => group?.seatsLeft ?? (kGroupMax - 2);

  @override
  Future<AddPersonResult> addPerson(int memberId) async {
    final g = group;
    if (g != null) return g.addPerson(memberId);
    final c = _c, api = _api, tr = _transport;
    final id = c?.callId;
    if (c == null || id == null || api == null || tr == null || !c.isLive) {
      return AddPersonResult.ended;
    }
    try {
      final j = await ApiGroupCallApi(api, tr).addPerson(id, memberId);
      if (group == null) {
        _create(GroupRoster.fromJson(j));
      } else {
        group!.attachJson(j);
      }
      return AddPersonResult.ok;
    } catch (e) {
      callLog('group_bridge#3', e);
      return addResultFrom(e);
    }
  }

  Future<void> openAddPerson(BuildContext context) async {
    final api = _api;
    if (api == null) return;
    await AddPersonSheet.show(context,
        loadContacts: () async {
          final m = await api.getJson('/circle/members');
          return ((m['results'] ?? m['members'] ?? const []) as List)
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
        },
        session: this);
  }

  // ------------------------------------------------------------ widgets
  /// The 1:1 screen's extra row: Add person + Share screen (video only).
  Widget extras(BuildContext context, CallController c,
      {required bool video}) {
    final t = AppLocalizations.of(context);
    final s = share;
    final canShare = video && s != null && s.supported;
    if (!c.isLive) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          _pill(
            key: const Key('call-add-person'),
            icon: Icons.person_add_alt_1_rounded,
            label: t.cgAddPerson,
            onTap: _api == null && group == null
                ? null
                : () => unawaited(openAddPerson(context)),
          ),
          if (canShare)
            _pill(
              key: const Key('call-share-screen'),
              icon: Icons.screen_share_rounded,
              label: s.sharing ? t.ssStop : t.ssShare,
              active: s.sharing,
              onTap: s.busy ? null : () => unawaited(runScreenShareFlow(context, s)),
            ),
        ],
      ),
    );
  }

  Widget _pill(
      {required Key key,
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
      bool active = false}) {
    return OutlinedButton.icon(
      key: key,
      style: OutlinedButton.styleFrom(
        foregroundColor: active ? Brand.ink : CallInk.text,
        backgroundColor: active ? CallInk.text : CallInk.glass,
        disabledForegroundColor: CallInk.textHint,
        side: const BorderSide(color: CallInk.textHint),
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      ),
      icon: Icon(icon),
      onPressed: onTap,
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  /// The red sharing bar (1:1 view) / the refused-or-failed line.
  Widget shareBar() {
    final s = share;
    if (s == null) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (s.sharing) ScreenShareBar(onStop: () => unawaited(s.stop())),
      ScreenShareNoticeText(share: s),
    ]);
  }

  /// The other person's shared screen, uncropped (null = not sharing).
  Widget? remoteScreen(CallController c, Object? surface) {
    if (!c.isLive || !c.remoteScreen) return null;
    if (surface is ScreenShareSurface) return surface.remoteScreenView();
    return null;
  }

  /// The group grid (null = keep the 1:1 stage).
  Widget? groupStage(BuildContext context,
      {required Future<void> Function() onLeave,
      VoidCallback? onSpeaker,
      bool speakerOn = false}) {
    final g = group;
    if (g == null || !g.isGroupView) return null;
    final Object? host = _c?.media;
    final s = share;
    return GroupCallView(
      session: g,
      share: s,
      selfView: host is MeshHost ? () => host.localPreview() : null,
      onShareTap:
          s == null ? null : () => unawaited(runScreenShareFlow(context, s)),
      onAddPerson: () => unawaited(openAddPerson(context)),
      onSpeaker: onSpeaker,
      speakerOn: speakerOn,
      onHangup: onLeave,
    );
  }

  /// Leave the group (the red button in the grid).
  Future<void> leave() async {
    await share?.stop();
    await group?.leave();
  }

  bool _preview = false;

  void dispose({required bool handedOff}) {
    if (_preview) {
      // gallery / tests own the injected session + share controller
      _preview = false;
      group?.removeListener(onChange);
      share?.removeListener(onChange);
      return;
    }
    final c = _c;
    if (handedOff && c?.callId != null && !(c?.isEnded ?? true)) {
      // minimized: keep sharing / the group alive with the call
      _parkedNow = true;
      _parked[c!.callId!] = this;
      return;
    }
    _disposed = true;
    _rosterSub?.cancel();
    _c?.removeListener(_onCall);
    final s = share;
    if (s != null) {
      s.removeListener(_onShare);
      if (!handedOff) {
        unawaited(s.stop());
        s.dispose();
      }
    }
    final g = group;
    if (g != null) {
      g.removeListener(onChange);
      if (!handedOff) {
        unawaited(g.leave());
        GroupCalls.instance.unregister(g);
        g.dispose();
        final Object? host = _c?.media;
        if (host is MeshHost) {
          unawaited(host.releaseAll().catchError((Object e) {
            callLog('group_bridge#4', e);
          }));
        }
      }
    }
  }
}
