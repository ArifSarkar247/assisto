import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'home_v2_tokens.dart';

/// NEW BOTTOM BAR (owner reference .nav): Home, All Services, the raised
/// centre Assisto Voice button (one tap = a voice conversation), Reminders,
/// Business. Never carries an ad. Labels shrink-to-fit in their fifth (at
/// most [HV2.navLabelMaxScale]), so 200 % font never clips or overflows.
class HomeV2BottomBar extends StatelessWidget {
  final VoidCallback onHome;
  final VoidCallback onAllServices;
  final VoidCallback onVoice;
  final VoidCallback onReminders;
  final VoidCallback onBusiness;
  const HomeV2BottomBar({
    super.key,
    required this.onHome,
    required this.onAllServices,
    required this.onVoice,
    required this.onReminders,
    required this.onBusiness,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = HomeV2Palette.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final scale = MediaQuery.textScalerOf(context)
        .scale(1)
        .clamp(1.0, HV2.navLabelMaxScale);
    final barH = HV2.navH + (scale - 1) * HV2.navLabel * 1.3;
    // The bar is [HV2.voiceLift] taller than its painted part: that strip is
    // transparent (the home scrolls behind it, Scaffold.extendBody) except
    // for the raised voice circle, which stays fully tappable.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: HV2.navLabelMaxScale,
      child: SizedBox(
        height: HV2.voiceLift + barH + bottom,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: barH + bottom,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: p.nav,
                border: Border(top: BorderSide(color: p.navBorder)),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottom,
            height: barH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Item(
                    key: const ValueKey('hv2_nav_home'),
                    icon: Icons.home_rounded,
                    label: t.hv2NavHome,
                    active: true,
                    onTap: onHome),
                _Item(
                    key: const ValueKey('hv2_nav_all'),
                    icon: Icons.grid_view_outlined,
                    label: t.hv2NavAll,
                    onTap: onAllServices),
                const Expanded(child: SizedBox.shrink()),
                _Item(
                    key: const ValueKey('hv2_nav_reminders'),
                    icon: Icons.alarm_rounded,
                    label: t.navReminders,
                    onTap: onReminders),
                _Item(
                    key: const ValueKey('hv2_nav_business'),
                    icon: Icons.storefront_outlined,
                    label: t.sidebarBusiness,
                    onTap: onBusiness),
              ],
            ),
          ),
          Positioned(
            top: 0,
            bottom: bottom,
            left: 0,
            right: 0,
            child: Row(children: [
              const Spacer(flex: 2),
              Expanded(child: _Voice(onTap: onVoice)),
              const Spacer(flex: 2),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Item({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = HomeV2Palette.of(context);
    final color = active ? p.navActive : p.navInk;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        excludeSemantics: true,
        child: InkResponse(
          onTap: onTap,
          containedInkWell: true,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: HV2.navIcon, color: color),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label,
                      maxLines: 1,
                      style: TextStyle(
                          color: color,
                          fontSize: HV2.navLabel,
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w500)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The raised centre Assisto Voice button: 58 dp gradient circle with a
/// 4 dp ring in the bar colour, lifted 26 dp above the bar.
class _Voice extends StatelessWidget {
  final VoidCallback onTap;
  const _Voice({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = HomeV2Palette.of(context);
    final (begin, end) = HV2.cssAngle(140);
    return Semantics(
      button: true,
      label: t.hv2VoiceA11y,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('hv2_voice'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(children: [
          Container(
            width: HV2.voice,
            height: HV2.voice,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                  begin: begin,
                  end: end,
                  colors: HomeV2Palette.voiceGradient,
                  stops: const [0, 0.55, 1]),
              border: Border.all(color: p.voiceRing, width: HV2.voiceRing),
              boxShadow: const [
                BoxShadow(
                    color: HomeV2Palette.voiceShadow,
                    blurRadius: 18,
                    offset: Offset(0, 8)),
              ],
            ),
            child: const Icon(Icons.mic_none_rounded,
                size: HV2.voiceIcon, color: HomeV2Palette.onColor),
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(t.hv2NavVoice,
                  maxLines: 1,
                  style: TextStyle(
                      color: p.voiceLabel,
                      fontSize: HV2.navLabel,
                      fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }
}
