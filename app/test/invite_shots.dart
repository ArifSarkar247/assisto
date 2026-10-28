// invite-join: gallery states for test/screenshots_test.dart — the invited
// person's "Join X's circle" (signed out form, signed in one-tap, expired,
// offline) and the inviter's share sheet + "invited, not joined yet".
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:assisto/invite/invite_join_screen.dart';
import 'package:assisto/invite/invite_share_sheet.dart';
import 'package:assisto/state.dart';

import 'fake_invite.dart';

/// The gallery stub is signed in; the invited person is NOT.
class SignedOut extends StatelessWidget {
  final String lang;
  final Widget child;
  const SignedOut({super.key, required this.lang, required this.child});
  @override
  Widget build(BuildContext context) {
    final s = AppState()
      ..locale = Locale(lang)
      ..loading = false;
    return ChangeNotifierProvider<AppState>.value(value: s, child: child);
  }
}

String _who(String lang) => lang == 'bn' ? 'রহিম' : 'Rahim';

final Map<String, Widget Function(String)> inviteShots = {
  'ij_join_form': (lang) => SignedOut(
      lang: lang,
      child: InviteJoinScreen(
          code: 'K7QF2M9PAB', asRoot: true,
          backend: FakeInviteBackend(inviter: _who(lang)))),
  'ij_join_signed_in': (lang) => InviteJoinScreen(
      code: 'K7QF2M9PAB', backend: FakeInviteBackend(inviter: _who(lang))),
  'ij_join_expired': (lang) => SignedOut(
      lang: lang,
      child: InviteJoinScreen(
          code: 'K7QF2M9PAB', asRoot: true,
          backend: FakeInviteBackend(state: 'expired', inviter: _who(lang)))),
  'ij_join_offline': (lang) => InviteJoinScreen(
      code: 'K7QF2M9PAB', backend: FakeInviteBackend(state: 'offline')),
  'ij_share_sheet': (lang) => Scaffold(
      body: SafeArea(
          child: InviteShareSheet(backend: FakeInviteBackend(inviter: _who(lang))))),
  'ij_sent': (lang) => InviteSentScreen(
      backend: FakeInviteBackend(sent: fakeSentRows(lang))),
};
