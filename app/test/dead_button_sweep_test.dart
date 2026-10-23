// db1 — DEAD-BUTTON SWEEP (owner order item 5).
//
// For every screen the screenshot gallery can pump (gallerySpecs() in
// screenshots_test.dart, same FakeApi + fakes), this harness:
//   1. pumps the screen fresh (pushed on top of a blank base route, so a
//      "close"/back button has somewhere to pop to),
//   2. finds every ENABLED tappable — InkWell/InkResponse/GestureDetector with
//      onTap, ListTile, every ButtonStyleButton (Elevated/Filled/Text/Outlined/
//      IconButton), FAB, PopupMenuButton, Switch/Checkbox/Radio (+ ListTile
//      variants), chips, DropdownButton,
//   3. for each one: pumps the screen fresh again, taps it, and records what
//      happened — route push/pop (page/dialog/sheet/menu), SnackBar, a FakeApi
//      or network call, a meaningful platform-channel call (url_launcher,
//      share, clipboard, permissions, picker, …), text-field focus, an error,
//      or a change of the widget tree vs. an untapped run with the exact same
//      fake-clock schedule.
// A tap with NO observable effect is DEAD. The test fails on any DEAD tap not
// on the reviewed [_allowDead] list. Reports: dead_button_sweep.{json,md} in
// $DB1_REPORT_DIR (or $ASSISTO_SHOT_DIR, or build/dead_button_sweep).
//
// Knobs: DB1_SWEEP_ONLY=name,name  DB1_SWEEP_MAX=<taps per screen, default 60>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/a11y_prefs.dart';

import 'package:assisto/screens/accessibility_mode_screen.dart' show AccessibilityModeScreen;
import 'package:assisto/screens/delete_account_screen.dart' show DeleteAccountScreen;
import 'package:assisto/screens/fall_detect_screen.dart' show FallDetectScreen;
import 'package:assisto/screens/lost_stolen_screen.dart' show LostStolenScreen;
import 'package:assisto/screens/messenger/channel_list_screen.dart' show ChannelListScreen;
import 'package:assisto/screens/messenger/connection_requests_screen.dart' show ConnectionRequestsScreen;
import 'package:assisto/screens/messenger/discover_screen.dart' show DiscoverScreen;
import 'package:assisto/screens/messenger/linked_devices_screen.dart' show LinkedDevicesScreen;
import 'package:assisto/screens/messenger/msgr_set_account_screen.dart' show MsgrSetAccountScreen;
import 'package:assisto/screens/messenger/msgr_set_calls_screen.dart' show MsgrSetCallsScreen;
import 'package:assisto/screens/messenger/msgr_set_change_number_screen.dart' show MsgrSetChangeNumberScreen;
import 'package:assisto/screens/messenger/msgr_set_chats_screen.dart' show MsgrSetChatsScreen;
import 'package:assisto/screens/messenger/msgr_set_privacy_screen.dart' show MsgrSetPrivacyScreen, MsgrSetBlockedListScreen, MsgrSetMessageRequestsScreen;
import 'package:assisto/screens/messenger/msgr_set_storage_screen.dart' show MsgrSetStorageScreen;
import 'package:assisto/screens/messenger/msgr_set_twostep_screen.dart' show MsgrSetTwoStepScreen;
import 'package:assisto/screens/my_lost_phone_screen.dart' show MyLostPhoneScreen;
import 'package:assisto/screens/phone_safety_screen.dart' show PhoneSafetyScreen;
import 'package:assisto/screens/recovery_screen.dart' show RecoveryScreen;
import 'package:assisto/screens/report_stolen_screen.dart' show ReportStolenScreen;
import 'package:assisto/screens/security_screen.dart' show SecurityScreen;
import 'package:assisto/screens/sell_my_phone_screen.dart' show SellMyPhoneScreen;
import 'package:assisto/screens/settings_screen.dart' show AuditScreen;
import 'package:assisto/screens/voice_sos_screen.dart' show VoiceSosScreen;
import 'fake_api.dart';
import 'screenshots_test.dart' as gallery;

/// Reviewed allow-list: "screen|label" (or "*|label") -> justification.
/// Keep it tiny. Every entry must say why the tap legitimately has no
/// observable effect in a widget test.
/// Key: "<screen>|<text in the button id>"; a screen ending in `*` is a prefix.
/// Two kinds only: (A) the GALLERY FIXTURE itself wires a no-op callback (the
/// real screen that wires it is swept separately), (B) the effect needs real
/// device machinery a widget test cannot run (raster capture, OS settings).
const Map<String, String> _allowDead = {
  // (A) gallery fixtures with `() {}` callbacks — not app code.
  't1_*|IconButton "icon:0x': 'A: t1_ticks_shots.dart header icons use onPressed: () {}',
  'mr1_last_seen_*|IconButton "icon:0x': 'A: mr1_shots.dart header call icons use onPressed: () {}; the real chat header wires calls',
  'md1_attach_sheet|key=attach-': 'A: md1_shots.dart renders CircleAttachGrid(onPick: (_) {}); the real sheet pops the kind and the chat runs the picker (md1_media_test / mr1_test cover it)',
  'md1_viewer|key=mv-': 'A: md1_shots.dart passes onSave/onShare: (_) {}; media_actions.dart wires MediaStore save + share sheet',
  'md1_recorder|key=md1-rec-': 'A: md1_shots.dart pins VoiceRecorderSheet as a static bottomSheet (no route to pop) with a fake recorder; md1_media_test proves Send returns the draft',
  'mr1_requests_list|TextButton "See all"':'A: mr1_shots.dart passes onSeeAll: () {}; MessengerHome wires it to _openRequests',
  'm3_new_chat|key=m3-new-': 'A: spec passes M3NewChatActions(onAdd: () {}, …); the real header in MessengerHome._openNewChat is wired',
  'b1_call_mini_bar|key=call-mini-bar': 'A: b1_calls_shots.dart has no app navigator (CallRuntime.start never ran); the bar re-opens the call through it in the app — b1_calls_test "Minimize hands the LIVE call…" proves the re-open',
  'cam_perm_*|Continue':'A: spec passes onPrimary: () {}; CameraPermissionGate wires the real request',
  'voice_results|Turn off': 'A: spec passes VaButton(…, () async {})',
  'voice_listening|GestureDetector': 'A: debugListening fixture — stop() while not really listening',
  'chat_voice|Tap to stop': 'A: debugListening fixture — stop() while not really listening',
  'onboarding|Skip': 'A: spec passes onDone: () {}; the app swaps the root on done',
  'home_hero_*|Install': 'A: fake native-ad template in h1_home_fakes.dart',
  'push_settings|Open': 'A: spec uses probe: false, which disables the OS-settings calls',
  'reminders|tip:Sync': 'A: gallery repos keep the pre-stub ApiClient (no token) so sync() returns early; on device it syncs with a spinner',
  // (B) needs real device machinery
  'c2_call_video_*|icon:0xef26': 'B: camera flip on the fake media stack; real flip is WebRTC (call-proof workflow)',
  'money_wrapped*|Share this card': 'B: RepaintBoundary.toImage needs a real rasterizer (never completes under fake async)',
  'referral|Share achievement card': 'B: same image-capture share as Money Wrapped',
};

/// Errors a widget test cannot avoid (no plugins, no network, no sqflite).
/// Any OTHER error thrown by a tap fails the sweep.
bool _harnessError(String e) =>
    e.contains('MissingPluginException') ||
    e.contains('network disabled in dead-button sweep') ||
    e.contains('databaseFactory not initialized');

/// Gallery variants that are the same screen as another spec (layout-only
/// variants), so sweeping them again adds time but no coverage.
bool _skipSpec(String name) =>
    name.endsWith('_bottom') || name.endsWith('_xl') || name.endsWith('_menu');


/// Screens the screenshot gallery does not pump but that are reachable in the
/// app (My Circle settings, account, anti-theft). Swept here too (en, data).
final Map<String, gallery.GallerySpec> _sweepOnlySpecs = {
  'x_msgr_set_account': (build: (_) => const MsgrSetAccountScreen(), mode: FakeMode.data, full: false),
  'x_msgr_set_chats': (build: (_) => const MsgrSetChatsScreen(), mode: FakeMode.data, full: false),
  'x_msgr_set_privacy': (build: (_) => const MsgrSetPrivacyScreen(), mode: FakeMode.data, full: false),
  'x_msgr_set_calls': (build: (_) => const MsgrSetCallsScreen(), mode: FakeMode.data, full: false),
  'x_msgr_set_storage': (build: (_) => const MsgrSetStorageScreen(), mode: FakeMode.data, full: false),
  'x_msgr_set_twostep': (build: (_) => const MsgrSetTwoStepScreen(), mode: FakeMode.data, full: false),
  'x_msgr_set_blocked': (build: (_) => const MsgrSetBlockedListScreen(), mode: FakeMode.data, full: false),
  'x_msgr_set_requests': (build: (_) => const MsgrSetMessageRequestsScreen(), mode: FakeMode.data, full: false),
  'x_msgr_set_change_number': (build: (_) => const MsgrSetChangeNumberScreen(), mode: FakeMode.data, full: false),
  'x_linked_devices': (build: (_) => const LinkedDevicesScreen(), mode: FakeMode.data, full: false),
  'x_connection_requests': (build: (_) => const ConnectionRequestsScreen(), mode: FakeMode.data, full: false),
  'x_channel_list': (build: (_) => const ChannelListScreen(), mode: FakeMode.data, full: false),
  'x_msgr_discover': (build: (_) => const DiscoverScreen(), mode: FakeMode.data, full: false),
  'x_security': (build: (_) => const SecurityScreen(), mode: FakeMode.data, full: false),
  'x_delete_account': (build: (_) => const DeleteAccountScreen(), mode: FakeMode.data, full: false),
  'x_accessibility_mode': (build: (_) => const AccessibilityModeScreen(), mode: FakeMode.data, full: false),
  'x_lost_stolen': (build: (_) => const LostStolenScreen(), mode: FakeMode.data, full: false),
  'x_my_lost_phone': (build: (_) => const MyLostPhoneScreen(), mode: FakeMode.data, full: false),
  'x_phone_safety': (build: (_) => const PhoneSafetyScreen(), mode: FakeMode.data, full: false),
  'x_recovery': (build: (_) => const RecoveryScreen(), mode: FakeMode.data, full: false),
  'x_sell_my_phone': (build: (_) => const SellMyPhoneScreen(), mode: FakeMode.data, full: false),
  'x_voice_sos': (build: (_) => const VoiceSosScreen(), mode: FakeMode.data, full: false),
  'x_fall_detect': (build: (_) => const FallDetectScreen(), mode: FakeMode.data, full: false),
  'x_report_stolen': (build: (_) => const ReportStolenScreen(), mode: FakeMode.data, full: false),
  'x_audit': (build: (_) => const AuditScreen(), mode: FakeMode.data, full: false),
};

// ---------------------------------------------------------------- recorders
int _netCalls = 0;
int _rebuilds = 0;

/// Class names declared in app/lib — a rebuild of one of these after a tap
/// means app state changed (framework-internal rebuilds such as a button's
/// pressed highlight are not counted).
final Set<String> _appTypes = () {
  final out = <String>{};
  final re = RegExp(r'^(?:abstract\s+|final\s+|base\s+)*class\s+([A-Za-z_]\w*)', multiLine: true);
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is File && f.path.endsWith('.dart')) {
      for (final m in re.allMatches(f.readAsStringSync())) {
        out.add(m.group(1)!);
      }
    }
  }
  return out;
}();
final List<String> _apiCalls = [];
final List<String> _platformCalls = [];

class _RecNet extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? c) => _RecDeadClient();
}

class _RecDeadClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation i) {
    final n = i.memberName.toString();
    if (n.contains('Url') || n.contains('open') || n.contains('get') ||
        n.contains('post') || n.contains('put') || n.contains('patch') ||
        n.contains('delete')) {
      _netCalls++;
    }
    throw const SocketException('network disabled in dead-button sweep');
  }
}

class _RecFakeApi extends FakeApi {
  _RecFakeApi({required super.mode, required super.lang});
  @override
  Future<Map<String, dynamic>> getJson(String path) {
    _apiCalls.add('GET $path');
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) {
    _apiCalls.add('POST $path');
    return super.postJson(path, body);
  }

  @override
  Future<Map<String, dynamic>> patchJson(String path,
      [Map<String, dynamic> body = const {}]) {
    _apiCalls.add('PATCH $path');
    return super.patchJson(path, body);
  }

  @override
  Future<Map<String, dynamic>> deleteJson(String path) {
    _apiCalls.add('DELETE $path');
    return super.deleteJson(path);
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) {
    _apiCalls.add('LIST $path');
    return super.listItems(path);
  }

  @override
  Future<Map<String, dynamic>> createItem(String path, Map<String, dynamic> body) {
    _apiCalls.add('CREATE $path');
    return super.createItem(path, body);
  }

  @override
  Future<void> updateItem(String path, int id, Map<String, dynamic> body) {
    _apiCalls.add('UPDATE $path');
    return super.updateItem(path, id, body);
  }

  @override
  Future<void> deleteItem(String path, int id) {
    _apiCalls.add('DELETEITEM $path');
    return super.deleteItem(path, id);
  }
}

class _NavRec extends NavigatorObserver {
  final List<String> events = [];
  String _kind(Route<dynamic>? r) {
    if (r == null) return 'route';
    if (r is DialogRoute || r is RawDialogRoute) return 'dialog';
    if (r is ModalBottomSheetRoute) return 'sheet';
    if (r is PopupRoute) return 'popup';
    return 'page';
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      events.add('push:${_kind(route)}');
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      events.add('pop:${_kind(route)}');
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      events.add('replace:${_kind(newRoute)}');
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      events.add('remove:${_kind(route)}');
}

// Platform channels that are pure UI plumbing (not a user-visible effect).
const _noiseChannels = {
  'flutter/mousecursor', 'flutter/accessibility', 'flutter/keyevent',
  'flutter/navigation', 'flutter/restoration', 'flutter/lifecycle',
  'flutter/system', 'flutter/settings', 'flutter/textinput', 'flutter/spellcheck',
  'flutter/keyboard', 'flutter/scribe', 'flutter/processtext',
};
const _noisePlatformMethods = {
  'HapticFeedback.vibrate', 'SystemSound.play', 'SystemChrome.setApplicationSwitcherDescription',
  'SystemChrome.setSystemUIOverlayStyle', 'SystemChrome.setEnabledSystemUIMode',
  'SystemChrome.setPreferredOrientations', 'SystemChrome.restoreSystemUIOverlays',
  'TextInput.hide', 'TextInput.clearClient',
  // a text field merely being built/focused probes these:
  'LiveText.isLiveTextInputAvailable', 'Clipboard.hasStrings',
};

Future<ByteData?>? _allMessages(
    String channel, MessageHandler? handler, ByteData? message) {
  if (!_noiseChannels.contains(channel)) {
    String method = '';
    try {
      method = const StandardMethodCodec().decodeMethodCall(message).method;
    } catch (_) {
      try {
        method = const JSONMethodCodec().decodeMethodCall(message).method;
      } catch (_) {}
    }
    final noisy = channel == 'flutter/platform' &&
        (_noisePlatformMethods.contains(method) || method.startsWith('SystemChrome.'));
    if (!noisy) _platformCalls.add(method.isEmpty ? channel : '$channel#$method');
  }
  if (handler != null) return handler(message);
  return null; // unhandled -> MissingPluginException, like a real missing plugin
}

// ------------------------------------------------------------- candidates
class _Cand {
  final int index;
  final String type;
  final String label;
  final Element element;
  final Function cb;
  _Cand(this.index, this.type, this.label, this.element, this.cb);
  String get id => '#$index $type "$label"';
}

/// Types whose internals are never separate user controls.
bool _atomic(Widget w) =>
    w is ButtonStyleButton || w is IconButton || w is FloatingActionButton ||
    w is PopupMenuButton || w is Switch || w is Checkbox || w is Radio ||
    w is SwitchListTile || w is CheckboxListTile || w is RadioListTile ||
    w is RawChip || w is ActionChip || w is FilterChip || w is ChoiceChip ||
    w is InputChip || w is DropdownButton || w is BackButton || w is CloseButton ||
    w is SegmentedButton || w is TextField || w is EditableText;

(String, Function)? _classify(Widget w) {
  if (w is ButtonStyleButton && w.onPressed != null) return ('${w.runtimeType}', w.onPressed!);
  if (w is IconButton && w.onPressed != null) return ('IconButton', w.onPressed!);
  if (w is FloatingActionButton && w.onPressed != null) return ('FAB', w.onPressed!);
  // Generic widgets are read dynamically: `w is X` checks X<dynamic>, and a
  // typed field read (e.g. ValueChanged<String?>) would fail the covariance check.
  if (w is PopupMenuButton && w.enabled) return ('PopupMenuButton', (w as dynamic).itemBuilder as Function);
  if (w is SwitchListTile && w.onChanged != null) return ('SwitchListTile', w.onChanged!);
  if (w is CheckboxListTile && w.onChanged != null) return ('CheckboxListTile', w.onChanged!);
  if (w is RadioListTile && (w as dynamic).onChanged != null) return ('RadioListTile', (w as dynamic).onChanged as Function);
  if (w is Switch && w.onChanged != null) return ('Switch', w.onChanged!);
  if (w is Checkbox && w.onChanged != null) return ('Checkbox', w.onChanged!);
  if (w is ActionChip && w.onPressed != null) return ('ActionChip', w.onPressed!);
  if (w is FilterChip && w.onSelected != null) return ('FilterChip', w.onSelected!);
  if (w is ChoiceChip && w.onSelected != null) return ('ChoiceChip', w.onSelected!);
  if (w is InputChip && (w.onPressed ?? w.onSelected) != null) {
    return ('InputChip', (w.onPressed ?? w.onSelected)!);
  }
  if (w is DropdownButton && (w as dynamic).onChanged != null) return ('DropdownButton', (w as dynamic).onChanged as Function);
  if (w is ListTile && w.onTap != null && w.enabled) return ('ListTile', w.onTap!);
  if (w is InkResponse && w.onTap != null) return ('InkWell', w.onTap!);
  if (w is GestureDetector && w.onTap != null) return ('GestureDetector', w.onTap!);
  return null;
}

String _labelOf(Element e) {
  final parts = <String>[];
  String? tip;
  void visit(Element c) {
    if (parts.length >= 3) return;
    final w = c.widget;
    if (w is Tooltip && tip == null) tip = w.message;
    if (w is Text) {
      final t = (w.data ?? w.textSpan?.toPlainText() ?? '').trim();
      if (t.isNotEmpty) parts.add(t);
    } else if (w is RichText) {
      final t = w.text.toPlainText().trim();
      if (t.isNotEmpty && parts.isEmpty) parts.add(t);
    } else if (w is Icon && w.icon != null) {
      parts.add(w.semanticLabel ?? 'icon:0x${w.icon!.codePoint.toRadixString(16)}');
    } else if (w is Semantics && (w.properties.label ?? '').isNotEmpty) {
      parts.add(w.properties.label!);
    }
    c.visitChildren(visit);
  }

  final w = e.widget;
  if (w is IconButton && w.tooltip != null) tip = w.tooltip;
  if (w is FloatingActionButton && w.tooltip != null) tip = w.tooltip;
  if (w is PopupMenuButton && w.tooltip != null) tip = w.tooltip;
  e.visitChildren(visit);
  e.visitAncestorElements((a) {
    if (a.widget is Tooltip) {
      tip ??= (a.widget as Tooltip).message;
      return false;
    }
    return a.widget is! Scaffold;
  });
  final key = w.key is ValueKey ? ' key=${(w.key as ValueKey).value}' : '';
  var s = [if (tip != null) 'tip:$tip', ...parts].join(' | ').replaceAll('\n', ' ');
  if (s.length > 70) s = '${s.substring(0, 70)}…';
  return '$s$key';
}

List<_Cand> _discover(WidgetTester tester) {
  final out = <_Cand>[];
  // sinceInk: element depth since the nearest InkWell/ListTile candidate.
  // An InkWell builds its own GestureDetector (a different closure) a few
  // levels down — that is the same control, not a second one.
  void walk(Element e, Set<Function> ancestorCbs, bool inAtomic, int sinceInk) {
    final w = e.widget;
    var cbs = ancestorCbs;
    var atomic = inAtomic;
    var ink = sinceInk < 0 ? -1 : sinceInk + 1;
    if (!inAtomic) {
      final c = _classify(w);
      final internalGd = c != null && c.$1 == 'GestureDetector' && ink >= 0 && ink <= 16;
      if (c != null && !internalGd && !ancestorCbs.contains(c.$2)) {
        out.add(_Cand(out.length, c.$1, _labelOf(e), e, c.$2));
        cbs = {...ancestorCbs, c.$2};
        ink = (c.$1 == 'InkWell' || c.$1 == 'ListTile') ? 0 : -1;
      }
      if (_atomic(w)) atomic = true;
    }
    if (w is Offstage && w.offstage) return;
    if (w is TickerMode && !w.enabled) return; // covered routes
    e.visitChildren((c) => walk(c, cbs, atomic, ink));
  }

  walk(tester.binding.rootElement!, <Function>{}, false, -1);
  return out;
}

/// True when the control is the currently selected option (selected tab,
/// selected ChoiceChip, a row announced as selected): re-tapping it is a
/// no-op by design, so it is reported as SKIP, not DEAD.
bool _alreadySelected(Element e) {
  final w = e.widget;
  if (w is ChoiceChip && w.selected) return true;
  if (w is RadioListTile) {
    final d = w as dynamic;
    Object? group;
    try {
      group = d.groupValue;
    } catch (_) {}
    if (group == null) {
      e.visitAncestorElements((a) {
        if (a.widget.runtimeType.toString().startsWith('RadioGroup<')) {
          group = (a.widget as dynamic).groupValue;
          return false;
        }
        return true;
      });
    }
    if (group != null && group == d.value) return true;
  }
  var hit = false;
  var n = 0;
  e.visitAncestorElements((a) {
    final aw = a.widget;
    if (aw is Semantics && aw.properties.selected == true) hit = true;
    return !hit && ++n < 10;
  });
  if (hit) return true;
  void down(Element c, int d) {
    if (hit || d > 30) return;
    final cw = c.widget;
    if (cw is Semantics && cw.properties.selected == true) {
      hit = true;
      return;
    }
    // Custom option rows (language / theme pickers) mark the current choice
    // with a filled radio / check-circle icon.
    if (d <= 26 && cw is Icon && (cw.icon == Icons.radio_button_checked || cw.icon == Icons.check_circle)) {
      hit = true;
      return;
    }
    c.visitChildren((x) => down(x, d + 1));
  }

  e.visitChildren((x) => down(x, 1));
  return hit;
}

/// A point inside [c] where a tap reaches [c] itself (not a nested control,
/// not something drawn over it). null = unreachable.
Offset? _tapPoint(WidgetTester tester, _Cand c, Set<RenderObject> candROs, Size screen) {
  final ro = c.element.renderObject;
  if (ro is! RenderBox || !ro.attached || !ro.hasSize || ro.size.isEmpty) return null;
  final topLeft = ro.localToGlobal(Offset.zero);
  final rect = topLeft & ro.size;
  final vis = rect.intersect(Offset.zero & screen);
  if (vis.width < 2 || vis.height < 2) return null;
  final pts = [
    vis.center,
    vis.topLeft + const Offset(3, 3), vis.bottomRight - const Offset(3, 3),
    vis.centerLeft + const Offset(3, 0), vis.centerRight - const Offset(3, 0),
    vis.topCenter + const Offset(0, 3), vis.bottomCenter - const Offset(0, 3),
  ];
  for (final p in pts) {
    final res = HitTestResult();
    tester.binding.hitTestInView(res, p, tester.view.viewId);
    RenderObject? deepest;
    for (final entry in res.path) {
      final t = entry.target;
      if (t is RenderObject && candROs.contains(t)) {
        deepest = t;
        break;
      }
    }
    if (deepest == ro) return p;
    if (_debug && p == pts.first) {
      debugPrint('[db1] ${c.id} rect=$rect hit=${res.path.take(12).map((e) => e.target.runtimeType).join(">")} deepestCand=${deepest?.runtimeType} mine=${ro.runtimeType}');
    }
  }
  return null;
}

final _debug = Platform.environment['DB1_DEBUG'] == '1';

String _sig(WidgetTester tester) {
  final b = StringBuffer();
  void visit(Element e) {
    final w = e.widget;
    b.write(w.runtimeType);
    if (w is Text) b.write('"${w.data ?? w.textSpan?.toPlainText()}"${w.style?.color?.toARGB32()}');
    if (w is RichText) b.write('"${w.text.toPlainText()}"');
    if (w is Icon) b.write('${w.icon?.codePoint}${w.color?.toARGB32()}');
    if (w is EditableText) b.write('[${w.controller.text}|${w.focusNode.hasFocus}]');
    if (w is Checkbox) b.write('${w.value}');
    if (w is Switch) b.write('${w.value}');
    if (w is RawChip) b.write('${w.selected}');
    if (w is DecoratedBox) b.write('${w.decoration.hashCode}');
    if (w is ColoredBox) b.write('${w.color.toARGB32()}');
    if (w is Material) b.write('${w.color?.toARGB32()}');
    if (w is Offstage) b.write('${w.offstage}');
    if (w is Opacity) b.write('${w.opacity}');
    if (w is Visibility) b.write('${w.visible}');
    if (w is ButtonStyleButton) b.write(w.onPressed == null ? '-' : '+');
    if (w is IconButton) b.write(w.onPressed == null ? '-' : '+');
    if (w is InkResponse) b.write(w.onTap == null ? '-' : '+');
    if (w is Image) {
      final img = w.image;
      if (img is MemoryImage) {
        final by = img.bytes;
        var h = by.length;
        for (var i = 0; i < by.length; i += 97) {
          h = (h * 31 + by[i]) & 0x3fffffff;
        }
        b.write('mem$h');
      } else {
        b.write('${img.runtimeType}');
      }
    }
    b.write('(');
    e.visitChildren(visit);
    b.write(')');
  }

  visit(tester.binding.rootElement!);
  return b.toString();
}

class _Run {
  final _NavRec nav;
  _Run(this.nav);
}

const _screen = Size(360, 2400);
final _tapPhase = <Duration>[
  Duration.zero, const Duration(milliseconds: 50), const Duration(milliseconds: 100),
  const Duration(milliseconds: 150), const Duration(milliseconds: 200),
  const Duration(milliseconds: 300), const Duration(milliseconds: 400),
];

Future<_Run> _pumpScreen(WidgetTester tester, String name, gallery.GallerySpec spec) async {
  // Fresh persisted state every pump: a tap in one run (e.g. "Allow
  // contacts" saving consent) must not change the next run's screen.
  SharedPreferences.setMockInitialValues({});
  gallery.galleryPrime(name);
  final app = gallery.galleryStub(lang: 'en', mode: spec.mode);
  app.api = _RecFakeApi(mode: spec.mode, lang: 'en');
  final screen = spec.build('en');
  final nav = _NavRec();
  await tester.binding.setSurfaceSize(_screen);
  // A fresh tree each time: drop the old one first so state never leaks.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<Updater>(create: (_) => Updater()),
    ],
    child: A11yScope(
      prefs: A11yPrefs(),
      child: MediaQuery(
      data: const MediaQueryData(size: _screen),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        navigatorObservers: [nav],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: SizedBox.expand())),
        onGenerateInitialRoutes: (_) => [
          MaterialPageRoute<void>(builder: (_) => const Scaffold(body: SizedBox.expand())),
          MaterialPageRoute<void>(builder: (_) => Builder(builder: (_) => screen)),
        ],
      ),
    ),
    ),
  ));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  nav.events.clear();
  return _Run(nav);
}

Future<void> _phase(WidgetTester tester, List<String> errors) async {
  for (final d in _tapPhase) {
    await tester.pump(d);
    final ex = tester.takeException();
    if (ex != null) errors.add(_short(ex));
  }
}

String _short(Object e) {
  var s = e.toString().split('\n').first;
  if (s.length > 140) s = '${s.substring(0, 140)}…';
  return s;
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // The app-wide realtime channel (started by chat/call screens a tap opened)
  // outlives the widget tree by design; stop it like the c3 tests do.
  RealtimeChannel.instance.resetForTest();
  CallRuntime.instance.resetForTest(); // owns the shared poll transport
  // Long one-shot timers (call ring/connect timeouts, debounces) must fire
  // before the test ends; periodic ones are cancelled by dispose.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 1));
    tester.takeException();
  }
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(minutes: 1));
    tester.takeException();
  }
}

// ----------------------------------------------------------------- results
class _Result {
  final String screen;
  final String button;
  final String effect; // comma list or DEAD / SKIP:<why>
  _Result(this.screen, this.button, this.effect);
  bool get dead => effect == 'DEAD';
  Map<String, String> toJson() => {'screen': screen, 'button': button, 'effect': effect};
}

final List<_Result> _results = [];
final Map<String, String> _screenNotes = {};

String _reportDir() {
  final env = Platform.environment;
  final d = env['DB1_REPORT_DIR'] ?? env['ASSISTO_SHOT_DIR'] ?? 'build/dead_button_sweep';
  Directory(d).createSync(recursive: true);
  return d;
}

void _writeReport() {
  if (_results.isEmpty && _screenNotes.isEmpty) return;
  final dir = _reportDir();
  final byScreen = <String, List<_Result>>{};
  for (final r in _results) {
    byScreen.putIfAbsent(r.screen, () => []).add(r);
  }
  File('$dir/dead_button_sweep.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
    'screens': {
      for (final s in {...byScreen.keys, ..._screenNotes.keys})
        s: {
          if (_screenNotes[s] != null) 'note': _screenNotes[s],
          'taps': [for (final r in byScreen[s] ?? <_Result>[]) r.toJson()],
        }
    },
  }));
  final dead = _results.where((r) => r.dead).length;
  final tested = _results.where((r) => !r.effect.startsWith('SKIP')).length;
  final md = StringBuffer()
    ..writeln('# Dead-button sweep report')
    ..writeln()
    ..writeln('Screens: ${byScreen.length + _screenNotes.keys.where((k) => !byScreen.containsKey(k)).length} · '
        'taps tested: $tested · DEAD: $dead · skipped: ${_results.length - tested}')
    ..writeln();
  for (final s in {...byScreen.keys, ..._screenNotes.keys}) {
    md.writeln('## $s');
    if (_screenNotes[s] != null) md.writeln('_${_screenNotes[s]}_');
    md.writeln();
    final rows = byScreen[s] ?? const <_Result>[];
    if (rows.isNotEmpty) {
      md.writeln('| button | effect |');
      md.writeln('|---|---|');
      for (final r in rows) {
        md.writeln('| ${r.button.replaceAll('|', '/')} | ${r.dead ? '**DEAD**' : r.effect.replaceAll('|', '/')} |');
      }
      md.writeln();
    }
  }
  File('$dir/dead_button_sweep.md').writeAsStringSync(md.toString());
}


Set<RenderObject> _ros(List<_Cand> cs) =>
    {for (final c in cs) if (c.element.renderObject != null) c.element.renderObject!};

/// Fresh pump, re-find candidate [idx] (must have the same id), optionally
/// scroll it into view; returns the run + a tap point, or null.
Future<(_Run, Offset)?> _prepare(WidgetTester tester, String name,
    gallery.GallerySpec spec, int idx, String id, bool scroll) async {
  final run = await _pumpScreen(tester, name, spec);
  tester.takeException();
  var now = _discover(tester);
  var c = idx < now.length ? now[idx] : null;
  if (c == null || c.id != id) return null;
  if (scroll) {
    try {
      await Scrollable.ensureVisible(c.element, alignment: 0.5);
    } catch (_) {
      return null;
    }
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    tester.takeException();
    now = _discover(tester);
    c = idx < now.length ? now[idx] : null;
    if (c == null || c.id != id) return null;
    run.nav.events.clear();
  }
  final p = _tapPoint(tester, c, _ros(now), _screen);
  return p == null ? null : (run, p);
}

// --------------------------------------------------------------------- main
void main() {
  final specs = {...gallery.gallerySpecs(), ..._sweepOnlySpecs};
  final onlyEnv = Platform.environment['DB1_SWEEP_ONLY'];
  final only = (onlyEnv == null || onlyEnv.isEmpty) ? null : onlyEnv.split(',').toSet();
  final maxTaps = int.tryParse(Platform.environment['DB1_SWEEP_MAX'] ?? '') ?? 60;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _RecNet();
    // Real fonts (same as the gallery) so layout matches the screenshots.
    Future<void> font(String family, String path) async {
      if (!File(path).existsSync()) return;
      final l = FontLoader(family);
      l.addFont(File(path).readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }

    await font('NotoSansBengali', 'assets/fonts/NotoSansBengali.ttf');
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    await font('MaterialIcons', '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  });
  tearDownAll(_writeReport);

  specs.forEach((name, spec) {
    if (_skipSpec(name)) return;
    if (only != null && !only.contains(name)) return;
    testWidgets('dead-button sweep: $name', (tester) async {
      debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
        if (_appTypes.contains(e.widget.runtimeType.toString())) _rebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.allMessagesHandler = _allMessages;
      addTearDown(() => messenger.allMessagesHandler = null);
      debugDisableShadows = true;

      // Discovery + untapped baseline, both under the same fake-clock schedule.
      await _pumpScreen(tester, name, spec);
      final initErr = tester.takeException();
      // The gallery pumps every one of these cleanly, so an error here is a
      // harness gap — fail loudly instead of reporting "0 dead".
      expect(initErr, isNull, reason: 'sweep could not pump "$name": $initErr');
      final cands = _discover(tester);
      final ros = _ros(cands);
      final plan = <(int, String, bool)>[]; // (index, id, needsScroll)
      for (final c in cands) {
        if (_alreadySelected(c.element)) {
          _results.add(_Result(name, c.id, 'SKIP:already the selected option'));
          continue;
        }
        final p = _tapPoint(tester, c, ros, _screen);
        if (p == null) {
          final inScroll = Scrollable.maybeOf(c.element) != null;
          if (inScroll) {
            plan.add((c.index, c.id, true));
          } else {
            _results.add(_Result(name, c.id, 'SKIP:not hittable (covered/zero-size)'));
          }
          continue;
        }
        final vis = (c.element.renderObject as RenderBox).size;
        if ((c.type == 'GestureDetector' || c.type == 'InkWell') &&
            vis.width * vis.height > _screen.width * _screen.height * 0.6) {
          _results.add(_Result(name, c.id, 'SKIP:full-screen background detector'));
          continue;
        }
        plan.add((c.index, c.id, false));
      }
      _rebuilds = 0;
      await _phase(tester, <String>[]);
      final idleSig = _sig(tester);
      final idleRebuilds = _rebuilds;
      // Second untapped run: if it differs, the screen is not deterministic
      // (clock text, real-time animation) and a pure tree-diff is not proof.
      await _pumpScreen(tester, name, spec);
      tester.takeException();
      await _phase(tester, <String>[]);
      final deterministic = _sig(tester) == idleSig;
      if (!deterministic) {
        _screenNotes[name] = 'screen changes by itself: taps with only a UI change are marked UNSURE';
      }
      if (plan.length > maxTaps) {
        _screenNotes[name] = '${_screenNotes[name] ?? ''} only first $maxTaps of ${plan.length} taps swept'.trim();
      }

      final deadHere = <String>[];
      final brokenHere = <String>[];
      for (final (idx, id, scroll) in plan.take(maxTaps)) {
        var base = idleSig;
        var baseRebuilds = idleRebuilds;
        if (scroll) {
          // Baseline for a scrolled state: same pump + scroll, no tap.
          final ok = await _prepare(tester, name, spec, idx, id, true);
          if (ok == null) {
            _results.add(_Result(name, id, 'SKIP:could not scroll it into view'));
            continue;
          }
          _rebuilds = 0;
          await _phase(tester, <String>[]);
          base = _sig(tester);
          baseRebuilds = _rebuilds;
        }
        final prep = await _prepare(tester, name, spec, idx, id, scroll);
        if (prep == null) {
          _results.add(_Result(name, id, scroll ? 'SKIP:could not scroll it into view' : 'SKIP:tree not stable between pumps'));
          continue;
        }
        final (run, p) = prep;
        _apiCalls.clear();
        _platformCalls.clear();
        _netCalls = 0;
        final focusBefore = FocusManager.instance.primaryFocus;
        final errs = <String>[];
        _rebuilds = 0;
        await runZonedGuarded(() async {
          try {
            await tester.tapAt(p);
          } catch (e) {
            errs.add(_short(e));
          }
          await _phase(tester, errs);
        }, (e, st) => errs.add('async: ${_short(e)}'));
        final effects = <String>[];
        if (run.nav.events.isNotEmpty) effects.add(run.nav.events.toSet().join('+'));
        if (find.byType(SnackBar).evaluate().isNotEmpty) effects.add('snackbar');
        if (_apiCalls.isNotEmpty) effects.add('api:${_apiCalls.toSet().take(3).join(' ')}');
        if (_netCalls > 0) effects.add('net');
        if (_platformCalls.isNotEmpty) effects.add('platform:${_platformCalls.toSet().take(3).join(' ')}');
        final f = FocusManager.instance.primaryFocus;
        if (f != focusBefore && f?.context?.widget is EditableText) effects.add('focus');
        final changed = _sig(tester) != base;
        if (changed) effects.add(deterministic ? 'ui-change' : 'ui-change?');
        // An app widget rebuilt more than in the untapped run: the handler
        // changed state (e.g. a refresh whose spinner came and went between
        // frames because the fake API answers instantly).
        if (!changed && _rebuilds > baseRebuilds) effects.add('state-change');
        if (errs.isNotEmpty) effects.add('ERROR:${errs.toSet().take(2).join(' ; ')}');
        final onlyWeak = effects.length == 1 && effects.first == 'ui-change?';
        final verdict = effects.isEmpty
            ? (deterministic ? 'DEAD' : 'UNSURE:no effect seen on a self-changing screen')
            : (onlyWeak ? 'UNSURE:only a UI change on a self-changing screen' : effects.join(', '));
        var r = _Result(name, scroll ? '$id (scrolled)' : id, verdict);
        if (r.dead) {
          final allowed = _allowDead.keys.any((k) {
            final parts = k.split('|');
            final scr = parts[0];
            final scrOk = scr == '*' || scr == name ||
                (scr.endsWith('*') && name.startsWith(scr.substring(0, scr.length - 1)));
            return scrOk && id.contains(parts.sublist(1).join('|'));
          });
          if (!allowed) {
            deadHere.add(id);
          } else {
            r = _Result(r.screen, r.button, 'ALLOWED-DEAD (reviewed: fixture/device-only)');
          }
        }
        _results.add(r);
        final hard = errs.where((e) => !_harnessError(e)).toList();
        if (hard.isNotEmpty) brokenHere.add('$id: ${hard.first}');
      }
      await _drain(tester);
      expect(deadHere, isEmpty,
          reason: 'DEAD taps on "$name" (no route/dialog/snackbar/api/platform/focus/UI change). '
              'Fix, hide (NO SHOWPIECES) or justify in _allowDead.');
      expect(brokenHere, isEmpty,
          reason: 'Taps on "$name" threw (not a missing-plugin/no-network test artifact).');
    }, timeout: const Timeout(Duration(minutes: 6)));
  });
}
