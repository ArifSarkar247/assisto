// Reality-audit harness (m2-reality). Runs ON THE CI EMULATOR against a
// throw-away Django inside the runner (REALITY_API_BASE=http://10.0.2.2:8700,
// seeded by `manage.py seed_reality`). Never points at the live server: the
// API base override is a debug-only dart-define (see lib/config.dart).
//
// What every flow gets:
//   * step(name, body)  — named step; a failure records which step broke
//   * shot(name)        — PNG of the app at that moment (written to the app's
//                         external files dir; CI pulls it with adb)
//   * http log          — every request the app's ApiClient made during the
//                         flow, with its status code (RecordingClient below)
//   * backend()         — an independent ApiClient logged in as the seeded
//                         user, used to ASSERT the round trip (the data the
//                         UI wrote must come back from the server)
//   * results.json      — rewritten after every flow, so a hang/crash still
//                         leaves evidence for every flow that ran
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/main.dart' show AssistoApp;
import 'package:assisto/push/push_service.dart' show PushService, appNavigatorKey;
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/state.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/a11y_prefs.dart';

/// Seeded demo accounts (backend/core/management/commands/seed_reality.py).
/// Fake CI-only credentials; overridable with dart-defines.
class Seed {
  static const phoneA = String.fromEnvironment('REALITY_PHONE_A', defaultValue: '01700000001');
  static const phoneB = String.fromEnvironment('REALITY_PHONE_B', defaultValue: '01700000002');
  static const password = String.fromEnvironment('REALITY_PASSWORD', defaultValue: 'Reality#2026');
  static const nameB = 'Reality Karim';
}

/// One recorded HTTP exchange.
class HttpHit {
  final String method;
  final String path;
  final int status;
  final int ms;
  HttpHit(this.method, this.path, this.status, this.ms);
  Map<String, dynamic> toJson() => {'m': method, 'p': path, 's': status, 'ms': ms};
}

/// Wraps the real client; records method/path/status of every request.
class RecordingClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final List<HttpHit> hits = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final sw = Stopwatch()..start();
    try {
      final r = await _inner.send(request);
      hits.add(HttpHit(request.method, request.url.path.replaceFirst('/api/v1', ''),
          r.statusCode, sw.elapsedMilliseconds));
      return r;
    } catch (e) {
      hits.add(HttpHit(request.method, request.url.path.replaceFirst('/api/v1', ''),
          -1, sw.elapsedMilliseconds));
      rethrow;
    }
  }
}

class StepResult {
  final String name;
  bool ok = false;
  String detail = '';
  final List<String> shots = [];
  StepResult(this.name);
  Map<String, dynamic> toJson() => {'name': name, 'ok': ok, 'detail': detail, 'shots': shots};
}

class FlowResult {
  final String id;
  final String section;
  final String feature;
  String status = 'running'; // pass | fail | skip | partial
  String note = '';
  String? error;
  final List<StepResult> steps = [];
  final List<HttpHit> http = [];
  final List<String> needsKey = [];
  final Stopwatch sw = Stopwatch()..start();
  FlowResult(this.id, this.section, this.feature);
  Map<String, dynamic> toJson() => {
        'id': id,
        'section': section,
        'feature': feature,
        'status': status,
        'note': note,
        'error': error,
        'needs_key': needsKey,
        'seconds': sw.elapsedMilliseconds / 1000,
        'steps': [for (final s in steps) s.toJson()],
        'http': [for (final h in http) h.toJson()],
        'http_errors': [
          for (final h in http)
            if (h.status >= 400 || h.status < 0) h.toJson()
        ],
      };
}

class Harness {
  Harness._();
  static final Harness I = Harness._();

  late final IntegrationTestWidgetsFlutterBinding binding;
  final RecordingClient recorder = RecordingClient();
  final List<FlowResult> results = [];
  final AppLocalizations t = lookupAppLocalizations(const Locale('en'));
  Directory? _out;
  final GlobalKey shotKey = GlobalKey(debugLabel: 'reality-shot');

  void init() {
    binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  }

  Future<Directory> outDir() async {
    if (_out != null) return _out!;
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ?? await getApplicationSupportDirectory();
    } catch (_) {
      base = await getApplicationSupportDirectory();
    }
    _out = Directory('${base.path}/reality');
    await _out!.create(recursive: true);
    await Directory('${_out!.path}/shots').create(recursive: true);
    await Directory('${_out!.path}/acks').create(recursive: true);
    return _out!;
  }

  /// rf1: flow ids a previous attempt (same CI job) already gave a verdict,
  /// or that crashed the emulator twice. tools/reality/run_flows.sh pushes
  /// them to <out>/skip_ids.txt before re-running a group after a device
  /// death, so the retry resumes instead of dying at the same flow again.
  Future<Set<String>> skipIds() async {
    try {
      final f = File('${(await outDir()).path}/skip_ids.txt');
      if (!await f.exists()) return {};
      return (await f.readAsLines()).map((l) => l.trim()).where((l) => l.isNotEmpty).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> writeResults() async {
    final d = await outDir();
    final body = const JsonEncoder.withIndent(' ').convert({
      'api_base': AppConfig.apiBase,
      'written_at': DateTime.now().toIso8601String(),
      'flows': [for (final r in results) r.toJson()],
    });
    await File('${d.path}/results.json').writeAsString(body);
    // The newest flow also goes to stdout/logcat in <=700-char chunks
    // (`REALITY_RESULT <id> <i>/<n> <json part>`), so the verdict survives
    // even when the device dies before results.json can be pulled.
    if (results.isNotEmpty) {
      final last = results.last;
      final js = jsonEncode(last.toJson());
      final n = (js.length / 700).ceil();
      for (var i = 0; i < n; i++) {
        final stop = (i + 1) * 700 > js.length ? js.length : (i + 1) * 700;
        // ignore: avoid_print
        print('REALITY_RESULT ${last.id} ${i + 1}/$n ${js.substring(i * 700, stop)}');
      }
    }
    binding.reportData = {'flows': [for (final r in results) r.toJson()]};
  }

  // ------------------------------------------------------------- backend
  ApiClient? _backendA;
  ApiClient? _backendB;

  /// Independent API client logged in as seeded user A (or B) — the
  /// round-trip assertions read the server through this, not through the UI.
  Future<ApiClient> backend({bool userB = false}) async {
    if (!userB && _backendA != null) return _backendA!;
    if (userB && _backendB != null) return _backendB!;
    final c = ApiClient();
    final res = await c.login(identifier: userB ? Seed.phoneB : Seed.phoneA, password: Seed.password);
    c.token = res.token;
    c.lang = 'en';
    if (userB) {
      _backendB = c;
    } else {
      _backendA = c;
    }
    return c;
  }

  // ------------------------------------------------------------- app boot
  AppState? app;

  /// Boots the REAL app widget tree (same providers as lib/main.dart) with a
  /// FRESH AppState that re-reads storage — calling it again is how flows
  /// simulate "close and reopen the app".
  Future<AppState> boot(WidgetTester tester) async {
    final a = http.runWithClient(() => AppState(), () => recorder);
    unawaited(a.init());
    final a11y = A11yPrefs();
    unawaited(a11y.load());
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: a),
          ChangeNotifierProvider(create: (_) => Updater()),
        ],
        child: AssistoApp(a11y: a11y),
      ),
    ));
    app = a;
    // ty1: lib/main.dart's deferred init starts the app's real-time loop
    // (in-app incoming calls, typing / online, live ticks) a few seconds
    // after the first frame. The harness pumps AssistoApp directly, so
    // before ty1 that loop NEVER ran here: 18_circle_real_call could not ring
    // in-app (B's call ended "offline" after the 20 s ack window) and
    // 19_circle_ticks never saw "typing…". Firebase stays off (no FCM on
    // CI), exactly like startup safe mode. Re-boots re-bind the new AppState.
    unawaited(PushService.instance.start(a, realtimeOnly: true));
    await settle(tester, seconds: 4);
    return a;
  }
}

// =============================================================== the flow API
typedef FlowBody = Future<void> Function(RFlow f);

/// Registers one reality flow as an integration test.
///
/// flutter_test tears the widget tree down after every test, so each flow
/// starts by booting the app again ([boot] = true): exactly like a user
/// closing and reopening it (storage, token and prefs survive).
void realityFlow(String id, String section, String feature, FlowBody body,
    {Duration timeout = const Duration(minutes: 4), bool boot = true}) {
  testWidgets(id, (tester) async {
    final h = Harness.I;
    final skips = await tester.runAsync(() => h.skipIds()) ?? const <String>{};
    if (skips.contains(id)) {
      // no FlowResult: the earlier attempt's verdict for [id] stands
      // ignore: avoid_print
      print('REALITY_SKIPPED $id (verdict from an earlier attempt)');
      return;
    }
    // ignore: avoid_print
    print('REALITY_FLOW_START $id'); // run_flows.sh: which flow a device death hit
    final r = FlowResult(id, section, feature);
    h.results.add(r);
    final f = RFlow(h, tester, r);
    final before = h.recorder.hits.length;
    try {
      if (boot) await h.boot(tester);
      await body(f).timeout(timeout);
      // rt1: a Flutter framework error during the flow (e.g. run 39878171841:
      // "markNeedsBuild() called during build" on opening Money) used to be
      // reported only as flutter_test's "[E]" while the flow row said pass.
      final fwErr = tester.takeException();
      if (fwErr != null) {
        throw TestFailure('Flutter error during the flow: ${'$fwErr'.split('\n').first}');
      }
      if (r.status == 'running') r.status = 'pass';
    } catch (e, st) {
      r.status = r.status == 'skip' ? 'skip' : 'fail';
      r.error = '$e'.split('\n').take(12).join('\n');
      debugPrint('REALITY FAIL $id: $e\n$st');
      try {
        await f.shot('FAILED');
      } catch (_) {}
    } finally {
      r.http.addAll(h.recorder.hits.sublist(before));
      await h.writeResults();
    }
    // A failed flow is recorded in results.json (classified C) but does not
    // abort the remaining flows.
  }, timeout: Timeout(timeout + const Duration(minutes: 1)));
}

class SkipFlow implements Exception {
  final String why;
  SkipFlow(this.why);
  @override
  String toString() => 'SKIP: $why';
}

const _shotMode = String.fromEnvironment('REALITY_SHOT_MODE', defaultValue: 'host');

class RFlow {
  final Harness h;
  final WidgetTester tester;
  final FlowResult r;
  RFlow(this.h, this.tester, this.r);

  AppLocalizations get t => h.t;
  AppState get app => h.app!;
  int _shotN = 0;
  StepResult? _cur;

  Future<void> step(String name, Future<void> Function() body) async {
    final s = StepResult(name);
    r.steps.add(s);
    _cur = s;
    try {
      await body();
      s.ok = true;
    } catch (e) {
      s.detail = '$e'.split('\n').first;
      rethrow;
    } finally {
      _cur = null;
    }
  }

  void note(String n) => r.note = r.note.isEmpty ? n : '${r.note}; $n';
  void needsKey(String k) => r.needsKey.add(k);
  void skip(String why) {
    r.status = 'skip';
    r.note = why;
    throw SkipFlow(why);
  }

  /// Screenshot of the device at this moment. Never fails the flow.
  ///
  /// Default mode "host": the app prints `REALITY_SHOT <file>` and the CI
  /// host (tools/reality/run_flows.sh) grabs the REAL screen with
  /// `adb exec-out screencap`, then touches `<out>/acks/<file>` so the flow
  /// continues at once. 22 Oct root cause: the in-app path
  /// (RenderRepaintBoundary.toImage = GPU read-back under Impeller/GLES) took
  /// down the whole swiftshader emulator at the first shot of flow 01, on
  /// every run. `--dart-define=REALITY_SHOT_MODE=inapp` keeps the old path.
  Future<String?> shot(String name) async {
    try {
      await tester.pump(const Duration(milliseconds: 300));
      _shotN++;
      final file = '${r.id}_${_shotN.toString().padLeft(2, '0')}_${_safe(name)}.png';
      if (_shotMode == 'inapp') {
        final ro = h.shotKey.currentContext?.findRenderObject();
        if (ro is! RenderRepaintBoundary) return null;
        await tester.runAsync(() async {
          final ui.Image img = await ro.toImage(pixelRatio: 1.0);
          final bd = await img.toByteData(format: ui.ImageByteFormat.png);
          final d = await h.outDir();
          await File('${d.path}/shots/$file').writeAsBytes(bd!.buffer.asUint8List());
        });
      } else {
        final d = await h.outDir();
        final ack = File('${d.path}/acks/$file');
        // ignore: avoid_print
        print('REALITY_SHOT $file');
        final end = DateTime.now().add(const Duration(seconds: 6));
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 150));
          final done = await tester.runAsync(() => ack.exists());
          if (done == true) break;
        }
      }
      (_cur ?? (r.steps.isNotEmpty ? r.steps.last : null))?.shots.add(file);
      return file;
    } catch (e) {
      debugPrint('shot failed: $e');
      return null;
    }
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-');

  // ------------------------------------------------------------ waiting
  Future<void> pumpFor(Duration d) => settle(tester, seconds: d.inMilliseconds / 1000);

  /// Pump until [finder] finds something (or throw after [seconds]).
  Future<Finder> waitFor(Finder finder, {double seconds = 15, String? what}) async {
    final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return finder;
    }
    throw TestFailure('timed out after ${seconds}s waiting for ${what ?? finder.describeMatch(Plurality.one)}');
  }

  Future<bool> appears(Finder finder, {double seconds = 6}) async {
    try {
      await waitFor(finder, seconds: seconds);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Poll [probe] (usually a backend read) until it returns true.
  Future<void> eventually(String what, Future<bool> Function() probe,
      {double seconds = 20}) async {
    final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
    Object? last;
    while (DateTime.now().isBefore(end)) {
      try {
        if (await tester.runAsync(probe) == true) return;
      } catch (e) {
        last = e;
      }
      await tester.pump(const Duration(milliseconds: 700));
    }
    throw TestFailure('backend never confirmed: $what${last != null ? ' (last error: $last)' : ''}');
  }

  /// Run a real network call from the test body (outside fake time).
  Future<T> net<T>(Future<T> Function() fn) async => (await tester.runAsync(fn)) as T;

  // ------------------------------------------------------------ actions
  Future<void> tap(Finder f, {double settleSeconds = 1.5}) async {
    await waitFor(f);
    // Scroll only what is NOT already on screen. rt1: ensureVisible on the
    // Notes tab's FAB scrolled the TabBarView (a PageView) towards To-Do, so
    // the saved note was "missing" — the user never sees that jump.
    if (f.hitTestable().evaluate().isEmpty) {
      await tester.ensureVisible(f.first);
    }
    await tester.pump();
    await tester.tap(f.first, warnIfMissed: false);
    await pumpFor(Duration(milliseconds: (settleSeconds * 1000).round()));
  }

  Future<void> tapText(String text, {double settleSeconds = 1.5}) =>
      tap(find.text(text), settleSeconds: settleSeconds);

  /// Tap the topmost Save / Add / Done button (dialogs and sheets differ).
  Future<void> tapSave({double settleSeconds = 3}) async {
    for (final label in [t.save, t.add, t.aichatSave, t.done]) {
      final f = find.text(label).hitTestable();
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.last, warnIfMissed: false);
        await pumpFor(Duration(milliseconds: (settleSeconds * 1000).round()));
        return;
      }
    }
    throw TestFailure('no Save/Add button on screen');
  }

  Future<void> tapTooltip(String tip, {double settleSeconds = 1.5}) =>
      tap(find.byTooltip(tip), settleSeconds: settleSeconds);

  // rf1: no IconData finders. The f5 icon migration (Material -> Rounded,
  // 25 Oct) silently broke every byIcon(Icons.send / arrow_upward / ...)
  // finder (run 40205920547: 5 flows C on "waiting for widget with icon").
  // Find controls by tooltip / Key / label — what a screen reader sees.

  /// rf1: scroll the screen's main list until [f] is BUILT (a lazy ListView
  /// does not build a Save button at the bottom until the user scrolls —
  /// run 40216392274, CRM lead form). Drags like a finger, 300 px a time.
  Future<void> scrollTo(Finder f, {int maxDrags = 25}) async {
    for (var i = 0; i < maxDrags && f.evaluate().isEmpty; i++) {
      final sc = find.byType(Scrollable).hitTestable();
      if (sc.evaluate().isEmpty) break;
      await tester.drag(sc.first, const Offset(0, -300), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 350));
    }
  }

  /// The visible Send button (home chat, AI chat, My Circle chat all carry
  /// the tooltip "Send").
  Future<void> tapSend({double settleSeconds = 1.5}) =>
      tap(find.byTooltip(t.send).hitTestable(), settleSeconds: settleSeconds);

  /// Type into the TextField whose label/hint is [label] (or the [index]th
  /// TextField when label is null).
  Future<void> enter(String text, {String? label, int index = 0}) async {
    Finder f;
    if (label != null) {
      f = find.ancestor(of: find.text(label), matching: find.byType(TextField));
      if (f.evaluate().isEmpty) f = find.widgetWithText(TextField, label);
    } else {
      f = find.byType(TextField).at(index);
    }
    await waitFor(f, what: 'text field "${label ?? '#$index'}"');
    await tester.ensureVisible(f.first);
    await tester.tap(f.first, warnIfMissed: false);
    await tester.pump();
    await tester.enterText(f.first, text);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> back() async {
    final nav = find.byType(BackButton);
    if (nav.evaluate().isNotEmpty) {
      await tester.tap(nav.first, warnIfMissed: false);
    } else {
      await tester.pageBack();
    }
    await pumpFor(const Duration(milliseconds: 1200));
  }

  /// home_v2: the new home (flag `home_v2`, default ON) has no chat input;
  /// its menu button marks it. The old home is recognised by its input.
  static const _hv2Menu = ValueKey('hv2_menu');
  bool get isHomeV2 => find.byKey(_hv2Menu).evaluate().isNotEmpty;
  bool get _onHome =>
      isHomeV2 ||
      (find.text(t.inputHint).evaluate().isNotEmpty &&
          // the home_v2 chat screen has the input too, but is not home
          find.byKey(const ValueKey('hv2_chat_new')).evaluate().isEmpty);

  /// Open the side drawer from home (old home: the AppBar menu button;
  /// home_v2: the header menu button).
  Future<void> openDrawer({double settleSeconds = 2}) async {
    final old = find.byTooltip(MaterialLocalizations.of(
            tester.element(find.byType(Scaffold).first))
        .openAppDrawerTooltip);
    if (old.evaluate().isNotEmpty) {
      await tap(old, settleSeconds: settleSeconds);
    } else {
      await tap(find.byKey(_hv2Menu), settleSeconds: settleSeconds);
    }
  }

  /// The home chat: on the old home it IS the home; on home_v2 the Ask
  /// Assisto card opens it on its own screen (same thread, same input).
  Future<void> openHomeChat() async {
    if (isHomeV2) {
      final ask = find.byKey(const ValueKey('hv2_ask'));
      await tester.ensureVisible(ask);
      await tap(ask, settleSeconds: 3);
    }
    await waitFor(find.text(t.inputHint), seconds: 25, what: 'home chat input');
  }

  /// Go back until the home screen is visible.
  Future<void> backToHome() async {
    for (var i = 0; i < 6; i++) {
      if (_onHome && find.byType(Drawer).evaluate().isEmpty) return;
      try {
        final nav = Navigator.of(tester.element(find.byType(Scaffold).last));
        if (!nav.canPop()) return;
        nav.pop();
      } catch (_) {
        return;
      }
      await pumpFor(const Duration(milliseconds: 900));
    }
  }

  /// Open the side drawer (from home) and open the item labelled [label]
  /// through the drawer's own search box — the same thing a user does.
  Future<void> openFromDrawer(String label) async {
    await backToHome();
    await openDrawer();
    final search = find.descendant(of: find.byType(Drawer), matching: find.byType(TextField));
    await waitFor(search, what: 'drawer search');
    await tester.enterText(search.first, label);
    await pumpFor(const Duration(milliseconds: 900));
    // A drawer ROW (ListTile) with that text — never the search box itself,
    // whose EditableText also "finds" the typed label (rt1: the old finder
    // tapped the search field and reported the drawer path as working).
    final hit = find.descendant(
        of: find.descendant(of: find.byType(Drawer), matching: find.byType(ListTile)),
        matching: find.text(label));
    await waitFor(hit, what: 'drawer item "$label"');
    await tester.tap(hit.last, warnIfMissed: false);
    await pumpFor(const Duration(seconds: 3));
  }

  /// Open a feature by its ChatNav route (the same table the home chat and
  /// quick buttons use). Used where the drawer label is ambiguous.
  Future<void> openRoute(String route, {double settleSeconds = 3}) async {
    await backToHome();
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) throw TestFailure('no navigator');
    if (!ChatNav.push(ctx, route)) throw TestFailure('unknown route $route');
    await pumpFor(Duration(milliseconds: (settleSeconds * 1000).round()));
  }

  /// Open a feature the way a user does (drawer search → tap). If the drawer
  /// path fails the flow still continues through the ChatNav [route] and the
  /// result notes it — the drawer failure itself is evidence.
  Future<void> openFeature(String label, String route) async {
    try {
      await openFromDrawer(label);
    } catch (e) {
      note('drawer path failed for "$label" ($e); opened via route "$route"');
      await backToHome();
      // close a drawer left open
      final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      if (scaffold.isDrawerOpen) scaffold.closeDrawer();
      await pumpFor(const Duration(milliseconds: 600));
      await openRoute(route);
    }
  }

  /// Push an arbitrary screen (deep sub-screens a flow reaches via a sheet).
  Future<void> pushScreen(Widget screen, {double settleSeconds = 3}) async {
    final nav = appNavigatorKey.currentState;
    if (nav == null) throw TestFailure('no navigator');
    unawaited(nav.push(MaterialPageRoute(builder: (_) => screen)));
    await pumpFor(Duration(milliseconds: (settleSeconds * 1000).round()));
  }

  /// Wait until the home screen is showing (after boot).
  Future<void> home() async {
    await waitFor(
        find.byWidgetPredicate((w) =>
            w.key == _hv2Menu ||
            (w is Text && w.data == t.inputHint)),
        seconds: 25,
        what: 'home screen');
  }

  // ------------------------------------------------------------ asserts
  /// The flow must have made [method] [pathPrefix] with a 2xx status.
  void expectHttp(String method, String pathPrefix, {int since = 0}) {
    final hits = h.recorder.hits.skip(since).where((x) =>
        x.method == method && x.path.startsWith(pathPrefix));
    if (hits.isEmpty) {
      throw TestFailure('app never called $method $pathPrefix');
    }
    if (!hits.any((x) => x.status >= 200 && x.status < 300)) {
      throw TestFailure('$method $pathPrefix answered ${hits.map((x) => x.status).toList()}');
    }
  }

  int get httpMark => h.recorder.hits.length;

  void expectNoServerErrors({int since = 0}) {
    final bad = h.recorder.hits.skip(since).where((x) => x.status >= 500 || x.status == 404 || x.status == 405).toList();
    if (bad.isNotEmpty) {
      throw TestFailure('server errors: ${bad.map((x) => '${x.method} ${x.path} ${x.status}').join(', ')}');
    }
  }

  void expectVisible(Finder f, String what) {
    if (f.evaluate().isEmpty) throw TestFailure('not on screen: $what');
  }
}

/// Live-binding friendly settle: pumps real frames for [seconds] without
/// requiring the tree to go idle (spinners / pollers never "settle").
Future<void> settle(WidgetTester tester, {double seconds = 1}) async {
  final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
