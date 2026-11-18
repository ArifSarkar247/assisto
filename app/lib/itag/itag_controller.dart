// flag-itag (W7, server switch itag_tags): the iTag brain — pair, ring the
// tag, battery, unpair, "left behind" while "watch my bag" is on, and the
// tag's button ringing the phone (find my phone).
//
// Honest scope (Play rules, owner 9 Nov): NO background location and NO new
// foreground-service type. Links live only while Assisto runs; "watch my bag"
// is never restored after a restart and the tag screen shows a banner while
// it is on. The last-seen place is the phone's own location at the moment
// the link dropped, read ONLY if location is already allowed, and kept ONLY
// on this phone (ItagStore). Permissions are asked on the tag screen
// (lib/screens/itag/), never here.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../train/dest_alarm_sound.dart';
import 'itag_platform.dart';
import 'itag_store.dart';

enum ItagAlertKind { leftBehind, findPhone }

typedef ItagLocate = Future<ItagPlace?> Function();

/// The phone's location now — only when the user already allowed location.
Future<ItagPlace?> itagLocateIfAllowed() async {
  try {
    final p = await Geolocator.checkPermission();
    if (p != LocationPermission.whileInUse && p != LocationPermission.always) return null;
    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(timeLimit: Duration(seconds: 8)));
    } catch (_) {
      pos = await Geolocator.getLastKnownPosition();
    }
    if (pos == null) return null;
    return ItagPlace(pos.latitude, pos.longitude, DateTime.now().millisecondsSinceEpoch);
  } catch (_) {
    return null;
  }
}

class ItagController extends ChangeNotifier {
  ItagController({
    required this.platform,
    required this.sound,
    ItagStore? store,
    ItagLocate? locate,
    this.grace = const Duration(seconds: 10),
    this.retryEvery = const Duration(seconds: 15),
    this.phoneRingFor = const Duration(seconds: 30),
    this.tagRingFor = const Duration(seconds: 20),
    DateTime Function()? now,
  })  : store = store ?? ItagStore(),
        locate = locate ?? itagLocateIfAllowed,
        _now = now ?? DateTime.now;

  final ItagPlatform platform;
  final DestAlarmSound sound;
  final ItagStore store;
  final ItagLocate locate;
  final Duration grace;
  final Duration retryEvery;
  final Duration phoneRingFor;
  final Duration tagRingFor;
  final DateTime Function() _now;

  static ItagController? _instance;
  static ItagController get instance => _instance ??=
      ItagController(platform: MethodChannelItagPlatform(), sound: NativeDestAlarmSound());
  @visibleForTesting
  static set instanceForTest(ItagController? c) => _instance = c;

  /// Set by the tag screen layer: shows the full-screen alert + notification.
  void Function(ItagAlertKind kind, ItagTag tag)? onAlert;

  List<ItagTag> _tags = [];
  List<ItagTag> get tags => List.unmodifiable(_tags);
  final Set<String> connected = {};
  final Set<String> connecting = {};
  final Set<String> tagRinging = {};
  bool watching = false;
  bool buttonRingsPhone = true;
  String? leftBehind; // address of the tag that was left behind
  bool phoneRinging = false;
  bool _loaded = false;
  StreamSubscription<ItagEvent>? _sub;
  final Map<String, Timer> _graceTimers = {};
  final Map<String, Timer> _tagRingTimers = {};
  Timer? _retry;
  Timer? _phoneTimer;

  ItagTag? tag(String address) {
    for (final t in _tags) {
      if (t.address == address) return t;
    }
    return null;
  }

  bool isPaired(String address) => tag(address) != null;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    _tags = await store.load();
    buttonRingsPhone = await store.buttonRingsPhone();
    _sub ??= platform.events.listen(_onEvent);
    notifyListeners();
  }

  /// Reconnect every paired tag that is not linked now (screen open).
  Future<void> connectAll() async {
    for (final t in List.of(_tags)) {
      if (!connected.contains(t.address)) await _connect(t.address);
    }
  }

  Future<bool> _connect(String address) async {
    if (connecting.contains(address)) return false;
    connecting.add(address);
    notifyListeners();
    final ok = await platform.connect(address);
    connecting.remove(address);
    if (ok) {
      connected.add(address);
      await platform.linkLoss(address, watching ? kItagAlertHigh : kItagAlertOff);
      unawaited(refreshBattery(address));
    }
    notifyListeners();
    return ok;
  }

  /// Pair = connect + remember on this phone.
  Future<bool> pair(ItagFound f, String name) async {
    final ok = await _connect(f.address);
    if (!ok) return false;
    if (!isPaired(f.address)) {
      _tags = [
        ..._tags,
        ItagTag(f.address, name.trim().isEmpty ? f.name : name.trim(),
            _now().millisecondsSinceEpoch),
      ];
      await store.save(_tags);
    }
    notifyListeners();
    return true;
  }

  Future<void> rename(String address, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    _tags = [for (final t in _tags) t.address == address ? t.copyWith(name: n) : t];
    await store.save(_tags);
    notifyListeners();
  }

  /// "Ring my tag": Immediate Alert level 2; stops by itself after [tagRingFor].
  Future<bool> ringTag(String address) async {
    if (!connected.contains(address) && !await _connect(address)) return false;
    final ok = await platform.ring(address, kItagAlertHigh);
    if (!ok) return false;
    tagRinging.add(address);
    _tagRingTimers[address]?.cancel();
    _tagRingTimers[address] = Timer(tagRingFor, () => stopTag(address));
    notifyListeners();
    return true;
  }

  Future<void> stopTag(String address) async {
    _tagRingTimers.remove(address)?.cancel();
    tagRinging.remove(address);
    notifyListeners();
    if (connected.contains(address)) await platform.ring(address, kItagAlertOff);
  }

  Future<int?> refreshBattery(String address) async {
    final b = await platform.battery(address);
    if (b == null) return null;
    _tags = [
      for (final t in _tags)
        t.address == address
            ? t.copyWith(battery: b, batteryMs: _now().millisecondsSinceEpoch)
            : t,
    ];
    await store.save(_tags);
    notifyListeners();
    return b;
  }

  Future<void> unpair(String address) async {
    _cancelGrace(address);
    _tagRingTimers.remove(address)?.cancel();
    tagRinging.remove(address);
    if (leftBehind == address) await dismissLeftBehind();
    _tags = [for (final t in _tags) if (t.address != address) t];
    connected.remove(address);
    await store.save(_tags);
    notifyListeners();
    await platform.disconnect(address);
    if (_tags.isEmpty && watching) await setWatching(false);
  }

  /// "Watch my bag": only while Assisto is open (banner on the tag screen).
  Future<void> setWatching(bool on) async {
    watching = on;
    _retry?.cancel();
    _retry = null;
    if (on) {
      _retry = Timer.periodic(retryEvery, (_) => _retryLost());
    } else {
      for (final a in List.of(_graceTimers.keys)) {
        _cancelGrace(a);
      }
      if (leftBehind != null) await dismissLeftBehind();
    }
    notifyListeners();
    for (final a in List.of(connected)) {
      await platform.linkLoss(a, on ? kItagAlertHigh : kItagAlertOff);
    }
  }

  Future<void> _retryLost() async {
    for (final t in List.of(_tags)) {
      if (!connected.contains(t.address)) await _connect(t.address);
    }
  }

  Future<void> setButtonRingsPhone(bool on) async {
    buttonRingsPhone = on;
    notifyListeners();
    await store.setButtonRingsPhone(on);
  }

  Future<void> stopPhone() async {
    _phoneTimer?.cancel();
    _phoneTimer = null;
    if (!phoneRinging && leftBehind == null) return;
    phoneRinging = false;
    notifyListeners();
    if (leftBehind == null) await sound.stop();
  }

  Future<void> dismissLeftBehind() async {
    leftBehind = null;
    notifyListeners();
    if (!phoneRinging) await sound.stop();
  }

  void _cancelGrace(String a) => _graceTimers.remove(a)?.cancel();

  Future<void> _onEvent(ItagEvent e) async {
    final t = tag(e.address);
    switch (e.type) {
      case ItagEventType.connected:
        connected.add(e.address);
        _cancelGrace(e.address);
        if (leftBehind == e.address) await dismissLeftBehind(); // back in reach
        notifyListeners();
      case ItagEventType.disconnected:
        connected.remove(e.address);
        tagRinging.remove(e.address);
        _tagRingTimers.remove(e.address)?.cancel();
        notifyListeners();
        if (t == null || e.user) return;
        // the phone's place at the moment the link dropped (this phone only)
        final place = await locate();
        if (place != null) {
          _tags = [
            for (final x in _tags) x.address == e.address ? x.copyWith(lastSeen: place) : x,
          ];
          await store.save(_tags);
          notifyListeners();
        }
        if (!watching) return;
        _cancelGrace(e.address);
        _graceTimers[e.address] = Timer(grace, () => _graceOver(e.address));
        unawaited(_connect(e.address)); // a short drop reconnects silently
      case ItagEventType.button:
        if (t == null || !buttonRingsPhone) return;
        if (phoneRinging) {
          await stopPhone(); // a second press stops it
          return;
        }
        phoneRinging = true;
        notifyListeners();
        await sound.start(sound: true, vibrate: true);
        _phoneTimer?.cancel();
        _phoneTimer = Timer(phoneRingFor, stopPhone);
        onAlert?.call(ItagAlertKind.findPhone, t);
    }
  }

  Future<void> _graceOver(String address) async {
    _graceTimers.remove(address);
    final t = tag(address);
    if (!watching || t == null || connected.contains(address)) return;
    leftBehind = address;
    notifyListeners();
    await sound.start(sound: true, vibrate: true);
    onAlert?.call(ItagAlertKind.leftBehind, t);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _retry?.cancel();
    _phoneTimer?.cancel();
    for (final x in [..._graceTimers.values, ..._tagRingTimers.values]) {
      x.cancel();
    }
    super.dispose();
  }
}
