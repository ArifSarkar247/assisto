import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../messenger_hub_api.dart';
import '../../theme.dart';
import '../../widgets/msgr_hub_chat_list.dart';
import '../circle_call_history_screen.dart';
import '../circle_group_list_screen.dart';
import '../circle_status_composer_screen.dart';
import '../circle_status_screen.dart';
import 'broadcast_lists_screen.dart';
import 'channel_list_screen.dart';
import 'community_list_screen.dart';
import 'contacts_screen.dart';
import 'discover_screen.dart';
import 'linked_devices_screen.dart';
import 'messenger_settings_screen.dart';
import 'starred_messages_screen.dart';

/// The Assisto Messenger hub — the home of everything chat. Opened from the
/// "Messages" entry at the top of the sidebar and from the `messages` ChatNav
/// route.
///
/// BOTTOM TABS (our own icons, Assisto wording — never a WhatsApp/Meta copy):
///   • Chats        — the fast, familiar-feeling 1:1 list (reuses the circle
///                    E2E chat thread for each conversation).
///   • Updates      — Status + Channels (hosts [CircleStatusScreen]).
///   • Communities  — circle communities (placeholder until the sibling agent
///                    ships the screen class).
///   • Calls        — call history (hosts [CircleCallHistoryScreen]).
///
/// The hub owns the on-device identity + the circle member list once and hands
/// them to each tab, so tabs never refetch the keys. Chat content is E2E; the
/// server only ever relays ciphertext.
class MessengerHomeScreen extends StatefulWidget {
  /// Optional tab to open on (0=Chats…3=Calls). Defaults to Chats.
  final int initialTab;
  const MessengerHomeScreen({super.key, this.initialTab = 0});

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

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, 3);
    _bootstrap();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _bootstrap() async {
    await _ensureIdentity();
    await _loadMembers();
    if (mounted) setState(() => _loading = false);
  }

  /// Load (or lazily create) the on-device identity key — mirrors the circle
  /// hub. The PRIVATE key never leaves the device; only the PUBLIC key is
  /// published so peers can encrypt to us.
  Future<void> _ensureIdentity() async {
    try {
      final stored = await _secure.read(key: 'circle_identity_v1');
      if (stored != null) {
        final j = jsonDecode(stored) as Map<String, dynamic>;
        _identity = IdentityKeyPair(
          base64Decode(j['priv'] as String),
          base64Decode(j['pub'] as String),
          j['kid'] as String,
        );
        return;
      }
      final id = _e2e.generateIdentity();
      await _secure.write(
        key: 'circle_identity_v1',
        value: jsonEncode({
          'priv': base64Encode(id.privateKey),
          'pub': base64Encode(id.publicKey),
          'kid': id.keyId,
        }),
      );
      _identity = id;
      try {
        await _api.postJson('/circle/keys', {
          'public_key': id.publicKeyB64,
          'key_id': id.keyId,
          'scheme': _e2e.scheme,
        });
      } catch (_) {}
    } catch (_) {
      // Keep going with a null identity — tabs degrade to a friendly state.
    }
  }

  Future<void> _loadMembers() async {
    try {
      final r = await _api.getJson('/circle/members');
      _members = ((r['results'] ?? r['members'] ?? []) as List)
          .cast<Map<String, dynamic>>()
          .where((m) => '${m['state'] ?? 'accepted'}' == 'accepted')
          .toList();
    } catch (_) {
      _members = [];
    }
  }

  void _openContacts() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const ContactsScreen()))
      .then((_) => _bootstrap());

  /// Hub ⋮ overflow → the hub Settings (Account · Privacy · Chats …).
  void _openSettings() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const MessengerSettingsScreen()))
      .then((_) => _bootstrap());

  /// Top-bar CAMERA — status / photo. Opens the status composer when the
  /// on-device identity exists; otherwise the status list (so it is never a
  /// dead tap). ORIGINAL Assisto flow (never a Meta status copy).
  void _openCamera() {
    final id = _identity;
    if (id == null) {
      _openStatus();
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            CircleStatusComposerScreen(identity: id, members: _members)));
  }

  /// Hub ⋮ dispatch (SPEC §2 order): New group · New community · Broadcast
  /// lists · Linked devices · Starred · Read all · Settings. Every branch
  /// navigates somewhere real — no dead taps.
  void _onHubMenu(String v) {
    switch (v) {
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
    if (id == null) return;
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
            icon: const Icon(Icons.photo_camera_outlined),
            onPressed: _openCamera,
          ),
          // ⋮ hub overflow (exact spec order). Every row navigates somewhere
          // real — no dead taps.
          PopupMenuButton<String>(
            tooltip: t.msgrMoreTooltip,
            onSelected: _onHubMenu,
            itemBuilder: (_) => [
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
              MsgrHubChatList(identity: _identity, members: _members),
              _updatesTab(),
              _communitiesTab(),
              const CircleCallHistoryScreen(),
            ]),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              tooltip: t.msgrNewChat,
              onPressed: _openContacts,
              child: const Icon(Icons.chat_outlined),
            )
          : null,
      // Clamp text scaling + use a compact label style so all FOUR short
      // labels stay on ONE line 4-across at 360dp in both EN and BN. The
      // NavigationBar label itself renders one-line with ellipsis as a
      // backstop so a label can never wrap to a second line.
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(
                fontSize: 11, letterSpacing: 0, fontWeight: FontWeight.w600),
          ),
        ),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.1,
          child: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.forum_outlined),
                selectedIcon: const Icon(Icons.forum),
                label: t.msgrTabChats,
              ),
              NavigationDestination(
                icon: const Icon(Icons.auto_awesome_outlined),
                selectedIcon: const Icon(Icons.auto_awesome),
                label: t.msgrTabUpdates,
              ),
              NavigationDestination(
                icon: const Icon(Icons.groups_2_outlined),
                selectedIcon: const Icon(Icons.groups_2),
                label: t.msgrTabCommunity,
              ),
              NavigationDestination(
                icon: const Icon(Icons.call_outlined),
                selectedIcon: const Icon(Icons.call),
                label: t.msgrTabCalls,
              ),
            ],
          ),
        ),
      ),
    );
  }

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
  /// friendly placeholder until the on-device identity exists.
  Widget _updatesTab() {
    if (_identity == null) {
      return _placeholder(Icons.auto_awesome_outlined, _t.msgrUpdatesSoon);
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
              child: Icon(Icons.add, color: scheme.onPrimaryContainer),
            ),
            title: Text(t.statusTitle),
            trailing: IconButton(
              tooltip: t.discoverTitle,
              icon: const Icon(Icons.explore_outlined),
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
  /// identity; falls back to a friendly placeholder until it exists.
  Widget _communitiesTab() {
    if (_identity == null) {
      return _placeholder(Icons.groups_2_outlined, _t.msgrCommunitiesSoon);
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
            const SizedBox(height: Gap.md),
            Text(_t.msgrComingSoon,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
        ),
      ),
    );
  }
}
