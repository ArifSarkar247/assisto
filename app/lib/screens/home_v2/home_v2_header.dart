import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/circle_badges.dart';
import 'home_v2_tokens.dart';

/// The five greeting windows (owner feedback 27 Oct), by the DEVICE's local
/// hour: [05,12) morning, [12,16) noon, [16,18) afternoon, [18,22) evening,
/// [22,05) late night.
enum Hv2Daypart { morning, noon, afternoon, evening, night }

Hv2Daypart hv2Daypart(DateTime now) {
  final h = now.toLocal().hour;
  if (h >= 5 && h < 12) return Hv2Daypart.morning;
  if (h >= 12 && h < 16) return Hv2Daypart.noon;
  if (h >= 16 && h < 18) return Hv2Daypart.afternoon;
  if (h >= 18 && h < 22) return Hv2Daypart.evening;
  return Hv2Daypart.night;
}

/// Greeting word(s) by time of day (Bangla: shubho shokal / dupur / bikal /
/// shondha / ratri); English: Good morning / afternoon / afternoon / evening, and
/// "Hello, still up" late at night. (Root cause of "Good evening" at 2 AM:
/// the night string was "Good evening" in English and 21:00 started night.)
String hv2Greeting(AppLocalizations t, DateTime now) =>
    switch (hv2Daypart(now)) {
      Hv2Daypart.morning => t.hv2GreetMorning,
      Hv2Daypart.noon => t.hv2GreetNoon,
      Hv2Daypart.afternoon => t.hv2GreetAfternoon,
      Hv2Daypart.evening => t.hv2GreetEvening,
      Hv2Daypart.night => t.hv2GreetLate,
    };

/// The full header line: "Good morning, Rahim!" — late at night English
/// reads "Hello Rahim, still up?" (bn: the good-night greeting + name).
String hv2GreetingLine(AppLocalizations t, DateTime now, String? name) {
  if (hv2Daypart(now) == Hv2Daypart.night) {
    return name == null ? t.hv2GreetLatePlain : t.hv2GreetLateName(name);
  }
  final greet = hv2Greeting(t, now);
  return name == null ? t.hv2GreetPlain(greet) : t.hv2GreetName(greet, name);
}

/// The user's first name (first word of the profile name), or null.
String? hv2FirstName(String? name) {
  final n = (name ?? '').trim();
  if (n.isEmpty) return null;
  final first = n.split(RegExp(r'\s+')).first;
  // a phone number is not a name
  if (RegExp(r'^[+0-9]').hasMatch(first)) return null;
  return first;
}

/// HEADER (owner reference .hdr): navy gradient with the faint skyline, the
/// menu button (opens the existing sidebar), the real logo + "Assisto", Photo
/// Studio, Notifications (unseen badge) and My Circle (unread badge), then
/// the time-of-day greeting with the first name, the tagline and the three
/// tilted tags. Its bottom 18 dp is covered by the body's rounded top.
class HomeV2Header extends StatelessWidget {
  final String? firstName;
  final int notifUnseen;
  final int circleUnread;
  final VoidCallback onMenu;
  final VoidCallback onPhotoStudio;
  final VoidCallback onNotifications;
  final VoidCallback onCircle;

  /// Test / gallery seam for the greeting clock.
  final DateTime? now;

  /// Space under the greeting (the body's rounded top covers part of it).
  final double bottomPad;

  const HomeV2Header({
    super.key,
    required this.firstName,
    required this.notifUnseen,
    required this.circleUnread,
    required this.onMenu,
    required this.onPhotoStudio,
    required this.onNotifications,
    required this.onCircle,
    this.now,
    this.bottomPad = HV2.headerPadBottom,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = HomeV2Palette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final (begin, end) = HV2.cssAngle(HV2.headerAngleDeg);
    final title = hv2GreetingLine(t, now ?? DateTime.now(), firstName);
    final circleLabel = circleBadgeLabel(circleUnread, t.localeName);
    final notifLabel = circleBadgeLabel(notifUnseen, t.localeName);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: begin,
            end: end,
            colors: p.headerGradient,
            stops: HV2.headerStops),
      ),
      child: Stack(children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: HV2.skylineH,
          child: const ExcludeSemantics(
              child: CustomPaint(painter: _SkylinePainter())),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(HV2.headerPadSide,
              top + HV2.headerPadTop - 3, HV2.headerPadSide, bottomPad),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  _GlassButton(
                    key: const ValueKey('hv2_menu'),
                    icon: Icons.menu_rounded,
                    label: t.hv2MenuA11y,
                    onTap: onMenu,
                  ),
                  const SizedBox(width: 2),
                  ExcludeSemantics(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(HV2.logoRadius),
                        boxShadow: const [
                          BoxShadow(
                              color: HomeV2Palette.logoRing, spreadRadius: 1.5),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(HV2.logoRadius),
                        child: Image.asset('assets/branding/new_logo.png',
                            width: HV2.logo,
                            height: HV2.logo,
                            fit: BoxFit.cover),
                      ),
                    ),
                  ),
                  const SizedBox(width: HV2.barGap),
                  Expanded(
                    // the wordmark is part of the logo: it shrinks to fit
                    // beside the four buttons instead of being cut off
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: const Text('Assisto',
                          maxLines: 1,
                          style: TextStyle(
                              color: HomeV2Palette.onColor,
                              fontSize: HV2.brandSize,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2)),
                    ),
                  ),
                  _GlassButton(
                    key: const ValueKey('hv2_photo'),
                    icon: Icons.auto_fix_high_outlined,
                    label: t.b2PhotoStudioTitle,
                    onTap: onPhotoStudio,
                  ),
                  _GlassButton(
                    key: const ValueKey('hv2_notif'),
                    icon: Icons.notifications_none_rounded,
                    label: notifUnseen > 0
                        ? t.hv2NotifA11y(notifLabel)
                        : t.homeNotifications,
                    tooltip: t.homeNotifications,
                    onTap: onNotifications,
                    badge: notifUnseen > 0 ? notifLabel : null,
                    badgeColor: HomeV2Palette.badgeRed,
                  ),
                  _GlassButton(
                    key: const ValueKey('hv2_circle'),
                    icon: Icons.diversity_3,
                    label: circleUnread > 0
                        ? '${t.homeMyCircle}. ${t.hcUnread(circleLabel)}'
                        : t.homeMyCircle,
                    tooltip: t.homeMyCircle,
                    onTap: onCircle,
                    badge: circleUnread > 0 ? circleLabel : null,
                    badgeColor: HomeV2Palette.badgeGreen,
                  ),
                ]),
                const SizedBox(height: HV2.greetTop - 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HV2.greetSide),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(title,
                                      key: const ValueKey('hv2_greeting'),
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: HomeV2Palette.onColor,
                                          fontSize: HV2.greetSize,
                                          height: 1.3,
                                          fontWeight: FontWeight.w700)),
                                ),
                                Text(t.hv2Tagline,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: HomeV2Palette.headerSoft,
                                        fontSize: HV2.taglineSize,
                                        height: 1.35)),
                              ]),
                        ),
                        const SizedBox(width: HV2.barGap),
                        const _Tags(),
                      ]),
                ),
              ]),
        ),
      ]),
    );
  }
}

/// The three tilted tags + green underline (decorative brand line: capped
/// at 1.3x so it never pushes the greeting; read once by TalkBack).
class _Tags extends StatelessWidget {
  const _Tags();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    const style = TextStyle(
        color: HomeV2Palette.onColor,
        fontSize: HV2.tagsSize,
        height: 1.25,
        fontWeight: FontWeight.w700,
        fontStyle: FontStyle.italic);
    return Semantics(
      label: '${t.hv2TagSmarter}, ${t.hv2TagSafer}, ${t.hv2TagEasier}',
      excludeSemantics: true,
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Transform.rotate(
          angle: HV2.tagsTilt * math.pi / 180,
          child: Padding(
            padding: EdgeInsets.zero,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(t.hv2TagSmarter, style: style, maxLines: 1),
                  Text(t.hv2TagSafer, style: style, maxLines: 1),
                  Text(t.hv2TagEasier, style: style, maxLines: 1),
                  const SizedBox(height: 3),
                  Container(
                    width: HV2.tagUnderlineW,
                    height: HV2.tagUnderlineH,
                    decoration: BoxDecoration(
                      color: HomeV2Palette.tagLine,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ]),
          ),
        ),
      ),
    );
  }
}

/// A 42 dp translucent round header button inside a 48 dp touch target,
/// with an optional count badge (top-right, ringed in header navy).
class _GlassButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback onTap;
  final String? badge;
  final Color badgeColor;
  const _GlassButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
    this.badge,
    this.badgeColor = HomeV2Palette.badgeRed,
  });

  @override
  Widget build(BuildContext context) {
    final b = badge;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip ?? label,
        excludeFromSemantics: true,
        child: InkResponse(
          onTap: onTap,
          radius: HV2.iconBtnTap / 2,
          child: SizedBox(
            width: HV2.iconBtnTap,
            height: HV2.iconBtnTap,
            child: Center(
              child: Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: HV2.iconBtn,
                  height: HV2.iconBtn,
                  decoration: const BoxDecoration(
                      color: HomeV2Palette.headerGlass, shape: BoxShape.circle),
                  child: Icon(icon,
                      size: HV2.iconSize, color: HomeV2Palette.onColor),
                ),
                if (b != null)
                  Positioned(
                    top: 2 - 4,
                    right: -2,
                    child: MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.2,
                      child: Container(
                        constraints: const BoxConstraints(
                            minWidth: HV2.badgeSize, minHeight: HV2.badgeSize),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: badgeColor,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                              color: HomeV2Palette.badgeRing, width: 2),
                        ),
                        child: Text(b,
                            style: const TextStyle(
                                color: HomeV2Palette.onColor,
                                fontSize: HV2.badgeFont,
                                height: 1,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The faint skyline along the header's bottom edge (the reference SVG path,
/// 390 x 64, scaled to the real width).
class _SkylinePainter extends CustomPainter {
  const _SkylinePainter();

  static const _shapes = <List<double>>[
    [0, 64, 0, 40, 22, 40, 22, 30, 38, 30, 38, 40, 50, 40, 50, 22, 68, 22, 68, 40, 78, 40, 78, 34, 92, 34, 92, 64],
    [100, 64, 100, 26, 120, 26, 120, 14, 134, 14, 134, 26, 146, 26, 146, 36, 164, 36, 164, 20, 180, 20, 180, 64],
    [200, 64, 200, 30, 214, 30, 214, 18, 234, 18, 234, 30, 246, 30, 246, 8, 262, 8, 262, 30, 276, 30, 276, 38, 294, 38, 294, 64],
    [310, 64, 310, 34, 326, 34, 326, 22, 344, 22, 344, 34, 356, 34, 356, 28, 372, 28, 372, 36, 390, 36, 390, 64],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / HV2.skylineW;
    final sy = size.height / HV2.skylineH;
    final paint = Paint()..color = HomeV2Palette.skyline;
    for (final pts in _shapes) {
      final path = Path()..moveTo(pts[0] * sx, pts[1] * sy);
      for (var i = 2; i < pts.length; i += 2) {
        path.lineTo(pts[i] * sx, pts[i + 1] * sy);
      }
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SkylinePainter old) => false;
}
