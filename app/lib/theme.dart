import 'package:flutter/material.dart';

/// Assisto design system (f1 design pass).
///
/// One token set for the whole app: colour (light + dark, WCAG AA), a 4/8-pt
/// spacing grid, radii, elevation, motion and ONE type scale. Brand comes from
/// the logo: cyan → blue → green on navy #030B28. Screens should read colours
/// from `Theme.of(context).colorScheme` / [AssistoTokens] and sizes from
/// [Gap] / [Radii] / the text theme — never hard-coded literals.
///
/// Typography: Latin = Inter, Bangla = Noto Sans Bengali (see
/// `.phaseB/design_shots/BANGLA_FONT_DECISION.md`). Both are bundled OFL
/// static weights 400/500/600/700 (never downloaded at runtime). The theme
/// sets `fontFamily: Inter` + `fontFamilyFallback: [NotoSansBengali]`, so
/// Latin glyphs come from Inter and every Bangla glyph (incl. ZWJ/ZWNJ, which
/// the Inter subset deliberately omits) from Noto Sans Bengali.
class Brand {
  /// Readable "warning" ink for text/icons on a warning-tinted surface:
  /// dark amber on light, light amber on dark (QA a6: 0xFF8A6D00 on a dark
  /// surface was ~2:1).
  static Color warnInk(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFFFFD666)
          : const Color(0xFF8A6D00);

  Brand._();

  // Core brand colours — from the new logo (cyan → blue → green on navy).
  static const cyan = Color(0xFF22D3EE); // sparkle / highlight
  static const blue = Color(0xFF3B6EF6); // primary
  static const blueDeep = Color(0xFF2347D9); // pressed / deep primary
  static const green = Color(0xFF22C58B); // gradient tail (new logo)
  static const purple = Color(0xFF9B4DF0); // legacy tertiary accent
  static const ink = Color(0xFF05060A); // near-black (call / camera screens)
  static const navyInk = Color(0xFF030B28); // logo field (splash / hero bg)

  // Back-compat aliases (older code referenced navy/gold).
  static const navy = blue;
  static const gold = cyan;

  // Semantic
  static const success = Color(0xFF2E9E6B);
  static const warning = Color(0xFFE0A500);
  static const danger = Color(0xFFE0485A);
  static const info = Color(0xFF2F7BE5);

  /// Fill for destructive FILLED buttons/snackbars: white text on it is 5.6:1
  /// (Brand.danger is 4.0:1 with white, and with only a background set the
  /// dark theme drew its dark onPrimary text on it — ~2:1, QA qa1).
  static const dangerFill = Color(0xFFC62839);

  /// Fill for positive FILLED buttons (white text 5.3:1; Brand.success is
  /// 3.4:1 with white — below AA for button text).
  static const successFill = Color(0xFF1E7A50);

  /// The one positive FilledButton style (white text, both themes).
  static ButtonStyle successButton() => FilledButton.styleFrom(
      backgroundColor: successFill, foregroundColor: Colors.white);

  /// Readable text/icon colour for a semantic [color] drawn on its own light
  /// tint (status chips, badges): pulled toward the theme's onSurface so
  /// amber/blue/green labels pass AA on both themes (QA qa1: amber "order
  /// received" on its pale tint was ~2:1).
  static Color onTint(BuildContext context, Color color) {
    final s = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Color.lerp(color, s.onSurface, dark ? 0.25 : 0.45)!;
  }

  /// The one destructive FilledButton style (white text, both themes).
  static ButtonStyle dangerButton() => FilledButton.styleFrom(
      backgroundColor: dangerFill, foregroundColor: Colors.white);

  // Brand gradient (login / splash / hero surfaces / logo tint) — the new
  // logo's cyan → blue → green.
  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [cyan, blue, green],
  );

  // Dark hero backdrop gradient (splash / login behind the logo): the logo's
  // navy field.
  static const heroDark = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0A1640), navyInk],
  );
}

/// f3-design: ink for the ALWAYS-dark call canvas (calling / ringing /
/// connected / video / incoming / mini bar). These do not follow the app
/// theme on purpose — the canvas is [Brand.ink] / [Brand.heroDark] in both.
/// Every text tone here is ≥ 4.5:1 on [Brand.ink] and on the hero gradient.
class CallInk {
  CallInk._();
  static const text = Colors.white;

  /// Secondary text (status line, control labels): white @ 85 %.
  static const textSoft = Color(0xD9FFFFFF);

  /// Hints, the encrypted line, small print: white @ 75 %.
  static const textHint = Color(0xBFFFFFFF);

  /// A failure the user should notice (red status line), on the dark canvas.
  static const failure = Color(0xFFFFB3BB);

  /// Network-quality bars (the dark theme's success / warning / error).
  static const good = Color(0xFF5BD69A);
  static const fair = Color(0xFFFFC857);
  static const poor = Color(0xFFFF6B78);

  /// Glass surfaces on the canvas (controls tray, prompt card, chips).
  static const glass = Color(0x1AFFFFFF); // white @ 10 %
  static const glassHigh = Color(0x24FFFFFF); // white @ 14 %
  static const chip = Color(0x59000000); // black @ 35 %
  static const notice = Color(0x73000000); // black @ 45 %

  /// Over live remote video: top / bottom scrims so the ink stays readable.
  static const scrimTop = Color(0x99000000);
  static const scrimBottom = Color(0xB3000000);

  /// The minimized-call bar (white on it is 6.4:1) and its hang-up glyph.
  static const miniBar = Color(0xFF146C43);
  static const miniHangup = Color(0xFFFFD6DA);

  /// Self-view tile shadow on the video stage.
  static const tileShadow = Color(0x66000000);
}

/// 4/8-pt spacing scale. Use these instead of magic numbers.
class Gap {
  Gap._();
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;

  /// Standard screen edge padding.
  static const screen = EdgeInsets.symmetric(horizontal: lg);
}

/// Corner radii (4-pt grid).
class Radii {
  Radii._();
  static const xs = 4.0;
  static const sm = 8.0; // chips' inner parts, small tiles
  static const md = 12.0; // buttons, inputs, cards
  static const lg = 16.0; // large cards, dialogs content
  static const xl = 24.0; // sheets, dialogs
  static const pill = 999.0;
}

/// Elevation levels (Material 3 tonal elevation; shadows stay subtle).
class Elev {
  Elev._();
  static const none = 0.0;
  static const low = 1.0; // scrolled app bar, resting card on surface
  static const mid = 3.0; // menus, nav bar
  static const high = 6.0; // sheets, dialogs, FAB
}

/// Motion durations — short, purposeful (150–300 ms).
class Motion {
  Motion._();
  static const fast = Duration(milliseconds: 150);
  static const base = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 300);
  static const curve = Curves.easeOutCubic;
}

/// Minimum touch target (Android / WCAG 2.5.5).
const double kMinTap = 48.0;

/// Font families (bundled, OFL).
class AFonts {
  AFonts._();
  static const latin = 'Inter';
  static const bangla = 'NotoSansBengali';
  static const fallback = <String>[bangla];

  /// Tabular (fixed-width) figures for amounts, times and counters, so
  /// columns of numbers line up and live counters don't jitter.
  static const tabular = <FontFeature>[FontFeature.tabularFigures()];

  /// [style] with tabular figures.
  static TextStyle? figures(TextStyle? style) =>
      style?.copyWith(fontFeatures: tabular);
}

/// The ONE type scale as colour-less, weight-less metrics (size, line height,
/// letter spacing, even leading). [AssistoTheme]'s text theme is built from
/// these, so `AType.bodySmall` == `textTheme.bodySmall` minus colour/weight.
///
/// Use `Theme.of(context).textTheme.*` where a full role fits. Use `AType.*`
/// in place of a bare `TextStyle(fontSize: n)`: it keeps inheriting colour and
/// weight from the surrounding DefaultTextStyle (button label, ListTile
/// subtitle, white-on-gradient…), exactly like the literal it replaces, and
/// needs no BuildContext.
class AType {
  AType._();
  static const _even = TextLeadingDistribution.even;
  static const displayLarge = TextStyle(fontSize: 40, height: 1.35, letterSpacing: -0.5, leadingDistribution: _even);
  static const displayMedium = TextStyle(fontSize: 34, height: 1.35, letterSpacing: -0.4, leadingDistribution: _even);
  static const displaySmall = TextStyle(fontSize: 30, height: 1.35, letterSpacing: -0.3, leadingDistribution: _even);
  static const headlineLarge = TextStyle(fontSize: 28, height: 1.35, letterSpacing: -0.2, leadingDistribution: _even);
  static const headlineMedium = TextStyle(fontSize: 26, height: 1.35, letterSpacing: -0.2, leadingDistribution: _even);
  static const headlineSmall = TextStyle(fontSize: 22, height: 1.4, letterSpacing: -0.1, leadingDistribution: _even);
  static const titleLarge = TextStyle(fontSize: 20, height: 1.4, letterSpacing: 0, leadingDistribution: _even);
  static const titleMedium = TextStyle(fontSize: 16, height: 1.45, letterSpacing: 0, leadingDistribution: _even);
  static const titleSmall = TextStyle(fontSize: 14, height: 1.45, letterSpacing: 0, leadingDistribution: _even);
  static const bodyLarge = TextStyle(fontSize: 16, height: 1.5, letterSpacing: 0, leadingDistribution: _even);
  static const bodyMedium = TextStyle(fontSize: 14, height: 1.5, letterSpacing: 0, leadingDistribution: _even);
  static const bodySmall = TextStyle(fontSize: 12, height: 1.5, letterSpacing: 0, leadingDistribution: _even); // caption
  static const labelLarge = TextStyle(fontSize: 14, height: 1.45, letterSpacing: 0, leadingDistribution: _even);
  static const labelMedium = TextStyle(fontSize: 12, height: 1.45, letterSpacing: 0, leadingDistribution: _even);
  static const labelSmall = TextStyle(fontSize: 11, height: 1.45, letterSpacing: 0.2, leadingDistribution: _even);
}

/// Semantic colours that ColorScheme has no slot for (both themes, AA).
@immutable
class AssistoTokens extends ThemeExtension<AssistoTokens> {
  const AssistoTokens({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.info,
    required this.infoContainer,
    required this.onInfoContainer,
    required this.textMuted,
    required this.callSurface,
    required this.onCallSurface,
  });

  final Color success, onSuccess, successContainer, onSuccessContainer;
  final Color warning, onWarning, warningContainer, onWarningContainer;
  final Color info, infoContainer, onInfoContainer;

  /// Secondary text (captions, timestamps): ≥ 4.5:1 on surface.
  final Color textMuted;

  /// The always-dark call / camera canvas and its ink.
  final Color callSurface, onCallSurface;

  static const light = AssistoTokens(
    success: Color(0xFF1A6E48),
    onSuccess: Colors.white,
    successContainer: Color(0xFFD5F5E6),
    onSuccessContainer: Color(0xFF0B3D27),
    warning: Color(0xFF735A00),
    onWarning: Colors.white,
    warningContainer: Color(0xFFFFF0C2),
    onWarningContainer: Color(0xFF4A3A00),
    info: Color(0xFF1F5FC4),
    infoContainer: Color(0xFFDDE8FF),
    onInfoContainer: Color(0xFF0B2A66),
    textMuted: Color(0xFF555E70),
    callSurface: Color(0xFF05060A),
    onCallSurface: Colors.white,
  );

  static const dark = AssistoTokens(
    success: Color(0xFF5FD69E),
    onSuccess: Color(0xFF00391F),
    successContainer: Color(0xFF0E3A27),
    onSuccessContainer: Color(0xFFBDF2D7),
    warning: Color(0xFFFFD666),
    onWarning: Color(0xFF3D2F00),
    warningContainer: Color(0xFF3D3100),
    onWarningContainer: Color(0xFFFFE9A8),
    info: Color(0xFF8DB4FF),
    infoContainer: Color(0xFF15295A),
    onInfoContainer: Color(0xFFD7E3FF),
    textMuted: Color(0xFFA9B2C6),
    callSurface: Color(0xFF05060A),
    onCallSurface: Colors.white,
  );

  static AssistoTokens of(BuildContext context) =>
      Theme.of(context).extension<AssistoTokens>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  AssistoTokens copyWith() => this;

  @override
  AssistoTokens lerp(AssistoTokens? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AssistoTokens(
      success: l(success, other.success),
      onSuccess: l(onSuccess, other.onSuccess),
      successContainer: l(successContainer, other.successContainer),
      onSuccessContainer: l(onSuccessContainer, other.onSuccessContainer),
      warning: l(warning, other.warning),
      onWarning: l(onWarning, other.onWarning),
      warningContainer: l(warningContainer, other.warningContainer),
      onWarningContainer: l(onWarningContainer, other.onWarningContainer),
      info: l(info, other.info),
      infoContainer: l(infoContainer, other.infoContainer),
      onInfoContainer: l(onInfoContainer, other.onInfoContainer),
      textMuted: l(textMuted, other.textMuted),
      callSurface: l(callSurface, other.callSurface),
      onCallSurface: l(onCallSurface, other.onCallSurface),
    );
  }
}

class AssistoTheme {
  AssistoTheme._();

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  /// The one type scale (display / headline / title / body / label; caption =
  /// bodySmall). Line heights are chosen so Bangla never clips: Noto Sans
  /// Bengali's natural box is 1.325 em, every style here is ≥ 1.35 em, and
  /// [TextLeadingDistribution.even] keeps the extra leading split above and
  /// below (tall Bangla conjuncts and the below-base vowel signs stay inside
  /// the line box — test/f1_design_test.dart).
  static TextTheme _type(Color ink) {
    TextStyle s(TextStyle metrics, FontWeight w) => metrics.copyWith(
          fontFamily: AFonts.latin,
          fontFamilyFallback: AFonts.fallback,
          fontWeight: w,
          color: ink,
        );
    return TextTheme(
      displayLarge: s(AType.displayLarge, FontWeight.w700),
      displayMedium: s(AType.displayMedium, FontWeight.w700),
      displaySmall: s(AType.displaySmall, FontWeight.w700),
      headlineLarge: s(AType.headlineLarge, FontWeight.w700),
      headlineMedium: s(AType.headlineMedium, FontWeight.w700),
      headlineSmall: s(AType.headlineSmall, FontWeight.w700),
      titleLarge: s(AType.titleLarge, FontWeight.w700),
      titleMedium: s(AType.titleMedium, FontWeight.w600),
      titleSmall: s(AType.titleSmall, FontWeight.w600),
      bodyLarge: s(AType.bodyLarge, FontWeight.w400),
      bodyMedium: s(AType.bodyMedium, FontWeight.w400),
      bodySmall: s(AType.bodySmall, FontWeight.w400), // caption
      labelLarge: s(AType.labelLarge, FontWeight.w600),
      labelMedium: s(AType.labelMedium, FontWeight.w600),
      labelSmall: s(AType.labelSmall, FontWeight.w500),
    );
  }

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final seeded = ColorScheme.fromSeed(
      seedColor: Brand.blue,
      brightness: brightness,
    );
    final scheme = seeded.copyWith(
      // Brand across both modes: blue primary, cyan highlight, green accent
      // (new logo). Lightened in dark mode for AA contrast on dark surfaces.
      // Light primary deepened from Brand.blue (white text 4.4:1 → 5.8:1 AA).
      primary: isDark ? const Color(0xFF6FA0FF) : const Color(0xFF2C5BDB),
      secondary: isDark ? Brand.cyan : const Color(0xFF0E7F94),
      tertiary: isDark ? const Color(0xFF5FD69E) : const Color(0xFF16805A),
      // qa1 contrast: error buttons/text were E0485A with fromSeed's onError
      // (white 4.0:1 in light; dark-on-red 3.2:1 in dark). Light: a deeper red
      // (white 5.6:1, as text on surface 5.3:1). Dark: a lighter red with dark
      // ink (6.8:1), readable as text on the dark surface too (6.7:1).
      error: isDark ? const Color(0xFFFF6B78) : Brand.dangerFill,
      onError: isDark ? const Color(0xFF2D0006) : Colors.white,
      // Dark surfaces are tinted with the logo's navy (#030B28) instead of a
      // neutral grey, so dark mode reads as "Assisto".
      surface: isDark ? const Color(0xFF070E26) : const Color(0xFFFAFBFF),
      surfaceContainerLowest:
          isDark ? const Color(0xFF030B28) : Colors.white,
      surfaceContainerLow:
          isDark ? const Color(0xFF0D1631) : const Color(0xFFF3F5FC),
      surfaceContainer:
          isDark ? const Color(0xFF121C39) : const Color(0xFFEDF0F8),
      surfaceContainerHigh:
          isDark ? const Color(0xFF182342) : const Color(0xFFE7EAF4),
      surfaceContainerHighest:
          isDark ? const Color(0xFF1F2B4D) : const Color(0xFFE1E5F0),
      onSurface: isDark ? const Color(0xFFE6E9F2) : const Color(0xFF141824),
      onSurfaceVariant:
          isDark ? const Color(0xFFB4BCD0) : const Color(0xFF465063),
      outline: isDark ? const Color(0xFF8590A8) : const Color(0xFF6E788C),
      outlineVariant:
          isDark ? const Color(0xFF2C3758) : const Color(0xFFD5DAE6),
    );
    final type = _type(scheme.onSurface);

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: AFonts.latin,
      fontFamilyFallback: AFonts.fallback,
      textTheme: type,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      extensions: [isDark ? AssistoTokens.dark : AssistoTokens.light],
    );
    final t = base.textTheme;
    final rMd = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md));
    const btnPad = EdgeInsets.symmetric(horizontal: Gap.lg + Gap.xs, vertical: Gap.md);

    return base.copyWith(
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        // Android default (fade + scale, ~300 ms route duration).
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
      }),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: Elev.low,
        centerTitle: false,
        titleSpacing: Gap.lg,
        titleTextStyle: t.titleLarge?.copyWith(color: scheme.onSurface),
        iconTheme: IconThemeData(color: scheme.onSurface, size: 24),
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 24),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        minVerticalPadding: Gap.sm,
        minLeadingWidth: Gap.xl,
        horizontalTitleGap: Gap.md,
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: t.bodyLarge?.copyWith(
            fontWeight: FontWeight.w500, color: scheme.onSurface),
        subtitleTextStyle:
            t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        shape: rMd,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(t.labelMedium),
      ),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        labelTextStyle: WidgetStatePropertyAll(t.labelLarge),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md + Gap.xxs),
        hintStyle: t.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        labelStyle: t.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        helperStyle: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        errorStyle: t.bodySmall?.copyWith(color: scheme.error),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(kMinTap, kMinTap + 2),
          padding: btnPad,
          shape: rMd,
          textStyle: t.labelLarge?.copyWith(fontSize: 15),
          animationDuration: Motion.fast,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(kMinTap, kMinTap),
          padding: btnPad,
          shape: rMd,
          elevation: Elev.none,
          backgroundColor: scheme.surfaceContainerHigh,
          foregroundColor: scheme.primary,
          textStyle: t.labelLarge,
          animationDuration: Motion.fast,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(kMinTap, kMinTap),
          padding: btnPad,
          shape: rMd,
          side: BorderSide(color: scheme.outline),
          textStyle: t.labelLarge,
          animationDuration: Motion.fast,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(kMinTap, kMinTap),
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          shape: rMd,
          textStyle: t.labelLarge,
          animationDuration: Motion.fast,
        ),
      ),
      // IconButton keeps M3's 40 dp visual size; `materialTapTargetSize:
      // padded` (above) already gives it a 48 dp hit area. Forcing a 48 dp
      // layout size widened every app bar's actions by 8 dp each.
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(animationDuration: Motion.fast),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        elevation: Elev.mid,
        highlightElevation: Elev.high,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.lg)),
        extendedTextStyle: t.labelLarge,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(kMinTap, kMinTap),
          textStyle: t.labelLarge,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: t.labelLarge?.copyWith(color: scheme.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surfaceContainerLow,
        elevation: Elev.high,
        modalElevation: Elev.high,
        showDragHandle: false, // many sheets draw their own handle
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.5),
        dragHandleSize: const Size(36, 4),
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: Elev.high,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.xl)),
        titleTextStyle: t.headlineSmall?.copyWith(color: scheme.onSurface),
        contentTextStyle:
            t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: Elev.mid,
        textStyle: t.bodyLarge,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: Elev.mid,
        contentTextStyle:
            t.bodyMedium?.copyWith(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        textStyle: t.bodySmall?.copyWith(color: scheme.onInverseSurface),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: t.labelLarge,
        unselectedLabelStyle: t.labelLarge?.copyWith(fontWeight: FontWeight.w500),
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: scheme.outlineVariant,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 4,
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
      checkboxTheme: CheckboxThemeData(
        materialTapTargetSize: MaterialTapTargetSize.padded,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.xs)),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.error,
        textColor: scheme.onError,
        textStyle: t.labelSmall,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
    );
  }
}

/// home_v2 (owner final home design, 26 Oct — owner_actions/design/
/// home_v6_bn.html): EVERY colour of the new home lives here (the design guard
/// forbids colour literals elsewhere). Light values are copied 1:1 from the
/// owner's HTML; the dark set is designed for the same hierarchy (not an
/// inversion): the navy header and the coloured gradients stay, the surfaces
/// become deep navy-slate and every text tone keeps ≥ 4.5:1.
/// Sizes / radii / spacing live in lib/screens/home_v2/home_v2_tokens.dart.
class HomeV2Palette {
  const HomeV2Palette._({
    required this.dark,
    required this.headerGradient,
    required this.body,
    required this.sectionTitle,
    required this.dotOff,
    required this.dotOn,
    required this.tile,
    required this.tileBorder,
    required this.tileShadow,
    required this.tileLabel,
    required this.pinBorder,
    required this.pinTop,
    required this.chip,
    required this.chipBorder,
    required this.chipInk,
    required this.askGradient,
    required this.askShadow,
    required this.nav,
    required this.navBorder,
    required this.navInk,
    required this.navActive,
    required this.voiceRing,
    required this.voiceLabel,
    required this.missedRing,
    required this.discoverShadow,
  });

  final bool dark;
  final List<Color> headerGradient;
  final Color body;
  final Color sectionTitle;
  final Color dotOff;
  final Color dotOn;
  final Color tile;
  final Color tileBorder;
  final Color tileShadow;
  final Color tileLabel;
  final Color pinBorder;
  final Color pinTop;
  final Color chip;
  final Color chipBorder;
  final Color chipInk;
  final List<Color> askGradient;
  final Color askShadow;
  final Color nav;
  final Color navBorder;
  final Color navInk;
  final Color navActive;
  final Color voiceRing;
  final Color voiceLabel;
  final Color missedRing;
  final Color discoverShadow;

  static HomeV2Palette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkSet : light;

  static const light = HomeV2Palette._(
    dark: false,
    headerGradient: [Color(0xFF0A1A3F), Color(0xFF13306E), Color(0xFF1E4FB8)],
    body: Color(0xFFF4F6FA),
    sectionTitle: Color(0xFF0F172A),
    dotOff: Color(0xFFCBD5E1),
    dotOn: Color(0xFF0A84FF),
    tile: Colors.white,
    tileBorder: Color(0xFFEBEEF4),
    tileShadow: Color(0x0D0F172A), // rgba(15,23,42,.05)
    tileLabel: Color(0xFF0F172A),
    pinBorder: Color(0xFFA5B4FC),
    pinTop: Color(0xFFEEF2FF),
    chip: Colors.white,
    chipBorder: Color(0xFFE2E8F0),
    chipInk: Color(0xFF1E293B),
    askGradient: [Color(0xFF0B2560), Color(0xFF1D4ED8), Color(0xFF3B82F6)],
    askShadow: Color(0x471D4ED8), // rgba(29,78,216,.28)
    nav: Colors.white,
    navBorder: Color(0xFFE5E9F0),
    navInk: Color(0xFF475569),
    navActive: Color(0xFF1D4ED8),
    voiceRing: Colors.white,
    voiceLabel: Color(0xFF0F172A),
    missedRing: Colors.white,
    discoverShadow: Color(0x4D4F46E5), // rgba(79,70,229,.30)
  );

  static const darkSet = HomeV2Palette._(
    dark: true,
    headerGradient: [Color(0xFF060F29), Color(0xFF0D2252), Color(0xFF173F96)],
    body: Color(0xFF0B1120),
    sectionTitle: Color(0xFFE8EDF6),
    dotOff: Color(0xFF334155),
    dotOn: Color(0xFF4DA3FF),
    tile: Color(0xFF141C2F),
    tileBorder: Color(0xFF222D45),
    tileShadow: Color(0x33000000),
    tileLabel: Color(0xFFE2E8F0),
    pinBorder: Color(0xFF6366F1),
    pinTop: Color(0xFF1E1B4B),
    chip: Color(0xFF141C2F),
    chipBorder: Color(0xFF2A3650),
    chipInk: Color(0xFFE2E8F0),
    askGradient: [Color(0xFF0A1F52), Color(0xFF1A44BE), Color(0xFF2F6FE0)],
    askShadow: Color(0x40000000),
    nav: Color(0xFF0F172A),
    navBorder: Color(0xFF1E293B),
    navInk: Color(0xFFA3B1C6),
    navActive: Color(0xFF7CB4FF),
    voiceRing: Color(0xFF0F172A),
    voiceLabel: Color(0xFFE8EDF6),
    missedRing: Color(0xFF141C2F),
    discoverShadow: Color(0x40000000),
  );

  // ---- shared by both themes (always on a coloured / navy ground) ----
  static const onColor = Colors.white;
  static const headerSoft = Color(0xFFD3DEF7); // tagline
  static const headerGlass = Color(0x1FFFFFFF); // rgba(255,255,255,.12)
  static const skyline = Color(0x12FFFFFF); // rgba(255,255,255,.07)
  static const tagLine = Color(0xFF4ADE80);
  static const badgeRed = Color(0xFFF43F5E);
  static const badgeGreen = Color(0xFF22C55E);
  static const badgeRing = Color(0xFF13306E);
  static const logoRing = Color(0x59FFFFFF); // rgba(255,255,255,.35)
  static const glass = Color(0x29FFFFFF); // rgba(255,255,255,.16)
  static const glassBorder = Color(0x47FFFFFF); // rgba(255,255,255,.28)
  static const blob = Color(0x1AFFFFFF); // rgba(255,255,255,.10)
  static const discoverSub = Color(0xFFE0E7FF);
  static const discoverGo = Color(0xFF4338CA);
  static const gloss = Color(0x38FFFFFF); // rgba(255,255,255,.22)
  static const glossEnd = Color(0x00FFFFFF);
  static const countPill = Color(0xFF4F46E5);
  static const missedDot = Color(0xFFEF4444);
  static const askSub = Color(0xFFDBE6FF);
  static const askEm = Color(0xFFBFD0F5);
  static const askBtnInk = Color(0xFF0F2A6B);
  static const askBtnIcon = Color(0xFF22C55E);
  static const askOnline = Color(0xFF22C55E);
  static const voiceGradient = [
    Color(0xFF0A84FF),
    Color(0xFF0EA5B7),
    Color(0xFF14C27A),
  ];
  static const voiceShadow = Color(0x590A84FF); // rgba(10,132,255,.35)

  /// Discover: one premium gradient per card (picked by the card key, so a
  /// card keeps its colour across sessions). First = the HTML's main card.
  static const discoverGradients = <List<Color>>[
    [Color(0xFF4338CA), Color(0xFF6D28D9), Color(0xFF9333EA)],
    [Color(0xFF0F766E), Color(0xFF0E7490), Color(0xFF0E7490)],
    [Color(0xFFBE123C), Color(0xFFDB2777), Color(0xFFF472B6)],
    [Color(0xFF1D4ED8), Color(0xFF2563EB), Color(0xFF0EA5E9)],
    [Color(0xFFB45309), Color(0xFFD97706), Color(0xFFF59E0B)],
    [Color(0xFF047857), Color(0xFF059669), Color(0xFF10B981)],
    [Color(0xFF334155), Color(0xFF1E3A8A), Color(0xFF4338CA)],
  ];

  /// Shortcut squircle gradients (145°) — the HTML's per-tile pairs, keyed
  /// by ChatNav route; [tileFallback] colours every other pinnable feature.
  static const tileGradients = <String, List<Color>>{
    'circle': [Color(0xFF6366F1), Color(0xFF4338CA)],
    'family': [Color(0xFFFB7185), Color(0xFFE11D48)],
    'journey': [Color(0xFF10B981), Color(0xFF047857)],
    'khata': [Color(0xFF0EA5E9), Color(0xFF0369A1)],
    'sales_agent': [Color(0xFFA855F7), Color(0xFF7E22CE)],
    'watchman': [Color(0xFF06B6D4), Color(0xFF0E7490)],
    'vehicle_tracking': [Color(0xFFF97316), Color(0xFFC2410C)],
    'jobs': [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
    'lost_stolen': [Color(0xFF475569), Color(0xFF1E293B)],
    'prepaid_meter': [Color(0xFFF59E0B), Color(0xFFB45309)],
    'budget': [Color(0xFF22C55E), Color(0xFF15803D)],
    'contract': [Color(0xFFEC4899), Color(0xFFBE185D)],
  };
  static const tileFallback = <List<Color>>[
    [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
    [Color(0xFF10B981), Color(0xFF047857)],
    [Color(0xFFF97316), Color(0xFFC2410C)],
    [Color(0xFFA855F7), Color(0xFF7E22CE)],
    [Color(0xFF0EA5E9), Color(0xFF0369A1)],
    [Color(0xFFEC4899), Color(0xFFBE185D)],
    [Color(0xFFF59E0B), Color(0xFFB45309)],
    [Color(0xFF06B6D4), Color(0xFF0E7490)],
  ];

  static List<Color> tileGradient(String route) {
    final g = tileGradients[route];
    if (g != null) return g;
    var h = 0;
    for (final c in route.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return tileFallback[h % tileFallback.length];
  }

  /// The seeded cards keep the order of the owner's mockup (Photo Studio
  /// violet, then Phone safety teal, ...); any other card hashes its key.
  static const _discoverSeed = <String, int>{
    'photo_enhance': 0,
    'phone_safety': 1,
    'journey': 5,
    'messages': 3,
    'used_phone_check': 6,
    'vehicles': 4,
    'security': 2,
    'plans': 0,
    'asalify': 4,
    'axon': 3,
  };

  static List<Color> discoverGradient(String key) {
    final seeded = _discoverSeed[key];
    if (seeded != null) return discoverGradients[seeded];
    var h = 0;
    for (final c in key.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return discoverGradients[h % discoverGradients.length];
  }
}
