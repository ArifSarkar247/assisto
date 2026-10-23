// Premium-QA gallery for slot a6 (Safety/SOS, Family, My Circle, Settings,
// Account, Onboarding). Same rendering as screenshots_test.dart, plus:
//   * ASSISTO_SHOT_DIR   output dir (default ~/assisto/screenshots/qa_a6)
//   * ASSISTO_SHOT_SCALE text scale (default 1.0); files get _x<scale>
//   * ASSISTO_SHOT_ONLY  comma list of spec names
// Layout errors (RenderFlex overflow = clipped text) are NOT fatal here: they
// are collected and appended to <dir>/_report.txt so a whole batch can be
// triaged at once.
import 'dart:io';
import 'dart:ui' as ui;

import 'app_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/a11y_prefs.dart';
import 'package:assisto/screens/about_screen.dart';
import 'package:assisto/screens/accessibility_mode_screen.dart';
import 'package:assisto/screens/battery_guidance_screen.dart';
import 'package:assisto/screens/delete_account_screen.dart';
import 'package:assisto/screens/emergency_screen.dart';
import 'package:assisto/screens/fall_detect_screen.dart';
import 'package:assisto/screens/family_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/journey_sos_screen.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/language_picker_screen.dart';
import 'package:assisto/screens/login_screen.dart';
import 'package:assisto/screens/lost_stolen_screen.dart';
import 'package:assisto/screens/my_lost_phone_screen.dart';
import 'package:assisto/screens/onboarding_screen.dart';
import 'package:assisto/screens/phone_safety_screen.dart';
import 'package:assisto/screens/recovery_screen.dart';
import 'package:assisto/screens/safety_screen.dart';
import 'package:assisto/screens/security_screen.dart';
import 'package:assisto/screens/settings_screen.dart';
import 'package:assisto/screens/voice_sos_screen.dart';
import 'package:assisto/screens/disaster_alerts_screen.dart';
import 'package:assisto/screens/app_update_screen.dart';
import 'package:assisto/screens/referral_screen.dart';
import 'package:assisto/screens/credits_screen.dart';
import 'package:assisto/widgets/rewarded_ad_sheet.dart';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/circle_call_history_screen.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/screens/circle_group_info_screen.dart';
import 'package:assisto/screens/circle_group_list_screen.dart';
import 'package:assisto/screens/circle_privacy_screen.dart';
import 'package:assisto/screens/circle_screen.dart';
import 'package:assisto/screens/circle_search_screen.dart';
import 'package:assisto/screens/circle_status_composer_screen.dart';
import 'package:assisto/screens/circle_status_screen.dart';
import 'package:assisto/screens/messenger/broadcast_lists_screen.dart';
import 'package:assisto/screens/messenger/channel_list_screen.dart';
import 'package:assisto/screens/messenger/community_list_screen.dart';
import 'package:assisto/screens/messenger/connection_requests_screen.dart';
import 'package:assisto/screens/messenger/contact_info_screen.dart';
import 'package:assisto/screens/messenger/contacts_screen.dart';
import 'package:assisto/screens/messenger/discover_screen.dart';
import 'package:assisto/screens/messenger/linked_devices_screen.dart';
import 'package:assisto/screens/messenger/messenger_home_screen.dart';
import 'package:assisto/screens/messenger/messenger_profile_screen.dart';
import 'package:assisto/screens/messenger/messenger_settings_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_account_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_calls_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_chats_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_notifications_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_privacy_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_storage_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_twostep_screen.dart';
import 'package:assisto/screens/messenger/starred_messages_screen.dart';

import 'c2_calls_shots.dart';
import 'fake_api.dart';

class _NoNet extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? c) => _DeadClient();
}

class _DeadClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw const SocketException('network disabled in screenshot tests');
}

final String _outDir = Platform.environment['ASSISTO_SHOT_DIR']?.isNotEmpty == true
    ? Platform.environment['ASSISTO_SHOT_DIR']!
    : '${Platform.environment['HOME']}/assisto/screenshots/qa_a6';
final double _scale =
    double.tryParse(Platform.environment['ASSISTO_SHOT_SCALE'] ?? '') ?? 1.0;

Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family);
  loader.addFont(File(path).readAsBytes().then((b) => ByteData.view(b.buffer)));
  await loader.load();
}

/// Realistic data for endpoints the shared FakeApi doesn't cover (shapes
/// copied from backend views_security.py / views_lost.py).
class _QaApi extends FakeApi {
  _QaApi({required super.mode, required super.lang});

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (mode == FakeMode.data) {
      final bn = lang == 'bn';
      if (path == '/security/state') {
        return {
          'has_pin': true, 'armed': true, 'frozen_until': null,
          'status': 'active', 'wrong_pin_count': 0, 'trusted_place_count': 2,
          'family_approver': {'id': 1, 'name': bn ? 'আম্মু' : 'Mom'},
          'approver_candidates': [
            {'id': 1, 'name': bn ? 'আম্মু' : 'Mom'},
            {'id': 2, 'name': bn ? 'রাফি' : 'Rafi'},
          ],
          'pending': <dynamic>[],
        };
      }
      if (path == '/ads/wallet') {
        return {
          'balance_credits': 3,
          'caps': {'rewarded': {'cap': 5, 'used': 2, 'remaining': 3}},
          'ads_configured': false,
        };
      }
      if (path == '/circle/calls') {
        // backend shape after the QA fix (views_build61.CircleCallsView)
        return {
          'calls': [
            {'id': 1, 'kind': 'voice', 'state': 'ended', 'duration_sec': 65,
             'duration': bn ? '১:০৫' : '1:05', 'outgoing': true, 'mine': true,
             'outcome': bn ? 'আউটগোয়িং' : 'Outgoing',
             'name': bn ? 'আম্মু' : 'Mom', 'member_id': 1, 'relation': 'mother',
             'started_at': '2026-10-10T09:00:00Z'},
            {'id': 2, 'kind': 'video', 'state': 'missed', 'duration_sec': 0,
             'duration': '', 'outgoing': false, 'mine': false,
             'outcome': bn ? 'মিসড কল' : 'Missed call',
             'name': bn ? 'রাফি' : 'Rafi', 'member_id': 2, 'relation': 'friend',
             'started_at': '2026-10-09T20:15:00Z'},
          ],
        };
      }
      if (path == '/security/lost-phone') {
        return {
          'imei1': '356938035643809', 'imei2': '', 'model': 'Realme 9i',
          'armed': true, 'lost_mode': false, 'frozen': false,
          'went_dark_at': null,
          'last_location': {'lat': 23.7806, 'lng': 90.4070, 'at': '2026-10-21T09:12:00+06:00'},
          'trail': [
            {'lat': 23.7806, 'lng': 90.4070, 'at': '2026-10-21T09:12:00+06:00'},
            {'lat': 23.7790, 'lng': 90.4011, 'at': '2026-10-21T08:40:00+06:00'},
          ],
          'events': <dynamic>[], 'sim_change': null, 'status': 'active',
          'viewer': 'owner',
        };
      }
    }
    return super.getJson(path);
  }
}

AppState _stub(String lang, FakeMode mode) {
  final s = AppState();
  s.api = _QaApi(mode: mode, lang: lang);
  s.user = AppUser(
      id: 1,
      name: lang == 'bn' ? 'আরিফ' : 'Arif',
      phone: '01712345678',
      email: '',
      autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

typedef Spec = ({Widget Function() build, FakeMode mode});

final Map<String, Spec> specs = {
  // ---- Safety / SOS ----
  'safety': (build: () => const SafetyScreen(), mode: FakeMode.data),
  'emergency': (build: () => const EmergencyScreen(), mode: FakeMode.data),
  'voice_sos': (build: () => const VoiceSosScreen(), mode: FakeMode.data),
  'fall_detect': (build: () => const FallDetectScreen(), mode: FakeMode.data),
  'journey_start': (build: () => const JourneyStartScreen(), mode: FakeMode.data),
  'journey_live': (build: () => const JourneyLiveScreen(journeyId: 1), mode: FakeMode.data),
  'journey_sos': (build: () => const JourneySosScreen(journeyId: 1), mode: FakeMode.data),
  'lost_stolen': (build: () => const LostStolenScreen(), mode: FakeMode.data),
  'my_lost_phone': (build: () => const MyLostPhoneScreen(), mode: FakeMode.data),
  'recovery': (build: () => const RecoveryScreen(), mode: FakeMode.data),
  'phone_safety': (build: () => const PhoneSafetyScreen(), mode: FakeMode.data),
  'security_hub': (build: () => const SecurityScreen(), mode: FakeMode.data),
  // ---- Family ----
  'family': (build: () => const FamilyScreen(), mode: FakeMode.data),
  'family_empty': (build: () => const FamilyScreen(), mode: FakeMode.empty),
  'family_error': (build: () => const FamilyScreen(), mode: FakeMode.fail),
  // ---- Onboarding / login / language ----
  'login': (build: () => const LoginScreen(), mode: FakeMode.data),
  'language_picker': (build: () => const LanguagePickerScreen(), mode: FakeMode.data),
  'onboarding': (build: () => OnboardingScreen(onDone: () {}), mode: FakeMode.data),
  // ---- Settings / Account ----
  'settings': (build: () => const SettingsScreen(), mode: FakeMode.data),
  'accessibility': (build: () => const AccessibilityModeScreen(), mode: FakeMode.data),
  'battery_guidance': (build: () => const BatteryGuidanceScreen(), mode: FakeMode.data),
  'about': (build: () => const AboutScreen(), mode: FakeMode.data),
  'delete_account': (build: () => const DeleteAccountScreen(), mode: FakeMode.data),
  // ---- gen-l10n arg-order call sites (verify on the shot) ----
  'disaster': (build: () => const DisasterAlertsScreen(), mode: FakeMode.data),
  'app_update': (build: () => const AppUpdateScreen(), mode: FakeMode.data),
  'referral': (build: () => const ReferralScreen(), mode: FakeMode.data),
  'credits': (build: () => const CreditsScreen(), mode: FakeMode.data),
  'rewarded_sheet': (build: () => const Scaffold(body: SafeArea(child: RewardedAdSheet())), mode: FakeMode.data),
};

// ---- batch 2: My Circle ----
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

/// Batch-2 specs are built per language (names in the right script).
final Map<String, ({Widget Function(bool bn) build, FakeMode mode})> circleSpecs = {
  'circle': (build: (_) => const CircleScreen(), mode: FakeMode.data),
  'circle_empty': (build: (_) => const CircleScreen(), mode: FakeMode.empty),
  'circle_error': (build: (_) => const CircleScreen(), mode: FakeMode.fail),
  'circle_chat': (build: (bn) => CircleChatScreen(member: _member(bn), identity: _identity), mode: FakeMode.data),
  // c2-calls: the real call screen starts WebRTC + the real-time transport,
  // so its gallery states live in c2_calls_shots.dart (frozen controllers).
  'circle_call_out': (build: (bn) => c2Shots['c2_call_calling']!(bn ? 'bn' : 'en'), mode: FakeMode.data),
  'circle_call_video_in': (build: (bn) => c2Shots['c2_call_video_connected']!(bn ? 'bn' : 'en'), mode: FakeMode.data),
  'incoming_call': (build: (bn) => IncomingCallScreen(payload: PushPayload({'kind': 'call', 'call_id': '7', 'chat_id': '3', 'caller_name': bn ? 'আয়েশা রহমান' : 'Ayesha Rahman', 'video': 'false', 'lang': bn ? 'bn' : 'en'})), mode: FakeMode.data),
  'circle_call_history': (build: (_) => const CircleCallHistoryScreen(), mode: FakeMode.data),
  'circle_privacy': (build: (_) => const CirclePrivacyScreen(), mode: FakeMode.data),
  'circle_search': (build: (bn) => CircleSearchScreen(members: [_member(bn)], identity: _identity), mode: FakeMode.data),
  'circle_groups': (build: (bn) => CircleGroupListScreen(identity: _identity, circleMembers: [_member(bn)]), mode: FakeMode.data),
  'circle_group_chat': (build: (bn) => CircleGroupChatScreen(group: _group(bn), identity: _identity, circleMembers: [_member(bn)]), mode: FakeMode.data),
  'circle_group_info': (build: (bn) => CircleGroupInfoScreen(group: _group(bn), identity: _identity, circleMembers: [_member(bn)]), mode: FakeMode.data),
  'circle_status': (build: (bn) => CircleStatusScreen(identity: _identity, members: [_member(bn)]), mode: FakeMode.data),
  'circle_status_new': (build: (bn) => CircleStatusComposerScreen(identity: _identity, members: [_member(bn)]), mode: FakeMode.data),
  'messenger': (build: (_) => const MessengerHomeScreen(), mode: FakeMode.data),
  'messenger_empty': (build: (_) => const MessengerHomeScreen(), mode: FakeMode.empty),
  'msgr_profile': (build: (_) => const MessengerProfileScreen(), mode: FakeMode.data),
  'msgr_contacts': (build: (_) => const ContactsScreen(), mode: FakeMode.data),
  'msgr_contact_info': (build: (bn) => ContactInfoScreen(member: _member(bn)), mode: FakeMode.data),
  'msgr_discover': (build: (_) => const DiscoverScreen(), mode: FakeMode.data),
  'msgr_requests': (build: (_) => const ConnectionRequestsScreen(), mode: FakeMode.data),
  'msgr_channels': (build: (_) => const ChannelListScreen(), mode: FakeMode.data),
  'msgr_communities': (build: (_) => CommunityListScreen(identity: _identity), mode: FakeMode.data),
  'msgr_starred': (build: (bn) => StarredMessagesScreen(identity: _identity, members: [_member(bn)]), mode: FakeMode.data),
  'msgr_broadcasts': (build: (bn) => BroadcastListsScreen(identity: _identity, members: [_member(bn)]), mode: FakeMode.data),
  'msgr_linked_devices': (build: (_) => const LinkedDevicesScreen(), mode: FakeMode.data),
  'msgr_settings': (build: (_) => const MessengerSettingsScreen(), mode: FakeMode.data),
  'msgr_set_account': (build: (_) => const MsgrSetAccountScreen(), mode: FakeMode.data),
  'msgr_set_privacy': (build: (_) => const MsgrSetPrivacyScreen(), mode: FakeMode.data),
  'msgr_set_chats': (build: (_) => const MsgrSetChatsScreen(), mode: FakeMode.data),
  'msgr_set_notifs': (build: (_) => const MsgrSetNotificationsScreen(), mode: FakeMode.data),
  'msgr_set_calls': (build: (_) => const MsgrSetCallsScreen(), mode: FakeMode.data),
  'msgr_set_storage': (build: (_) => const MsgrSetStorageScreen(), mode: FakeMode.data),
  'msgr_set_twostep': (build: (_) => const MsgrSetTwoStepScreen(), mode: FakeMode.data),
};

void main() {
  final report = <String>[];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _NoNet();
    await loadAppFonts(); // f1-design: Inter + Noto Sans Bengali
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons =
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) await _loadFont('MaterialIcons', icons);
    Directory(_outDir).createSync(recursive: true);
    // Plugins absent on the host: answer like an idle device would.
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (c) async => null);
    m.setMockMethodCallHandler(
        const MethodChannel('flutter_foreground_task/methods'),
        (c) async => false);
  });

  tearDownAll(() {
    File('$_outDir/_report.txt')
        .writeAsStringSync('${report.join('\n')}\n', mode: FileMode.append);
  });

  Future<void> shoot(WidgetTester tester, String name, String lang,
      Brightness b, Spec spec) async {
    final errors = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      final msg = d.exceptionAsString().split('\n').first;
      errors.add(msg.length > 160 ? msg.substring(0, 160) : msg);
    };
    // Real soft shadows (the test default draws elevation as a hard black
    // outline, which looks like a bug in the shots). Restored in finally.
    debugDisableShadows = false;
    try {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      final key = GlobalKey();
      final app = _stub(lang, spec.mode);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<Updater>(create: (_) => Updater()),
        ],
        child: A11yScope(
          prefs: A11yPrefs(),
          child: RepaintBoundary(
            key: key,
            child: MediaQuery(
              data: MediaQueryData(
                  size: const Size(360, 800),
                  textScaler: TextScaler.linear(_scale)),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: Locale(lang),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                theme: AssistoTheme.light,
                darkTheme: AssistoTheme.dark,
                themeMode:
                    b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
                home: Builder(builder: (_) => spec.build()),
              ),
            ),
          ),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 2.0))
          as ui.Image;
      final bytes = await tester
          .runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final tag = _scale == 1.0 ? '' : '_x$_scale';
      File('$_outDir/${name}_${lang}_${b.name}$tag.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    } catch (e) {
      errors.add('EXCEPTION: ${'$e'.split('\n').first}');
    } finally {
      FlutterError.onError = prev;
      debugDisableShadows = true;
    }
    final uniq = errors.toSet().toList();
    report.add('$name $lang ${b.name} x$_scale: '
        '${uniq.isEmpty ? 'OK' : uniq.join(' | ')}');
  }

  final onlyEnv = Platform.environment['ASSISTO_SHOT_ONLY'];
  final only = (onlyEnv == null || onlyEnv.isEmpty)
      ? null
      : onlyEnv.split(',').toSet();
  final batch2 = Platform.environment['ASSISTO_QA_BATCH'] == '2';
  final Map<String, Spec Function(String lang)> all = batch2
      ? circleSpecs.map((k, v) => MapEntry(
          k, (String lang) => (build: () => v.build(lang == 'bn'), mode: v.mode)))
      : specs.map((k, v) => MapEntry(k, (String _) => v));
  all.forEach((name, specFor) {
    if (only != null && !only.contains(name)) return;
    for (final lang in ['bn', 'en']) {
      for (final b in [Brightness.light, Brightness.dark]) {
        // the large-font pass only needs bn-light + en-dark
        if (_scale != 1.0 &&
            !((lang == 'bn' && b == Brightness.light) ||
                (lang == 'en' && b == Brightness.dark))) {
          continue;
        }
        testWidgets('qa $name $lang ${b.name} x$_scale', (tester) async {
          await shoot(tester, name, lang, b, specFor(lang));
          // swallow anything the framework still holds so the run continues
          tester.takeException();
        });
      }
    }
  });
}
