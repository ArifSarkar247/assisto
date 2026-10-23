import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/paywall_sheet.dart';
import 'app_open_gate.dart';
import 'sponsor_api.dart';
import 'sponsor_models.dart';

/// p2-money: DIRECT sponsor UI — our own server-served creatives (works
/// without AdMob). Every surface carries a clear "Sponsored" label, a
/// "Why am I seeing this?" sheet and hide / mute-brand controls. Free users
/// only (the server never serves a paid user); never on safety, payment,
/// login or call screens (the server and [AppOpenGate] both refuse).

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

SponsorBackend sponsorBackendOf(BuildContext context) =>
    ApiSponsorBackend(context.read<AppState>().api);

Future<void> openSponsorLink(SponsorCreative c) async {
  if (!c.hasLink) return;
  try {
    await launchUrl(Uri.parse(c.url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

class SponsoredLabel extends StatelessWidget {
  const SponsoredLabel({super.key, this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      decoration: BoxDecoration(
        color: onDark ? Colors.black.withValues(alpha: 0.55) : scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(t.p2Sponsored,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: onDark ? Colors.white : scheme.onTertiaryContainer)),
    );
  }
}

/// "Why am I seeing this?" — the server's honest reasons + hide / mute.
class SponsorWhySheet extends StatelessWidget {
  const SponsorWhySheet({super.key, required this.creative, this.onHide, this.onMute});
  final SponsorCreative creative;
  final VoidCallback? onHide;
  final VoidCallback? onMute;

  static Future<void> show(BuildContext context, SponsorCreative c,
          {VoidCallback? onHide, VoidCallback? onMute}) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => SponsorWhySheet(creative: c, onHide: onHide, onMute: onMute),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lines = creative.why(_bn(context));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.p2WhyTitle, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(t.p2AdBy(creative.sponsor),
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.check_circle_outline, size: 18, color: scheme.primary),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text(l, style: const TextStyle(height: 1.35))),
                ]),
              ),
            const SizedBox(height: Gap.sm),
            if (onHide != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.visibility_off_outlined),
                title: Text(t.p2HideAd),
                onTap: () {
                  Navigator.pop(context);
                  onHide!();
                },
              ),
            if (onMute != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block_outlined),
                title: Text(t.p2MuteBrand(creative.sponsor)),
                onTap: () {
                  Navigator.pop(context);
                  onMute!();
                },
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.workspace_premium_outlined),
              title: Text(t.p2RemoveAds),
              onTap: () {
                Navigator.pop(context);
                PaywallSheet.show(context, PaywallReason.adFree);
              },
            ),
          ],
        ),
      ),
    );
  }
}

Widget _creativeImage(SponsorCreative c, {double? height, BoxFit fit = BoxFit.cover}) {
  if (c.imageUrl.isEmpty) return const SizedBox.shrink();
  return Image.network(c.imageUrl,
      height: height,
      width: double.infinity,
      fit: fit,
      errorBuilder: (_, __, ___) => const SizedBox.shrink());
}

// ------------------------------------------------------------ app open
/// FULL-SCREEN sponsor card shown on app open / resume (Free users, from day
/// 2, max N a day). The Skip button works after [skipAfterS] (owner: 5 s);
/// before that it shows the countdown. Back also works only after the
/// countdown, so the card can't be skipped by accident — and nothing on it
/// is placed where a stray tap lands on the sponsor link (the link is a
/// separate, clearly labelled button).
class SponsorAppOpenScreen extends StatefulWidget {
  const SponsorAppOpenScreen({
    super.key,
    required this.creative,
    this.skipAfterS = 5,
    this.backend,
    this.autoTick = true,
  });

  final SponsorCreative creative;
  final int skipAfterS;
  final SponsorBackend? backend;

  /// Tests drive the countdown by hand.
  final bool autoTick;

  static Future<void> show(BuildContext context, SponsorCreative c,
          {int skipAfterS = 5, SponsorBackend? backend}) =>
      push(Navigator.of(context), c, skipAfterS: skipAfterS, backend: backend);

  /// From outside the widget tree (AdsService uses the app navigator key).
  static Future<void> push(NavigatorState nav, SponsorCreative c,
      {int skipAfterS = 5, SponsorBackend? backend}) {
    return nav.push(PageRouteBuilder<void>(
      opaque: true,
      fullscreenDialog: true,
      settings: const RouteSettings(name: 'sponsor_app_open'),
      pageBuilder: (_, __, ___) =>
          SponsorAppOpenScreen(creative: c, skipAfterS: skipAfterS, backend: backend),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  State<SponsorAppOpenScreen> createState() => SponsorAppOpenScreenState();
}

class SponsorAppOpenScreenState extends State<SponsorAppOpenScreen> {
  late final SkipCountdown countdown = SkipCountdown(widget.skipAfterS);
  Timer? _timer;
  bool _counted = false;

  SponsorBackend? get _backend {
    try {
      return widget.backend ?? sponsorBackendOf(context);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoTick) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_counted || !mounted) return;
      _counted = true;
      unawaited(_backend?.event(widget.creative.token, 'impression'));
    });
  }

  @visibleForTesting
  void tick() {
    if (!mounted) return;
    if (countdown.tick()) setState(() {});
    if (countdown.canSkip) _timer?.cancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _close() {
    if (countdown.canSkip) Navigator.of(context).maybePop();
  }

  Future<void> _open() async {
    unawaited(_backend?.event(widget.creative.token, 'click'));
    await openSponsorLink(widget.creative);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final c = widget.creative;
    final bn = _bn(context);
    final cta = c.cta(bn).isNotEmpty ? c.cta(bn) : t.p2Learn;
    return PopScope(
      canPop: countdown.canSkip,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const SponsoredLabel(),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(c.sponsor,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
                Semantics(
                  button: true,
                  enabled: countdown.canSkip,
                  child: OutlinedButton.icon(
                    key: const Key('p2-skip'),
                    onPressed: countdown.canSkip ? _close : null,
                    icon: Icon(countdown.canSkip ? Icons.close : Icons.timer_outlined,
                        size: 18),
                    label: Text(countdown.canSkip
                        ? t.p2Skip
                        : t.p2SkipIn('${countdown.remaining}')),
                  ),
                ),
              ]),
              const SizedBox(height: Gap.lg),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.lg),
                  child: Container(
                    color: scheme.surfaceContainerHighest,
                    child: c.imageUrl.isEmpty
                        ? Center(
                            child: Icon(Icons.local_offer_outlined,
                                size: 72, color: scheme.primary))
                        : _creativeImage(c, fit: BoxFit.contain),
                  ),
                ),
              ),
              const SizedBox(height: Gap.lg),
              Text(c.title(bn),
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              if (c.body(bn).isNotEmpty) ...[
                const SizedBox(height: Gap.sm),
                Text(c.body(bn),
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
              ],
              const SizedBox(height: Gap.lg),
              if (c.hasLink)
                FilledButton.icon(
                  key: const Key('p2-cta'),
                  onPressed: _open,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(cta),
                ),
              const SizedBox(height: Gap.sm),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: Gap.sm,
                children: [
                  TextButton(
                    onPressed: () => SponsorWhySheet.show(context, c),
                    child: Text(t.p2WhyAd),
                  ),
                  TextButton(
                    onPressed: () =>
                        PaywallSheet.show(context, PaywallReason.adFree),
                    child: Text(t.p2RemoveAds),
                  ),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ post card
/// A Telegram-style "Sponsored" post (end of a large community / channel,
/// the offers feed, the home hero slot).
class SponsoredPostCard extends StatelessWidget {
  const SponsoredPostCard({
    super.key,
    required this.creative,
    this.onHide,
    this.onMute,
    this.onClick,
    this.compactImage = false,
    this.footer,
  });

  final SponsorCreative creative;
  final VoidCallback? onHide;
  final VoidCallback? onMute;
  final VoidCallback? onClick;
  final bool compactImage;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bn = _bn(context);
    final c = creative;
    final cta = c.cta(bn).isNotEmpty ? c.cta(bn) : t.p2Learn;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 0),
          child: Row(children: [
            const SponsoredLabel(),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(c.sponsor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (c.matchesYou)
              Padding(
                padding: const EdgeInsets.only(right: Gap.xs),
                child: Text(t.p2OffersForYou,
                    style: TextStyle(fontSize: 12, color: scheme.primary)),
              ),
            IconButton(
              tooltip: t.p2WhyAd,
              icon: const Icon(Icons.more_horiz),
              onPressed: () =>
                  SponsorWhySheet.show(context, c, onHide: onHide, onMute: onMute),
            ),
          ]),
        ),
        if (c.imageUrl.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: _creativeImage(c, height: compactImage ? 120 : 180),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
          child: Text(c.title(bn),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        ),
        if (c.body(bn).isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
            child: Text(c.body(bn),
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
          ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
            child: footer!,
          ),
        if (c.hasLink)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
            child: OutlinedButton.icon(
              onPressed: () async {
                onClick?.call();
                await openSponsorLink(c);
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(cta),
            ),
          )
        else
          const SizedBox(height: Gap.md),
      ]),
    );
  }
}

/// The Sponsored post slot at the END of a community / channel. Asks the
/// server (which checks: Free user, member/follower count >= the owner's
/// threshold, not your own community, daily cap); renders nothing otherwise.
class SponsoredPostSlot extends StatefulWidget {
  const SponsoredPostSlot({
    super.key,
    required this.ctxKind,
    required this.ctxId,
    this.backend,
  });

  /// 'channel' | 'community'
  final String ctxKind;
  final int ctxId;
  final SponsorBackend? backend;

  @override
  State<SponsoredPostSlot> createState() => _SponsoredPostSlotState();
}

class _SponsoredPostSlotState extends State<SponsoredPostSlot> {
  SponsorCreative? _c;
  bool _hidden = false;

  SponsorBackend? get _backend {
    try {
      return widget.backend ?? sponsorBackendOf(context);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final b = _backend;
    if (b == null) return;
    try {
      final s = await b.slot('community_post',
          screen: widget.ctxKind, ctxKind: widget.ctxKind, ctxId: widget.ctxId);
      if (!mounted || !s.isDirect) return;
      // AdMob native fill for this slot binds with the native-ad bridge once
      // AdMob is linked; until then an empty slot simply shows nothing.
      setState(() => _c = s.creative);
      unawaited(b.event(s.creative!.token, 'impression'));
    } catch (_) {}
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || _hidden) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    return SponsoredPostCard(
      creative: c,
      onClick: () => unawaited(_backend?.event(c.token, 'click')),
      onHide: () {
        unawaited(_backend?.event(c.token, 'hide'));
        setState(() => _hidden = true);
        _snack(t.p2AdHidden);
      },
      onMute: () {
        unawaited(_backend?.event(c.token, 'mute'));
        setState(() => _hidden = true);
        _snack(t.p2BrandMuted(c.sponsor));
      },
    );
  }
}

/// The home HERO slot filled by a DIRECT sponsor (same slot as the AdMob
/// native ad; "Sponsored" label above, fixed height so it never grows into
/// the chat or the input).
class SponsorHeroCard extends StatelessWidget {
  const SponsorHeroCard({super.key, required this.creative, required this.height, this.onClick});
  final SponsorCreative creative;
  final double height;
  final VoidCallback? onClick;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bn = _bn(context);
    final c = creative;
    return Semantics(
      container: true,
      label: t.p2Sponsored,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const SponsoredLabel(),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(c.sponsor,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: t.p2WhyAd,
            icon: const Icon(Icons.info_outline, size: 18),
            onPressed: () => SponsorWhySheet.show(context, c),
          ),
        ]),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: SizedBox(
            height: height,
            child: Material(
              color: scheme.surfaceContainerHighest,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (c.imageUrl.isNotEmpty)
                  Expanded(child: _creativeImage(c))
                else
                  const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(c.title(bn),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (c.body(bn).isNotEmpty)
                          Text(c.body(bn),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                    if (c.hasLink) ...[
                      const SizedBox(width: Gap.sm),
                      FilledButton.tonal(
                        onPressed: () async {
                          onClick?.call();
                          await openSponsorLink(c);
                        },
                        child: Text(c.cta(bn).isNotEmpty ? c.cta(bn) : t.p2Learn),
                      ),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
