import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

// insets (owner real-phone test 28 Oct): the vehicle "Add tracker" sheet's
// main button sat BEHIND the phone's navigation bar and could not be tapped.
//
// Root cause: the app draws edge-to-edge (Flutter's default on Android; Android
// 15 enforces it for targetSdk 35+), so a modal bottom sheet reaches the very
// bottom of the screen, under the 3-button / gesture navigation bar. Flutter's
// `useSafeArea: true` only guards the TOP and the sides
// (`SafeArea(bottom: false)`), and most sheets padded only for the keyboard
// (`viewInsets.bottom`), never for the navigation bar (`viewPadding.bottom`).
//
// Fix: EVERY bottom sheet in the app opens through [showAppSheet], which wraps
// the content in [AppSheetInsets] — bottom padding = max(keyboard, nav bar),
// and the content then sees a MediaQuery with those bottom insets consumed so
// a sheet that still pads for the keyboard / wraps itself in SafeArea never
// pads twice. test/insets_guard_test.dart fails if a primary button is under
// the bar/keyboard; test/insets_lint_test.dart fails on a raw
// `showModalBottomSheet` outside this file.

/// The one way to open a modal bottom sheet in Assisto. Same parameters as
/// [showModalBottomSheet]; the sheet's content always stays above the system
/// navigation bar and the keyboard. `useSafeArea` defaults to true (status bar
/// / cut-outs when the sheet is tall).
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio = 9.0 / 16.0,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = true,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) {
  // ignore: assisto_raw_sheet — the shared helper itself
  return showModalBottomSheet<T>(
    context: context,
    builder: (ctx) => AppSheetInsets(child: builder(ctx)),
    backgroundColor: backgroundColor,
    barrierLabel: barrierLabel,
    elevation: elevation,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor,
    isScrollControlled: isScrollControlled,
    scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
    sheetAnimationStyle: sheetAnimationStyle,
    requestFocus: requestFocus,
  );
}

/// Keeps [child] above the navigation bar and the keyboard: pads the bottom by
/// max(keyboard, nav bar) and hands the child a MediaQuery whose bottom
/// padding / viewPadding / viewInsets are already consumed (no double
/// padding when the child also pads for the keyboard or uses SafeArea).
/// The sheet's own background still fills the area under the bar.
class AppSheetInsets extends StatelessWidget {
  const AppSheetInsets({super.key, required this.child});

  final Widget child;

  /// The bottom space the system takes right now (keyboard or nav bar).
  static double bottomOf(BuildContext context) {
    final mq = MediaQuery.of(context);
    return math.max(mq.viewInsets.bottom, mq.viewPadding.bottom);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottom = math.max(mq.viewInsets.bottom, mq.viewPadding.bottom);
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: MediaQuery(
        data: mq.copyWith(
          padding: mq.padding.copyWith(bottom: 0),
          viewPadding: mq.viewPadding.copyWith(bottom: 0),
          viewInsets: mq.viewInsets.copyWith(bottom: 0),
        ),
        child: child,
      ),
    );
  }
}

/// Sheet layout with a STICKY primary action: [child] scrolls (so 200% text
/// and a small screen never clip it) while [primary] stays pinned at the
/// bottom of the sheet, above the nav bar / keyboard (via [showAppSheet]).
class AppSheetBody extends StatelessWidget {
  const AppSheetBody({
    super.key,
    required this.child,
    this.primary,
    this.padding = const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
  });

  final Widget child;
  final Widget? primary;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final p = primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: p == null ? padding : padding.copyWith(bottom: Gap.sm),
            child: child,
          ),
        ),
        if (p != null)
          Padding(
            padding: EdgeInsets.fromLTRB(
                padding.left, Gap.sm, padding.right, Gap.md),
            child: p,
          ),
      ],
    );
  }
}

/// A sticky bottom action bar for full screens
/// (`Scaffold(bottomNavigationBar: AppStickyBar(child: FilledButton(...)))`):
/// always above the navigation bar, surface-coloured edge to edge.
class AppStickyBar extends StatelessWidget {
  const AppStickyBar({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
  });

  final Widget child;
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color ?? Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Padding for a full screen's scrolling body: [base] plus the bottom system
/// inset, so the last field / button of a form can be scrolled clear of the
/// navigation bar (a ListView with an explicit padding ignores it).
EdgeInsets withNavBarInset(BuildContext context, EdgeInsets base) =>
    base.copyWith(bottom: base.bottom + MediaQuery.paddingOf(context).bottom);
