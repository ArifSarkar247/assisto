import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'home_v2_tokens.dart';

/// ASK ASSISTO card (owner reference .ask): blue gradient, the real logo in a
/// white box with the green "online" dot, Need help? / Ask Assisto /
/// Chat | Guide | Solve, and the white Chat pill with the green icon. The
/// whole card (and the pill) opens the Assisto AI chat screen.
///
/// Large font: above 1.3x the pill moves under the text (nothing clipped).
class HomeV2AskCard extends StatelessWidget {
  final VoidCallback onOpen;
  const HomeV2AskCard({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = HomeV2Palette.of(context);
    final (begin, end) = HV2.cssAngle(HV2.discoverAngleDeg);
    final radius = BorderRadius.circular(HV2.askRadius);
    final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;

    final bot = Container(
      width: HV2.bot,
      height: HV2.bot,
      decoration: BoxDecoration(
        color: HomeV2Palette.onColor,
        borderRadius: BorderRadius.circular(HV2.botRadius),
        boxShadow: const [
          BoxShadow(color: HomeV2Palette.glass, spreadRadius: HV2.botRing),
        ],
      ),
      child: Stack(clipBehavior: Clip.none, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(HV2.botRadius),
          child: Image.asset('assets/branding/new_logo.png',
              width: HV2.bot, height: HV2.bot, fit: BoxFit.cover),
        ),
        Positioned(
          right: 1,
          bottom: 3,
          child: Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: HomeV2Palette.askOnline,
              shape: BoxShape.circle,
              border: Border.all(color: HomeV2Palette.onColor, width: 2),
            ),
          ),
        ),
      ]),
    );

    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(t.hv2AskTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: HomeV2Palette.onColor,
                fontSize: HV2.askTitle,
                height: 1.3,
                fontWeight: FontWeight.w700)),
        Text(t.hv2AskSub,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: HomeV2Palette.askSub,
                fontSize: HV2.askSub,
                height: 1.35)),
        Text(t.hv2AskEm,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: HomeV2Palette.askEm, fontSize: HV2.askEm, height: 1.35)),
      ],
    );

    final pill = Container(
      key: const ValueKey('hv2_ask_btn'),
      constraints: const BoxConstraints(minHeight: HV2.askBtnH),
      padding: const EdgeInsetsDirectional.fromSTEB(7, 4, 13, 4),
      decoration: BoxDecoration(
        color: HomeV2Palette.onColor,
        borderRadius: BorderRadius.circular(HV2.askBtnH / 2),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: HV2.askBtnIcon,
          height: HV2.askBtnIcon,
          decoration: const BoxDecoration(
              color: HomeV2Palette.askBtnIcon, shape: BoxShape.circle),
          child: const Icon(Icons.chat_bubble_outline_rounded,
              size: 14, color: HomeV2Palette.onColor),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(t.hv2AskBtn,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: HomeV2Palette.askBtnInk,
                  fontSize: HV2.askBtnFont,
                  fontWeight: FontWeight.w700)),
        ),
      ]),
    );

    return Semantics(
      button: true,
      label: t.hv2AskA11y,
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
              begin: begin,
              end: end,
              colors: p.askGradient,
              stops: const [0, 0.65, 1]),
          boxShadow: [
            BoxShadow(
                color: p.askShadow, blurRadius: 22, offset: const Offset(0, 10)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('hv2_ask'),
            borderRadius: radius,
            onTap: onOpen,
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(children: [
                Positioned(
                  right: -50,
                  top: -80,
                  child: Container(
                    width: HV2.blobAsk,
                    height: HV2.blobAsk,
                    decoration: const BoxDecoration(
                        color: HomeV2Palette.blob, shape: BoxShape.circle),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(HV2.askPad),
                  child: stacked
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              bot,
                              const SizedBox(width: HV2.askGap),
                              Expanded(child: texts),
                            ]),
                            const SizedBox(height: HV2.askGap),
                            pill,
                          ])
                      : Row(children: [
                          bot,
                          const SizedBox(width: HV2.askGap),
                          Expanded(child: texts),
                          const SizedBox(width: HV2.askGap),
                          pill,
                        ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
