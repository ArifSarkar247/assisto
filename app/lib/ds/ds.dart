// designv2 — Design System V2: import this one file in a screen.
// Tokens (colours, radii, motion, perf budget): lib/theme.dart
// (DsTokens, DsRadius, DsMotion, DsPerf, Gap, AType). One input style, tabs,
// dialogs, bottom nav and sheets come from the theme (AssistoTheme) — sheets
// always open through showAppSheet (lib/widgets/app_sheet.dart).
export '../theme.dart' show DsTokens, DsSchemeTokens, DsRadius, DsMotion, DsPerf, Gap, kMinTap, AType;
export '../widgets/app_sheet.dart' show showAppSheet;
export 'ds_controls.dart';
export 'ds_feedback.dart';
export 'ds_surfaces.dart';
