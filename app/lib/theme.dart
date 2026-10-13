import 'package:flutter/material.dart';

/// Assisto design system.
///
/// Brand comes straight from the logo: a navy field, a gold hand, a cyan brain.
/// Everything else (spacing, radius, type, motion) is derived from these tokens
/// so every screen feels like one app.
class Brand {
  Brand._();

  // Core brand colours — sampled from the logo (cyan → blue → purple on black).
  static const cyan = Color(0xFF22D3EE); // sparkle / highlight
  static const blue = Color(0xFF3B6EF6); // primary
  static const blueDeep = Color(0xFF2347D9); // pressed / deep primary
  static const purple = Color(0xFF9B4DF0); // tertiary / gradient tail
  static const ink = Color(0xFF05060A); // logo black (splash/hero bg)

  // Back-compat aliases (older code referenced navy/gold).
  static const navy = blue;
  static const gold = cyan;

  // Semantic
  static const success = Color(0xFF2E9E6B);
  static const warning = Color(0xFFE0A500);
  static const danger = Color(0xFFE0485A);

  // Brand gradient (login / splash / hero surfaces / logo tint)
  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [cyan, blue, purple],
  );

  // Dark hero backdrop gradient (splash / login behind the logo).
  static const heroDark = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0A0C14), ink],
  );
}

/// 8-pt spacing scale. Use these instead of magic numbers.
class Gap {
  Gap._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Corner radii.
class Radii {
  Radii._();
  static const xs = 4.0;
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const pill = 999.0;
}

/// Motion durations — short, purposeful.
class Motion {
  Motion._();
  static const fast = Duration(milliseconds: 150);
  static const base = Duration(milliseconds: 250);
  static const slow = Duration(milliseconds: 400);
}

class AssistoTheme {
  AssistoTheme._();

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: Brand.blue,
      brightness: brightness,
    ).copyWith(
      // Brand across both modes: blue primary, cyan highlight, purple accent.
      // Lightened in dark mode for AA contrast on dark surfaces.
      primary: isDark ? const Color(0xFF6FA0FF) : Brand.blue,
      secondary: isDark ? Brand.cyan : const Color(0xFF0E9FB8),
      tertiary: isDark ? const Color(0xFFC08BFF) : Brand.purple,
      error: Brand.danger,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'NotoSansBengali',
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 66,
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        elevation: 2,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(
          base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          textStyle: base.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
        titleLarge: base.textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
        titleMedium: base.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600, height: 1.35),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.45),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
      ),
    );
  }
}
