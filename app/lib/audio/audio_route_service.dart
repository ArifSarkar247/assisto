import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// audioroute (owner 28 Oct, CRITICAL: "Call voice does not go to Bluetooth
/// earphones"). The ONE app-wide audio route service. Every place in the app
/// that plays or records sound goes through it (CI guard:
/// test/audio_route_guard_test.dart):
///
///  * calls (voice + video; group calls when they get media) — [beginCall] /
///    [select] / [setVideo] / [endCall];
///  * voice notes, the AI voice assistant, Car Mode, kids-watch voice
///    messages, video / media playback — [acquire] an [AudioUse] lease and
///    release it when done.
///
/// Policy (WhatsApp behaviour):
///  1. a connected headset (Bluetooth > wired / USB-C) is used automatically
///     for BOTH the speaker and the microphone — over the earpiece in a voice
///     call and over the loudspeaker in a video call;
///  2. connect / disconnect mid-call switches live; the peer connection is
///     never touched, the call never drops. A headset that CONNECTS mid-call
///     takes over (like the phone's own dialer) even after a manual pick; a
///     headset that DISCONNECTS falls back to earpiece (voice) / speaker
///     (video), or to the route the user picked if it is still there;
///  3. a manual pick (route button) sticks for the rest of the call;
///  4. without Android 12+ "Nearby devices" permission the call still works
///     on earpiece / speaker ([bluetoothDenied] tells the screen);
///  5. [restore] always returns the phone to normal audio (music never stuck
///     in call mode / on the earpiece) — on every call end, and on the next
///     launch if the app was killed mid-call ([recoverIfStale]).
///
/// SOS sirens are the documented exception: they play on STREAM_ALARM at full
/// volume on the loudspeaker by design (a siren must be heard in the room),
/// so [AudioUse.sos] never moves audio to a headset.
enum AudioRoute { earpiece, speaker, bluetooth, wired }

/// Who is using audio (for the registry + the CI guard + debugging).
enum AudioUse {
  call,
  voiceNoteRecord,
  voiceNotePlay,
  assistantListen,
  assistantSpeak,
  carMode,
  sos,
  kidsWatchRecord,
  kidsWatchPlay,
  media,
}

/// Uses that need the HEADSET MICROPHONE: a Bluetooth mic only works in
/// communication mode (SCO), so these open a short communication session
/// while a Bluetooth headset is connected. Playback-only uses never force a
/// route: Android sends media to the connected headset by itself.
const Set<AudioUse> micUses = {
  AudioUse.voiceNoteRecord,
  AudioUse.assistantListen,
  AudioUse.kidsWatchRecord,
};

/// One output the phone can use right now.
@immutable
class AudioOutput {
  const AudioOutput(this.route, {this.name = '', this.id});
  final AudioRoute route;

  /// Product name ("AirPods Pro", "realme Buds T100") — may be empty.
  final String name;
  final int? id;

  static AudioOutput? fromMap(Map<dynamic, dynamic> m) {
    final r = routeFromKind('${m['kind']}');
    if (r == null) return null;
    final id = m['id'];
    return AudioOutput(r,
        name: '${m['name'] ?? ''}'.trim(), id: id is int ? id : null);
  }

  @override
  bool operator ==(Object other) =>
      other is AudioOutput &&
      other.route == route &&
      other.name == name &&
      other.id == id;

  @override
  int get hashCode => Object.hash(route, name, id);

  @override
  String toString() => 'AudioOutput(${route.name}, $name)';
}

AudioRoute? routeFromKind(String k) => switch (k) {
      'earpiece' => AudioRoute.earpiece,
      'speaker' => AudioRoute.speaker,
      'bluetooth' => AudioRoute.bluetooth,
      'wired' => AudioRoute.wired,
      _ => null,
    };

String kindOfRoute(AudioRoute r) => r.name;

bool isHeadset(AudioRoute r) =>
    r == AudioRoute.bluetooth || r == AudioRoute.wired;

/// The native side (AudioRouteChannel.kt in the app; a fake in tests).
abstract class AudioRoutePlatform {
  /// MODE_IN_COMMUNICATION + audio focus. Returns false when the native side
  /// could not become the only routing owner (flutter_webrtc's own switch is
  /// still on) — [fallback] is then used for selection.
  Future<bool> beginCommunication();
  Future<List<AudioOutput>> outputs();
  Future<AudioRoute?> active();
  Future<bool> select(AudioOutput o);
  Future<void> restore();
  Future<bool> bluetoothPermitted();
  Future<bool> bluetoothPresent();

  /// Fires on any device / route change (connect, disconnect, SCO up).
  Stream<void> get changes;
}

/// The (rare) fallback when the native owner can't switch flutter_webrtc's
/// audio switch off: routes through the WebRTC plugin instead. Set by
/// webrtc_audio_fallback.dart (lives in lib/audio/, the only folder allowed
/// to call the plugin's routing helpers).
typedef AudioSelectFallback = Future<void> Function(AudioRoute r);

/// Asks for Android 12+ "Nearby devices" (with a Bangla/English reason
/// sheet first). Returns true when granted. Set by the UI layer
/// (audio_route_permission.dart); null = never ask (tests, background).
typedef BluetoothPermissionAsker = Future<bool> Function();

class AudioRouteLease {
  AudioRouteLease._(this._svc, this.use, this.id);
  final AudioRouteService _svc;
  final AudioUse use;
  final int id;
  bool _released = false;
  bool get released => _released;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _svc._release(this);
  }
}

class AudioRouteService extends ChangeNotifier {
  AudioRouteService(this._p, {this.stalePrefs = true});

  static AudioRouteService? _instance;
  static AudioRouteService get instance =>
      _instance ??= AudioRouteService(MethodChannelAudioRoutePlatform());

  @visibleForTesting
  static set instanceForTest(AudioRouteService? s) => _instance = s;

  final AudioRoutePlatform _p;

  /// Persist "a communication session is open" so a kill mid-call is
  /// repaired on the next launch ([recoverIfStale]). Off in unit tests.
  final bool stalePrefs;

  static const _staleKey = 'audio_route_session_open';

  /// Every widget / service file that plays or records sound declares its use
  /// here (checked by the CI guard together with a source scan).
  static const Map<String, AudioUse> registry = {
    'lib/calls/webrtc_media.dart': AudioUse.call,
    'lib/audio/webrtc_audio_fallback.dart': AudioUse.call,
    'lib/messaging/media/voice_recorder_sheet.dart': AudioUse.voiceNoteRecord,
    'lib/messaging/media/voice_player.dart': AudioUse.voiceNotePlay,
    'lib/messaging/media/video_player_impl.dart': AudioUse.media,
    'lib/screens/shop_live_rtc.dart': AudioUse.media,
    'lib/voice/va_native.dart': AudioUse.assistantSpeak,
    'lib/widgets/voice_input.dart': AudioUse.assistantListen,
    'lib/widgets/voice_command_sheet.dart': AudioUse.assistantListen,
    'lib/screens/money_voice_screen.dart': AudioUse.assistantListen,
    // SOS: the documented exception — the voice-SOS listener never moves
    // audio, and sirens play on STREAM_ALARM on the loudspeaker by design.
    'lib/widgets/voice_sos_service.dart': AudioUse.sos,
  };


  // ------------------------------------------------------------- state
  List<AudioOutput> outputs = const [];
  AudioRoute? active;
  bool inCall = false;
  bool video = false;

  /// The route the user picked with the route button this call (sticks).
  AudioRoute? userRoute;

  /// Android 12+ "Nearby devices" was refused: Bluetooth may not be usable;
  /// earpiece / speaker still work. The call screen says so honestly.
  bool bluetoothDenied = false;

  /// false = flutter_webrtc's switch is still on; selections use [fallback].
  bool nativeOwner = true;
  AudioSelectFallback? fallback;
  BluetoothPermissionAsker? askBluetooth;
  bool _askedBluetooth = false;

  final Map<int, AudioRouteLease> _leases = {};
  int _nextLease = 1;
  bool _commOpen = false;
  StreamSubscription<void>? _sub;
  final _routeCtl = StreamController<AudioRoute>.broadcast();
  Future<void> _chain = Future<void>.value();

  /// The route in use, every time it changes (call screens, tests).
  Stream<AudioRoute> get routeChanges => _routeCtl.stream;

  /// Uses currently holding a lease (debug + tests).
  List<AudioUse> get activeUses => [for (final l in _leases.values) l.use];

  final List<String> log = []; // event trace (debug + tests)

  bool has(AudioRoute r) => outputs.any((o) => o.route == r);
  AudioOutput? outputFor(AudioRoute r) {
    for (final o in outputs) {
      if (o.route == r) return o;
    }
    return null;
  }

  /// Bluetooth device name for the route button ("AirPods Pro").
  String? get bluetoothName {
    final n = outputFor(AudioRoute.bluetooth)?.name ?? '';
    return n.isEmpty ? null : n;
  }

  /// What the policy wants right now.
  AudioRoute preferred() {
    final u = userRoute;
    if (u != null && has(u)) return u;
    if (has(AudioRoute.bluetooth) && !bluetoothDenied) {
      return AudioRoute.bluetooth;
    }
    if (has(AudioRoute.wired)) return AudioRoute.wired;
    if (video || !has(AudioRoute.earpiece)) return AudioRoute.speaker;
    return AudioRoute.earpiece;
  }

  // ------------------------------------------------------------- calls
  /// A call's media is opening (BEFORE getUserMedia, so the microphone comes
  /// from the headset too). Never throws.
  Future<void> beginCall({required bool video}) => _serial(() async {
        inCall = true;
        this.video = video;
        userRoute = null;
        log.add('begin:${video ? 'video' : 'voice'}');
        await _openComm();
        await _refresh();
        await _maybeAskBluetooth();
        await _apply('begin');
      });

  /// Voice <-> video mid-call: a video call prefers the speaker over the
  /// earpiece (a headset still wins).
  Future<void> setVideo(bool on) => _serial(() async {
        if (video == on) return;
        video = on;
        log.add('video:$on');
        // the earpiece is useless while looking at the screen
        if (on && userRoute == AudioRoute.earpiece) userRoute = null;
        if (inCall) await _apply('video');
      });

  /// The user picked [r] on the route sheet / button. Sticks for the call.
  Future<void> select(AudioRoute r) => _serial(() async {
        log.add('pick:${r.name}');
        if (r == AudioRoute.bluetooth && bluetoothDenied) {
          // asked again only because the user tapped Bluetooth
          _askedBluetooth = false;
          bluetoothDenied = false;
          await _maybeAskBluetooth(force: true);
        }
        userRoute = r;
        if (inCall || _commOpen) {
          await _apply('pick');
        } else {
          notifyListeners();
        }
      });

  /// The call ended (any path: hang-up, remote end, failure, timeout,
  /// dispose). Restores normal audio unless a mic lease still needs it.
  Future<void> endCall() => _serial(() async {
        if (!inCall && !_commOpen) return;
        inCall = false;
        video = false;
        userRoute = null;
        log.add('end');
        if (!_leases.values.any((l) => micUses.contains(l.use))) {
          await _restoreNow();
        }
      });

  /// Always safe; idempotent. Back to MODE_NORMAL, nothing forced.
  Future<void> restore() => _serial(_restoreNow);

  // ------------------------------------------------------------- leases
  /// Every non-call audio place takes a lease while it plays / records.
  /// Recording with a Bluetooth headset connected opens a short
  /// communication session so the HEADSET microphone is used; playback never
  /// forces a route (Android sends media to the headset by itself) but a
  /// stale call mode is cleared first so it never plays on the earpiece.
  Future<AudioRouteLease> acquire(AudioUse use) async {
    final l = AudioRouteLease._(this, use, _nextLease++);
    _leases[l.id] = l;
    await _serial(() async {
      log.add('acquire:${use.name}');
      if (inCall || use == AudioUse.sos || use == AudioUse.call) return;
      if (micUses.contains(use)) {
        bool bt = false;
        try {
          bt = await _p.bluetoothPresent();
        } catch (e) {
          _err('present', e);
        }
        // no Bluetooth (or not allowed): the phone / wired mic works as is
        if (!bt || bluetoothDenied) return;
        await _openComm();
        await _refresh();
        await _apply('mic');
      } else if (_commOpen &&
          !_leases.values.any((x) => micUses.contains(x.use))) {
        // a leftover call/mic session: never play media on the earpiece
        await _restoreNow();
      }
    });
    return l;
  }

  /// Playback (voice notes, read-aloud, videos, kids-watch messages): no
  /// lease to keep — Android sends media to the connected headset by itself.
  /// Only clears a stale call / mic session so it never plays on the
  /// earpiece. Never touches Android when nothing is open (the common case).
  Future<void> preparePlayback(AudioUse use) => _serial(() async {
        log.add('play:${use.name}');
        if (inCall || !_commOpen) return;
        if (_leases.values.any((x) => micUses.contains(x.use))) return;
        await _restoreNow();
      });

  Future<void> _release(AudioRouteLease l) => _serial(() async {
        _leases.remove(l.id);
        log.add('release:${l.use.name}');
        if (inCall) return;
        if (_commOpen &&
            !_leases.values.any((x) => micUses.contains(x.use))) {
          await _restoreNow();
        }
      });

  // ------------------------------------------------------------- launch
  /// Called once, a few seconds after launch: if the app was killed while a
  /// communication session was open, put the phone back to normal audio.
  /// Touches the native channel ONLY when the flag is set (launch stays lazy).
  Future<void> recoverIfStale() async {
    if (!stalePrefs) return;
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getBool(_staleKey) != true) return;
      if (inCall || _commOpen) return;
      log.add('recover-stale');
      await _p.restore();
      await sp.remove(_staleKey);
    } catch (e) {
      _err('recover', e);
    }
  }

  // ------------------------------------------------------------- internals
  Future<void> _serial(Future<void> Function() fn) {
    final f = _chain.then((_) => fn()).catchError((Object e) {
      _err('serial', e);
    });
    _chain = f;
    return f;
  }

  Future<void> _openComm() async {
    _watch();
    if (_commOpen) return;
    _commOpen = true;
    await _markStale(true);
    try {
      nativeOwner = await _p.beginCommunication();
    } catch (e) {
      _err('begin', e);
    }
  }

  Future<void> _restoreNow() async {
    final wasOpen = _commOpen;
    _commOpen = false;
    userRoute = null;
    try {
      await _p.restore();
    } catch (e) {
      _err('restore', e);
    }
    if (wasOpen) log.add('restore');
    active = null;
    await _markStale(false);
    await _sub?.cancel();
    _sub = null;
    notifyListeners();
  }

  void _watch() {
    _sub ??= _p.changes.listen((_) {
      unawaited(_serial(_onChanged));
    }, onError: (Object e) => _err('changes', e));
  }

  Future<void> _onChanged() async {
    final before = {for (final o in outputs) o.route};
    await _refresh();
    if (!(inCall || _commOpen)) {
      notifyListeners();
      return;
    }
    final now = {for (final o in outputs) o.route};
    final arrived = now.difference(before).where(isHeadset).toList();
    if (arrived.isNotEmpty) {
      // a headset CONNECTED mid-call: it takes over (phone-dialer behaviour)
      log.add('connected:${arrived.map((r) => r.name).join(',')}');
      userRoute = null;
      if (arrived.contains(AudioRoute.bluetooth)) {
        await _maybeAskBluetooth();
      }
    }
    final gone = before.difference(now).where(isHeadset).toList();
    if (gone.isNotEmpty) log.add('disconnected:${gone.map((r) => r.name).join(',')}');
    await _apply('change');
  }

  Future<void> _refresh() async {
    try {
      final o = await _p.outputs();
      outputs = List.unmodifiable(o);
    } catch (e) {
      _err('outputs', e);
    }
  }

  Future<void> _apply(String why) async {
    final want = preferred();
    if (want != active) {
      final out = outputFor(want) ?? AudioOutput(want);
      var ok = false;
      try {
        if (nativeOwner) {
          ok = await _p.select(out);
        } else if (fallback != null) {
          await fallback!(want);
          ok = true;
        }
      } catch (e) {
        _err('select', e);
      }
      log.add('route:${want.name}${ok ? '' : '!'}:$why');
      active = want;
      _routeCtl.add(want);
    }
    notifyListeners();
  }

  Future<void> _maybeAskBluetooth({bool force = false}) async {
    if (!has(AudioRoute.bluetooth) && !force) return;
    bool ok = true;
    try {
      ok = await _p.bluetoothPermitted();
    } catch (e) {
      _err('btperm', e);
    }
    if (ok) {
      bluetoothDenied = false;
      return;
    }
    final ask = askBluetooth;
    if (ask == null || (_askedBluetooth && !force)) {
      // never asked here: try anyway (most phones route without it), but
      // remember so the sheet can explain if it fails
      return;
    }
    _askedBluetooth = true;
    try {
      ok = await ask();
    } catch (e) {
      _err('btask', e);
      ok = false;
    }
    bluetoothDenied = !ok;
    log.add(ok ? 'bt-permission:granted' : 'bt-permission:denied');
    if (ok) await _refresh();
  }

  Future<void> _markStale(bool open) async {
    if (!stalePrefs) return;
    try {
      final sp = await SharedPreferences.getInstance();
      if (open) {
        await sp.setBool(_staleKey, true);
      } else {
        await sp.remove(_staleKey);
      }
    } catch (e) {
      _err('stale', e);
    }
  }

  void _err(String where, Object e) {
    log.add('err:$where');
    if (kDebugMode) debugPrint('audio_route#$where $e');
  }

  @visibleForTesting
  void resetForTest() {
    outputs = const [];
    active = null;
    inCall = false;
    video = false;
    userRoute = null;
    bluetoothDenied = false;
    _askedBluetooth = false;
    _commOpen = false;
    _leases.clear();
    log.clear();
  }
}

/// AudioRouteChannel.kt over a MethodChannel + EventChannel. Lazy: nothing
/// is sent to Android until a call / recorder / player asks.
class MethodChannelAudioRoutePlatform implements AudioRoutePlatform {
  static const _m = MethodChannel('com.assisto/audio_route');
  static const _e = EventChannel('com.assisto/audio_route/events');

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    if (!_android) return null;
    try {
      return await _m.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> beginCommunication() async {
    final r = await _call<Map<dynamic, dynamic>>('beginCommunication');
    return r == null || r['owner'] != false;
  }

  @override
  Future<List<AudioOutput>> outputs() async {
    final r = await _call<List<dynamic>>('outputs');
    if (r == null) return const [];
    return r
        .whereType<Map<dynamic, dynamic>>()
        .map(AudioOutput.fromMap)
        .whereType<AudioOutput>()
        .toList();
  }

  @override
  Future<AudioRoute?> active() async {
    final k = await _call<String>('active');
    return k == null ? null : routeFromKind(k);
  }

  @override
  Future<bool> select(AudioOutput o) async =>
      await _call<bool>('select', {'kind': kindOfRoute(o.route), 'id': o.id}) ==
      true;

  @override
  Future<void> restore() async {
    await _call<bool>('restore');
  }

  @override
  Future<bool> bluetoothPermitted() async =>
      await _call<bool>('btPermitted') ?? true;

  @override
  Future<bool> bluetoothPresent() async =>
      await _call<bool>('btPresent') ?? false;

  Stream<void>? _changes;

  @override
  Stream<void> get changes {
    if (!_android) return const Stream<void>.empty();
    return _changes ??= _e
        .receiveBroadcastStream()
        .handleError((Object _) {})
        .map<void>((_) {});
  }
}

/// A microphone user's hold on the route service (speech recognisers, the
/// wake word, kids-watch recording): [start] / [stop] are fire-and-forget,
/// idempotent and race-safe, so wiring them never changes a screen's timing.
/// While held and a Bluetooth headset is connected, the HEADSET mic is used.
class MicRouteHold {
  MicRouteHold(this.use, {AudioRouteService? service}) : _svc = service;
  final AudioUse use;
  final AudioRouteService? _svc;
  AudioRouteLease? _lease;
  int _gen = 0;
  bool _want = false;

  bool get held => _want;

  void start() {
    if (_want) return;
    _want = true;
    final gen = ++_gen;
    unawaited(() async {
      try {
        final l = await (_svc ?? AudioRouteService.instance).acquire(use);
        if (!_want || gen != _gen) {
          await l.release();
        } else {
          _lease = l;
        }
      } catch (_) {}
    }());
  }

  void stop() {
    if (!_want) return;
    _want = false;
    _gen++;
    final l = _lease;
    _lease = null;
    if (l != null) unawaited(l.release().catchError((Object _) {}));
  }
}
