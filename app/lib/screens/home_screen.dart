import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../updater.dart';
import '../state.dart';
import '../theme.dart';
import '../home_api.dart';
import '../l10n/app_localizations.dart';
import '../messaging/badges_bus.dart';
import '../widgets/chatnav.dart';
import '../widgets/home_badge_icon.dart';
import '../widgets/home_hero.dart';
import '../widgets/home_quick_buttons.dart';
import '../widgets/home_suggestions.dart';
import 'agent_thread_screen.dart';
import 'app_drawer.dart';
import 'assisto_chats_screen.dart';
import 'photo_studio_screen.dart';
import 'messenger/messenger_home_screen.dart';
// Built by another agent; imported by class name per the home spec.
import 'notification_centre_screen.dart';

/// The app is chat-first: the home is only the conversation. Everything else
/// lives in the left drawer (opened via the ☰ button). No bottom nav.
///
/// Top-right: My Circle (→ messenger) and a Bell (→ notification centre), each
/// with an unread/unseen badge polled from GET /home/badges on focus/resume.
/// A fresh chat shows dynamic, engine-ranked suggestion cards; running a card
/// sends the prompt (or navigates its route).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // Changing this key starts a fresh chat (New chat).
  Key _threadKey = UniqueKey();

  // Thread wiring: which saved home conversation to show, whether "New chat"
  // was pressed, and a tapped suggestion to send once the thread is ready.
  String? _openSessionId;
  bool _fresh = false;
  String? _pendingSend;

  // Fresh chat shows the suggestion cards; they hide once the user runs one.
  bool _showSuggestions = true;

  HomeBadges _badges = HomeBadges.empty;
  Future<void> Function()? _refreshSuggestions;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The Assisto AI chats page (also opened from the home quick shortcut via
    // ChatNav) reopens home chats / starts a new one here.
    HomeChatLink.register(onNew: _newChat, onOpen: _openHomeChat);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBadges());
    // b2-badges: re-fetch when a chat / the notification centre was opened
    // anywhere (drawer, notification tap) or the server pushed badges.update.
    BadgesBus.instance.tick.addListener(_onBadgesTick);
  }

  void _onBadgesTick() {
    if (mounted) _loadBadges();
  }

  @override
  void dispose() {
    HomeChatLink.unregister(_newChat);
    BadgesBus.instance.tick.removeListener(_onBadgesTick);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Same foreground-refresh pattern as alerts: poll when the app returns.
    if (state == AppLifecycleState.resumed) {
      _loadBadges();
      _refreshSuggestions?.call();
    }
  }

  Future<void> _loadBadges() async {
    final app = context.read<AppState>();
    if (!app.loggedIn) return;
    try {
      final b = await app.api.homeBadges();
      if (mounted) setState(() => _badges = b);
    } catch (_) {/* best-effort: offline/server down — keep last counts */}
  }

  // "New chat": a fresh, empty home thread (the old one stays in the Assisto
  // AI chats page) with the Discover cards + quick buttons back.
  void _newChat() => setState(() {
        _threadKey = UniqueKey();
        _openSessionId = null;
        _fresh = true;
        _pendingSend = null;
        _showSuggestions = true;
      });

  // Reopen a saved home conversation from the Assisto AI chats page.
  void _openHomeChat(String sessionId) => setState(() {
        _threadKey = UniqueKey();
        _openSessionId = sessionId;
        _fresh = false;
        _pendingSend = null;
        _showSuggestions = false;
      });

  // Run a tapped suggestion: route → navigate; else send it in the current
  // home thread (so it is saved like any typed message).
  Future<void> _runSuggestion(HomeSuggestion s) async {
    final route = s.route ?? ChatNav.detectRoute(s.sendText);
    if (ChatNav.push(context, route)) return;
    setState(() {
      _showSuggestions = false;
      _openSessionId = null;
      _fresh = false;
      _pendingSend = s.sendText;
      _threadKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      // A1 — explicit: the body shrinks for the keyboard so the input bar (at
      // the bottom of the thread) always sits directly above it.
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/branding/new_logo.png',
                width: 30, height: 30, fit: BoxFit.cover),
          ),
          const SizedBox(width: Gap.sm),
          // f1-design: app-bar titles are now a real 20 sp title style; the
          // name may shrink-ellipsize on very narrow / 200% text, never overflow.
          const Flexible(
            child: Text('Assisto',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
        // OWNER UI FIX: bell (notifications) to the LEFT, My Circle at the
        // far-right corner (its original place). actions render left→right, so
        // the bell comes first and My Circle last.
        actions: [
          // OWNER-REQUESTED home entry: one-tap "Enhance photo" opens Photo
          // Studio (owner-approved change, 21 Oct: the old tool is removed).
          IconButton(
            icon: const Icon(Icons.auto_fix_high_outlined),
            tooltip: t.b2PhotoStudioTitle,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PhotoStudioScreen()),
            ),
          ),
          HomeBadgeIcon(
            icon: Icons.notifications_outlined,
            count: _badges.notifUnseen,
            tooltip: t.homeNotifications,
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const NotificationCentreScreen()),
              );
              _loadBadges(); // refresh on return
            },
          ),
          HomeBadgeIcon(
            icon: Icons.diversity_3_outlined,
            count: _badges.myCircleUnread,
            tooltip: t.homeMyCircle,
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MessengerHomeScreen()),
              );
              _loadBadges(); // refresh on return
            },
          ),
          const SizedBox(width: Gap.xs),
        ],
      ),
      drawer: AppDrawer(onNewChat: _newChat, onOpenHomeChat: _openHomeChat),
      // Small in-chat new-chat action stays available on home.
      // rt1 (reality audit): endFloat put this FAB exactly over the input
      // bar's Send button, so tapping Send while typing started a NEW chat
      // and threw the typed message away. Same FAB, lifted above the bar.
      floatingActionButtonLocation: const _AboveInputBarFab(),
      floatingActionButton: _showSuggestions
          ? null
          : FloatingActionButton.small(
              tooltip: t.newChat,
              onPressed: _newChat,
              child: const Icon(Icons.add_comment_outlined),
            ),
      body: Column(children: [
        const _UpdateBanner(),
        if (_showSuggestions)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HomeSuggestions(
                    onRun: _runSuggestion,
                    onReady: (fn) => _refreshSuggestions = fn,
                  ),
                  // OWNER ORDER: 6 customizable one-tap shortcuts (hidden while
                  // the keyboard is open so the input is never pushed off-screen).
                  if (!keyboardOpen) ...[
                    const SizedBox(height: Gap.sm),
                    const HomeQuickBar(),
                  ],
                ]),
          )
        else if (!keyboardOpen)
          // During a conversation the shortcuts shrink to one chip row; hidden
          // while typing so the keyboard never covers the input.
          const Padding(
            padding: EdgeInsets.only(top: Gap.xs),
            child: HomeQuickBar(compact: true),
          ),
        Expanded(
          child: AgentThreadScreen(
            key: _threadKey,
            sessionId: _openSessionId,
            fresh: _fresh,
            initialSend: _pendingSend,
            // OWNER ORDER (h1-home): the welcome block (logo + "Hi, I'm
            // Assisto") is the hero slot — Free users may see ONE native ad
            // there instead (never Premium/Business, never over content);
            // it collapses on input focus and disappears once a chat starts.
            heroBuilder: (_, logoBlock, collapsed, height) => HomeHero(
                fallback: logoBlock,
                collapsed: collapsed || keyboardOpen,
                availableHeight: height),
            // A1 — collapse the Discover/spotlight area the moment the input
            // gains focus so the chat + input fill the screen and the keyboard
            // never covers what the user is typing.
            onInputFocus: () {
              if (_showSuggestions && mounted) {
                setState(() => _showSuggestions = false);
              }
            },
          ),
        ),
      ]),
    );
  }
}

/// endFloat, raised by the chat input bar's height (Gap.xs + 48 dp Send +
/// Gap.sm, plus a small gap) so the FAB never covers Send / mic / photo.
class _AboveInputBarFab extends StandardFabLocation
    with FabEndOffsetX, FabFloatOffsetY {
  const _AboveInputBarFab();
  static const double inputBarHeight = Gap.xs + 48 + Gap.sm + Gap.sm;

  @override
  double getOffsetY(
          ScaffoldPrelayoutGeometry scaffoldGeometry, double adjustment) =>
      super.getOffsetY(scaffoldGeometry, adjustment) - inputBarHeight;
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();
  @override
  Widget build(BuildContext context) {
    final up = context.watch<Updater>();
    if (up.available == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context);
    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.system_update,
                  color: scheme.onPrimaryContainer, size: 20),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.updateAvailable,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer)),
              ),
              if (!up.downloading)
                IconButton(
                    onPressed: up.dismiss,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close,
                        size: 18, color: scheme.onPrimaryContainer)),
            ]),
            if (up.downloading) ...[
              const SizedBox(height: Gap.xs),
              LinearProgressIndicator(
                  value: up.progress > 0 ? up.progress : null),
              const SizedBox(height: Gap.xs),
              Text('${(up.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onPrimaryContainer)),
            ] else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: up.downloadAndInstall,
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(t.update),
                ),
              ),
            if (up.error != null)
              Text('${up.error}',
                  style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
