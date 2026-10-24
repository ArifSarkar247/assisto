// play-nomed — Google Play rejected the app: a personal developer account
// may not publish medical features. In the Play flavour
// (kMedicalFeaturesAllowed == false) every dedicated medical entry point is
// hidden; the website APK (gate on) keeps all of them. Each check runs with
// the gate forced OFF (Play) and ON (website APK).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_gates.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/doctor_serial_screen.dart';
import 'package:assisto/screens/elderly_home_screen.dart';
import 'package:assisto/screens/family_screen.dart';
import 'package:assisto/screens/health_timeline_screen.dart';
import 'package:assisto/screens/health_tips_screen.dart';
import 'package:assisto/screens/medicine_db_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/emergency_card_view.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';
import 'package:assisto/widgets/onb_first_win.dart';
import 'package:assisto/widgets/onb_role.dart';
import 'package:assisto/widgets/sidebar_sections.dart';
import 'package:assisto/widgets/watch_item.dart';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final calls = <String>[];

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async {
    calls.add('list:$path');
    if (path == 'family') {
      return [
        {'id': 1, 'name': 'Rina', 'relation': 'Mother', 'phone': '01700000000'}
      ];
    }
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> medicinesToday() async {
    calls.add('medicinesToday');
    return [];
  }

  @override
  Future<Map<String, dynamic>> caregiverDashboard() async {
    calls.add('caregiver');
    return {};
  }

  @override
  Future<Map<String, dynamic>> getEmergency() async => {
        'contacts': [
          {'name': 'Rina', 'phone': '01700000000', 'relation': 'Mother'}
        ]
      };

  @override
  Future<Map<String, dynamic>> getJson(String path) async => {};
}

Future<(AppLocalizations, _Api)> _pump(WidgetTester tester, Widget screen,
    {bool settle = true}) async {
  final app = AppState();
  final api = _Api();
  app.api = api;
  app.user = AppUser(
      id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'en');
  app.loading = false;
  late AppLocalizations t;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (ctx) {
        t = AppLocalizations.of(ctx);
        return screen;
      }),
    ),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  return (t, api);
}

const _medicalScreens = [
  MedicineDbScreen,
  HealthTipsScreen,
  HealthTimelineScreen,
  DoctorSerialScreen,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugMedicalFeaturesOverride = null);

  test('website APK default: medical features allowed (no PLAY_STORE define)',
      () {
    expect(kMedicalFeaturesAllowed, isTrue);
  });

  for (final allowed in [false, true]) {
    final flavour = allowed ? 'website APK' : 'Play';
    final present = allowed ? isTrue : isFalse;

    group('$flavour (medical allowed: $allowed)', () {
      setUp(() => debugMedicalFeaturesOverride = allowed);

      testWidgets('sidebar medical modules', (tester) async {
        await tester.pumpWidget(const SizedBox());
        final ctx = tester.element(find.byType(SizedBox));
        final screens = [
          for (final s in SidebarSections.all)
            for (final i in s.items) i.builder(ctx).runtimeType
        ];
        for (final m in _medicalScreens) {
          expect(screens.contains(m), present, reason: '$m');
        }
        // Non-medical modules stay in both flavours.
        expect(screens, contains(FamilyScreen));
      });

      test('chat routes + English keyword aliases', () {
        for (final r in kMedicalRoutes.where((r) => r != 'health_timeline' &&
            r != 'doctor_serial')) {
          expect(ChatNav.routes.containsKey(r), present, reason: r);
        }
        expect(ChatNav.routes.containsKey('family'), isTrue);
        expect(ChatNav.routes.containsKey('emergency'), isTrue);
        expect(ChatNav.detectRoute('show medicine database'),
            allowed ? 'medicine_db' : isNull);
        expect(ChatNav.detectRoute("show mom's medicine"),
            allowed ? 'family' : isNull);
        expect(ChatNav.detectRoute('open health tips'),
            allowed ? 'health_tips' : isNull);
        // Plain reminders keep working in both flavours.
        expect(ChatNav.detectRoute('open reminders'), 'reminders');
        expect(ChatNav.detectRoute('open family'), 'family');
      });

      test('home quick-button picker + saved sets', () {
        final routes = HomeQuickButtons.catalog.map((s) => s.route).toSet();
        expect(routes.contains('medicine_db'), present);
        expect(routes.contains('health_tips'), present);
        final saved = HomeQuickButtons.sanitize(
            ['medicine_db', 'health_tips', 'money', 'notes']);
        expect(saved.length, HomeQuickButtons.count);
        expect(saved.contains('medicine_db'), present);
        expect(saved.contains('health_tips'), present);
        expect(saved, containsAll(['money', 'notes']));
      });

      test('watch feed medicine source', () {
        expect(watchSourcesAvailable().contains(WatchSource.medicine), present);
        expect(watchSourcesAvailable(), contains(WatchSource.reminders));
      });

      testWidgets('family screen medicine / prescription / caregiver tabs',
          (tester) async {
        final (t, api) = await _pump(tester, const FamilyScreen());
        final medTabs = [
          t.familyTabToday,
          t.familyTabMedicines,
          t.medTabCaregiver,
          t.medTabPrescriptions,
        ];
        for (final label in medTabs) {
          expect(find.text(label).evaluate().isNotEmpty, present,
              reason: label);
        }
        expect(find.text(t.moduleFamily), findsWidgets);
        expect(api.calls.contains('medicinesToday'), present);
        expect(api.calls.contains('list:prescriptions'), present);
        expect(api.calls.contains('caregiver'), present);
        expect(api.calls, contains('list:family'));
      });

      testWidgets('elderly home: medicine tile', (tester) async {
        final (t, api) = await _pump(tester, const ElderlyHomeScreen(),
            settle: false);
        expect(find.text(t.elderlyTileMeds).evaluate().isNotEmpty, present);
        // Play swaps in a plain Reminders tile (2x2 grid unchanged).
        expect(find.text(t.navReminders).evaluate().isNotEmpty, !allowed);
        expect(api.calls.contains('medicinesToday'), present);
        expect(find.text(t.elderlyTileSos), findsOneWidget);
      });

      testWidgets('emergency card: medical record fields', (tester) async {
        final (t, _) = await _pump(
            tester,
            const SingleChildScrollView(
              child: EmergencyCardView(
                name: 'Karim',
                bloodGroup: 'O+',
                allergies: 'Penicillin',
                conditions: 'Asthma',
                medicines: 'Salbutamol',
                doctor: 'Dr X',
                insurance: 'INS-1',
                organDonor: true,
                contacts: [
                  {'name': 'Rina', 'phone': '01700000000', 'relation': 'Mother'}
                ],
              ),
            ));
        for (final v in [
          'O+',
          'Penicillin',
          'Asthma',
          'Salbutamol',
          'Dr X',
          'INS-1',
          t.emergencyBloodGroup,
          t.emergencyOrganDonor,
        ]) {
          expect(find.text(v).evaluate().isNotEmpty, present, reason: v);
        }
        // Plain contact info stays in both flavours.
        expect(find.text('Karim'), findsOneWidget);
        expect(find.textContaining('01700000000'), findsOneWidget);
      });

      testWidgets('emergency card empty hint', (tester) async {
        final (t, _) = await _pump(tester, const EmergencyCardView());
        expect(find.text(t.emergencyCardEmptyHint).evaluate().isNotEmpty,
            present);
        expect(find.text(t.emergencyCardEmptyHintBasic).evaluate().isNotEmpty,
            !allowed);
      });

      testWidgets('onboarding first win: no medicine tile in Play',
          (tester) async {
        final (t, _) = await _pump(
            tester,
            Scaffold(
                body: OnbFirstWin(role: OnbRole.parent, onPick: (_) {})));
        expect(find.text(t.onbWinMedicineTitle).evaluate().isNotEmpty,
            present);
        expect(find.text(t.onbWinJourneyTitle), findsOneWidget);
      });
    });
  }
}
