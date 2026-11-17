import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'perf/low_ram.dart';

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
          : const Color(0xFF735A00); // designv2: AA 5.4 on the V2 background

  /// train-app: the "next station" yellow dot on the train timeline (its
  /// text uses [warnInk]; the dot has a warnInk ring for 3:1 on both themes).
  static Color nextStop(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFFFFC83D)
          : const Color(0xFFF2B000);

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
  // fcsos: SOS surfaces with white body text (7.0:1, WCAG AA); danger stays for icons
  static const sosRed = Color(0xFFB71C1C);
  static const info = Color(0xFF2F7BE5);

  /// Fill for destructive FILLED buttons/snackbars: white text on it is 5.6:1
  /// (Brand.danger is 4.0:1 with white, and with only a background set the
  /// dark theme drew its dark onPrimary text on it — ~2:1, QA qa1).
  static const dangerFill = Color(0xFFC62839);

  /// Fill for positive FILLED buttons (white text 5.3:1; Brand.success is
  /// 3.4:1 with white — below AA for button text).
  static const successFill = Color(0xFF1E7A50);
  // design3: Elderly home tile fills (white ink AAA at the tile sizes)
  static const elderPurple = Color(0xFF4A148C);
  static const elderTeal = Color(0xFF004D40);
  static const elderSlate = Color(0xFF37474F);

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

/// bizbar: ink for printed / PDF pages (the khata statement). Paper is
/// always white, so these never follow the app theme; every text tone is
/// >= 4.5:1 on [paper] and on [band].
class PrintInk {
  PrintInk._();
  static const paper = Color(0xFFFFFFFF);
  static const ink = Color(0xFF1B1B1F);
  static const muted = Color(0xFF5F5E66);
  static const line = Color(0xFFDADAE0);
  static const band = Color(0xFFF1F0F7);
  static const brand = Color(0xFF3D4BD6);
  static const gave = Color(0xFFB3261E);
  static const got = Color(0xFF1B7F3B);
  // invoices: thermal printers print pure black only
  static const thermal = Color(0xFF000000);
  static const shadow = Color(0x33000000);

  /// invdesign: print-safe A4 brand accents (every one >= 4.5:1 on white, so
  /// titles and table heads stay readable on cheap office printers). Keys
  /// mirror backend invoice_calc.ACCENTS.
  static const accents = <String, Color>{
    'brand': brand,
    'teal': Color(0xFF00575A),
    'green': Color(0xFF175C2C),
    'maroon': Color(0xFF7D1A2A),
    'navy': Color(0xFF1F3A68),
    'charcoal': Color(0xFF2F3237),
    'plum': Color(0xFF5E275E),
    'brown': Color(0xFF6B4019),
  };
  static Color accent(String key) => accents[key] ?? brand;
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

  /// The taka sign ৳ only (Hind Siliguri subset): Noto's ৳ reads as "b".
  static const taka = 'AssistoTaka';
  /// learnwire: Language Partner scripts (Arabic, pinyin tone vowels, the
  /// Chinese pack characters) — bundled so they never render as boxes.
  static const arabic = 'AssistoArabic';
  static const pinyin = 'AssistoPinyin';
  static const cjk = 'AssistoCjk';
  static const fallback = <String>[taka, bangla, pinyin, arabic, cjk];

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
    // designv2 (owner order 10 Nov 01:40): the owner-picked V2 palette —
    // the exact values live in [DsTokens]; the scheme maps them onto Material
    // roles. Text-role colours that missed WCAG AA by a hair are deepened /
    // lightened a few % (owner_actions/DESIGN_SYSTEM_V2_BN.md lists each).
    final v = isDark ? DsTokens.dark : DsTokens.light;
    final scheme = seeded.copyWith(
      primary: v.primaryInk,
      onPrimary: v.onPrimary,
      primaryContainer: v.primarySoft,
      onPrimaryContainer: v.text,
      secondary: isDark ? Brand.cyan : const Color(0xFF0E7F94),
      secondaryContainer: v.primarySoft,
      onSecondaryContainer: v.text,
      tertiary: v.successInk,
      // dark: the danger fill (#F0525A) is 4.1:1 as text on a card — the
      // error role is also text, so dark uses the danger ink (buttons use dangerFill)
      error: isDark ? v.dangerInk : v.dangerFill,
      onError: isDark ? v.card : v.onDangerFill,
      errorContainer: v.dangerBg,
      onErrorContainer: v.dangerInk,
      surface: v.bg,
      onSurface: v.text,
      onSurfaceVariant: v.muted,
      surfaceContainerLowest: v.card,
      surfaceContainerLow: v.card,
      surfaceContainer: v.cardAlt,
      surfaceContainerHigh: v.cardHigh,
      surfaceContainerHighest: v.cardHighest,
      outline: isDark ? const Color(0xFF7D8DAD) : const Color(0xFF6F82A6),
      outlineVariant: v.border,
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
      extensions: [
        isDark ? AssistoTokens.dark : AssistoTokens.light,
        isDark ? DsTokens.dark : DsTokens.light,
      ],
    );
    final t = base.textTheme;
    final rMd = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md));
    // designv2: buttons are radius 8 (cards 12).
    final rBtn = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DsRadius.button));
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
      // designv2: "alive" cards — white (dark: #1C2A47), radius 12, a soft
      // brand-tinted Material shadow (one cheap rrect shadow; DsCard draws
      // the owner's full two-layer shadow + top highlight).
      cardTheme: CardThemeData(
        elevation: DsPerf.lite ? 1 : 2,
        shadowColor: v.shadowTint,
        margin: EdgeInsets.zero,
        color: v.card,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DsRadius.card),
          side: BorderSide(color: v.border.withValues(alpha: isDark ? 1 : 0.7)),
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
        backgroundColor: v.card,
        indicatorColor: v.primarySoft,
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
        backgroundColor: v.card,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: v.inputFill,
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
          shape: rBtn,
          textStyle: t.labelLarge?.copyWith(fontSize: 15),
          animationDuration: Motion.fast,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(kMinTap, kMinTap),
          padding: btnPad,
          shape: rBtn,
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
          shape: rBtn,
          side: BorderSide(color: scheme.outline),
          textStyle: t.labelLarge,
          animationDuration: Motion.fast,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(kMinTap, kMinTap),
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          shape: rBtn,
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
        backgroundColor: v.card,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: v.card,
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
        backgroundColor: v.card,
        surfaceTintColor: Colors.transparent,
        elevation: Elev.high,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.xl)),
        titleTextStyle: t.headlineSmall?.copyWith(color: scheme.onSurface),
        contentTextStyle:
            t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: v.card,
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
    required this.circleSub,
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

  /// Pinned My Circle subtitle (owner 26 Oct): purple, >= 4.5:1 on its tile.
  final Color circleSub;
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
    body: Color(0xFFDFEAFE) /* designv2 bg */,
    sectionTitle: Color(0xFF0F1A2E),
    dotOff: Color(0xFFCBD5E1),
    dotOn: Color(0xFF0A84FF),
    tile: Colors.white,
    tileBorder: Color(0xFFC1D3F5),
    tileShadow: Color(0x1A2563EB), // designv2 rgba(37,99,235,.10)
    tileLabel: Color(0xFF0F1A2E),
    circleSub: Color(0xFF800080),
    pinBorder: Color(0xFFA5B4FC),
    pinTop: Color(0xFFEEF2FF),
    chip: Colors.white,
    chipBorder: Color(0xFFC1D3F5),
    chipInk: Color(0xFF0F1A2E),
    askGradient: [Color(0xFF0B2560), Color(0xFF1D4ED8), Color(0xFF3B82F6)],
    askShadow: Color(0x471D4ED8), // rgba(29,78,216,.28)
    nav: Colors.white,
    navBorder: Color(0xFFC1D3F5),
    navInk: Color(0xFF576780),
    navActive: Color(0xFF1D4ED8),
    voiceRing: Colors.white,
    voiceLabel: Color(0xFF0F1A2E),
    missedRing: Colors.white,
    discoverShadow: Color(0x4D4F46E5), // rgba(79,70,229,.30)
  );

  static const darkSet = HomeV2Palette._(
    dark: true,
    headerGradient: [Color(0xFF060F29), Color(0xFF0D2252), Color(0xFF173F96)],
    body: Color(0xFF111A2E) /* designv2 bg */,
    sectionTitle: Color(0xFFEEF3FF),
    dotOff: Color(0xFF334155),
    dotOn: Color(0xFF4DA3FF),
    tile: Color(0xFF1C2A47),
    tileBorder: Color(0xFF2A3B61),
    tileShadow: Color(0x33000000),
    tileLabel: Color(0xFFEEF3FF),
    circleSub: Color(0xFFE08AE0),
    pinBorder: Color(0xFF6366F1),
    pinTop: Color(0xFF1E1B4B),
    chip: Color(0xFF1C2A47),
    chipBorder: Color(0xFF2A3B61),
    chipInk: Color(0xFFEEF3FF),
    askGradient: [Color(0xFF0A1F52), Color(0xFF1A44BE), Color(0xFF2F6FE0)],
    askShadow: Color(0x40000000),
    nav: Color(0xFF1C2A47),
    navBorder: Color(0xFF2A3B61),
    navInk: Color(0xFF93A3C0),
    navActive: Color(0xFF7CB4FF),
    voiceRing: Color(0xFF1C2A47),
    voiceLabel: Color(0xFFEEF3FF),
    missedRing: Color(0xFF1C2A47),
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
    // homeshort (owner 28 Oct): the new default shortcuts
    'crm': [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
    'business': [Color(0xFF22C55E), Color(0xFF15803D)],
    'emergency': [Color(0xFFEF4444), Color(0xFFB91C1C)],
    'money': [Color(0xFF14B8A6), Color(0xFF0F766E)],
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


/// p3life: fixed artwork palettes for the Bangla invitation cards (the card
/// is an image people share, so it looks the same in light and dark).
class InviteCardColors {
  InviteCardColors._();
  static const roseBg = Color(0xFF6D0F2A), roseBg2 = Color(0xFF9B1B3F), roseAccent = Color(0xFFF3C969);
  static const holudBg = Color(0xFFFFE082), holudBg2 = Color(0xFFFFC107), holudInk = Color(0xFF1B3A12), holudAccent = Color(0xFF2E7D32);
  static const classicBg = Color(0xFFFFFBF2), classicBg2 = Color(0xFFF1E6CF), classicInk = Color(0xFF14213D), classicAccent = Color(0xFF9C6B12);
}


// ===========================================================================
// designv2 — Design System V2 (owner order 10 Nov 01:40). The ONE source of
// truth for the premium look: colours (light + dark), radii, shadows, motion
// budget. Components live in lib/ds/ (DsCard, DsHeroCard, DsTile, DsButton…);
// owner doc: owner_actions/DESIGN_SYSTEM_V2_BN.md.
// ===========================================================================

/// Radii: cards & tiles 12, buttons 8, chips pill, sheets 24.
class DsRadius {
  DsRadius._();
  static const card = 12.0;
  static const button = 8.0;
  static const chip = 999.0;
  static const sheet = 24.0;
  static const small = 8.0;
}

/// Performance budget for decoration + motion. "Lite" = low-RAM phone
/// (Android isLowRamDevice or ≤ 3 GB), or the system / in-app reduce-motion
/// switch (Android battery saver on most phones sets the animator scale to 0,
/// which Flutter reports as disableAnimations). Lite → one small shadow, no
/// glow, no pulse, no press animation.
class DsPerf {
  DsPerf._();

  /// Test / diag override (null = follow the device).
  static bool? debugLite;

  /// Lite = the cheap look: one small static shadow, no glow, no top
  /// highlight, no press lift, no looping animation. On for tests, low-RAM
  /// phones (≤ 3.25 GB, common Mali/PowerVR GPUs in Bangladesh), emulators /
  /// software GPUs (b323: swiftshader died under the full look), and on
  /// Android until the device probe has answered (first-run screens draw
  /// cheap on the very first frames).
  static bool get lite =>
      debugLite ??
      (_underTest ||
          LowRamTuning.lowRam ||
          LowRamTuning.emulator ||
          (_android && !LowRamTuning.probed) ||
          (LowRamTuning.ramMb > 0 && LowRamTuning.ramMb <= 3328));

  static final bool _android = () {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }();

  /// Widget tests run still (no endless pulse → pumpAndSettle settles);
  /// a test that checks the motion sets [debugLite] = false.
  static final bool _underTest = () {
    try {
      return Platform.environment['FLUTTER_TEST'] == 'true';
    } catch (_) {
      return false;
    }
  }();

  static bool liteOf(BuildContext context) =>
      lite || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
}

/// Motion tokens (V2).
class DsMotion {
  DsMotion._();
  static const press = Duration(milliseconds: 120);
  static const pulse = Duration(milliseconds: 2000);
  static const curve = Curves.easeOutCubic;
  static const lift = 2.0; // cards and tiles lift 2 px on press
}

/// The owner's V2 palette. Exact owner values are marked "owner"; text roles
/// adjusted for WCAG AA are marked "AA".
@immutable
/// designv2: the V2 tokens from any ColorScheme (no BuildContext needed) —
/// `scheme.ds.muted`. Same light/dark sets DsTokens.of falls back to.
extension DsSchemeTokens on ColorScheme {
  DsTokens get ds => brightness == Brightness.dark ? DsTokens.dark : DsTokens.light;
}

class DsTokens extends ThemeExtension<DsTokens> {
  const DsTokens({
    required this.isDark,
    required this.bg,
    required this.card,
    required this.cardAlt,
    required this.cardHigh,
    required this.cardHighest,
    required this.inputFill,
    required this.text,
    required this.muted,
    required this.border,
    required this.primary,
    required this.primaryInk,
    required this.onPrimary,
    required this.primarySoft,
    required this.success,
    required this.successInk,
    required this.successBg,
    required this.danger,
    required this.dangerInk,
    required this.dangerBg,
    required this.dangerBorder,
    required this.dangerFill,
    required this.onDangerFill,
    required this.heroTop,
    required this.heroBottom,
    required this.dangerHero,
    required this.onDangerHero,
    required this.onDangerHeroSoft,
    required this.highlight,
    required this.shadowTint,
    required this.shadows,
    required this.pressedShadows,
    required this.liteShadows,
    required this.primaryGlow,
    required this.dangerGlow,
  });

  final bool isDark;
  final Color bg, card, cardAlt, cardHigh, cardHighest, inputFill;
  final Color text, muted, border;
  final Color primary, primaryInk, onPrimary, primarySoft;
  final Color success, successInk, successBg;
  final Color danger, dangerInk, dangerBg, dangerBorder, dangerFill, onDangerFill;
  final Color heroTop, heroBottom;
  final List<Color> dangerHero;
  final Color onDangerHero, onDangerHeroSoft;
  final Color highlight, shadowTint;
  final List<BoxShadow> shadows, pressedShadows, liteShadows;
  final List<BoxShadow> primaryGlow, dangerGlow;

  static const light = DsTokens(
    isDark: false,
    bg: Color(0xFFDFEAFE), // owner
    card: Color(0xFFFFFFFF), // owner
    cardAlt: Color(0xFFF2F7FF), // owner (hero gradient end)
    cardHigh: Color(0xFFEAF1FF),
    cardHighest: Color(0xFFE8F0FE), // AA: muted 5.0, primary ink 4.8 on it
    inputFill: Color(0xFFF2F7FF),
    text: Color(0xFF0F1A2E), // owner
    muted: Color(0xFF576780), // AA (owner #5B6B85: 4.46:1 on the background)
    border: Color(0xFFC1D3F5), // owner
    primary: Color(0xFF2563EB), // owner (fills, glow)
    primaryInk: Color(0xFF1F55CF), // AA as text on the background (5.3:1) and on tinted panels (≥ 4.7:1)
    onPrimary: Color(0xFFFFFFFF),
    primarySoft: Color(0xFFE6EEFF),
    success: Color(0xFF2F9E6E), // owner (dots, icons, fills)
    successInk: Color(0xFF216F4D), // AA as text on #E4F5EC
    successBg: Color(0xFFE4F5EC), // owner
    danger: Color(0xFFE5484D), // owner (dots, icons, glow)
    dangerInk: Color(0xFFB8373C), // AA as text on #FFF1F1 and the background
    dangerBg: Color(0xFFFFF1F1), // owner
    dangerBorder: Color(0xFFF6C5C7),
    dangerFill: Color(0xFFB8373C), // AA: white text 5.75:1
    onDangerFill: Color(0xFFFFFFFF),
    heroTop: Color(0xFFFFFFFF), // owner: white → #F2F7FF
    heroBottom: Color(0xFFF2F7FF),
    dangerHero: [Color(0xFFC93F44), Color(0xFFA7303A)], // white text ≥ 4.9:1
    onDangerHero: Color(0xFFFFFFFF),
    onDangerHeroSoft: Color(0xFFFFE3E4),
    highlight: Color(0xFFFFFFFF), // owner: 1 px white top highlight
    shadowTint: Color(0x592563EB),
    shadows: [
      BoxShadow(color: Color(0x1A2563EB), offset: Offset(0, 4), blurRadius: 10), // owner .10
      BoxShadow(color: Color(0x2E2563EB), offset: Offset(0, 16), blurRadius: 32), // owner .18
    ],
    pressedShadows: [
      BoxShadow(color: Color(0x242563EB), offset: Offset(0, 6), blurRadius: 12),
      BoxShadow(color: Color(0x382563EB), offset: Offset(0, 18), blurRadius: 34),
    ],
    liteShadows: [
      BoxShadow(color: Color(0x262563EB), offset: Offset(0, 2), blurRadius: 6),
    ],
    primaryGlow: [
      BoxShadow(color: Color(0x592563EB), offset: Offset(0, 6), blurRadius: 16),
    ],
    dangerGlow: [
      BoxShadow(color: Color(0x59E5484D), offset: Offset(0, 6), blurRadius: 16),
    ],
  );

  static const dark = DsTokens(
    isDark: true,
    bg: Color(0xFF111A2E), // owner
    card: Color(0xFF1C2A47), // owner
    cardAlt: Color(0xFF18243F),
    cardHigh: Color(0xFF22314F),
    cardHighest: Color(0xFF21304E), // AA: muted 5.2, primary ink 5.1 on it
    inputFill: Color(0xFF16223B),
    text: Color(0xFFEEF3FF), // owner
    muted: Color(0xFF93A3C0), // owner
    border: Color(0xFF2A3B61), // owner
    primary: Color(0xFF3B82F6), // owner (fills, glow)
    primaryInk: Color(0xFF6CA1F8), // AA as text on the card (5.5:1)
    onPrimary: Color(0xFF0B1530),
    primarySoft: Color(0xFF1F3257),
    success: Color(0xFF3DD68C), // owner
    successInk: Color(0xFF3DD68C), // owner (6.5:1 on the card)
    successBg: Color(0xFF0F3A2A),
    danger: Color(0xFFFF7A80), // owner danger text
    dangerInk: Color(0xFFFF7A80), // owner
    dangerBg: Color(0xFF3A1A22), // owner danger card
    dangerBorder: Color(0xFF4A2430), // owner
    dangerFill: Color(0xFFF0525A), // owner danger button
    onDangerFill: Color(0xFF2A0A0E), // AA: 5.3:1 on #F0525A
    heroTop: Color(0xFF1C2A47), // owner: card → background
    heroBottom: Color(0xFF111A2E),
    dangerHero: [Color(0xFFA7303A), Color(0xFF6E1C27)],
    onDangerHero: Color(0xFFFFFFFF),
    onDangerHeroSoft: Color(0xFFFFE3E4),
    highlight: Color(0x14FFFFFF), // owner rgba(255,255,255,.08)
    shadowTint: Color(0x993B82F6),
    shadows: [
      BoxShadow(color: Color(0x473B82F6), offset: Offset(0, 8), blurRadius: 24), // owner .28
    ],
    pressedShadows: [
      BoxShadow(color: Color(0x5C3B82F6), offset: Offset(0, 10), blurRadius: 28),
    ],
    liteShadows: [
      BoxShadow(color: Color(0x40000000), offset: Offset(0, 2), blurRadius: 6),
    ],
    primaryGlow: [
      BoxShadow(color: Color(0x663B82F6), offset: Offset(0, 6), blurRadius: 18),
    ],
    dangerGlow: [
      BoxShadow(color: Color(0x66F0525A), offset: Offset(0, 6), blurRadius: 18),
    ],
  );

  static DsTokens of(BuildContext context) =>
      Theme.of(context).extension<DsTokens>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  DsTokens copyWith() => this;

  @override
  DsTokens lerp(DsTokens? other, double t) =>
      other == null ? this : (t < 0.5 ? this : other);
}
