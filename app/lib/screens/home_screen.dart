import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../updater.dart';
import '../state.dart';
import '../theme.dart';
import '../home_api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/chatnav.dart';
import '../widgets/home_badge_icon.dart';
import '../widgets/home_suggestions.dart';
import 'agent_thread_screen.dart';
import 'app_drawer.dart';
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

  // When set, the thread renders a seeded exchange (a run suggestion). null =>
  // live chat / welcome.
  List<Map<String, dynamic>>? _seed;

  // Fresh chat shows the suggestion cards; they hide once the user runs one.
  bool _showSuggestions = true;

  HomeBadges _badges = HomeBadges.empty;
  Future<void> Function()? _refreshSuggestions;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBadges());
  }

  @override
  void dispose() {
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
    } catch (_) {/* offline/server down — keep last counts */}
  }

  // A fresh chat: show the dynamic suggestion cards, and seed the thread with a
  // single greeting bubble so AgentThreadScreen's built-in welcome (which still
  // carries hard-coded cards we must not duplicate) never renders.
  List<Map<String, dynamic>> _greetingSeed() => [
        {'user': false, 'text': AppLocalizations.of(context).welcomeHeadline},
      ];

  void _newChat() => setState(() {
        _threadKey = UniqueKey();
        _seed = _greetingSeed();
        _showSuggestions = true;
      });

  // Run a tapped suggestion: route → navigate; else send to the agent and show
  // the resulting exchange in a fresh thread. Never touches AgentThreadScreen's
  // internals — it just re-seeds the home-owned thread.
  Future<void> _runSuggestion(HomeSuggestion s) async {
    // 1) Explicit engine route, or a local route the text maps to.
    final route = s.route ?? ChatNav.detectRoute(s.sendText);
    if (ChatNav.push(context, route)) return;

    // 2) Otherwise send to the agent; the backend may still return a route.
    final app = context.read<AppState>();
    final text = s.sendText;
    final seed = <Map<String, dynamic>>[
      {'user': true, 'text': text},
    ];
    setState(() {
      _showSuggestions = false;
      _seed = seed;
      _threadKey = UniqueKey();
    });
    try {
      final r = await app.api.agent(text);
      if (!mounted) return;
      if (ChatNav.push(context, r['route'] as String?)) return;
      final cards = ((r['cards'] ?? []) as List).cast<Map<String, dynamic>>();
      setState(() {
        _seed = [
          ...seed,
          {'user': false, 'text': r['reply'] ?? '', 'cards': cards},
        ];
        _threadKey = UniqueKey();
      });
      app.reminders.sync();
      app.txns.sync();
      app.loans.sync();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _seed = [
          ...seed,
          {'user': false, 'text': AppLocalizations.of(context).sendFailed},
        ];
        _threadKey = UniqueKey();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    // Seed the greeting on the first build (localizations are ready here) so
    // the thread's built-in welcome — with its hard-coded cards — never shows.
    _seed ??= _greetingSeed();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/branding/new_logo.png',
                width: 30, height: 30, fit: BoxFit.cover),
          ),
          const SizedBox(width: Gap.sm),
          const Text('Assisto', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        // OWNER UI FIX: bell (notifications) to the LEFT, My Circle at the
        // far-right corner (its original place). actions render left→right, so
        // the bell comes first and My Circle last.
        actions: [
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
      drawer: AppDrawer(onNewChat: _newChat),
      // Small in-chat new-chat action stays available on home.
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
            child: HomeSuggestions(
              onRun: _runSuggestion,
              onReady: (fn) => _refreshSuggestions = fn,
            ),
          ),
        Expanded(
          child: AgentThreadScreen(key: _threadKey, debugSeed: _seed),
        ),
      ]),
    );
  }
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
              Icon(Icons.system_update, color: scheme.onPrimaryContainer, size: 20),
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
                    icon: Icon(Icons.close, size: 18, color: scheme.onPrimaryContainer)),
            ]),
            if (up.downloading) ...[
              const SizedBox(height: Gap.xs),
              LinearProgressIndicator(value: up.progress > 0 ? up.progress : null),
              const SizedBox(height: Gap.xs),
              Text('${(up.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 12, color: scheme.onPrimaryContainer)),
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
