import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../invite/space_link.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/msg_notify.dart' show loadStoredIdentity;
import '../../messenger_channel_api.dart';
import '../../messenger_community_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_channel_common.dart';
import '../../widgets/msgr_community_card.dart';
import 'package:assisto/widgets/app_sheet.dart';
import 'channel_detail_screen.dart';
import 'community_detail_screen.dart';

/// channels (2 Nov) — My Circle → Communities tab.
///
/// Owner phone-test bug: there was no way to create a community and the tab
/// was always empty. Now: my communities (admin first), "waiting for
/// approval", New community (name, about, starter groups — an announcements
/// group comes with it), and "Join with a link or code". A community is
/// private: people join with the admin's link / QR and an admin approves.
/// Every group inside is a real end-to-end encrypted group chat.
class CommunitiesHomeScreen extends StatefulWidget {
  final IdentityKeyPair identity;

  /// Open the create sheet once on first frame (hub ⋮ → New community).
  final bool startCreate;
  const CommunitiesHomeScreen(
      {super.key, required this.identity, this.startCreate = false});

  @override
  State<CommunitiesHomeScreen> createState() => CommunitiesHomeScreenState();
}

class CommunitiesHomeScreenState extends State<CommunitiesHomeScreen> {
  bool _loading = true;
  bool _error = false;
  List<Map<String, dynamic>> _mine = [];
  List<Map<String, dynamic>> _requested = [];

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.startCreate) {
      WidgetsBinding.instance.addPostFrameCallback((_) => create());
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final j = await _api.communitiesMine();
      _mine = ((j['results'] ?? const []) as List).cast<Map<String, dynamic>>();
      _requested =
          ((j['requested'] ?? const []) as List).cast<Map<String, dynamic>>();
      _error = false;
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _open(Map<String, dynamic> c) {
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) =>
                CommunityDetailScreen(community: c, identity: widget.identity)))
        .then((_) => _load());
  }

  /// New community sheet (also called from the hub ⋮ menu).
  Future<void> create() async {
    final made = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CreateCommunitySheet(),
    );
    if (made == null || !mounted) return;
    await _load();
    final c = (made['community'] ?? made) as Map;
    _open(c.cast<String, dynamic>());
  }

  Future<void> _joinByLink() async {
    final link = await showAppSheet<SpaceLink>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _JoinByLinkSheet(),
    );
    if (link == null || !mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SpaceLinkScreen(link: link)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('chx-community-create'),
        heroTag: 'chx-community-fab',
        onPressed: create,
        icon: const Icon(Icons.add_rounded),
        label: Text(t.chxNewCommunity),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _joinTile(AppLocalizations t) => ListTile(
        key: const Key('chx-community-join'),
        minVerticalPadding: Gap.md,
        leading: const CircleAvatar(child: Icon(Icons.link_rounded)),
        title: Text(t.chxJoinWithLink),
        subtitle: Text(t.chxJoinWithLinkSub),
        onTap: _joinByLink,
      );

  Widget _body(AppLocalizations t) {
    if (_error && _mine.isEmpty) {
      return ListView(children: [
        const SizedBox(height: Gap.xxl * 2),
        MsgrEmptyState(
          icon: Icons.cloud_off_rounded,
          title: t.communityLoadError,
          body: t.checkInternetRetry,
          action: FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry),
          ),
        ),
      ]);
    }
    if (_mine.isEmpty && _requested.isEmpty) {
      // empty state = benefit line + big button + how-to
      return ListView(children: [
        const SizedBox(height: Gap.xl),
        MsgrEmptyState(
          icon: Icons.diversity_3_rounded,
          title: t.chxCommunitiesEmptyTitle,
          body: t.chxCommunitiesEmptyBody,
          action: Column(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.icon(
              key: const Key('chx-community-empty-create'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: create,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.chxNewCommunity),
            ),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _joinByLink,
              icon: const Icon(Icons.link_rounded),
              label: Text(t.chxJoinWithLink),
            ),
            const SizedBox(height: Gap.lg),
            Text(t.chxCommunitiesHowTo,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(height: Gap.xxl * 2),
      ]);
    }
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.only(bottom: Gap.xxl * 3)),
      children: [
        _joinTile(t),
        const Divider(height: 1),
        for (final c in _mine)
          MsgrCommunityCard(
            name: '${c['name'] ?? ''}',
            description: '${c['description'] ?? ''}',
            countLabel: t.communityMemberCount('${c['member_count'] ?? 0}'),
            badge: c['viewer_role'] == 'admin'
                ? Text(t.chxYouAreAdmin,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.tertiary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600))
                : null,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _open(c),
          ),
        if (_requested.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
            child: Text(t.chxWaitingApproval,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary)),
          ),
          for (final c in _requested)
            MsgrCommunityCard(
              name: '${c['name'] ?? ''}',
              description: '${c['description'] ?? ''}',
              trailing: MsgrActionChip(
                  label: t.communityRequested,
                  icon: Icons.hourglass_empty_rounded,
                  muted: true),
            ),
        ],
      ],
    );
  }
}

class _CreateCommunitySheet extends StatefulWidget {
  const _CreateCommunitySheet();
  @override
  State<_CreateCommunitySheet> createState() => _CreateCommunitySheetState();
}

class _CreateCommunitySheetState extends State<_CreateCommunitySheet> {
  final _name = TextEditingController();
  final _about = TextEditingController();
  final _groups = [TextEditingController(), TextEditingController()];
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    for (final g in _groups) {
      g.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.chxNameRequired)));
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await context.read<AppState>().api.communityCreate(
            _name.text.trim(),
            description: _about.text.trim(),
            groups: [
              for (final g in _groups)
                if (g.text.trim().isNotEmpty) g.text.trim()
            ],
          );
      if (mounted) Navigator.of(context).pop(r);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.status == 429
                ? t.chxRateLimited
                : t.communityActionFailed)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.communityActionFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.chxNewCommunity,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            Text(t.chxNewCommunitySub,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            TextField(
              key: const Key('chx-community-name'),
              controller: _name,
              decoration: InputDecoration(labelText: t.chxCommunityName),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _about,
              maxLines: 2,
              decoration: InputDecoration(labelText: t.channelDescription),
            ),
            const SizedBox(height: Gap.lg),
            Text(t.chxStarterGroups,
                style: Theme.of(context).textTheme.titleSmall),
            Text(t.chxStarterGroupsSub,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            for (var i = 0; i < _groups.length; i++) ...[
              const SizedBox(height: Gap.sm),
              TextField(
                controller: _groups[i],
                decoration: InputDecoration(
                    labelText: i == 0 ? t.chxGroupExample1 : t.chxGroupExample2),
              ),
            ],
            const SizedBox(height: Gap.xl),
            FilledButton(
              key: const Key('chx-community-submit'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.chxCreate),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoinByLinkSheet extends StatefulWidget {
  const _JoinByLinkSheet();
  @override
  State<_JoinByLinkSheet> createState() => _JoinByLinkSheetState();
}

class _JoinByLinkSheetState extends State<_JoinByLinkSheet> {
  final _c = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _go() {
    final l = SpaceLink.parse(_c.text);
    if (l == null) {
      setState(() => _err = AppLocalizations.of(context).chxLinkInvalid);
      return;
    }
    Navigator.of(context).pop(l);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.chxJoinWithLink, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('chx-join-link-field'),
            controller: _c,
            autofocus: true,
            decoration: InputDecoration(
              labelText: t.chxPasteLink,
              hintText: 'lifeassisto.com/cm/…',
              errorText: _err,
            ),
            onSubmitted: (_) => _go(),
          ),
          const SizedBox(height: Gap.lg),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: _go,
            child: Text(t.chxOpenLink),
          ),
        ],
      ),
    );
  }
}

/// Opens a shared channel / community link (App Link, paste, QR scan).
/// Channel -> the channel page (private code carried along); community ->
/// its preview with "Ask to join" (an admin approves). Signed out -> kept
/// for after sign-in. Wrong / old link -> an honest page, never a dead end.
class SpaceLinkScreen extends StatefulWidget {
  final SpaceLink link;
  const SpaceLinkScreen({super.key, required this.link});
  @override
  State<SpaceLinkScreen> createState() => _SpaceLinkScreenState();
}

class _SpaceLinkScreenState extends State<SpaceLinkScreen> {
  bool _loading = true;
  bool _notFound = false;
  bool _signIn = false;
  bool _busy = false;
  Map<String, dynamic> _c = {};
  bool _started = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    final app = context.read<AppState>();
    if (app.loading) return;
    _started = true;
    if (!app.loggedIn) {
      SpaceLink.pending = widget.link;
      _loading = false; // build() follows didChangeDependencies
      _signIn = true;
      return;
    }
    SpaceLink.pending = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    final l = widget.link;
    try {
      if (l.isChannel) {
        final j = await _api.channelResolve(l.handle, code: l.code);
        final ch = (j['channel'] ?? j) as Map;
        final id = (ch['id'] as num).toInt();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => ChannelDetailScreen(
                channelId: id,
                inviteCode: l.code,
                startAsAdmin: ch['is_admin'] == true)));
        return;
      }
      _c = await _api.communityPreview(l.code);
    } on ApiException catch (e) {
      _notFound = e.status == 404;
      if (!_notFound) _c = {};
    } catch (_) {
      _c = {};
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _ask() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await _api.communityJoinByCode(widget.link.code);
      _c['state'] = '${r['state'] ?? 'requested'}';
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.status == 429
                ? t.chxRateLimited
                : t.communityActionFailed)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.communityActionFailed)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openCommunity() async {
    final id = await loadStoredIdentity();
    if (!mounted) return;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).c3KeysNotReady)));
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => CommunityDetailScreen(community: _c, identity: id)));
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>(); // re-check once the session has loaded
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_signIn) {
      body = MsgrEmptyState(
        icon: Icons.login_rounded,
        title: t.chxSignInFirstTitle,
        body: t.chxSignInFirstBody,
      );
    } else if (_notFound || _c.isEmpty) {
      body = MsgrEmptyState(
        icon: Icons.link_off_rounded,
        title: t.chxNotFoundTitle,
        body: _notFound ? t.chxNotFoundBody : t.checkInternetRetry,
        action: _notFound
            ? null
            : FilledButton.icon(
                onPressed: () {
                  setState(() => _loading = true);
                  _resolve();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.retry),
              ),
      );
    } else {
      final state = '${_c['state'] ?? 'none'}';
      body = ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
          children: [
        Icon(Icons.diversity_3_rounded, size: 64, color: scheme.primary),
        const SizedBox(height: Gap.lg),
        Text('${_c['name'] ?? ''}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall),
        if ('${_c['description'] ?? ''}'.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text('${_c['description']}',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: Gap.sm),
        Text(t.communityMemberCount('${_c['member_count'] ?? 0}'),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xl),
        if (state == 'member')
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: _openCommunity,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(t.communityOpen),
          )
        else if (state == 'requested')
          Text(t.chxRequestSentWait,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium)
        else ...[
          FilledButton.icon(
            key: const Key('chx-ask-join'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: _busy ? null : _ask,
            icon: const Icon(Icons.how_to_reg_rounded),
            label: Text(t.chxAskToJoin),
          ),
          const SizedBox(height: Gap.sm),
          Text(t.chxAskToJoinNote,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.link.isChannel
          ? t.channelsTitle
          : t.communityTitle)),
      body: body,
    );
  }
}
