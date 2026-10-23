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
    TextStyle s(double size, FontWeight w, double h, [double ls = 0]) =>
        TextStyle(
          fontFamily: AFonts.latin,
          fontFamilyFallback: AFonts.fallback,
          fontSize: size,
          fontWeight: w,
          height: h,
          letterSpacing: ls,
          leadingDistribution: TextLeadingDistribution.even,
          color: ink,
        );
    return TextTheme(
      displayLarge: s(40, FontWeight.w700, 1.35, -0.5),
      displayMedium: s(34, FontWeight.w700, 1.35, -0.4),
      displaySmall: s(30, FontWeight.w700, 1.35, -0.3),
      headlineLarge: s(28, FontWeight.w700, 1.35, -0.2),
      headlineMedium: s(26, FontWeight.w700, 1.35, -0.2),
      headlineSmall: s(22, FontWeight.w700, 1.4, -0.1),
      titleLarge: s(20, FontWeight.w700, 1.4),
      titleMedium: s(16, FontWeight.w600, 1.45),
      titleSmall: s(14, FontWeight.w600, 1.45),
      bodyLarge: s(16, FontWeight.w400, 1.5),
      bodyMedium: s(14, FontWeight.w400, 1.5),
      bodySmall: s(12, FontWeight.w400, 1.5), // caption
      labelLarge: s(14, FontWeight.w600, 1.45),
      labelMedium: s(12, FontWeight.w600, 1.45),
      labelSmall: s(11, FontWeight.w500, 1.45, 0.2),
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
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(kMinTap, kMinTap),
          animationDuration: Motion.fast,
        ),
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
