import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../feature_flags.dart' show FeatureFlags;
import '../../home_api.dart';
import '../../messaging/badges_bus.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/chatnav.dart';
import '../../widgets/circle_badges.dart';
import '../../widgets/home_hero.dart';
import '../../widgets/home_suggestions.dart';
import '../app_drawer.dart';
import '../assisto_chats_screen.dart' show HomeChatLink;
import '../home_screen.dart';
import '../messenger/messenger_home_screen.dart';
import '../notification_centre_screen.dart';
import '../photo_studio_screen.dart';
import 'all_services_screen.dart';
import 'assisto_chat_screen.dart';
import 'home_v2_ask_card.dart';
import 'home_v2_bottom_bar.dart';
import 'home_v2_header.dart';
import 'home_v2_shortcuts.dart';
import 'home_v2_tokens.dart';

/// Which home to show: the `home_v2` flag from the CACHED flag set (no
/// network wait). OFF = the previous [HomeScreen], unchanged.
Widget selectHome({bool? v2}) =>
    (v2 ?? FeatureFlags.instance.isOn('home_v2'))
        ? const HomeV2Screen()
        : const HomeScreen();

/// HOME v2 — the owner's final home design (26 Oct, owner_actions/design/
/// assisto_home_v6.png + home_v6_bn.html), behind the `home_v2` feature flag
/// (OFF = the previous [HomeScreen], unchanged).
///
/// Top to bottom: header (menu -> the existing sidebar, logo, Photo Studio,
/// Notifications + My Circle with their badges, greeting, tags), Discover
/// (the same server-driven system, restyled), 12 shortcuts (My Circle pinned
/// + 11, one Edit button), ONE native ad for Free users only, the Ask Assisto
/// card (opens the AI chat, which now has its own screen), and the bottom bar
/// with the raised Assisto Voice button. No chat input / new-chat FAB here.
///
/// First paint needs no network: flags, Discover cards and shortcuts come
/// from the on-device cache; badges / cards refresh in the background.
class HomeV2Screen extends StatefulWidget {
  /// Gallery / test seams (never set in the app).
  final DateTime? debugNow;
  final List<String>? debugRoutes;
  final CircleBadgeState? debugCircle;
  final HomeBadges? debugBadges;
  const HomeV2Screen(
      {super.key,
      this.debugNow,
      this.debugRoutes,
      this.debugCircle,
      this.debugBadges});

  @override
  State<HomeV2Screen> createState() => _HomeV2ScreenState();
}

class _HomeV2ScreenState extends State<HomeV2Screen>
    with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _scroll = ScrollController();
  late HomeBadges _badges = widget.debugBadges ?? HomeBadges.empty;
  Future<void> Function()? _refreshDiscover;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The chats page (drawer / History) reopens home chats or starts a new
    // one: on v2 that means the Assisto AI chat screen.
    HomeChatLink.register(onNew: _newChat, onOpen: _openHomeChat);
    if (widget.debugBadges == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadBadges());
    }
    BadgesBus.instance.tick.addListener(_onBadgesTick);
  }

  void _onBadgesTick() {
    if (mounted && widget.debugBadges == null) _loadBadges();
  }

  @override
  void dispose() {
    HomeChatLink.unregister(_newChat);
    BadgesBus.instance.tick.removeListener(_onBadgesTick);
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onBadgesTick();
      _refreshDiscover?.call();
    }
  }

  /// Same badge source and rules as the old home (GET /home/badges).
  Future<void> _loadBadges() async {
    final app = context.read<AppState>();
    if (!app.loggedIn) return;
    try {
      final b = await app.api.homeBadges();
      CircleBadges.instance.setUnread(b.myCircleUnread);
      if (mounted) setState(() => _badges = b);
    } catch (_) {/* offline: keep the last counts */}
    await CircleBadges.instance.refreshMissed(app.api);
  }

  Future<void> _openChat({String? sessionId, bool fresh = false}) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                AssistoChatScreen(sessionId: sessionId, fresh: fresh),
            settings: const RouteSettings(name: AssistoChatScreen.routeName)));
  }

  void _newChat() => _openChat(fresh: true);
  void _openHomeChat(String id) => _openChat(sessionId: id);

  Future<void> _push(Widget screen, {String? name}) async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => screen, settings: RouteSettings(name: name)));
    if (widget.debugBadges == null) _loadBadges();
  }

  void _toTop() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: Motion.slow, curve: Motion.curve);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = HomeV2Palette.of(context);
    final app = context.watch<AppState>();
    final circleUnread =
        widget.debugCircle?.unread ?? _badges.myCircleUnread;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        key: _scaffold,
        extendBody: true,
        backgroundColor: p.body,
        drawer: AppDrawer(
            onNewChat: _newChat,
            onOpenHomeChat: _openHomeChat,
            debugCircle: widget.debugCircle),
        bottomNavigationBar: HomeV2BottomBar(
          onHome: _toTop,
          onAllServices: () => _push(AllServicesScreen(onOpenChat: _newChatOrResume),
              name: 'all_services'),
          onVoice: () => ChatNav.push(context, 'voice_assistant'),
          onReminders: () => ChatNav.push(context, 'reminders'),
          onBusiness: () => ChatNav.push(context, 'business'),
        ),
        body: Builder(builder: (context) {
          // Scaffold.extendBody reports the whole bar (incl. the transparent
          // strip under the raised voice button) as bottom padding.
          final bottom = MediaQuery.paddingOf(context).bottom;
          final askBottom = bottom - HV2.voiceLift + 12;
          return CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Stack(children: [
                  HomeV2Header(
                    firstName: hv2FirstName(app.user?.name),
                    notifUnseen: _badges.notifUnseen,
                    circleUnread: circleUnread,
                    now: widget.debugNow,
                    bottomPad:
                        HV2.headerPadBottom - (HV2.bodyOverlap - HV2.pagePad),
                    onMenu: () => _scaffold.currentState?.openDrawer(),
                    onPhotoStudio: () =>
                        _push(const PhotoStudioScreen(), name: 'photo_studio'),
                    onNotifications: () => _push(
                        const NotificationCentreScreen(),
                        name: 'notifications'),
                    onCircle: () => _push(const MessengerHomeScreen(),
                        name: 'circle'),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: HV2.pagePad,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        maxHeight: HV2.bodyRadius * 2,
                        child: Container(
                          height: HV2.bodyRadius * 2,
                          decoration: BoxDecoration(
                            color: p.body,
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(HV2.bodyRadius)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: HV2.pagePad),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    HomeSuggestions(
                      v2: true,
                      onReady: (fn) => _refreshDiscover = fn,
                    ),
                    const SizedBox(height: HV2.sectionGap - 8),
                    HomeV2ShortcutsSection(
                        debugRoutes: widget.debugRoutes,
                        debugCircle: widget.debugCircle),
                    // Free users only (server plan check in HeroAdRules), at
                    // most ONE native ad on home, labelled "Ad", never in the
                    // bottom bar. Renders nothing for Premium / Business.
                    const HomeHero(
                        key: ValueKey('hv2_ad_slot'),
                        fallback: SizedBox.shrink(),
                        gapWhenShown: HV2.sectionGap,
                        availableHeight: HV2.adSlot),
                  ]),
                ),
              ),
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      HV2.pagePad,
                      HV2.sectionGap,
                      HV2.pagePad,
                      askBottom > 12 ? askBottom : 12),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: HomeV2AskCard(onOpen: _newChatOrResume),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  /// Ask Assisto: open the AI chat on the remembered conversation (the same
  /// thread the old home showed), so nothing the user was doing is lost.
  void _newChatOrResume() => _openChat();
}
