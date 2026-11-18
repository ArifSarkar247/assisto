// e2eproof — the 8 PROOF flows (owner WORLD CLASS rule: "proof before done
// = scripted E2E tests of main flows on emulators and Firebase Test Lab").
//
// Runs ONLY in .github/workflows/e2e.yml (REALITY_ONLY=e2e) against the
// throw-away Django with settings_e2eproof: real server code, with the network
// seams faked by backend/ci_e2e (AI + photo answers, SMS OTP, Google Places,
// push outbox, fake-clock tick). It never reaches the live server.
//
//   A = Reality Rahim (this app, driven through the UI)
//   B = Reality Karim (the "second phone": an independent API client)
//
// Every step is timed (results.json: steps[].at_ms / ms) and screenshotted;
// e2e.yml turns results.json + the server outbox into e2e_proof.json.
// Map to the quality board: owner_actions/E2E_PROOF_BN.md.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path_provider/path_provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/carecall/carecall_ring_screen.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/messaging/media/multi_pick.dart' as mp;
import 'package:assisto/notifications.dart';
import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/reminders/alarm_plan.dart';
import 'package:assisto/reminders/reminder_alarms.dart';
import 'package:assisto/screens/ai_chat_screen.dart'; // gap-aichat
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/otp/otp_verify_screen.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';
import 'package:assisto/widgets/otp_code_input.dart';

import '../support/harness.dart';

const _otp = String.fromEnvironment('E2E_TEST_OTP', defaultValue: '135790');
final _tag = DateTime.now().millisecondsSinceEpoch % 100000;
const _oem = MethodChannel('com.assisto/oem_guide');

// ---------------------------------------------------------------- helpers
/// Any text on screen (Text, RichText, SelectableText — markdown answers are
/// RichText) containing [s]. Typed input (EditableText) is NOT matched.
Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      if (w is SelectableText) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      return false;
    });

List<Map<String, dynamic>> _rows(Map<String, dynamic> r, [String key = 'results']) =>
    ((r[key] ?? r['members'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

int _uid(Map<String, dynamic> me) =>
    ((me['id'] ?? (me['user'] as Map?)?['id']) as num).toInt();

/// A's server client = the APP's own session token. A second password login
/// (Harness.backend) rotates A's token on current servers and logs the app
/// out (run 42548977601: every call after it was 401).
ApiClient _apiA(RFlow f) {
  final c = ApiClient.detached(f.app.api.token ?? '');
  c.lang = 'en';
  return c;
}

/// Server-side proof rows the CI fakes recorded (ci_e2e outbox).
Future<List<Map<String, dynamic>>> _outbox(ApiClient api,
    {String kind = '', double since = 0, String user = ''}) async {
  final q = 'since=$since${kind.isEmpty ? '' : '&kind=$kind'}${user.isEmpty ? '' : '&user=$user'}';
  return _rows(await api.getJson('/ci-e2e/outbox?$q'), 'rows');
}

Future<double> _now(ApiClient api) async =>
    ((await api.getJson('/ci-e2e/outbox?kind=none'))['now'] as num).toDouble();

/// A real PNG (red circle on white) written to the app's temp dir.
Future<String> _png(String name) async {
  final im = img.Image(width: 160, height: 160);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));
  img.fillCircle(im, x: 80, y: 80, radius: 56, color: img.ColorRgb8(214, 32, 39));
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name.png');
  await f.writeAsBytes(img.encodePng(im));
  return f.path;
}

/// The system photo picker cannot be driven from a test; this stands in for
/// it at the platform-interface level (everything after the pick is real).
class _FakePicker extends ImagePickerPlatform {
  _FakePicker(this.paths);
  final List<String> paths;
  @override
  Future<XFile?> getImageFromSource(
          {required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async =>
      paths.isEmpty ? null : XFile(paths.first);
  @override
  Future<List<XFile>> getMedia({required MediaOptions options}) async =>
      [for (final p in paths) XFile(p)];
  @override
  Future<List<XFile>> getMultiImageWithOptions(
          {MultiImagePickerOptions options = const MultiImagePickerOptions()}) async =>
      [for (final p in paths) XFile(p)];
}

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Future<void> _askHome(RFlow f, String q, {double settle = 6}) async {
  await f.enter(q, label: f.t.inputHint);
  await f.tapSend(settleSeconds: settle);
}

void registerE2eProofFlows() {
  // ------------------------------------------------------------ 1 OTP
  realityFlow('e2e1_signup_login_otp', 'E2E proof',
      'Sign-up with SMS OTP (new number) -> log out -> log in with SMS OTP (test code)', (f) async {
    // B's client reads the outbox: this flow logs A's app session out and in,
    // which may rotate A's server token.
    final api = await f.h.backend(userB: true);
    final since = await f.net(() => _now(api));
    final phone = '0175${(DateTime.now().millisecondsSinceEpoch % 10000000).toString().padLeft(7, '0')}';
    await f.step('first run: language picker -> English', () async {
      await f.shot('first-run');
      if (find.text('English').evaluate().isNotEmpty) {
        await f.tapText('English');
        await f.tapText('Continue', settleSeconds: 3);
      } else {
        f.note('language already chosen (not a fresh install)');
      }
      if (f.app.loggedIn) {
        await f.net(() => f.app.logout());
        await f.pumpFor(const Duration(seconds: 3));
      }
      await f.waitFor(find.text(f.t.login).hitTestable(), what: 'login screen');
    });
    await f.step('sign up: name + new phone + password -> SMS code screen', () async {
      await f.tapText(f.t.noAccount, settleSeconds: 2);
      await f.enter('E2E Shila $_tag', label: f.t.name);
      await f.enter(phone, label: f.t.phoneOptional);
      await f.enter('E2e#Proof2026', label: f.t.password);
      await f.shot('signup-form');
      await f.tap(find.widgetWithText(FilledButton, f.t.register), settleSeconds: 4);
      await f.waitFor(find.byType(OtpVerifyScreen), seconds: 20, what: 'OTP screen');
      await f.waitFor(find.byType(OtpCodeInput), what: 'code boxes');
      await f.shot('otp-sent');
    });
    await f.step('server "sent" the signup SMS (fake gateway outbox)', () async {
      await f.eventually('signup SMS in the outbox', () async {
        final rows = await _outbox(api, kind: 'sms', since: since);
        return rows.any((r) =>
            phone.endsWith('${r['to']}'));
      });
    });
    await f.step('enter the test code -> account created + logged in', () async {
      final box = find.descendant(of: find.byType(OtpCodeInput), matching: find.byType(TextField));
      await f.tester.enterText(box.first, _otp);
      await f.pumpFor(const Duration(seconds: 6));
      await f.eventually('logged in as the new user', () async => f.app.loggedIn, seconds: 25);
      await f.shot('signed-up');
      f.expectHttp('POST', '/auth/otp/verify');
    });
    await f.step('log out -> log in as A with "Log in with SMS code"', () async {
      await f.net(() => f.app.logout());
      await f.pumpFor(const Duration(seconds: 3));
      await f.waitFor(find.byKey(const Key('login-with-sms')), seconds: 20, what: 'SMS login button');
      await f.tap(find.byKey(const Key('login-with-sms')), settleSeconds: 2);
      // the phone mode's field (_PhoneField) has no key: the screen's only TextField
      final id = await f.waitFor(find.byType(TextField).hitTestable(), what: 'mobile number field');
      await f.tester.enterText(id.first, Seed.phoneA);
      await f.pumpFor(const Duration(milliseconds: 500));
      await f.tap(find.byKey(const Key('otp-send')), settleSeconds: 4);
      await f.waitFor(find.byType(OtpCodeInput), seconds: 20, what: 'code boxes');
      final box = find.descendant(of: find.byType(OtpCodeInput), matching: find.byType(TextField));
      await f.tester.enterText(box.first, _otp);
      await f.pumpFor(const Duration(seconds: 6));
      await f.eventually('logged in as A', () async => f.app.loggedIn, seconds: 25);
      f.expectHttp('POST', '/auth/otp/login');
      await f.shot('logged-in-a');
    });
    await f.step('onboarding (if shown) -> home', () async {
      for (var i = 0; i < 4; i++) {
        final skip = find.text(f.t.skip).hitTestable();
        if (skip.evaluate().isEmpty) break;
        await f.tap(skip, settleSeconds: 3);
      }
      await f.home();
      await f.shot('home');
    });
  }, timeout: const Duration(minutes: 5));

  registerAichatProofFlows(); // aichat-nine: also alone (e2e.yml group start+aichat)

  // ------------------------------------------------------------ 3 My Circle
  realityFlow('e2e3_circle_media', 'E2E proof',
      'My Circle A->B: text, photo album (2), view-once photo opened once by B (two accounts)', (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final idB = e2e.generateIdentity();
    final apiB = await f.h.backend(userB: true);
    late Map<String, dynamic> edgeB;
    Future<List<Map<String, dynamic>>> fromA() async =>
        _rows(await apiB.getJson('/circle/${edgeB['id']}/messages'))
            .where((m) => m['mine'] != true)
            .toList();
    await f.step('B publishes a fresh key', () async {
      await f.net(() async {
        await apiB.postJson('/circle/keys',
            {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme});
        edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
      });
    });
    final text = 'E2E proof hello $_tag';
    late int before;
    await f.step('A opens B and sends a text -> B decrypts it', () async {
      before = (await f.net(fromA)).length;
      await f.openRoute('circle');
      // first open of My Circle may offer chat bubbles (a sheet): "Later"
      if (await f.appears(find.text(f.t.bbl2Title), seconds: 4)) {
        await f.shot('bubbles-offer');
        await f.tap(find.text('Later').hitTestable().last, settleSeconds: 2);
      }
      await f.waitFor(find.text(Seed.nameB), what: 'B in the chat list');
      await f.tap(find.text(Seed.nameB), settleSeconds: 3);
      await f.waitFor(find.byType(CircleChatScreen), what: 'chat');
      await f.enter(text, label: f.t.circleMessageHint);
      await f.tapSend(settleSeconds: 3);
      await f.shot('text-sent');
      await f.eventually('B decrypts "$text"', () async {
        final edge = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
        final peer = base64Decode('${edge['public_key']}');
        for (final m in await fromA()) {
          final pt = e2e.decrypt(self: idB, senderPublicKey: peer,
              ct: Ciphertext(ciphertextB64: '${m['ciphertext']}', nonceB64: '${m['nonce']}',
                  senderKeyId: '${m['sender_key_id'] ?? ''}', scheme: '${m['scheme'] ?? e2e.scheme}'));
          if (pt != null && pt.contains(text)) return true;
        }
        return false;
      }, seconds: 30);
    });
    Future<void> sendPhotos(List<String> paths, {bool viewOnce = false}) async {
      mp.pickMultipleMediaPaths = (limit) async => paths;
      await f.tap(find.byTooltip(f.t.circleAttach).hitTestable(), settleSeconds: 2);
      await f.tap(find.byKey(const Key('attach-gallery')), settleSeconds: 4);
      await f.waitFor(find.byKey(const Key('cm-send')), seconds: 20, what: 'album preview');
      if (viewOnce) {
        await f.tap(find.byKey(const Key('e-vo-toggle')), settleSeconds: 1);
        // the toggle's "view once on" SnackBar sits over the send row: clear it
        ScaffoldMessenger.of(f.tester.element(find.byKey(const Key('cm-send')))).clearSnackBars();
        await f.pumpFor(const Duration(milliseconds: 800));
      }
      await f.shot(viewOnce ? 'view-once-preview' : 'album-preview');
      await f.tap(find.byKey(const Key('cm-send')), settleSeconds: 6);
      if (find.byKey(const Key('cm-send')).evaluate().isNotEmpty) {
        await f.tap(find.byKey(const Key('cm-send')), settleSeconds: 6); // one retry
      }
    }

    await f.step('A sends a 2-photo album -> B has 2 new photo messages', () async {
      final ps = [
        await f.net(() => _png('e2e_album1_$_tag')),
        await f.net(() => _png('e2e_album2_$_tag')),
      ];
      final n0 = (await f.net(fromA)).length;
      await sendPhotos(ps);
      await f.eventually('B lists the album (2 photos)', () async {
        final rows = (await fromA()).skip(n0).where((m) => '${m['content_type']}' == 'photo');
        return rows.length >= 2;
      }, seconds: 60);
      await f.shot('album-sent');
    });
    await f.step('A sends a view-once photo -> B opens it once -> A sees "opened"', () async {
      final n0 = (await f.net(fromA)).length;
      await sendPhotos([await f.net(() => _png('e2e_once_$_tag'))], viewOnce: true);
      late int mid;
      await f.eventually('B has a view-once photo', () async {
        final vo = (await fromA()).skip(n0).where((m) => m['view_once'] == true).toList();
        if (vo.isEmpty) return false;
        mid = (vo.last['id'] as num).toInt();
        return true;
      }, seconds: 60);
      await f.net(() => apiB.postJson('/circle/messages/$mid/view-once-open'));
      await f.eventually('B cannot get it a second time (content gone)', () async {
        final m = (await fromA()).firstWhere((x) => x['id'] == mid);
        return m['view_once_opened'] == true && '${m['ciphertext'] ?? ''}'.isEmpty;
      });
      final apiA = _apiA(f);
      await f.eventually('A\'s copy says opened', () async {
        final edgeA = _rows(await apiA.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}' == Seed.nameB);
        final m = _rows(await apiA.getJson('/circle/${edgeA['id']}/messages'))
            .firstWhere((x) => x['id'] == mid, orElse: () => {});
        return m['view_once_opened'] == true;
      });
      await f.pumpFor(const Duration(seconds: 8));
      await f.shot('view-once-opened');
      f.note('messages from A before this flow: $before');
    });
  }, timeout: const Duration(minutes: 6));

  // ------------------------------------------------------------ 4 Safe Journey
  realityFlow('e2e4_safe_journey_chandra', 'E2E proof',
      'Safe Journey: search "Chandra" (Places) -> pick -> start with B watching -> arrived', (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    await f.net(() async {
      final a = await api.getJson('/journey/active');
      if (a['id'] != null) await api.postJson('/journey/${a['id']}/arrived');
    });
    await f.step('type "Chandra" -> suggestions -> pick "Chandra"', () async {
      await f.openRoute('journey');
      final dest = find.byKey(const ValueKey('j100_dest'));
      // the Safe Journey hub: "My Trip" opens the trip form
      if (!await f.appears(dest, seconds: 4)) {
        await f.shot('hub');
        await f.tap(find.text(f.t.sjlBtnTrip), settleSeconds: 3);
      }
      await f.waitFor(dest, what: 'destination search');
      await f.tester.tap(dest, warnIfMissed: false);
      // sjproof: since the qjourney/sjp0 P0 change the app asks ONE merged
      // /maps/search (our free BD list first); the SERVER adds Google
      // Autocomplete only when fewer than 5 good local matches. "Chandra"
      // alone is in our own list (no Google needed); "Chandra Bus" is not ->
      // the Google row (fake Places) must appear, then ONE Place Details.
      await f.tester.enterText(dest, 'Chandra Bus');
      final gRow = find.ancestor(
          of: find.textContaining('Chandra Bus Stand'),
          matching: find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('ps_row_')));
      await f.waitFor(gRow, seconds: 20, what: 'Google row in the merged suggestions');
      await f.shot('suggestions');
      f.expectHttp('GET', '/maps/search');
      await f.tap(gRow.first, settleSeconds: 4);
      final use = find.byKey(const ValueKey('ps_use'));
      if (await f.appears(use, seconds: 6)) {
        await f.shot('confirm-place');
        await f.tap(use, settleSeconds: 3);
      }
      f.expectHttp('GET', '/maps/place');
    });
    await f.step('B as watcher -> Start -> live screen', () async {
      // gatefix: sjstart2 replaced the watcher checkboxes with FilterChips
      // (Family first, several allowed) — find B's chip, tap it, and require
      // it to be SELECTED (gate run 44061721110 looked for CheckboxListTile).
      final b = find.widgetWithText(FilterChip, Seed.nameB);
      await f.scrollTo(b); // the watcher list is below the fold (lazy list)
      if (!await f.appears(b, seconds: 8)) throw TestFailure('watcher ${Seed.nameB} not listed');
      await f.tester.ensureVisible(b);
      if (!f.tester.widget<FilterChip>(b).selected) await f.tap(b);
      if (!f.tester.widget<FilterChip>(b).selected) {
        throw TestFailure('watcher ${Seed.nameB} chip did not select');
      }
      await f.shot('form');
      final start = find.byKey(const ValueKey('j100_start'));
      await f.tester.ensureVisible(start);
      await f.tap(start, settleSeconds: 3);
      // no road time (the emulator has no GPS fix): Start asks for the
      // arrival time like it asks a user -> type now + 1 h, OK, Start again
      if (await f.appears(find.byType(TimePickerDialog), seconds: 3)) {
        await f.shot('arrival-time');
        final ml = MaterialLocalizations.of(f.tester.element(find.byType(TimePickerDialog)));
        final kb = find.byTooltip(ml.inputTimeModeButtonLabel);
        if (kb.evaluate().isNotEmpty) await f.tap(kb, settleSeconds: 1);
        final now = DateTime.now();
        final at = now.add(const Duration(hours: 1));
        final h12 = at.hour % 12 == 0 ? 12 : at.hour % 12;
        final fields = find.descendant(of: find.byType(TimePickerDialog), matching: find.byType(TextField));
        await f.tester.enterText(fields.at(0), '$h12');
        await f.tester.enterText(fields.at(1), at.minute.toString().padLeft(2, '0'));
        if ((at.hour >= 12) != (now.hour >= 12)) {
          await f.tap(find.descendant(of: find.byType(TimePickerDialog),
              matching: find.text(at.hour >= 12 ? ml.postMeridiemAbbreviation : ml.anteMeridiemAbbreviation)));
        }
        await f.pumpFor(const Duration(milliseconds: 500));
        await f.tap(find.text(ml.okButtonLabel).last, settleSeconds: 2);
        if (find.byType(JourneyLiveScreen).evaluate().isEmpty && start.evaluate().isNotEmpty) {
          await f.tester.ensureVisible(start);
          await f.tap(start, settleSeconds: 3);
        }
      }
      final skip = find.byKey(const ValueKey('j100b_bg_skip'));
      if (await f.appears(skip, seconds: 3)) await f.tap(skip, settleSeconds: 3);
      final notNow = find.text(f.t.notNow);
      if (await f.appears(notNow, seconds: 3)) await f.tap(notNow, settleSeconds: 3);
      await f.waitFor(find.byType(JourneyLiveScreen), seconds: 25, what: 'live journey');
      await f.shot('live');
      f.expectHttp('POST', '/journey/start');
    });
    late int jid;
    await f.step('server: destination = Chandra (picked place coordinates); B watching', () async {
      await f.eventually('active journey to Chandra', () async {
        final a = await api.getJson('/journey/active');
        final d = (a['destination'] as Map?) ?? {};
        if (!'${d['name']}'.contains('Chandra')) return false;
        final lat = (d['lat'] as num?)?.toDouble() ?? 0;
        if ((lat - 24.04).abs() > 0.05) throw TestFailure('destination lat $lat is not Chandra');
        jid = (a['id'] as num).toInt();
        return true;
      });
      await f.eventually('B lists the journey', () async =>
          _rows(await apiB.getJson('/journey/watching'), 'journeys').any((j) => j['id'] == jid));
    });
    await f.step('I\'ve arrived -> over on the server; B sees arrived', () async {
      final btn = find.byKey(const ValueKey('j100_arrived'));
      await f.tester.ensureVisible(btn);
      await f.tap(btn, settleSeconds: 3);
      await f.shot('arrived');
      await f.eventually('no active journey', () async =>
          (await api.getJson('/journey/active'))['id'] == null);
      await f.eventually('B sees arrived', () async => _rows(await apiB.getJson('/journey/watching'), 'journeys')
          .any((j) => j['id'] == jid && j['status'] == 'arrived'));
    });
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------ 5 SOS
  realityFlow('e2e5_sos_guardian', 'E2E proof',
      'SOS: hold the button -> countdown -> alert created -> guardian B notified (server push)', (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final since = await f.net(() => _now(api));
    final bId = _uid(await f.net(() => apiB.getJson('/me')));
    await f.step('open Emergency -> hold SOS -> countdown runs out', () async {
      await f.openFeature(f.t.moduleEmergency, 'emergency');
      final btn = find.byKey(const ValueKey('sosat-sos-hold'));
      await f.waitFor(btn, what: 'SOS hold button');
      await f.tester.ensureVisible(btn);
      final g = await f.tester.startGesture(f.tester.getCenter(btn));
      await f.pumpFor(const Duration(milliseconds: EmergencySosPanel.holdMs + 600));
      await g.up();
      await f.pumpFor(const Duration(seconds: 1));
      await f.shot('countdown');
      await f.eventually('SOS sent (POST /family/sos)', () async =>
          f.h.recorder.hits.any((h) => h.method == 'POST' && h.path.startsWith('/family/sos') &&
              h.status >= 200 && h.status < 300), seconds: 30);
      await f.pumpFor(const Duration(seconds: 2));
      await f.shot('sos-sent');
    });
    await f.step('server: B has the SOS delivery from A', () async {
      await f.eventually('B received an unseen SOS', () async {
        final b = await apiB.getJson('/family/alerts');
        return (b['received'] as List).cast<Map>().any((x) => x['kind'] == 'sos' && x['active'] != false);
      });
    });
    await f.step('guardian notified: the server pushed "sos" to B', () async {
      await f.eventually('push to B in the outbox', () async {
        final rows = await _outbox(api, kind: 'push', since: since);
        return rows.any((r) => r['user_id'] == bId && '${r['push_kind']}' == 'sos');
      });
    });
    await f.net(() => api.postJson('/family/sos/resolve'));
  }, timeout: const Duration(minutes: 4));

  // ------------------------------------------------------------ 6 reminder
  realityFlow('e2e6_reminder_fires', 'E2E proof',
      'Reminder by chat ("৩ মিনিট পরে ...") -> confirm Yes -> exact OS alarm -> server push at the time (fake clock) -> Android shows it',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final since = await f.net(() => _now(api));
    await f.step('ask in chat -> confirm card -> Yes', () async {
      await f.openHomeChat();
      await _askHome(f, '৩ মিনিট পরে ওষুধ খাওয়ার কথা মনে করিয়ে দাও');
      final yes = find.byKey(const Key('ai-confirm-yes'));
      await f.waitFor(yes, seconds: 40, what: 'confirm card');
      await f.shot('confirm-card');
      await f.tap(yes, settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('ai-confirm-done')), seconds: 20, what: 'saved line');
      f.expectHttp('POST', '/agent/confirm');
      await f.shot('confirmed');
    });
    late Map<String, dynamic> rem;
    await f.step('server has the reminder (source ai)', () async {
      await f.eventually('reminder on the server', () async {
        final rows = await api.listItems('reminders');
        final m = rows.where((r) => '${r['title']}' == 'ওষুধ খাওয়া' && r['done'] != true).toList();
        if (m.isEmpty) return false;
        rem = m.last;
        return true;
      });
    });
    late AlarmPlan plan;
    await f.step('the phone syncs it -> exact alarm handed to Android', () async {
      await f.net(() => Notifications.init());
      await f.eventually('alarm scheduled', () async {
        await f.app.reminders.sync();
        await ReminderAlarms.reconcile(f.app.reminders.items);
        final plans = planReminderAlarms(f.app.reminders.items, now: DateTime.now())
            .where((p) => p.key == 'rem-${rem['id']}' || p.title == 'ওষুধ খাওয়া');
        if (plans.isEmpty) return false;
        plan = plans.first;
        final ids = await Notifications.pendingIds();
        return ids != null && ids.contains(plan.id);
      }, seconds: 40);
      f.note('alarm at ${plan.at.toIso8601String()}');
    });
    await f.step('fake clock +4 min: the server reminder job pushes it to A', () async {
      final r = await f.net(() => api.postJson('/ci-e2e/tick', {'job': 'push_due_reminders', 'advance_min': 4}));
      f.note('tick: ${r['fake_now']}');
      final me = _uid(await f.net(() => api.getJson('/me')));
      await f.eventually('reminder push in the outbox', () async {
        final rows = await _outbox(api, kind: 'push', since: since);
        return rows.any((x) => x['user_id'] == me && '${x['push_kind']}' == 'reminder' &&
            '${(x['data'] as Map?)?['reminder_id']}' == '${rem['id']}');
      });
    });
    await f.step('real clock: Android posts the alarm on time (<= 60 s late)', () async {
      int? post;
      await f.eventually('notification posted', () async {
        final m = await _oem.invokeMethod<Map>('activePostTimes');
        final v = m?[plan.id];
        post = v is int ? v : null;
        return post != null;
      }, seconds: 260);
      final lateS = ((post! - plan.at.millisecondsSinceEpoch) / 1000).round();
      f.note('delivered ${lateS}s after its time');
      await f.shot('delivered');
      if (lateS > 60) throw TestFailure('reminder ${lateS}s late');
    });
  }, timeout: const Duration(minutes: 8));

  // ------------------------------------------------------------ 7 khata
  realityFlow('e2e7_khata_expense_confirm', 'E2E proof',
      'Money/khata: "চায়ে ৫০ টাকা খরচ লিখে রাখো" -> confirm card -> Yes -> expense on the server', (f) async {
    await f.home();
    final api = _apiA(f);
    final before = (await f.net(() => api.listItems('transactions'))).length;
    await f.step('ask in chat -> confirm card shows ৳50', () async {
      await f.openHomeChat();
      await _askHome(f, 'চায়ে ৫০ টাকা খরচ লিখে রাখো');
      final yes = find.byKey(const Key('ai-confirm-yes'));
      await f.waitFor(yes, seconds: 40, what: 'confirm card');
      await f.shot('confirm-card');
    });
    await f.step('nothing is saved before Yes', () async {
      final n = (await f.net(() => api.listItems('transactions'))).length;
      if (n != before) throw TestFailure('an entry was written before the user said Yes');
    });
    await f.step('Yes -> one ৳50 expense (category চা) on the server', () async {
      await f.tap(find.byKey(const Key('ai-confirm-yes')).last, settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('ai-confirm-done')), seconds: 20, what: 'saved line');
      await f.shot('saved');
      await f.eventually('expense on the server', () async {
        final rows = await api.listItems('transactions');
        return rows.any((r) => '${r['kind']}' == 'expense' &&
            double.tryParse('${r['amount']}') == 50 && '${r['category']}'.contains('চা'));
      });
    });
  }, timeout: const Duration(minutes: 4));

  // ------------------------------------------------------------ 8 Care Call
  realityFlow('e2e8_care_call', 'E2E proof',
      'Care Call: B sets one for A -> A accepts (consent) -> server tick rings A -> A taps Done -> B told',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final probe = await f.net(() async {
      try {
        await api.getJson('/carecall');
        return true;
      } catch (_) {
        return false;
      }
    });
    if (!probe) {
      f.skip('Care Call is not on this build yet (GET /carecall missing) — the flow runs once agent/carecall is merged');
    }
    final since = await f.net(() => _now(api));
    final aId = _uid(await f.net(() => api.getJson('/me')));
    late int ccId;
    await f.step('A sets quiet hours away from now; B creates a once Care Call for A', () async {
      // carecallfix: a Care Call time is on the RECEIVER's clock (fcbrain
      // Probashi) = the zone A's phone reports on every app open. The CI
      // emulator runs on UTC (real BD phones on +06:00), so the slot is
      // "in 2 min" on THIS phone's clock — never an assumed Dhaka clock
      // (that put it 6 h away: nightly 43783087111 'carecall_tick made 0').
      await f.net(() => api.postJson('/family/brain/ping',
          {'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes}));
      final q = DateTime.now().add(const Duration(hours: 12));
      await f.net(() => api.postJson('/carecall/quiet',
          {'start': _hhmm(q), 'end': _hhmm(q.add(const Duration(minutes: 1)))}));
      final at = DateTime.now().add(const Duration(minutes: 2));
      final r = await f.net(() => apiB.postJson('/carecall', {
            'receiver_id': aId,
            'text': 'ওষুধ খাওয়ার সময় (CI $_tag)',
            'time': _hhmm(at),
            'repeat': 'once',
            'date': _ymd(at),
          }));
      ccId = ((r['care_call'] as Map)['id'] as num).toInt();
      // the server must agree: the slot is ~2 min ahead (not hours)
      final next = DateTime.tryParse('${(r['care_call'] as Map)['next_at'] ?? ''}');
      final ahead = next?.difference(DateTime.now()).inSeconds ?? -1;
      if (ahead < 0 || ahead > 5 * 60) {
        throw StateError('Care Call slot not ~2 min ahead on A\'s clock: next_at=$next '
            'receiver_tz=${(r['care_call'] as Map)['receiver_tz']} phone=${DateTime.now().timeZoneOffset}');
      }
    });
    await f.step('A opens Care Call -> sees the invite -> Accept (consent)', () async {
      await f.openRoute('carecall');
      await f.waitFor(find.text('Accept'), seconds: 20, what: 'consent invite');
      await f.shot('invite');
      await f.tap(find.text('Accept'), settleSeconds: 3);
      await f.eventually('B sees "accepted"', () async =>
          _rows(await apiB.getJson('/carecall'), 'sent')
              .any((c) => c['id'] == ccId && c['link'] == 'accepted'));
      await f.shot('accepted');
    });
    late Map<String, String> ring;
    await f.step('server tick (fake clock +3 min) rings A', () async {
      await f.net(() => api.postJson('/ci-e2e/tick', {'job': 'carecall_tick', 'advance_min': 3}));
      await f.eventually('ring push to A in the outbox', () async {
        final rows = (await _outbox(api, kind: 'push', since: since))
            .where((r) => r['user_id'] == aId && '${r['push_kind']}' == 'carecall' &&
                '${(r['data'] as Map?)?['care_call_id']}' == '$ccId')
            .toList();
        if (rows.isEmpty) return false;
        ring = (rows.last['data'] as Map).map((k, v) => MapEntry('$k', '$v'));
        return true;
      });
    });
    await f.step('the ring screen opens (as from the push) -> A taps Done', () async {
      // exactly what the push tap does (push_service -> openOnce)
      CareCallRingScreen.openOnce(appNavigatorKey.currentState, ring);
      await f.waitFor(find.text('Done'), seconds: 15, what: 'ring screen Done');
      await f.shot('ringing');
      await f.tap(find.text('Done'), settleSeconds: 4);
      await f.shot('done');
    });
    await f.step('B is told: "confirmed" in B\'s Care Call feed', () async {
      await f.eventually('B feed confirmed', () async =>
          _rows(await apiB.getJson('/carecall'), 'feed')
              .any((x) => x['care_call_id'] == ccId && x['kind'] == 'confirmed'));
    });
  }, timeout: const Duration(minutes: 5));
}

/// aichat-nine: the AI chat proof flows (row 1) — inside the e2e group and
/// alone with REALITY_ONLY=start,aichat (e2e.yml input group=start+aichat).
void registerAichatProofFlows() {
  // ------------------------------------------------------------ 2 AI chat
  realityFlow('e2e2_ai_chat_bn', 'E2E proof',
      'AI chat: Bangla question -> Bangla answer; follow-up uses context; photo + question; photo follow-up',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final since = await f.net(() => _now(api));
    await f.step('open the chat; ask in Bangla -> Bangla answer', () async {
      await f.openHomeChat();
      await _askHome(f, 'বাংলাদেশের রাজধানী কোথায়?');
      await f.waitFor(_sees('রাজধানী ঢাকা'), seconds: 40, what: 'Bangla answer');
      await f.shot('bn-answer');
      f.expectHttp('POST', '/agent');
    });
    await f.step('follow-up "সেখানে কত মানুষ থাকে?" -> answer knows the earlier turn', () async {
      await _askHome(f, 'সেখানে কত মানুষ থাকে?');
      await f.waitFor(_sees('আগের প্রশ্নটা মনে আছে'), seconds: 40,
          what: 'answer built on the earlier turn (history reached the model)');
      await f.shot('follow-up');
    });
    await f.step('photo + question -> photo answer in Bangla', () async {
      ImagePickerPlatform.instance = _FakePicker([await f.net(() => _png('e2e_photo_$_tag'))]);
      await f.enter('এই ছবিতে কী আছে?', label: f.t.inputHint);
      await f.tap(find.byTooltip(f.t.h1AttachPhoto).hitTestable(), settleSeconds: 2);
      await f.tap(find.text(f.t.h1PhotoGallery).hitTestable(), settleSeconds: 3);
      await f.shot('photo-sent');
      await f.waitFor(_sees('লাল বৃত্ত'), seconds: 60, what: 'photo answer');
      await f.shot('photo-answer');
    });
    await f.step('photo follow-up "বৃত্তটা কোন রঙের?" -> answer from the photo', () async {
      await _askHome(f, 'বৃত্তটা কোন রঙের?');
      await f.waitFor(_sees('ছবিতে যা দেখেছি'), seconds: 40, what: 'photo-context answer');
      await f.shot('photo-follow-up');
    });
    await f.step('server: every model turn was Bangla in, Bangla out; the photo reached vision', () async {
      final ai = await f.net(() => _outbox(api, kind: 'ai', since: since));
      final chat = ai.where((r) => '${r['q']}'.isNotEmpty).toList();
      if (chat.length < 3) throw TestFailure('only ${chat.length} chat turns reached the model');
      final bad = chat.where((r) => r['bn_q'] == true && r['bn_a'] != true).toList();
      if (bad.isNotEmpty) throw TestFailure('Bangla question answered in another language: $bad');
      final vis = await f.net(() => _outbox(api, kind: 'vision', since: since));
      if (vis.isEmpty || ((vis.last['bytes'] as num?) ?? 0) < 100) {
        throw TestFailure('the photo never reached the vision provider: $vis');
      }
      f.note('model turns ${chat.length}, vision calls ${vis.length} (CI fake providers)');
    });
  }, timeout: const Duration(minutes: 6));

  // gap-aichat: Assisto AI — a long answer cut at its limit ends at a full
  // sentence + honest hint + Continue; Continue finishes from the cut point,
  // free (the server got the Continue note; no credits on the second turn).
  realityFlow('e2e2c_ai_continue', 'E2E proof',
      'Assisto AI: long plan cut -> full sentence + hint + Continue -> rest from the cut point, free',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final since = await f.net(() => _now(api));
    await f.step('ask a long plan in Assisto AI -> cut answer + hint + Continue', () async {
      await f.pushScreen(const AiChatScreen());
      await f.enter('চায়ের দোকানের পুরো পরিকল্পনা লিখে দাও', label: f.t.aichatInputHint);
      await f.tapTooltip(f.t.aichatSend, settleSeconds: 6);
      await f.waitFor(_sees('ভাড়া নিন।'), seconds: 40, what: 'cut answer up to a full sentence');
      if (_sees('সরঞ্জাম কি').evaluate().isNotEmpty) {
        throw TestFailure('the cut answer still ends mid-word');
      }
      await f.waitFor(find.byKey(const ValueKey('aichat_continue')), what: 'Continue button');
      await f.waitFor(find.byKey(const ValueKey('aichat_cut_hint')), what: 'cut hint');
      await f.shot('cut-answer');
    });
    await f.step('Continue -> the rest from the cut point, free', () async {
      await f.tap(find.byKey(const ValueKey('aichat_continue')), settleSeconds: 6);
      await f.waitFor(_sees('সরঞ্জাম কিনুন'), seconds: 40, what: 'continuation');
      await f.waitFor(_sees(f.t.aibarFreeAnswer), what: 'free credit line');
      await f.shot('continued');
    });
    await f.step('server: the second model turn carried the Continue note', () async {
      final ai = await f.net(() => _outbox(api, kind: 'ai', since: since));
      if (!ai.any((r) => r['cut'] == true)) throw TestFailure('no cut turn: $ai');
      if (!ai.any((r) => r['cont'] == true)) throw TestFailure('no Continue turn: $ai');
      f.note('model turns ${ai.length} (CI fake providers)');
    });
  }, timeout: const Duration(minutes: 5));


  // aichat-nine: romanized Bangla in -> Bangla (Bengali script) out, and the
  // answer STREAMS: the first sentence is on screen while the model is still
  // writing (CI fake: one sentence every E2E_AI_STREAM_MS = 400 ms).
  realityFlow('e2e2r_ai_romanized', 'E2E proof',
      'Assisto AI: romanized Bangla question -> Bangla answer in Bengali script, streamed (first words before the end)',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final since = await f.net(() => _now(api));
    int? firstMs;
    int? fullMs;
    await f.step('ask "bkash e taka pathabo kivabe?" -> first sentence, then the rest', () async {
      await f.pushScreen(const AiChatScreen());
      await f.enter('bkash e taka pathabo kivabe?', label: f.t.aichatInputHint);
      final sw = Stopwatch()..start();
      await f.tapTooltip(f.t.aichatSend, settleSeconds: 0);
      while (sw.elapsedMilliseconds < 45000) {
        await f.tester.pump(const Duration(milliseconds: 50));
        if (firstMs == null && _sees('সংক্ষেপে: বিকাশ অ্যাপের').evaluate().isNotEmpty) {
          firstMs = sw.elapsedMilliseconds;
        }
        if (_sees('পরের ধাপ: প্রথমবার ছোট অঙ্ক').evaluate().isNotEmpty) {
          fullMs = sw.elapsedMilliseconds;
          break;
        }
      }
      await f.shot('romanized-answer');
      if (firstMs == null || fullMs == null) {
        throw TestFailure('answer never shown (first=$firstMs full=$fullMs)');
      }
      if (_sees('Send Money').evaluate().isNotEmpty || _sees('Open bKash').evaluate().isNotEmpty) {
        throw TestFailure('romanized Bangla was answered in English');
      }
      if (firstMs! >= fullMs!) {
        throw TestFailure('not streamed: first words $firstMs ms, full answer $fullMs ms');
      }
      f.note('AICHAT9-UI first words ${firstMs}ms, full answer ${fullMs}ms (CI fake, 5 sentences x 400 ms)');
    });
    await f.step('server: Bangla task for the romanized question, streamed request', () async {
      final ai = await f.net(() => _outbox(api, kind: 'ai', since: since));
      final row = ai.where((r) => '${r['q']}'.contains('bkash e taka')).toList();
      if (row.isEmpty) throw TestFailure('the question never reached the model: $ai');
      if (row.last['roman'] != true) throw TestFailure('no Bangla task for romanized Bangla: ${row.last}');
      if (row.last['bn_a'] != true) throw TestFailure('answer not in Bengali script: ${row.last}');
      if (row.last['stream'] != true) throw TestFailure('the chat did not stream: ${row.last}');
    });
  }, timeout: const Duration(minutes: 4));
}
