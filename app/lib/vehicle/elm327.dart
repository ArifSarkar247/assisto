import 'package:flutter/services.dart';

/// ELM327 OBD-II response parsing — PURE (no I/O), unit-tested in
/// test/vehicle_elm327_test.dart.
///
/// Commands we use (SAE J1979 mode 01 / 03, plus ELM's own ATRV):
///   0105  coolant temperature   A - 40 (deg C)
///   012F  fuel level            A * 100 / 255 (%) — many cars do NOT support it
///   010C  engine rpm            (256A + B) / 4
///   03    stored trouble codes  2 bytes per code
///   ATRV  battery voltage measured by the dongle itself ("12.6V")
class Elm327 {
  Elm327._();

  /// Init sequence: reset, echo off, linefeeds off, spaces off, headers off,
  /// automatic protocol.
  static const initCommands = ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0'];

  static const _noData = [
    'NO DATA', 'UNABLE TO CONNECT', 'CAN ERROR', 'BUS INIT', 'STOPPED', 'ERROR', '?'
  ];

  /// True when the dongle answered but the car has no value for this PID.
  static bool isNoData(String raw) {
    final u = raw.toUpperCase();
    return _noData.any(u.contains);
  }

  /// Hex bytes of a response, with ELM noise removed: prompt '>', echo,
  /// "SEARCHING...", CAN multi-frame prefixes ("0:", "1:") and the byte-count
  /// line ("00A") that precedes a multi-frame answer.
  static List<int> bytes(String raw) {
    final out = <int>[];
    for (var line in raw.replaceAll('>', '').split(RegExp(r'[\r\n]+'))) {
      line = line.trim().toUpperCase();
      if (line.isEmpty || line.startsWith('SEARCHING')) continue;
      line = line.replaceFirst(RegExp(r'^[0-9A-F]:'), '');
      final hex = line.replaceAll(RegExp(r'[^0-9A-F]'), '');
      if (RegExp(r'^[0-9A-F]{3}$').hasMatch(hex)) continue; // multi-frame length
      for (var i = 0; i + 1 < hex.length; i += 2) {
        out.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
    }
    return out;
  }

  /// Data bytes A, B, ... for a mode-01 [pid] (skips the "41 PID" header).
  static List<int>? mode01(String raw, int pid) {
    if (isNoData(raw)) return null;
    final b = bytes(raw);
    for (var i = 0; i + 1 < b.length; i++) {
      if (b[i] == 0x41 && b[i + 1] == pid) return b.sublist(i + 2);
    }
    return null;
  }

  static int? coolantC(String raw) {
    final d = mode01(raw, 0x05);
    return (d == null || d.isEmpty) ? null : d[0] - 40;
  }

  static double? fuelPct(String raw) {
    final d = mode01(raw, 0x2F);
    return (d == null || d.isEmpty) ? null : (d[0] * 100 / 255);
  }

  static int? rpm(String raw) {
    final d = mode01(raw, 0x0C);
    return (d == null || d.length < 2) ? null : ((d[0] * 256 + d[1]) ~/ 4);
  }

  /// "12.6V" -> 12.6
  static double? voltage(String raw) {
    final m = RegExp(r'(\d{1,2}\.\d)\s*V', caseSensitive: false).firstMatch(raw);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  /// Mode 03 stored DTCs. CAN answers carry a count byte after 0x43 (odd
  /// payload length); older protocols don't. 0x0000 pairs are padding.
  static List<String> dtcs(String raw) {
    if (isNoData(raw)) return const [];
    final b = bytes(raw);
    final codes = <String>[];
    final start = b.indexOf(0x43);
    if (start < 0) return codes;
    var payload = b.sublist(start + 1);
    if (payload.length.isOdd) payload = payload.sublist(1); // CAN count byte
    for (var k = 0; k + 1 < payload.length; k += 2) {
      final c = decodeDtc(payload[k], payload[k + 1]);
      if (c != null && !codes.contains(c)) codes.add(c);
    }
    return codes;
  }

  static String? decodeDtc(int a, int b) {
    if (a == 0 && b == 0) return null;
    const letters = ['P', 'C', 'B', 'U'];
    final l = letters[(a >> 6) & 0x03];
    final d1 = (a >> 4) & 0x03;
    String h(int v) => v.toRadixString(16).toUpperCase();
    return '$l$d1${h(a & 0x0F)}${h(b >> 4)}${h(b & 0x0F)}';
  }
}

/// What one Bluetooth read produced. Every field is nullable: a car that
/// does not support a PID leaves it null — the UI says "not supported".
class ObdReading {
  final int? coolantC;
  final double? batteryV;
  final double? fuelPct;
  final int? rpm;
  final List<String> dtcs;
  const ObdReading(
      {this.coolantC, this.batteryV, this.fuelPct, this.rpm, this.dtcs = const []});
}

enum ObdBtState { unavailable, bluetoothOff, noPermission, ready }

/// Classic-Bluetooth (SPP / RFCOMM) bridge to an ELM327 dongle, over the
/// native channel in android_overlay/.../vehicle/ObdBtChannel.kt.
///
/// LAZY + CRASH-GUARDED: nothing here runs until the OBD screen calls it.
/// If the native side is missing (iOS, or a build without the channel
/// registered) every call degrades to [ObdBtState.unavailable] — never a crash.
class ObdBluetooth {
  ObdBluetooth._();
  static const _ch = MethodChannel('com.assisto/obd_bt');

  static Future<ObdBtState> state() async {
    try {
      final s = await _ch.invokeMethod<String>('state');
      switch (s) {
        case 'ready':
          return ObdBtState.ready;
        case 'off':
          return ObdBtState.bluetoothOff;
        case 'no_permission':
          return ObdBtState.noPermission;
      }
    } catch (_) {}
    return ObdBtState.unavailable;
  }

  /// Paired (bonded) devices: [{name, address}]. ELM327 dongles must be
  /// paired once in Android Bluetooth settings (PIN usually 1234 or 0000).
  static Future<List<Map<String, String>>> bonded() async {
    try {
      final l = await _ch.invokeMethod<List<dynamic>>('bonded');
      return (l ?? const [])
          .whereType<Map>()
          .map((m) => {
                'name': '${m['name'] ?? ''}',
                'address': '${m['address'] ?? ''}',
              })
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> connect(String address) async {
    try {
      return await _ch.invokeMethod<bool>('connect', {'address': address}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> send(String cmd, {int timeoutMs = 4000}) async {
    try {
      return await _ch.invokeMethod<String>(
              'send', {'cmd': cmd, 'timeoutMs': timeoutMs}) ??
          '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> disconnect() async {
    try {
      await _ch.invokeMethod('disconnect');
    } catch (_) {}
  }

  /// Init the dongle and read everything we show. Null = could not talk to it.
  static Future<ObdReading?> readAll() async {
    for (final c in Elm327.initCommands) {
      final r = await send(c, timeoutMs: c == 'ATZ' ? 6000 : 3000);
      if (c == 'ATZ' && r.isEmpty) return null;
    }
    final coolant = Elm327.coolantC(await send('0105', timeoutMs: 8000));
    final volt = Elm327.voltage(await send('ATRV'));
    final fuel = Elm327.fuelPct(await send('012F'));
    final rpm = Elm327.rpm(await send('010C'));
    final dtcs = Elm327.dtcs(await send('03', timeoutMs: 6000));
    return ObdReading(
        coolantC: coolant, batteryV: volt, fuelPct: fuel, rpm: rpm, dtcs: dtcs);
  }
}
