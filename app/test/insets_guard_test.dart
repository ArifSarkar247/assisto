// insets (owner real-phone test 28 Oct): "the main button of the vehicle Add
// tracker bottom sheet sits behind the phone navigation bar".
//
// GUARD: every reachable bottom sheet with a primary (filled) button is
// opened through its REAL code path under simulated system insets —
//   nav3   3-button navigation  (viewPadding.bottom 48 dp)
//   gest   gesture navigation   (viewPadding.bottom 24 dp)
//   small  320x568 + 3-button nav + text 2.0x
//   kb     keyboard open        (viewInsets.bottom 300 dp) + 3-button nav
// — every scrollable in the sheet is scrolled to its end, and the test FAILS
// when the last filled button is (a) still under the system bar / keyboard,
// (b) off screen, or (c) not the thing a tap at its centre reaches; and when
// ANY filled button can be hit from inside the system-bar / keyboard band
// (= drawn under the navigation bar). Layout exceptions (overflow) fail too.
//
// ASSISTO_SHOT_DIR=<dir> also writes nav3 PNGs (insets_<sheet>_<lang>.png).
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/checkout_sheet.dart';
import 'package:assisto/payments/credits_out_sheet.dart';
import 'package:assisto/plans_v2/plans_v2.dart';
import 'package:assisto/plans_v2/upgrade_sheet.dart';
import 'package:assisto/screens/crm/crm100_api.dart';
import 'package:assisto/screens/crm/crm_log_activity_sheet.dart';
import 'package:assisto/screens/crm/crm_send_sheet.dart';
import 'package:assisto/screens/vehicle_tracking_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/app_sheet.dart';
import 'package:assisto/widgets/paywall_sheet.dart';

import 'app_fonts.dart';
import 'fake_api.dart';
import 'pay1_fakes.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

typedef _Profile = ({String id, Size size, double nav, double kb, double text});

const List<_Profile> _profiles = [
  (id: 'nav3', size: Size(360, 800), nav: 48, kb: 0, text: 1),
  (id: 'gest', size: Size(360, 800), nav: 24, kb: 0, text: 1),
  (id: 'small', size: Size(320, 568), nav: 48, kb: 0, text: 2),
  (id: 'kb', size: Size(360, 800), nav: 48, kb: 300, text: 1),
];

/// How a sheet is opened: either a full screen whose own button opens it
/// ([screen] + [tap]) or a static `show(...)` called from a host button.
class _Sheet {
  final Widget Function()? screen;
  final Finder Function()? tap;
  final void Function(BuildContext)? open;
  const _Sheet({this.screen, this.tap, this.open});
}

final Map<String, _Sheet> _sheets = {
  // the bug the owner hit: Vehicle tracking -> Add tracker (FAB) -> sheet
  'veh_add_tracker': _Sheet(
      screen: () => const VehicleTrackingScreen(),
      tap: () => find.byIcon(Icons.add_link_rounded)),
  'checkout': _Sheet(
      open: (c) => CheckoutSheet.show(c, 'premium_monthly',
          backend: FakePaymentsBackend(), flavour: 'web')),
  'credits_buy': _Sheet(
      open: (c) => CreditsOut.offer(c,
          screen: 'chat', need: 5, backend: FakePaymentsBackend(), flavour: 'web')),
  'upgrade': _Sheet(
      open: (c) => UpgradeSheet.show(
          c, const UpgradeReason(feature: 'crm_write', neededPlan: 'premium'),
          backend: FakePaymentsBackend(), flavour: 'web')),
  'paywall': _Sheet(open: (c) => PaywallSheet.show(c, PaywallReason.outOfCredits)),
  'crm_send': _Sheet(
      open: (c) => CrmSendSheet.show(c,
          target: const CustomerTarget(phone: '01712345678'),
          name: 'Karim Mia',
          initialText: 'Hello')),
  'crm_log_activity':
      _Sheet(open: (c) => CrmLogActivitySheet.show(c, leadId: 1)),
  // the two layouts every other sheet uses, through the shared helper:
  // a long form that scrolls with its button at the end ...
  'helper_form_scroll': _Sheet(
      open: (c) => showAppSheet<void>(
          context: c,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < 8; i++)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TextField(
                                decoration: InputDecoration(labelText: 'Field $i'))),
                      FilledButton(onPressed: () {}, child: const Text('Save')),
                    ]),
              ))),
  // ... and a short, non-scroll-controlled sheet (menu / confirm)
  'helper_short': _Sheet(
      open: (c) => showAppSheet<void>(
          context: c,
          builder: (_) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Delete this?'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: () {}, child: const Text('Delete')),
                ]),
              ))),
  // ... and the sticky-button body
  'helper_sticky': _Sheet(
      open: (c) => showAppSheet<void>(
          context: c,
          isScrollControlled: true,
          builder: (_) => AppSheetBody(
                primary: FilledButton(onPressed: () {}, child: const Text('Pay')),
                child: Column(children: [
                  for (var i = 0; i < 30; i++) Text('Line $i'),
                ]),
              ))),
};

Future<void> _loadFonts() async {
  await loadAppFonts();
  final root = Platform.environment['FLUTTER_ROOT'] ??
      '${Platform.environment['HOME']}/assisto/tools/flutter';
  final icons =
      File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final l = FontLoader('MaterialIcons')
      ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
    await l.load();
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// The modal-sheet route's subtree (the last BottomSheet on screen).
Finder _sheetRoot() => find.byType(BottomSheet).last;

Future<void> _scrollSheetToEnd(WidgetTester tester) async {
  final scrollables = find.descendant(
      of: _sheetRoot(), matching: find.byType(Scrollable));
  for (final e in scrollables.evaluate().toList()) {
    final s = (e as StatefulElement).state as ScrollableState;
    final p = s.position;
    if (p.axis != Axis.vertical) continue;
    if (p.hasContentDimensions && p.maxScrollExtent > 0) {
      p.jumpTo(p.maxScrollExtent);
    }
  }
  await _settle(tester);
}

bool _hits(WidgetTester tester, Offset at, RenderObject target) {
  final r = HitTestResult();
  WidgetsBinding.instance.hitTestInView(r, at, tester.view.viewId);
  return r.path.any((e) => identical(e.target, target));
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
  });

  for (final s in _sheets.entries) {
    for (final p in _profiles) {
      for (final lang in const ['bn', 'en']) {
        // bn/en only matter for the screenshots and the large-text profile
        if (lang == 'en' && p.id != 'small' && p.id != 'nav3') continue;
        testWidgets('insets ${s.key} ${p.id} $lang', (tester) async {
          SharedPreferences.setMockInitialValues({});
          FakeApi.planSlug = 'premium';
          tester.view.physicalSize = p.size * 2;
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.reset);
          final shot = GlobalKey();
          final app = AppState()
            ..api = FakeApi(lang: lang)
            ..user = AppUser(
                id: 1, name: 'Me', phone: '01712345678', email: '',
                autonomyLevel: 2, language: lang)
            ..locale = Locale(lang)
            ..loading = false;
          final spec = s.value;
          await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: app,
            child: RepaintBoundary(
              key: shot,
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
                themeMode: ThemeMode.dark,
                // the phone: status bar 24, nav bar p.nav, keyboard p.kb
                builder: (ctx, child) {
                  final mq = MediaQuery.of(ctx);
                  return MediaQuery(
                    data: mq.copyWith(
                      textScaler: TextScaler.linear(p.text),
                      viewPadding: EdgeInsets.only(top: 24, bottom: p.nav),
                      padding: EdgeInsets.only(
                          top: 24, bottom: math.max(0, p.nav - p.kb)),
                      viewInsets: EdgeInsets.only(bottom: p.kb),
                    ),
                    child: Stack(children: [
                      child!,
                      // paint the system bars so the screenshots show them
                      Positioned(
                        left: 0, right: 0, bottom: 0,
                        height: math.max(p.nav, p.kb),
                        child: IgnorePointer(
                          child: ColoredBox(
                              color: p.kb > 0
                                  ? const Color(0xCC303030)
                                  : const Color(0x99000000)),
                        ),
                      ),
                    ]),
                  );
                },
                home: spec.screen != null
                    ? spec.screen!()
                    : Scaffold(
                        body: Builder(
                          builder: (ctx) => Center(
                            child: TextButton(
                              onPressed: () => spec.open!(ctx),
                              child: const Text('open-sheet'),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ));
          await _settle(tester);
          await tester.tap(spec.tap != null ? spec.tap!() : find.text('open-sheet'));
          await _settle(tester);
          expect(find.byType(BottomSheet), findsWidgets,
              reason: '${s.key}: the sheet did not open');
          await _scrollSheetToEnd(tester);
          if (_out != null && p.id == 'nav3') {
            final rb =
                shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2))
                as ui.Image;
            final bytes = await tester
                .runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
            Directory(_out!).createSync(recursive: true);
            File('$_out/insets_${s.key}_$lang.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            img.dispose();
          }
          try {
            expect(tester.takeException(), isNull,
                reason: '${s.key} ${p.id}: layout error (overflow?)');

            final screen = p.size;
            final band = math.max(p.nav, p.kb); // covered by bar / keyboard
            final safeBottom = screen.height - band;
            final buttons = find
                .descendant(of: _sheetRoot(), matching: find.byType(FilledButton))
                .hitTestable(at: Alignment.center);
            final all = find.descendant(
                of: _sheetRoot(), matching: find.byType(FilledButton));
            // (1) nothing tappable under the bar: a tap inside the band must
            //     never reach a filled button.
            for (final e in all.evaluate()) {
              final ro = e.renderObject! as RenderBox;
              if (!ro.attached || !ro.hasSize) continue;
              final rect = ro.localToGlobal(Offset.zero) & ro.size;
              if (rect.bottom <= safeBottom) continue;
              for (final fx in const [0.2, 0.5, 0.8]) {
                for (var y = math.max(rect.top, safeBottom) + 1;
                    y < math.min(rect.bottom, screen.height);
                    y += 6) {
                  final pt = Offset(rect.left + rect.width * fx, y);
                  expect(_hits(tester, pt, ro), isFalse,
                      reason: '${s.key} ${p.id}: a filled button is under the '
                          'system bar/keyboard at $pt (rect $rect, safe bottom '
                          '$safeBottom)');
                }
              }
            }
            // (2) after scrolling to the end, the last filled button is fully
            //     visible above the bar and a tap at its centre reaches it.
            if (all.evaluate().isNotEmpty) {
              expect(buttons, findsWidgets,
                  reason: '${s.key} ${p.id}: no filled button is tappable after '
                      'scrolling to the end');
              Rect rectOf(Element e) {
                final ro = e.renderObject! as RenderBox;
                return ro.localToGlobal(Offset.zero) & ro.size;
              }
              final r = buttons
                  .evaluate()
                  .map(rectOf)
                  .reduce((a, b) => a.bottom >= b.bottom ? a : b);
              expect(r.bottom, lessThanOrEqualTo(safeBottom + 0.5),
                  reason: '${s.key} ${p.id}: primary button $r is under the '
                      'system bar/keyboard (safe bottom $safeBottom)');
              expect(r.top >= 0 && r.left >= 0 && r.right <= screen.width + 0.5,
                  isTrue,
                  reason: '${s.key} ${p.id}: primary button $r is off screen');
            }
          } finally {
            // close the sheet (its future completes: one-at-a-time guards reset)
            Navigator.of(tester.element(_sheetRoot())).pop();
            await _settle(tester);
            await tester.pumpWidget(const SizedBox());
            await _settle(tester);
          }
        });
      }
    }
  }

  // full-screen form: the last button of a scrolling body must scroll clear
  // of the navigation bar (withNavBarInset).
  for (final p in _profiles.where((p) => p.kb == 0)) {
    testWidgets('insets full-screen form ${p.id}', (tester) async {
      tester.view.physicalSize = p.size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AssistoTheme.dark,
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(
                textScaler: TextScaler.linear(p.text),
                viewPadding: EdgeInsets.only(top: 24, bottom: p.nav),
                padding: EdgeInsets.only(top: 24, bottom: p.nav)),
            child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('Form')),
            body: ListView(
              padding: withNavBarInset(context, const EdgeInsets.all(16)),
              children: [
                for (var i = 0; i < 10; i++)
                  TextField(decoration: InputDecoration(labelText: 'Field $i')),
                FilledButton(onPressed: () {}, child: const Text('Save')),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      final pos = tester.state<ScrollableState>(find.byType(Scrollable)).position;
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pump();
      final r = tester.getRect(find.byType(FilledButton));
      expect(r.bottom, lessThanOrEqualTo(p.size.height - p.nav + 0.5),
          reason: 'full-screen form ${p.id}: Save $r is under the nav bar');
    });
  }
}
