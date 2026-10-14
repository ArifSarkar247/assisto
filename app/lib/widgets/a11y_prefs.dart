import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// a11y_prefs.dart — the single source of truth for Assisto's TRUE ACCESSIBILITY
/// MODE (#200, SPEC v2.1 §20).
///
/// A small [ChangeNotifier] holding six accessibility preferences, persisted to
/// SharedPreferences (pure client prefs — no server round-trip, so they apply
/// instantly and offline). [A11yScope] exposes it down the tree; [AssistoApp]
/// wraps [MaterialApp] with it and applies the three app-wide ones (text scale,
/// high contrast, reduce motion) via a [MediaQuery] override + a theme merge, so
/// EVERY screen respects them without per-screen work.
///
/// HONEST ABOUT REACH. Each flag documents exactly what it does today:
///   * textScale      — APP-WIDE. Overrides MediaQuery.textScaler; all Text grows.
///   * highContrast   — APP-WIDE. Flips MediaQuery.highContrast + a higher-contrast
///                      ThemeData (stronger outlines, pure fg/bg) merged in main.
///   * reduceMotion   — APP-WIDE. Sets MediaQuery.disableAnimations; Flutter's
///                      implicit animations + page transitions shorten/soften.
///   * simplifiedLayout — PARTIAL. A read-only flag screens MAY honour (fewer
///                      decorative elements). Not every screen reads it yet — the
///                      app already ships a dedicated Elderly simple-mode for a
///                      fully simplified home; this flag is the lighter, opt-in
///                      hint. Honestly surfaced as "where supported".
///   * screenReaderHints — TalkBack/VoiceOver is driven by the OS, not a toggle.
///                      This flag turns ON extra in-app Semantics labels/hints on
///                      icon-only controls. The screen states that the OS reader
///                      must be enabled separately.
///   * haptics        — APP-WIDE preference other features check before calling
///                      HapticFeedback. The a11y screen itself gives a live
///                      confirmation buzz when toggled on.
///
/// None of these claim a protection or OS capability that isn't real.
class A11yPrefs extends ChangeNotifier {
  // SharedPreferences keys (stable; namespaced a11y_*).
  static const kTextScale = 'a11y_text_scale';
  static const kHighContrast = 'a11y_high_contrast';
  static const kReduceMotion = 'a11y_reduce_motion';
  static const kSimplified = 'a11y_simplified_layout';
  static const kScreenReaderHints = 'a11y_screen_reader_hints';
  static const kHaptics = 'a11y_haptics';

  /// Allowed text-scale steps. 1.0 is the app default; up to 1.6 keeps layouts
  /// readable without breaking 360dp screens (verified against the widest rows).
  static const List<double> textScaleSteps = [1.0, 1.15, 1.3, 1.45, 1.6];
  static const double minTextScale = 1.0;
  static const double maxTextScale = 1.6;

  double _textScale = 1.0;
  bool _highContrast = false;
  bool _reduceMotion = false;
  bool _simplifiedLayout = false;
  bool _screenReaderHints = false;
  bool _haptics = true; // on by default — most phones expect tactile feedback
  bool _loaded = false;

  double get textScale => _textScale;
  bool get highContrast => _highContrast;
  bool get reduceMotion => _reduceMotion;
  bool get simplifiedLayout => _simplifiedLayout;
  bool get screenReaderHints => _screenReaderHints;
  bool get haptics => _haptics;
  bool get loaded => _loaded;

  /// True when any non-default accessibility preference is active — the a11y
  /// screen shows an honest "active" banner based on this.
  bool get anyActive =>
      _textScale != 1.0 ||
      _highContrast ||
      _reduceMotion ||
      _simplifiedLayout ||
      _screenReaderHints ||
      !_haptics;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _textScale =
          (p.getDouble(kTextScale) ?? 1.0).clamp(minTextScale, maxTextScale);
      _highContrast = p.getBool(kHighContrast) ?? false;
      _reduceMotion = p.getBool(kReduceMotion) ?? false;
      _simplifiedLayout = p.getBool(kSimplified) ?? false;
      _screenReaderHints = p.getBool(kScreenReaderHints) ?? false;
      _haptics = p.getBool(kHaptics) ?? true;
    } catch (_) {
      // defaults already set; never block startup on prefs.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _setBool(String key, bool v, void Function(bool) assign) async {
    assign(v);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(key, v);
    } catch (_) {}
  }

  Future<void> setTextScale(double v) async {
    _textScale = v.clamp(minTextScale, maxTextScale);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(kTextScale, _textScale);
    } catch (_) {}
  }

  Future<void> setHighContrast(bool v) =>
      _setBool(kHighContrast, v, (x) => _highContrast = x);
  Future<void> setReduceMotion(bool v) =>
      _setBool(kReduceMotion, v, (x) => _reduceMotion = x);
  Future<void> setSimplifiedLayout(bool v) =>
      _setBool(kSimplified, v, (x) => _simplifiedLayout = x);
  Future<void> setScreenReaderHints(bool v) =>
      _setBool(kScreenReaderHints, v, (x) => _screenReaderHints = x);
  Future<void> setHaptics(bool v) =>
      _setBool(kHaptics, v, (x) => _haptics = x);

  /// Reset everything to the app defaults (and clear the stored keys).
  Future<void> resetAll() async {
    _textScale = 1.0;
    _highContrast = false;
    _reduceMotion = false;
    _simplifiedLayout = false;
    _screenReaderHints = false;
    _haptics = true;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in [
        kTextScale,
        kHighContrast,
        kReduceMotion,
        kSimplified,
        kScreenReaderHints,
        kHaptics,
      ]) {
        await p.remove(k);
      }
    } catch (_) {}
  }
}

/// Exposes the single [A11yPrefs] to the whole widget tree and rebuilds
/// dependents when it changes. Placed above [MaterialApp] by [AssistoApp].
class A11yScope extends InheritedNotifier<A11yPrefs> {
  const A11yScope({
    super.key,
    required A11yPrefs prefs,
    required super.child,
  }) : super(notifier: prefs);

  static A11yPrefs of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<A11yScope>();
    assert(scope != null, 'A11yScope not found in widget tree');
    return scope!.notifier!;
  }
}

/// A high-contrast overlay merged onto the active theme when [A11yPrefs
/// .highContrast] is on. Strengthens outlines and text contrast without
/// changing brand hue — WCAG-minded, both light and dark.
ThemeData applyHighContrast(ThemeData base) {
  final cs = base.colorScheme;
  final isDark = cs.brightness == Brightness.dark;
  final strongFg = isDark ? Colors.white : Colors.black;
  final outline = isDark ? Colors.white70 : Colors.black87;
  return base.copyWith(
    colorScheme: cs.copyWith(
      onSurface: strongFg,
      onSurfaceVariant: strongFg,
      outline: outline,
      outlineVariant: outline,
    ),
    dividerColor: outline,
    dividerTheme: base.dividerTheme.copyWith(color: outline, thickness: 1.2),
  );
}
