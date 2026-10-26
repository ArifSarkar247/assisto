// booking1: the booking bot on the app side (fake server): first-run guide →
// 3-step setup wizard saves services / hours / rules; today list → detail →
// confirm; day view; manual booking; customer books from a link (real free
// times only) and cancels; honest hidden / offline / error states; bn + en,
// dark mode and 200% text with NO overflow on every booking screen.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/booking/booking_biz_screen.dart';
import 'package:assisto/screens/booking/booking_detail_screen.dart';
import 'package:assisto/screens/booking/my_bookings_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'booking1_fakes.dart';
import 'booking1_shots.dart';
import 'fake_api.dart';
AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}
Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );
Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
late AppLocalizations en;
/// A real phone surface (360 dp wide); flows get a tall one so lazy lists
/// build every row.
void _phone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}
void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('first run: guide + welcome, then the 3-step wizard saves for real', (tester) async {
    _phone(tester, height: 2400);
    final src = FakeBooking('empty');
    await tester.pumpWidget(_app(BookingBizScreen(source: src)));
    await _settle(tester);
    expect(find.text(en.bkgGuideTitle), findsOneWidget);
    expect(find.text(en.bkgWelcomeTitle), findsOneWidget);
    await tester.tap(find.text(en.bkgStartSetup));
    await _settle(tester);
    // step 1: Next without a service is refused honestly
    await tester.tap(find.text(en.bkgNext));
    await _settle(tester);
    expect(find.text(en.bkgAddOneService), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, en.bkgServiceName), 'Haircut');
    await tester.enterText(find.widgetWithText(TextField, en.bkgPrice), '300');
    await tester.tap(find.widgetWithText(OutlinedButton, en.bkgAddService));
    await _settle(tester);
    expect(src.calls, contains('addService'));
    expect(find.text('Haircut'), findsOneWidget);
    await tester.tap(find.text(en.bkgNext));
    await _settle(tester);
    // step 2: hours (Friday closed by default) → saved
    expect(find.text(en.bkgStep2Title), findsOneWidget);
    await tester.tap(find.text(en.bkgNext));
    await _settle(tester);
    final hours = src.saved.last['weekly_hours'] as Map;
    expect(hours.containsKey('4'), isFalse);
    expect(hours['0'], [['10:00', '20:00']]);
    // step 3: rules + switch on
    expect(find.text(en.bkgStep3Title), findsOneWidget);
    await tester.ensureVisible(find.text(en.bkgFinish));
    await tester.tap(find.text(en.bkgFinish));
    await _settle(tester);
    expect(src.saved.last['enabled'], isTrue);
    expect(src.saved.last['slug'], 'rupa-salon');
  });

  testWidgets('today list → detail → confirm; call/chat buttons present', (tester) async {
    _phone(tester, height: 1600);
    final src = FakeBooking('data');
    await tester.pumpWidget(_app(BookingBizScreen(source: src, guide: false)));
    await _settle(tester);
    expect(find.text('Karim Ahmed'), findsOneWidget);
    expect(find.text('Nadia'), findsOneWidget);
    expect(find.text(en.bkgCountPending('1')), findsOneWidget);
    await tester.tap(find.text('Nadia'));
    await _settle(tester);
    expect(find.text(en.bkgCall), findsOneWidget);
    expect(find.text(en.bkgChat), findsOneWidget);
    await tester.tap(find.text(en.bkgConfirm));
    await _settle(tester);
    expect(src.calls, contains('act:2:confirmed'));
    expect(find.text(en.bkgConfirm), findsNothing);       // no longer offered
    await tester.tap(find.text(en.bkgCancelBooking));
    await _settle(tester);
    expect(find.text(en.bkgCancelQ), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, en.bkgCancelBooking));
    await _settle(tester);
    expect(src.calls, contains('act:2:cancelled'));
  });

  testWidgets('reschedule from detail uses server free times only', (tester) async {
    _phone(tester, height: 1600);
    final src = FakeBooking('data');
    await tester.pumpWidget(_app(BookingDetailScreen(
        source: src, bookingId: 1, initial: FakeBooking.row(1, 'confirmed'))));
    await _settle(tester);
    await tester.tap(find.text(en.bkgMove));
    await _settle(tester);
    expect(find.text(en.bkgMoveTitle), findsOneWidget);
    expect(find.byType(ChoiceChip), findsWidgets);
    await tester.tap(find.text('3:00 PM'));
    await tester.pump();
    await tester.tap(find.text(en.bkgMoveHere));
    await _settle(tester);
    expect(src.calls, contains('act:1:reschedule'));
  });

  testWidgets('day view and upcoming tabs', (tester) async {
    _phone(tester, height: 1600);
    final src = FakeBooking('data');
    await tester.pumpWidget(_app(BookingBizScreen(source: src, guide: false, initialTab: 2)));
    await _settle(tester);
    expect(src.calls, contains('bookings:day'));
    expect(find.text('Karim Ahmed'), findsOneWidget);
    await tester.tap(find.byTooltip(en.bkgNextDay));
    await _settle(tester);
    expect(find.text(en.bkgEmptyDay), findsOneWidget);
  });

  testWidgets('manual booking sheet needs a time, then saves', (tester) async {
    _phone(tester, height: 2000);
    final src = FakeBooking('data');
    await tester.pumpWidget(_app(BookingBizScreen(source: src, guide: false)));
    await _settle(tester);
    await tester.tap(find.text(en.bkgAddBooking));
    await _settle(tester);
    await tester.tap(find.text(en.bkgSaveBooking));
    await _settle(tester);
    expect(find.text(en.bkgPickTimeFirst), findsOneWidget);
    await tester.tap(find.text('11:00 AM'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, en.bkgCustomerName), 'Walk-in');
    await tester.tap(find.text(en.bkgSaveBooking));
    await _settle(tester);
    expect(src.calls, contains('addManual'));
    expect(src.saved.last['name'], 'Walk-in');
  });

  testWidgets('honest states: hidden, offline (retry), server error', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(BookingBizScreen(source: FakeBooking('off'), guide: false)));
    await _settle(tester);
    expect(find.text(en.bkgOffTitle), findsOneWidget);
    final off = FakeBooking('offline');
    await tester.pumpWidget(_app(BookingBizScreen(source: off, guide: false)));
    await _settle(tester);
    expect(find.text(en.bkgOfflineTitle), findsOneWidget);
    await tester.tap(find.text(en.bkgRetry));
    await _settle(tester);
    expect(off.calls.where((c) => c == 'page').length, 2);
    await tester.pumpWidget(_app(MyBookingsScreen(source: FakeBooking('fail'), guide: false)));
    await _settle(tester);
    expect(find.text(en.bkgErrorTitle), findsOneWidget);
  });

  testWidgets('customer: link → service → free time → booked', (tester) async {
    _phone(tester, height: 2000);
    final src = FakeBooking('mine');
    await tester.pumpWidget(_app(BookWithBusinessScreen(source: src)));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), '!!');
    await tester.tap(find.text(en.bkgOpenLink));
    await _settle(tester);
    expect(find.text(en.bkgLinkInvalid), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'lifeassisto.com/b/nobody-here');
    await tester.tap(find.text(en.bkgOpenLink));
    await _settle(tester);
    expect(find.text(en.bkgLinkNotFound), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'https://lifeassisto.com/b/rupa-salon?lang=en');
    await tester.tap(find.text(en.bkgOpenLink));
    await _settle(tester);
    expect(src.calls, contains('publicPage:rupa-salon'));
    await tester.tap(find.text('Facial'));
    await _settle(tester);
    final book = find.widgetWithText(FilledButton, en.bkgConfirmBooking);
    expect(tester.widget<FilledButton>(book).onPressed, isNull);    // no time yet
    await tester.tap(find.text('10:00 AM'));
    await tester.pump();
    await tester.ensureVisible(book);
    await tester.tap(book);
    await _settle(tester);
    expect(src.calls.any((c) => c.startsWith('book:2:')), isTrue);
    expect(find.text(en.bkgRequestedTitle), findsOneWidget);
  });

  testWidgets('customer: my bookings → cancel inside the window', (tester) async {
    _phone(tester, height: 1600);
    final src = FakeBooking('mine');
    await tester.pumpWidget(_app(MyBookingsScreen(source: src, guide: false)));
    await _settle(tester);
    expect(find.text(en.bkgUpcoming), findsOneWidget);
    expect(find.text(en.bkgPast), findsOneWidget);
    await tester.tap(find.text('Rupa Salon').first);
    await _settle(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, en.bkgCancelBooking));
    await _settle(tester);
    expect(src.calls, contains('myAct:1:cancelled'));
    expect(find.text(en.bkgCancelledMsg), findsOneWidget);
  });

  testWidgets('customer empty state shows the guide and the book button', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(MyBookingsScreen(source: FakeBooking('empty'))));
    await _settle(tester);
    expect(find.text(en.bkgMyGuideTitle), findsOneWidget);
    expect(find.text(en.bkgMyEmpty), findsOneWidget);
    expect(find.text(en.bkgBookNew), findsOneWidget);
  });

  // 200% font, bn + en, light + dark: no overflow / layout error anywhere.
  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('every booking screen at 200% text — $lang ${dark ? 'dark' : 'light'}', (tester) async {
        _phone(tester);
        for (final e in booking1Shots.entries) {
          await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
          await _settle(tester, 8);
          final err = tester.takeException();
          expect(err, isNull, reason: '${e.key} ($lang, 2.0x): $err');
        }
      });
    }
  }
}
