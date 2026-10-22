import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// tl1: OEM background guide — device detection, step catalogue and the
/// "show once after login" gate. UI lives in screens/battery_guidance_screen.
///
/// Native side: android_overlay/.../oem/OemGuideChannel.kt on channel
/// "com.assisto/oem_guide". Every call here is try/catch and returns a safe
/// "unknown" value, so a ROM quirk can never break the screen or the launch.

/// Phone families whose background rules differ. realme / OnePlus share the
/// ColorOS packages with OPPO but word their menus differently.
enum OemFamily { xiaomi, oppo, realme, oneplus, vivo, samsung, transsion, nearStock }

/// Detect the family from Build.MANUFACTURER / Build.BRAND (lower-cased).
/// Walton, Symphony, Nokia, Motorola, Pixel… are near-stock Android: only
/// the standard battery-optimisation step applies.
OemFamily detectOemFamily(String manufacturer, String brand) {
  final s = '${manufacturer.toLowerCase()} ${brand.toLowerCase()}';
  bool has(String k) => s.contains(k);
  if (has('xiaomi') || has('redmi') || has('poco')) return OemFamily.xiaomi;
  if (has('realme')) return OemFamily.realme;
  if (has('oneplus')) return OemFamily.oneplus;
  if (has('oppo')) return OemFamily.oppo;
  if (has('vivo') || has('iqoo')) return OemFamily.vivo;
  if (has('samsung')) return OemFamily.samsung;
  if (has('infinix') || has('tecno') || has('itel') || has('transsion')) {
    return OemFamily.transsion;
  }
  return OemFamily.nearStock;
}

/// What the phone told us. Null booleans mean "Android can't tell us"
/// (older API level or the lookup failed) — never treated as satisfied.
class OemInfo {
  final String manufacturer;
  final String brand;
  final String model;
  final int sdkInt;
  final String release;
  final String rom;
  final bool? batteryOptIgnored;
  final bool? bgRestricted;
  const OemInfo({
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.sdkInt = 0,
    this.release = '',
    this.rom = '',
    this.batteryOptIgnored,
    this.bgRestricted,
  });

  factory OemInfo.fromMap(Map m) => OemInfo(
        manufacturer: '${m['manufacturer'] ?? ''}',
        brand: '${m['brand'] ?? ''}',
        model: '${m['model'] ?? ''}',
        sdkInt: (m['sdkInt'] is int) ? m['sdkInt'] as int : 0,
        release: '${m['release'] ?? ''}',
        rom: '${m['rom'] ?? ''}',
        batteryOptIgnored: m['batteryOptIgnored'] is bool ? m['batteryOptIgnored'] as bool : null,
        bgRestricted: m['bgRestricted'] is bool ? m['bgRestricted'] as bool : null,
      );

  OemFamily get family => detectOemFamily(manufacturer, brand);

  /// "Samsung SM-A155F · Android 14 · One UI 6.1" (empty parts skipped).
  String get label {
    var make = manufacturer.isEmpty ? brand : manufacturer;
    if (make.isNotEmpty) make = make[0].toUpperCase() + make.substring(1);
    final parts = <String>[
      [make, model].where((e) => e.isNotEmpty).join(' '),
      if (release.isNotEmpty) 'Android $release',
      if (rom.isNotEmpty) rom,
    ];
    return parts.where((e) => e.isNotEmpty).join(' · ');
  }
}

/// What an "Open" button would do on this phone (from the native resolve).
enum OemOpen { oem, details, none }

OemOpen _openOf(Object? v) => switch (v) {
      'oem' => OemOpen.oem,
      'details' => OemOpen.details,
      _ => OemOpen.none,
    };

/// Native bridge. Tests and the gallery pass a fake.
abstract class OemGuideNative {
  Future<OemInfo?> info();
  Future<OemOpen> available(String step);
  Future<OemOpen> open(String step);
}

class ChannelOemGuideNative implements OemGuideNative {
  const ChannelOemGuideNative();
  static const _ch = MethodChannel('com.assisto/oem_guide');

  @override
  Future<OemInfo?> info() async {
    try {
      final m = await _ch.invokeMethod<Map>('info');
      return m == null ? null : OemInfo.fromMap(m);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<OemOpen> available(String step) async {
    try {
      return _openOf(await _ch.invokeMethod<String>('available', {'step': step}));
    } catch (_) {
      return OemOpen.none;
    }
  }

  @override
  Future<OemOpen> open(String step) async {
    try {
      return _openOf(await _ch.invokeMethod<String>('open', {'step': step}));
    } catch (_) {
      return OemOpen.none;
    }
  }
}

/// Step ids. [nativeStep] is the channel step the "Open" button fires; null
/// for by-hand-only steps (no settings screen exists, so no button at all).
enum OemStepId { batteryOpt, bgRestricted, samsungUnrestricted, autostart, oemBattery, lockRecent }

extension OemStepNative on OemStepId {
  String? get nativeStep => switch (this) {
        OemStepId.batteryOpt => 'battery_opt',
        OemStepId.bgRestricted => 'app_details',
        OemStepId.samsungUnrestricted => 'app_details',
        OemStepId.autostart => 'autostart',
        OemStepId.oemBattery => 'oem_battery',
        OemStepId.lockRecent => null,
      };

  /// True when Android can report this setting (so "done" is real).
  bool get checkable =>
      this == OemStepId.batteryOpt ||
      this == OemStepId.bgRestricted ||
      this == OemStepId.samsungUnrestricted;
}

/// The steps that apply to [family], in the order to do them.
/// [bgRestricted] adds the "allow background use" step only when Android says
/// the app IS restricted (API 28+).
List<OemStepId> oemSteps(OemFamily family, {bool? bgRestricted}) {
  final s = <OemStepId>[
    if (bgRestricted == true) OemStepId.bgRestricted,
  ];
  switch (family) {
    case OemFamily.xiaomi:
    case OemFamily.oppo:
    case OemFamily.realme:
    case OemFamily.oneplus:
    case OemFamily.vivo:
    case OemFamily.transsion:
      s.addAll([OemStepId.autostart, OemStepId.oemBattery, OemStepId.batteryOpt, OemStepId.lockRecent]);
    case OemFamily.samsung:
      s.addAll([OemStepId.samsungUnrestricted, OemStepId.oemBattery]);
    case OemFamily.nearStock:
      s.add(OemStepId.batteryOpt);
  }
  return s;
}

/// Is [step] already satisfied on this phone? Only checkable steps can be.
bool oemStepDone(OemStepId step, OemInfo info) => switch (step) {
      OemStepId.batteryOpt => info.batteryOptIgnored == true,
      OemStepId.samsungUnrestricted => info.batteryOptIgnored == true,
      OemStepId.bgRestricted => info.bgRestricted == false,
      _ => false,
    };

/// Worth showing the guide on first run? False only when every step is
/// checkable AND already done (e.g. a Walton phone with optimisation off).
bool oemGuideRelevant(OemInfo info) {
  final steps = oemSteps(info.family, bgRestricted: info.bgRestricted);
  return steps.any((s) => !oemStepDone(s, info));
}

/// "Show once after login". Called from the root route AFTER login +
/// onboarding; never from the home screen. Waits a few seconds so nothing
/// extra runs during the launch, then (Android only) pushes the guide once.
class OemGuideGate {
  static const prefKey = 'oem_guide_seen_v1';
  static bool _scheduled = false;

  /// Overridable in tests.
  @visibleForTesting
  static bool Function() isAndroid = () => !kIsWeb && Platform.isAndroid;
  @visibleForTesting
  static OemGuideNative native = const ChannelOemGuideNative();
  @visibleForTesting
  static Duration delay = const Duration(seconds: 4);
  @visibleForTesting
  static void resetForTest() => _scheduled = false;

  /// Schedules the one-time check; safe to call on every build.
  static void schedule(BuildContext context, Widget Function() screen) {
    if (_scheduled) return;
    _scheduled = true;
    bool android;
    try {
      android = isAndroid();
    } catch (_) {
      android = false;
    }
    if (!android) return;
    final nav = Navigator.maybeOf(context);
    if (nav == null) return;
    final route = ModalRoute.of(context);
    unawaited(Future<void>.delayed(delay, () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool(prefKey) ?? false) return;
        final info = await native.info();
        if (info == null) return; // can't tell — try again next launch
        // Never cover another screen (a ringing call, a chat the user opened
        // from a notification): only when the root route is on top; else
        // try again next launch.
        if (!nav.mounted || (route != null && !route.isCurrent)) return;
        await prefs.setBool(prefKey, true);
        if (!oemGuideRelevant(info)) return;
        await nav.push(MaterialPageRoute(
            settings: const RouteSettings(name: 'oem_guide_first_run'),
            builder: (_) => screen()));
      } catch (_) {}
    }));
  }
}
