// f3-design gallery states for test/screenshots_test.dart: the ring
// checklist (what is missing on this phone) and a My Circle group chat —
// the two f3 screens the gallery did not render yet.
import 'package:flutter/widgets.dart';

import 'package:assisto/calls/ring_checklist.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/screens/ring_checklist_screen.dart';
import 'package:assisto/services/oem_guide.dart';

class _RingNative implements RingCheckNative {
  @override
  Future<bool?> notificationsEnabled() async => true;
  @override
  Future<bool?> callChannelOk() async => true;
  @override
  Future<bool?> canFullScreen() async => false;
  @override
  Future<OemInfo?> oemInfo() async => const OemInfo(
      manufacturer: 'Xiaomi', brand: 'Redmi', model: 'Note 12', sdkInt: 34,
      release: '14', batteryOptIgnored: false, bgRestricted: false);
  @override
  Future<bool> fixNotifications() async => true;
  @override
  Future<bool> fixCallChannel() async => true;
  @override
  Future<bool> fixFullScreen() async => true;
  @override
  Future<OemOpen> openOemStep(String nativeStep) async => OemOpen.oem;
}

/// Puts RingChecklist.isAndroid back to "not Android" (the test host) when
/// the shot is torn down, so later gallery screens are unaffected.
class _RestoreIsAndroid extends StatefulWidget {
  const _RestoreIsAndroid({required this.child});
  final Widget child;
  @override
  State<_RestoreIsAndroid> createState() => _RestoreIsAndroidState();
}

class _RestoreIsAndroidState extends State<_RestoreIsAndroid> {
  @override
  void dispose() {
    RingChecklist.isAndroid = () => false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final IdentityKeyPair _identity = SoftwareE2E().generateIdentity();

Map<String, dynamic> _member(bool bn) => {
      'id': 1,
      'name': bn ? 'আম্মু' : 'Mom',
      'phone': '01710000000',
      'status': 'accepted',
      'relation': 'mother',
      'public_key': _identity.publicKeyB64,
    };

Map<String, dynamic> _group(bool bn) => {
      'id': 5,
      'name': bn ? 'পরিবার' : 'Family',
      'my_role': 'admin',
      'my_member_id': 1,
      'announcements_only': false,
      'disappearing': 0,
      'mute': false,
      'favourite': false,
    };

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> f3Shots = {
  'f3_ring_checklist': (l) {
    RingChecklist.isAndroid = () => true;
    return _RestoreIsAndroid(
        child: RingChecklistScreen(native: _RingNative(), firstRun: true));
  },
  'f3_group_chat': (l) => CircleGroupChatScreen(
      group: _group(l == 'bn'),
      identity: _identity,
      circleMembers: [_member(l == 'bn')]),
};
