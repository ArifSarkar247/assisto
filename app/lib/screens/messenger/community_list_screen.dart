import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_community_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_community_card.dart';
import 'community_detail_screen.dart';

/// Assisto Messenger — COMMUNITIES list (Step 3, item 1).
///
/// Communities are the owner's larger OPEN surface (distinct from the
/// circle-only groups). This screen shows the groups the user is in and the
/// groups they can join. Joining is per-group: an OPEN group joins instantly;
/// a REQUEST group creates a join request the admins approve. The
/// partition (joined / joinable / requested) is computed server-side by
/// `partition_groups` — this screen only renders it.
///
/// Backend: GET /community/<id>/groups. Until the backend is live the screen
/// shows a friendly empty / pending state (no crash). ORIGINAL identity —
/// Assisto brand tokens and Material icons only.
class CommunityListScreen extends StatefulWidget {
  final IdentityKeyPair identity;

  /// The community this list belongs to (umbrella). When null the screen asks
  /// the shell to pass one; the empty state covers the "no community yet" case.
  final Map<String, dynamic>? community;

  const CommunityListScreen({
    super.key,
    required this.identity,
    this.community,
  });

  @override
  State<CommunityListScreen> createState() => _CommunityListScreenState();
}

class _CommunityListScreenState extends State<CommunityListScreen> {
  bool _loading = true;
  bool _backendReady = true;
  List<Map<String, dynamic>> _joined = [];
  List<Map<String, dynamic>> _joinable = [];
  List<Map<String, dynamic>> _requested = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);
  String? get _communityId =>
      widget.community == null ? null : '${widget.community!['id']}';

  Future<void> _load() async {
    final cid = _communityId;
    if (cid == null) {
      setState(() {
        _loading = false;
        _backendReady = true;
      });
      return;
    }
    try {
      final r = await _api.communityGroups(cid);
      _joined = _list(r['joined']);
      _joinable = _list(r['joinable']);
      _requested = _list(r['requested']);
      _backendReady = true;
    } catch (_) {
      _backendReady = false;
      _joined = [];
      _joinable = [];
      _requested = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _list(dynamic v) =>
      ((v ?? const []) as List).cast<Map<String, dynamic>>();

  Future<void> _join(Map<String, dynamic> group) async {
    try {
      final r = await _api.communityGroupJoin('${group['id']}');
      final action = '${r['action'] ?? ''}';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(action == 'joined'
              ? _t.communityJoinedNow
              : _t.communityRequestSent),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_t.communityActionFailed)));
      }
    }
    await _load();
  }

  void _open(Map<String, dynamic> group) {
    final community = widget.community;
    if (community == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommunityDetailScreen(
        community: community,
        identity: widget.identity,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.community?['name']?.toString() ?? _t.communityTitle;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: Gap.xxl),
                children: [
                  if (_isEmpty) _emptyState(scheme),
                  if (_joined.isNotEmpty) ...[
                    _header(_t.communityGroupsYoureIn, scheme),
                    for (final g in _joined)
                      _groupCard(g, joined: true),
                  ],
                  if (_joinable.isNotEmpty || _requested.isNotEmpty) ...[
                    _header(_t.communityGroupsYouCanJoin, scheme),
                    for (final g in _requested)
                      _groupCard(g, requested: true),
                    for (final g in _joinable)
                      _groupCard(g, joinable: true),
                  ],
                ],
              ),
            ),
    );
  }

  bool get _isEmpty =>
      _joined.isEmpty && _joinable.isEmpty && _requested.isEmpty;

  Widget _header(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: scheme.primary)),
      );

  Widget _groupCard(
    Map<String, dynamic> g, {
    bool joined = false,
    bool joinable = false,
    bool requested = false,
  }) {
    final count = g['member_count'] ?? 0;
    final openJoin = '${g['join_mode'] ?? 'request'}' == 'open';
    final isAnnouncements = '${g['kind'] ?? ''}' == 'announcements';
    Widget? trailing;
    if (joined) {
      trailing = MsgrActionChip(
          label: _t.communityOpen, icon: Icons.arrow_forward, onPressed: () => _open(g));
    } else if (requested) {
      trailing = MsgrActionChip(
          label: _t.communityRequested,
          icon: Icons.hourglass_empty,
          muted: true);
    } else if (joinable) {
      trailing = MsgrActionChip(
        label: openJoin ? _t.communityJoin : _t.communityRequestToJoin,
        icon: openJoin ? Icons.add : Icons.outgoing_mail,
        onPressed: () => _join(g),
      );
    }
    return MsgrCommunityCard(
      name: '${g['name'] ?? ''}',
      description: '${g['description'] ?? ''}',
      photoRef: g['photo_ref']?.toString(),
      countLabel: _t.communityMemberCount('$count'),
      badge: isAnnouncements
          ? _badge(_t.communityAnnouncementsGroup, Icons.campaign_outlined)
          : null,
      trailing: trailing,
      onTap: joined ? () => _open(g) : null,
    );
  }

  Widget _badge(String label, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: scheme.tertiary),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                color: scheme.tertiary,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _emptyState(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          children: [
            const SizedBox(height: Gap.xxl),
            Icon(Icons.diversity_3_outlined,
                size: 56, color: scheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: Gap.md),
            Text(_t.communityEmptyTitle,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: Gap.xs),
            Text(
              _backendReady
                  ? _t.communityEmptyBody
                  : _t.communityBackendPending,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      );
}
