import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'bubble_ask.dart';
import 'msg_native.dart';

/// bubbles2 (owner FINAL bubbles order, points 6–8) — the ONE
/// "Turn on floating chat bubbles?" card, used by:
///  * the install-day step ([BubbleOnboardingScreen], right after the
///    Android 13+ notification permission — one permission per screen);
///  * the "Later" re-asks at My Circle ([maybeAskBubblesAtCircle]);
///  * My Circle settings and a chat's ⋮ "Show as bubble" ([showBubbleCard]).
///
/// "Turn on" opens Assisto's exact Bubbles page; when the user comes back we
/// re-check and show "Floating chat bubbles are on." — or an honest line
/// (only picked chats / not yet / the phone blocks bubbles / notifications
/// off). No company names anywhere (point 7).
class BubbleTurnOnCard extends StatefulWidget {
  const BubbleTurnOnCard({
    super.key,
    required this.onDone,
    this.initial,
    this.openSettings,
    this.readStatus,
  });

  /// Called with true after the success line was shown (Continue), false on
  /// "Later".
  final void Function(bool turnedOn) onDone;

  /// Test / gallery seams.
  final BubbleStatus? initial;
  final Future<bool> Function()? openSettings;
  final Future<BubbleStatus> Function()? readStatus;

  @override
  State<BubbleTurnOnCard> createState() => _BubbleTurnOnCardState();
}

class _BubbleTurnOnCardState extends State<BubbleTurnOnCard>
    with WidgetsBindingObserver {
  BubbleStatus? _st;
  bool _wentToSettings = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _st = widget.initial;
    if (_st == null) unawaited(_recheck());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // back from the system Bubbles page → re-check at once
    if (state == AppLifecycleState.resumed && _wentToSettings) {
      unawaited(_recheck());
    }
  }

  Future<void> _recheck() async {
    if (_checking) return;
    _checking = true;
    try {
      final s = await (widget.readStatus ?? BubbleAsk.status)();
      if (mounted) setState(() => _st = s);
    } finally {
      _checking = false;
    }
  }

  Future<void> _turnOn() async {
    final ready = _st?.ready;
    if (ready == BubbleReady.notifsOff) {
      // bubbles come from notifications: the notification page first
      await Notifications.openSettings();
    } else {
      await (widget.openSettings ?? MsgNative.openBubbleSettings)();
    }
    if (mounted) setState(() => _wentToSettings = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ready = _st?.ready ?? BubbleReady.unknown;
    final on = ready == BubbleReady.on;
    final blocked = ready == BubbleReady.blocked;

    String? note;
    if (blocked) {
      note = t.bbl2Blocked;
    } else if (ready == BubbleReady.notifsOff) {
      note = t.bbl2NotifsOff;
    } else if (_wentToSettings && ready == BubbleReady.selectedOnly) {
      note = t.bbl2SelectedOnly;
    } else if (_wentToSettings && !on) {
      note = _st?.phoneOn == false ? t.bbl2PhoneSwitch : t.bbl2NotYet;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: BubbleIllustration()),
        const SizedBox(height: Gap.xl),
        Semantics(
          header: true,
          child: Text(t.bbl2Title,
              key: const Key('bbl2-title'),
              textAlign: TextAlign.center,
              style: AType.headlineSmall.copyWith(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
        ),
        const SizedBox(height: Gap.md),
        Text(t.bbl2Body,
            textAlign: TextAlign.center,
            style: AType.bodyLarge.copyWith(color: scheme.onSurfaceVariant)),
        if (!on && !blocked && ready != BubbleReady.notifsOff) ...[
          const SizedBox(height: Gap.md),
          Text(t.bbl2How,
              key: const Key('bbl2-how'),
              textAlign: TextAlign.center,
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: Gap.xl),
        if (on)
          Semantics(
            liveRegion: true,
            child: Container(
              key: const Key('bbl2-success'),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(children: [
                Icon(Icons.check_circle_rounded,
                    color: scheme.onPrimaryContainer),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.bbl2On,
                      style: AType.titleMedium.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          )
        else if (note != null)
          Semantics(
            liveRegion: true,
            child: Container(
              key: const Key('bbl2-note'),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(note,
                      style: AType.bodyMedium.copyWith(color: scheme.onSurface)),
                ),
              ]),
            ),
          ),
        const SizedBox(height: Gap.lg),
        if (on || blocked)
          FilledButton(
            key: const Key('bbl2-continue'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => widget.onDone(on),
            child: Text(t.bbl2Continue),
          )
        else ...[
          FilledButton(
            key: const Key('bbl2-turn-on'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _turnOn,
            child: Text(t.bbl2TurnOn),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            key: const Key('bbl2-later'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => widget.onDone(false),
            child: Text(t.bbl2Later),
          ),
        ],
      ],
    );
  }
}

/// A plain drawing of what a bubble looks like: a phone edge with round
/// "photo" circles (generic person icons — never a made-up person or name).
class BubbleIllustration extends StatelessWidget {
  const BubbleIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget dot(double size, IconData icon) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: Brand.gradient,
            border: Border.all(color: scheme.surface, width: 3),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))
            ],
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.5),
        );
    return ExcludeSemantics(
      child: SizedBox(
        width: 180,
        height: 132,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: 20,
            top: 0,
            bottom: 0,
            child: Container(
              width: 110,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: scheme.outlineVariant, width: 2),
              ),
            ),
          ),
          Positioned(right: 4, top: 10, child: dot(64, Icons.person_rounded)),
          Positioned(
            right: 44,
            top: 62,
            child: dot(46, Icons.chat_bubble_rounded),
          ),
          Positioned(
            right: 2,
            top: 8,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: scheme.error,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The install-day step as its own screen (one permission per screen).
class BubbleOnboardingScreen extends StatelessWidget {
  const BubbleOnboardingScreen({super.key, this.initial});
  final BubbleStatus? initial;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: withNavBarInset(
                  context, const EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.xl, Gap.xl)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: BubbleTurnOnCard(
                  initial: initial,
                  onDone: (_) => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
        ),
      );
}

/// The card in a sheet (My Circle re-asks, settings, a chat's ⋮ menu).
/// Returns true when bubbles ended up on.
Future<bool> showBubbleCard(BuildContext context, {BubbleStatus? initial}) async {
  final r = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SingleChildScrollView(
      padding: withNavBarInset(
          ctx, const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl)),
      child: BubbleTurnOnCard(
        initial: initial,
        onDone: (on) => Navigator.of(ctx).pop(on),
      ),
    ),
  );
  return r ?? false;
}

/// Point 6: the "Later" re-asks — the first My Circle open, then once after
/// 3 days, never again. Never over another route; crash-guarded.
Future<void> maybeAskBubblesAtCircle(BuildContext context) async {
  try {
    if (!await BubbleAsk.due(BubbleAskWhere.circleOpen)) return;
    if (!context.mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    await BubbleAsk.markAsked(BubbleAskWhere.circleOpen);
    if (!context.mounted) return;
    await showBubbleCard(context);
  } catch (_) {}
}

/// Point 6: the install-day step, pushed right after the notification
/// permission (RingCheckGate's `then`). Android 10 and below, a phone that
/// blocks bubbles, notifications off or already on → nothing (silently).
Future<void> maybeAskBubblesOnInstallDay(NavigatorState nav) async {
  try {
    if (!await BubbleAsk.due(BubbleAskWhere.onboarding)) return;
    if (!nav.mounted) return;
    await BubbleAsk.markAsked(BubbleAskWhere.onboarding);
    await nav.push(MaterialPageRoute(
        settings: const RouteSettings(name: 'bubbles_install_day'),
        builder: (_) => const BubbleOnboardingScreen()));
  } catch (_) {}
}
