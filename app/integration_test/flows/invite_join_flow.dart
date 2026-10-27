// invite-join — "tap the link, type your name, you're in", PROVEN on the CI
// emulator against the throw-away seeded Django (SMS is off in CI, so the
// no-OTP branch is the one exercised; the OTP branch is covered by
// core.tests_invite_join + test/invite_join_test.dart):
//
//   A = Reality Rahim (the app under test, signed in) — driven via the UI
//   B = a BRAND-NEW person (fresh number each run) — an independent ApiClient
//       doing exactly what B's freshly installed app does: preview the code,
//       sign up with name + number (NO password) — joined in the same call.
//
//   1  A: My Circle -> + -> Add to My Circle -> "Invite with a link" ->
//      Copy  -> the short link lifeassisto.com/i/<10 chars> is made
//   2  B: preview shows A's first name; sign-up with name + number -> token,
//      no password, member state "accepted"
//   3  A: B is in My Circle; "Invited, not joined yet" shows "Joined: B"
//   4  A opens an invite B made (the deep-link path: PendingInvite -> the
//      root pushes "Join B's circle") -> Join -> already connected -> chat
//
// Screenshot at every step.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/invite/invite_join_screen.dart';
import 'package:assisto/invite/invite_link.dart';
import 'package:assisto/invite/invite_share_sheet.dart';
import 'package:assisto/screens/messenger/m3_add_to_circle_screen.dart';
import 'package:assisto/screens/messenger/messenger_home_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 1000000;
final _phoneB = '01719${_tag.toString().padLeft(6, '0')}';
final _nameB = 'Invitee $_tag';

void registerInviteJoinFlows() {
  realityFlow('18_invite_join', 'My Circle',
      'Invite link: A makes a link, a brand-new person joins with name + number (no password), both in each other\'s circle',
      (f) async {
    await f.home();
    late String link;
    late String code;
    late ApiClient apiB;

    await f.step('A: My Circle -> + -> Add -> "Invite with a link"', () async {
      await f.openRoute('circle');
      await f.waitFor(find.byType(MessengerHomeScreen), what: 'My Circle home');
      await f.tap(find.byKey(const Key('m3-fab')), settleSeconds: 3);
      await f.tap(find.byKey(const Key('m3-new-add')), settleSeconds: 2);
      await f.waitFor(find.byType(M3AddToCircleScreen), what: 'Add to My Circle');
      await f.scrollTo(find.byKey(const Key('ij-invite-link')));
      await f.shot('add-screen-invite-tile');
      await f.tap(find.byKey(const Key('ij-invite-link')), settleSeconds: 2);
      await f.waitFor(find.byKey(const Key('ij-share-sheet')), what: 'share sheet');
      await f.shot('share-sheet');
    });

    await f.step('A: Copy -> one short link is made', () async {
      await f.tap(find.byKey(const Key('ij-via-copy')), settleSeconds: 3);
      f.expectHttp('POST', '/circle/invite/code');
      await f.waitFor(find.byKey(const Key('ij-preview')), what: 'message preview');
      final txt = find.descendant(
          of: find.byKey(const Key('ij-preview')), matching: find.byType(Text));
      final s = (f.tester.widget<Text>(txt.first).data ?? '');
      final m = RegExp(r'https?://\S+/i/([A-Z2-9]{10})').firstMatch(s);
      if (m == null) throw TestFailure('no short /i/<code> link in: $s');
      link = m.group(0)!;
      code = m.group(1)!;
      if (InviteLink.codeFrom(link) != code) throw TestFailure('app cannot parse $link');
      f.note('link $link');
      await f.shot('link-made');
      await f.back();
    });

    await f.step('B (new phone): preview shows A, sign-up with name + number, no password',
        () async {
      apiB = ApiClient()..lang = 'en';
      final p = await f.net(() => apiB.postJsonRaw('/invite/preview', {'code': code}));
      if (p['ok'] != true || '${p['inviter_name']}'.isEmpty) {
        throw TestFailure('preview: $p');
      }
      if ('$p'.contains('01700000001')) throw TestFailure('preview leaks the phone');
      final r = await f.net(() => apiB.postJsonRaw('/invite/signup', {
            'code': code, 'name': _nameB, 'phone': _phoneB, 'via': 'link',
            'device_id': 'reality-$_tag'}));
      if (r['_status'] != 201 || r['token'] == null) throw TestFailure('signup: $r');
      if (r['has_password'] != false) throw TestFailure('a password was set: $r');
      if ((r['member'] as Map)['state'] != 'accepted') throw TestFailure('not joined: $r');
      apiB.token = '${r['token']}';
    });

    await f.step('A: B is in My Circle; the invite shows "Joined"', () async {
      await f.backToHome();
      await f.openRoute('circle', settleSeconds: 4);
      await f.waitFor(find.text(_nameB), seconds: 20, what: 'B in the chat list');
      await f.shot('b-in-circle');
      await f.pushScreen(const InviteSentScreen());
      await f.waitFor(find.textContaining(_nameB), seconds: 15, what: 'Joined: B');
      await f.shot('invited-joined');
      await f.backToHome();
    });

    await f.step('B makes a link; A opens it (deep-link path) -> already connected -> chat',
        () async {
      final r = await f.net(() => apiB.postJsonRaw('/circle/invite/code', {}));
      final c2 = '${r['code']}';
      if (InviteLink.codeFrom(c2) == null) throw TestFailure('B code: $r');
      await PendingInvite.set(c2, via: 'link');
      await f.pumpFor(const Duration(seconds: 3));
      await f.waitFor(find.byType(InviteJoinScreen), seconds: 15, what: 'Join screen');
      await f.shot('join-signed-in');
      final open = find.byKey(const Key('ij-join'));
      final already = find.text(f.t.ijOpenChat);
      await f.tap(open.evaluate().isNotEmpty ? open : already, settleSeconds: 4);
      f.expectHttp('POST', '/invite/join');
      await f.waitFor(find.text(_nameB), seconds: 15, what: 'chat with B');
      await f.shot('chat-open');
    });
    f.expectNoServerErrors();
  });
}
