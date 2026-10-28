import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../../calls/fullscreen_call_prompt.dart'; // play-fsi
import '../ring_checklist_screen.dart'; // ring-everywhere banner
import '../../messaging/unread_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../crypto/identity_vault.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../messenger_hub_api.dart';
import '../../theme.dart';
import '../../widgets/loading_gate.dart';
import '../../widgets/m3_circle_widgets.dart';
import '../../widgets/msgr_hub_chat_list.dart';
import '../camera/camera_screen.dart';
import '../circle_call_history_screen.dart';
import '../circle_group_list_screen.dart';
import '../circle_status_screen.dart';
import 'broadcast_lists_screen.dart';
import 'channel_list_screen.dart';
import 'community_list_screen.dart';
import 'contacts_screen.dart';
import 'discover_screen.dart';
import 'linked_devices_screen.dart';
import 'm3_add_to_circle_screen.dart';
import 'm3_requests_screen.dart';
import 'messenger_settings_screen.dart';
import 'starred_messages_screen.dart';
import '../../widgets/circle_badges.dart';

/// The Assisto Messenger hub — the home of everything chat. Opened from the
/// "Messages" entry at the top of the sidebar and from the `messages` ChatNav
/// route.
///
/// BOTTOM TABS (our own icons, Assisto wording — never a WhatsApp/Meta copy):
///   • Chats        — the fast, familiar-feeling 1:1 list (reuses the circle
///                    E2E chat thread for each conversation).
///   • Updates      — Status + Channels (hosts [CircleStatusScreen]).
///   • Communities  — circle communities ([CommunityListScreen]).
///   • Calls        — call history (hosts [CircleCallHistoryScreen]).
///
/// The hub owns the on-device identity + the circle member list once and hands
/// them to each tab, so tabs never refetch the keys. Chat content is E2E; the
/// server only ever relays ciphertext.
class MessengerHomeScreen extends StatefulWidget {
  /// Optional tab to open on (0=Chats…3=Calls). Defaults to Chats.
  final int initialTab;

  /// m3-circle: open straight into "Add to My Circle" (chat command
  /// "circle" / "add someone", route `circle_add`). Back returns here.
  final bool startAdd;
  const MessengerHomeScreen(
      {super.key, this.initialTab = 0, this.startAdd = false});

  @override
  State<MessengerHomeScreen> createState() => _MessengerHomeScreenState();
}

class _MessengerHomeScreenState extends State<MessengerHomeScreen> {
  static const _secure = FlutterSecureStorage();
  final _e2e = SoftwareE2E();

  late int _tab;
  bool _loading = true;
  IdentityKeyPair? _identity;
  List<Map<String, dynamic>> _members = [];

  // m3-circle: incoming request count (badge) + chat-list refresh token.
  int _incoming = 0;
  int _refresh = 0;
  bool _startedAdd = false;
  final _bannerKey = GlobalKey<M3RequestsBannerState>();

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, 3);
    // home-circle: the Calls tab is on screen -> the missed-call dot clears
    if (_tab == 3) CircleBadges.instance.markCallsSeen();
    _bootstrap();
    // play-fsi: once, ask to allow full-screen incoming calls (Android 14+)
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => FullScreenCallPrompt.maybeShow(context));
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _bootstrap() async {
    // m3-circle global rule: the hub spinner ALWAYS ends (secure storage or
    // the network hanging used to keep it spinning forever).
    try {
      await loadGuard(_ensureIdentity(), timeout: const Duration(seconds: 8));
    } catch (_) {
      // Timed out: the spinner still ends; the SAME vault load (single-flight)
      // fills the identity in moments later so taps open the chat.
      unawaited(IdentityVault.instance.get().then((id) {
        if (mounted) setState(() => _identity ??= id);
      }, onError: (_) {}));
    }
    await _loadMembers();
    if (mounted) setState(() => _loading = false);
    if (widget.startAdd && !_startedAdd && mounted) {
      _startedAdd = true;
      _openAdd();
    }
  }

  /// Load (or lazily create) the on-device identity key — mirrors the circle
  /// hub. The PRIVATE key never leaves the device; only the PUBLIC key is
  /// published so peers can encrypt to us.
  Future<void> _ensureIdentity() async {
    // IdentityVault: secure storage with retry + encrypted app-private
    // fallback; never null, so the chat always opens and the key always
    // publishes even when the Keystore fails (ColorOS / MIUI).
    final id = await IdentityVault.instance.get();
    _identity = id;
    // Publish the PUBLIC key on every open (fire-and-forget; the key service
    // also retries with backoff): new connections only learn our key this way.
    unawaited(_api.postJson('/circle/keys', {
      'public_key': id.publicKeyB64,
      'key_id': id.keyId,
      'scheme': _e2e.scheme,
    }).then((_) {}, onError: (_) {}));
  }

  Future<void> _loadMembers() async {
    try {
      final r = await loadGuard(_api.getJson('/circle/members'));
      _members = ((r['results'] ?? r['members'] ?? []) as List)
          .cast<Map<String, dynamic>>()
          .where((m) => '${m['state'] ?? 'accepted'}' == 'accepted')
          .toList();
    } catch (_) {
      _members = [];
    }
  }

  /// FAB -> "New chat" (WhatsApp order): Add to My Circle, New group, New
  /// community, Invite a friend, then the phone contacts who are on Assisto
  /// (the c1 contacts screen: disclosure -> real phonebook -> match).
  void _openNewChat() {
    final t = _t;
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (ctx) => ContactsScreen(
            title: t.msgrNewChat,
            header: M3NewChatActions(
              onAdd: _openAdd,
              onNewGroup: () {
                Navigator.of(ctx).pop();
                _openNewGroup();
              },
              onNewCommunity: () {
                Navigator.of(ctx).pop();
                setState(() => _tab = 2);
              },
              onInvite: () => m3Invite(ctx, M3InviteVia.share),
            ),
          ),
        ))
        .then((_) => _afterChange());
  }

  /// "Add to My Circle" (number in any format / contacts / QR / link).
  Future<void> _openAdd() async {
    await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const M3AddToCircleScreen()));
    _afterChange();
  }

  Future<void> _openRequests() async {
    await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const M3RequestsScreen()));
    _afterChange();
  }

  /// Something may have changed (a request sent / accepted): reload the
  /// members, the chat list and the requests banner.
  Future<void> _afterChange() async {
    if (!mounted) return;
    await _loadMembers();
    if (!mounted) return;
    setState(() => _refresh++);
    _bannerKey.currentState?.reload();
  }

  /// Hub ⋮ overflow → the hub Settings (Account · Privacy · Chats …).
  void _openSettings() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const MessengerSettingsScreen()))
      .then((_) => _bootstrap());

  /// Top-bar CAMERA — opens the REAL in-app camera (live preview, photo/video,
  /// recent strip, gallery, flash, switch). From the capture/edit screen the
  /// user sends to a chat, several chats, or posts as Status — all through the
  /// existing circle paths. The on-device identity + member list are forwarded
  /// so the send targets are ready. ORIGINAL Assisto flow (never a Meta copy).
  void _openCamera() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            CameraScreen(identity: _identity, members: _members)));
  }

  /// Hub ⋮ dispatch (SPEC §2 order): New group · New community · Broadcast
  /// lists · Linked devices · Starred · Read all · Settings. Every branch
  /// navigates somewhere real — no dead taps.
  void _onHubMenu(String v) {
    switch (v) {
      case 'add_circle':
        _openAdd();
        break;
      case 'requests':
        _openRequests();
        break;
      case 'invite':
        m3Invite(context, M3InviteVia.share);
        break;
      case 'new_group':
        _openNewGroup();
        break;
      case 'new_community':
        setState(() => _tab = 2); // Community tab hosts the create flow.
        break;
      case 'broadcast':
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => BroadcastListsScreen(
                identity: _identity, members: _members)));
        break;
      case 'linked':
        Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LinkedDevicesScreen()));
        break;
      case 'starred':
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => StarredMessagesScreen(
                identity: _identity, members: _members)));
        break;
      case 'read_all':
        _readAll();
        break;
      case 'settings':
        _openSettings();
        break;
    }
  }

  /// New group → the circle group-create flow (pick members, name, photo,
  /// desc). Needs the on-device identity; falls back to Settings-free honest
  /// path via the group list screen's own create sheet.
  void _openNewGroup() {
    final id = _identity;
    if (id == null) {
      m3Snack(context, _t.m3SecureStoreNotReady, error: true);
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => CircleGroupListScreen(
              identity: id, circleMembers: _members),
        ))
        .then((_) => _bootstrap());
  }

  /// Read all → confirm, then hit the read-all endpoint. Honest success /
  /// failure feedback (never a silent no-op).
  Future<void> _readAll() async {
    final t = _t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.msgrReadAllTitle),
        content: Text(t.msgrReadAllBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.msgrReadAllConfirm)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.hubReadAll();
      UnreadStore.instance.clearAll();
      if (mounted) setState(() => _refresh++);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.msgrReadAllDone)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.msgrReadAllFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.sidebarMyCircle),
        actions: [
          // CAMERA — status/photo. Opens the status composer (or the status
          // list fallback) so the top-bar camera always does something real.
          IconButton(
            tooltip: t.msgrHubCameraTooltip,
            icon: const Icon(Icons.photo_camera_rounded),
            onPressed: _openCamera,
          ),
          // ⋮ hub overflow (exact spec order). Every row navigates somewhere
          // real — no dead taps.
          PopupMenuButton<String>(
            key: const Key('m3-hub-menu'),
            tooltip: t.msgrMoreTooltip,
            onSelected: _onHubMenu,
            icon: Badge(
              isLabelVisible: _incoming > 0,
              label: Text('$_incoming'),
              child: const Icon(Icons.more_vert_rounded),
            ),
            itemBuilder: (_) => [
              // m3-circle: adding people lives INSIDE My Circle.
              PopupMenuItem(
                  key: const Key('m3-menu-add'),
                  value: 'add_circle',
                  child: Text(t.m3AddToCircle)),
              PopupMenuItem(
                  key: const Key('m3-menu-requests'),
                  value: 'requests',
                  child: Text(_incoming > 0
                      ? t.m3RequestsCount(_incoming)
                      : t.m3RequestsTitle)),
              PopupMenuItem(
                  key: const Key('m3-menu-invite'),
                  value: 'invite',
                  child: Text(t.m3InviteFriend)),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'new_group', child: Text(t.msgrHubNewGroup)),
              PopupMenuItem(
                  value: 'new_community', child: Text(t.msgrHubNewCommunity)),
              PopupMenuItem(
                  value: 'broadcast', child: Text(t.msgrHubBroadcastLists)),
              PopupMenuItem(
                  value: 'linked', child: Text(t.msgrHubLinkedDevices)),
              PopupMenuItem(value: 'starred', child: Text(t.msgrHubStarred)),
              PopupMenuItem(value: 'read_all', child: Text(t.msgrHubReadAll)),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'settings', child: Text(t.msgrSettingsTitle)),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(index: _tab, children: [
              MsgrHubChatList(
                identity: _identity,
                members: _members,
                refreshToken: _refresh,
                onAdd: _openAdd,
                // Incoming requests at the TOP of My Circle (Accept/Decline).
                // ring-everywhere: above them, a small "calls may not ring"
                // banner while the call checklist finds something missing.
                header: Column(mainAxisSize: MainAxisSize.min, children: [
                  const RingCheckBanner(),
                  M3RequestsBanner(
                    key: _bannerKey,
                    identity: _identity, // mr1: request previews
                    onSeeAll: _openRequests,
                    onChanged: (n, accepted) {
                      if (!mounted) return;
                      setState(() => _incoming = n);
                      if (accepted) _afterChange();
                    },
                  ),
                ]),
              ),
              _updatesTab(),
              _communitiesTab(),
              const CircleCallHistoryScreen(standalone: false),
            ]),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              key: const Key('m3-fab'),
              // Own hero tag: a tab below may mount another FAB with the
              // default tag ("multiple heroes share the same tag" on push).
              heroTag: 'm3-fab',
              tooltip: t.msgrNewChat,
              onPressed: _openNewChat,
              child: const Icon(Icons.chat_rounded),
            )
          : null,
      // Clamp text scaling + use a compact label style so all FOUR short
      // labels stay on ONE line 4-across at 360dp in both EN and BN. The
      // NavigationBar label itself renders one-line with ellipsis as a
      // backstop so a label can never wrap to a second line.
      // banners-everywhere (owner 26 Oct): ONE banner ABOVE the tab bar, on
      // the Chats LIST tab only ('circle_list'). Never on Updates /
      // Community / Calls, never inside a conversation (own route, no slot).
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        // the NavigationBar below already pads for the system bar
        MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: AdBannerSlot(screen: 'circle_list', enabled: _tab == 0)),
        NavigationBarTheme(
        data: NavigationBarThemeData(
          labelTextStyle: WidgetStateProperty.all(
            AType.labelSmall
                .copyWith(letterSpacing: 0, fontWeight: FontWeight.w600),
          ),
        ),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.1,
          child: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) {
              if (i == 3) CircleBadges.instance.markCallsSeen();
              setState(() => _tab = i);
            },
            destinations: [
              // c3-msg: unread chats + incoming requests, live from the
              // UnreadStore (clears the moment a chat is opened).
              NavigationDestination(
                icon: _chatsBadge(const Icon(Icons.forum_outlined)),
                selectedIcon: _chatsBadge(const Icon(Icons.forum_rounded)),
                label: t.msgrTabChats,
              ),
              NavigationDestination(
                icon: const Icon(Icons.auto_awesome_outlined),
                selectedIcon: const Icon(Icons.auto_awesome_rounded),
                label: t.msgrTabUpdates,
              ),
              NavigationDestination(
                icon: const Icon(Icons.groups_2_outlined),
                selectedIcon: const Icon(Icons.groups_2_rounded),
                label: t.msgrTabCommunity,
              ),
              NavigationDestination(
                icon: const Icon(Icons.call_outlined),
                selectedIcon: const Icon(Icons.call_rounded),
                label: t.msgrTabCalls,
              ),
            ],
          ),
        ),
      ),
      ]),
    );
  }

  Widget _chatsBadge(Widget icon) => ValueListenableBuilder<int>(
        valueListenable: UnreadStore.instance.total,
        builder: (_, unread, __) {
          final n = unread + _incoming;
          return Badge(
              key: const Key('c3-tab-badge'),
              isLabelVisible: n > 0,
              label: Text(n > 99 ? '99+' : '$n'),
              child: icon);
        },
      );

  void _openStatus() {
    if (_identity == null) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            CircleStatusScreen(identity: _identity!, members: _members)));
  }

  void _openDiscover() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const DiscoverScreen()));

  /// Updates = Status + Channels. Hosts [ChannelListScreen] (which can create /
  /// follow channels and reach [DiscoverScreen]); a header row lets the user
  /// jump into their circle Status ([CircleStatusScreen]). Falls back to a
  /// honest "setting up encryption" state until the on-device identity exists.
  Widget _updatesTab() {
    if (_identity == null) {
      return _placeholder(Icons.auto_awesome_rounded, _t.c3KeysNotReady);
    }
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.surface,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.add_rounded, color: scheme.onPrimaryContainer),
            ),
            title: Text(t.statusTitle),
            trailing: IconButton(
              tooltip: t.discoverTitle,
              icon: const Icon(Icons.explore_rounded),
              onPressed: _openDiscover,
            ),
            onTap: _openStatus,
          ),
        ),
        const Divider(height: 1),
        const Expanded(child: ChannelListScreen()),
      ],
    );
  }

  /// Communities = the owner's open community groups. Needs the on-device
  /// identity; shows the honest "setting up encryption" state until then.
  Widget _communitiesTab() {
    if (_identity == null) {
      return _placeholder(Icons.groups_2_rounded, _t.c3KeysNotReady);
    }
    return CommunityListScreen(identity: _identity!);
  }

  Widget _placeholder(IconData icon, String body) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.primary.withValues(alpha: 0.7)),
            // f6: no "Preview" heading — this is an honest waiting state
            // (keys being set up), not a feature preview.
            const SizedBox(height: Gap.md),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
        ),
      ),
    );
  }
}
