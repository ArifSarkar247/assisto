// flag-itag (W7, server switch itag_tags): the Bluetooth iTag key finder.
// The native side is ItagChannel.kt ("com.assisto/itag"); tests use a fake.
import 'dart:async';

import 'package:flutter/services.dart';

/// What the phone's Bluetooth can do right now.
enum ItagRadio { ready, off, noPermission, locationOff, unsupported }

class ItagRadioState {
  final ItagRadio radio;
  final int sdk; // Android API level (0 = unknown)
  const ItagRadioState(this.radio, this.sdk);

  /// Android 12+ asks "Nearby devices" (scan + connect); 8–11 need location
  /// for a Bluetooth scan.
  bool get nearbyDevicesPermission => sdk >= 31;
}

/// One device seen by a scan.
class ItagFound {
  final String address;
  final String name;
  final int rssi;
  final bool likely; // named "iTag" or advertises the iTag services
  const ItagFound(this.address, this.name, this.rssi, this.likely);
}

enum ItagEventType { connected, disconnected, button }

class ItagEvent {
  final ItagEventType type;
  final String address;
  final bool user; // a disconnect the user asked for
  const ItagEvent(this.type, this.address, {this.user = false});
}

/// Alert levels of the Immediate Alert / Link Loss services.
const int kItagAlertOff = 0;
const int kItagAlertHigh = 2;

abstract class ItagPlatform {
  Future<ItagRadioState> state();
  Future<List<ItagFound>> scan({Duration duration = const Duration(seconds: 8)});
  Future<bool> connect(String address);
  Future<bool> ring(String address, int level);
  Future<bool> linkLoss(String address, int level);
  Future<int?> battery(String address);
  Future<void> disconnect(String address);
  Future<void> openSettings();
  Stream<ItagEvent> get events;
}

class MethodChannelItagPlatform implements ItagPlatform {
  MethodChannelItagPlatform() {
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'event') return null;
      final m = call.arguments;
      if (m is! Map) return null;
      final type = switch (m['type']) {
        'connected' => ItagEventType.connected,
        'disconnected' => ItagEventType.disconnected,
        'button' => ItagEventType.button,
        _ => null,
      };
      final a = (m['address'] ?? '').toString();
      if (type != null && a.isNotEmpty) {
        _events.add(ItagEvent(type, a, user: m['user'] == true));
      }
      return null;
    });
  }

  static const MethodChannel _ch = MethodChannel('com.assisto/itag');
  final _events = StreamController<ItagEvent>.broadcast();

  Future<T?> _call<T>(String m, [Map<String, Object?>? a]) async {
    try {
      return await _ch.invokeMethod<T>(m, a);
    } catch (_) {
      return null; // older build / no Bluetooth: treated as "not possible"
    }
  }

  @override
  Future<ItagRadioState> state() async {
    final m = await _call<Map<Object?, Object?>>('state');
    final r = switch (m?['state']) {
      'ready' => ItagRadio.ready,
      'off' => ItagRadio.off,
      'no_permission' => ItagRadio.noPermission,
      'location_off' => ItagRadio.locationOff,
      _ => ItagRadio.unsupported,
    };
    return ItagRadioState(r, (m?['sdk'] as num?)?.toInt() ?? 0);
  }

  @override
  Future<List<ItagFound>> scan({Duration duration = const Duration(seconds: 8)}) async {
    final l = await _call<List<Object?>>('scan', {'ms': duration.inMilliseconds});
    return [
      for (final m in (l ?? const []).whereType<Map>())
        ItagFound((m['address'] ?? '').toString(), (m['name'] ?? '').toString(),
            (m['rssi'] as num?)?.toInt() ?? -100, m['likely'] == true),
    ];
  }

  @override
  Future<bool> connect(String address) async =>
      await _call<bool>('connect', {'address': address}) ?? false;

  @override
  Future<bool> ring(String address, int level) async =>
      await _call<bool>('ring', {'address': address, 'level': level}) ?? false;

  @override
  Future<bool> linkLoss(String address, int level) async =>
      await _call<bool>('linkLoss', {'address': address, 'level': level}) ?? false;

  @override
  Future<int?> battery(String address) async =>
      (await _call<num>('battery', {'address': address}))?.toInt();

  @override
  Future<void> disconnect(String address) async {
    await _call<bool>('disconnect', {'address': address});
  }

  @override
  Future<void> openSettings() async {
    await _call<bool>('openSettings');
  }

  @override
  Stream<ItagEvent> get events => _events.stream;
}
