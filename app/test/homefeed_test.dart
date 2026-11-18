// homefeed (board row 38): Today facts are honest about WHEN they are from.
//  * the saved copy paints at once (cache first), dated "copy saved X ago",
//    then the server copy replaces it;
//  * offline: the copy stays with "You're offline — copy saved X ago", a pull
//    to refresh says so too (never a blank page, never a 0);
//  * a source outage: the last real numbers + "the source isn't responding —
//    last updated X ago"; too-old weather / other-day prayer times are not
//    shown as today's (they move to "Not connected yet" with the reason);
//  * old official gold price: "may have changed"; Bangla digits in bn.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/world/world_today_screen.dart';
import 'package:assisto/state.dart';

import 'world_fake.dart';

Widget _app(Widget child, {String lang = 'en'}) =>
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: child,
      ),
    );

String _ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();
String _bdDay([Duration back = Duration.zero]) {
  final d = DateTime.now().toUtc().add(const Duration(hours: 6)).subtract(back);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> _copy(
        {Duration savedAgo = const Duration(hours: 2),
        Duration weatherAgo = const Duration(minutes: 40),
        bool weatherStale = false,
        String? prayerDate,
        String goldDate = ''}) =>
    {
      'city': {'id': 'dhaka', 'name': 'Dhaka'},
      'generated_at': _ago(savedAgo),
      'cards': {
        'prayer': {
          'times': {'fajr': '04:52', 'dhuhr': '11:44', 'isha': '18:31'},
          'next': 'fajr',
          'date': prayerDate ?? _bdDay(),
          'note': 'Local calculation',
          'days': <Map<String, dynamic>>[],
        },
        'weather': {
          'temp': 27.6,
          'humidity': 70,
          'wind': 2.1,
          'label': 'Partly cloudy',
          'icon': 'cloud',
          'next': <Map<String, dynamic>>[],
          'updated': _ago(weatherAgo),
          'fetched_at': _ago(weatherAgo),
          'age_min': weatherAgo.inMinutes,
          'stale': weatherStale,
          'source': 'MET Norway (CC BY 4.0)',
          'source_url': 'https://api.met.no/',
        },
        if (goldDate.isNotEmpty)
          'gold': {
            'rows': [
              {'key': 'gold_22k', 'label': 'Gold 22K (per bhori)', 'bdt': 152000.0}
            ],
            'updated': goldDate,
            'source': 'Bangladesh Jewellers Association (BAJUS)',
            'source_url': 'https://www.bajus.org/gold-price',
            'entered_by_assisto': true,
            'stale': true,
          },
      },
      'hidden': <String, String>{},
      'hidden_since': <String, String>{},
    };

class _ServerApi extends FakeWorldApi {
  _ServerApi(this.body, {super.lang});
  Map<String, dynamic>? body; // null = offline
  Completer<void>? gate;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> today() async {
    calls++;
    if (gate != null) await gate!.future;
    if (body == null) throw StateError('offline');
    return body!;
  }

  @override
  Future<Map<String, dynamic>> config() async {
    if (body == null) throw StateError('offline');
    return super.config();
  }
}

Future<void> _cache(Map<String, dynamic> c, {String lang = 'en'}) async =>
    SharedPreferences.setMockInitialValues(
        {'world_cache_v1_today_$lang': jsonEncode(c)});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> tall(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('saved copy paints first (dated), then the server copy',
      (tester) async {
    await tall(tester);
    await _cache(_copy());
    final api = _ServerApi(_copy(savedAgo: Duration.zero))..gate = Completer();
    await tester.pumpWidget(_app(WorldTodayScreen(api: api)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // the server has NOT answered yet — the copy is already on screen
    expect(find.byKey(const ValueKey('uw_card_prayer')), findsOneWidget);
    expect(find.byKey(const ValueKey('uw_saved_copy')), findsOneWidget);
    expect(find.text('Copy saved 2 h ago — getting the latest…'), findsOneWidget);
    api.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uw_saved_copy')), findsNothing);
    expect(find.byKey(const ValueKey('uw_offline_copy')), findsNothing);
  });

  testWidgets('offline: copy stays with its age; pull to refresh says offline',
      (tester) async {
    await tall(tester);
    await _cache(_copy(savedAgo: const Duration(minutes: 25)));
    await tester.pumpWidget(_app(WorldTodayScreen(api: _ServerApi(null))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uw_offline_copy')), findsOneWidget);
    expect(find.text("You're offline — showing the copy saved 25 min ago."),
        findsOneWidget);
    expect(find.text('28°'), findsOneWidget); // the real last value, never blank
    // the pull itself is Flutter's gesture (proven on the emulator, flow 40);
    // here: what the screen does when that refresh fails offline
    final refresh = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    await tester.runAsync(() => refresh.onRefresh());
    await tester.pumpAndSettle();
    expect(find.text("You're offline — showing the copy saved 25 min ago."),
        findsNWidgets(2)); // banner + snackbar
  });

  testWidgets('no copy and offline: honest error with Retry (not blank)',
      (tester) async {
    await tester.pumpWidget(_app(WorldTodayScreen(api: _ServerApi(null))));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('source outage: last real number + "not responding, X ago"',
      (tester) async {
    await tall(tester);
    final api = _ServerApi(_copy(
        savedAgo: Duration.zero,
        weatherAgo: const Duration(hours: 5),
        weatherStale: true));
    await tester.pumpWidget(_app(WorldTodayScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uw_stale_weather')), findsOneWidget);
    expect(find.text("The source isn't responding — last updated 5 h ago."),
        findsOneWidget);
    expect(find.text('28°'), findsOneWidget);
    expect(find.text('0°'), findsNothing);
  });

  testWidgets('a saved copy keeps ageing: 30 h old weather is not "now"',
      (tester) async {
    await tall(tester);
    await _cache(_copy(
        savedAgo: const Duration(hours: 30),
        weatherAgo: const Duration(hours: 30)));
    await tester.pumpWidget(_app(WorldTodayScreen(api: _ServerApi(null))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uw_card_weather')), findsNothing);
    expect(
        find.text(
            'Weather — the source is not responding — last good data 30 h ago'),
        findsOneWidget);
  });

  testWidgets('a week-old copy never shows another day\'s prayer times',
      (tester) async {
    await tall(tester);
    await _cache(_copy(
        savedAgo: const Duration(days: 9),
        prayerDate: _bdDay(const Duration(days: 9))));
    await tester.pumpWidget(_app(WorldTodayScreen(api: _ServerApi(null))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uw_card_prayer')), findsNothing);
    expect(find.text('04:52'), findsNothing);
    expect(find.textContaining('the saved copy is too old'), findsOneWidget);
  });

  testWidgets('prayer times say their date', (tester) async {
    await tall(tester);
    await tester.pumpWidget(
        _app(WorldTodayScreen(api: _ServerApi(_copy(savedAgo: Duration.zero)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uw_prayer_date')), findsOneWidget);
    expect(find.textContaining('Times for '), findsOneWidget);
  });

  testWidgets('old official gold price: "may have changed"', (tester) async {
    await tall(tester);
    await tester.pumpWidget(_app(WorldTodayScreen(
        api: _ServerApi(_copy(
            savedAgo: Duration.zero, goldDate: _bdDay(const Duration(days: 20)))))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uw_stale_gold')), findsOneWidget);
    expect(find.textContaining('the price may have changed'), findsOneWidget);
    expect(find.text('৳152000'), findsOneWidget);
  });

  testWidgets('Bangla: ages and banner in Bangla digits', (tester) async {
    await tall(tester);
    await _cache(_copy(savedAgo: const Duration(hours: 5)), lang: 'bn');
    await tester.pumpWidget(
        _app(WorldTodayScreen(api: _ServerApi(null, lang: 'bn')), lang: 'bn'));
    await tester.pumpAndSettle();
    expect(find.text('আপনি অফলাইনে — ৫ ঘণ্টা আগে সেভ করা কপি দেখানো হচ্ছে।'),
        findsOneWidget);
    expect(find.text('২৮°'), findsOneWidget);
    expect(find.text('28°'), findsNothing);
  });
}
