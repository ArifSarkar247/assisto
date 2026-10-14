import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_chat_list.dart';
import '../circle_call_history_screen.dart';
import '../circle_status_screen.dart';
import 'channel_list_screen.dart';
import 'community_list_screen.dart';
import 'contacts_screen.dart';
import 'discover_screen.dart';
import 'messenger_profile_screen.dart';

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

  void _openProfile() => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MessengerProfileScreen()));

  void _openContacts() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const ContactsScreen()))
      .then((_) => _bootstrap());

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.msgrTitle),
        actions: [
          IconButton(
            tooltip: t.msgrProfileTitle,
            icon: const Icon(Icons.manage_accounts_outlined),
            onPressed: _openProfile,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(index: _tab, children: [
              MsgrChatList(identity: _identity, members: _members),
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
