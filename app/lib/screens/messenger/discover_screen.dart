import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_channel_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_channel_common.dart';
import 'channel_detail_screen.dart';
import 'channel_list_screen.dart' show msgrChannelCategories;

/// Assisto Messenger — DISCOVER (Step 3).
///
/// Search channels and public communities, browse by category, and see
/// channels "Suggested by Assisto". The suggestions come ONLY from the user's
/// chosen interests / language / public popularity — NEVER from private
/// messages or contacts — and the screen says so plainly. Includes invite
/// link / QR and share-to-other-apps. Original Assisto identity throughout.
///
/// Backend seam:
///   GET /channels/discover?q=&category=&language=
///        -> {results:[], suggested:[], categories:[]}
///   GET /channels/<id>/share-link -> {url, handle}
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _query = TextEditingController();
  String _category = '';
  bool _loading = true;
  bool _backendReady = true;
  List<Map<String, dynamic>> _results = [];
  List<Map<String, dynamic>> _suggested = [];
  final _busy = <int>{};

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    try {
      final j = await _api.channelDiscover(
        query: _query.text.trim(),
        category: _category,
      );
      _results = ((j['results'] ?? []) as List).cast<Map<String, dynamic>>();
      _suggested =
          ((j['suggested'] ?? []) as List).cast<Map<String, dynamic>>();
      _backendReady = true;
    } catch (_) {
      _backendReady = false;
      _results = [];
      _suggested = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _follow(Map<String, dynamic> ch) async {
    final id = (ch['id'] as num?)?.toInt();
    if (id == null) return;
    final following = ch['my_following'] == true;
    setState(() => _busy.add(id));
    try {
      if (following) {
        await _api.channelUnfollow(id);
      } else {
        await _api.channelFollow(id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(_t.channelFollowedCountOnlyToast)));
        }
      }
      ch['my_following'] = !following;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  void _open(Map<String, dynamic> ch) {
    final id = (ch['id'] as num?)?.toInt();
    if (id == null) return;
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) => ChannelDetailScreen(channelId: id)))
        .then((_) => _search());
  }

  Future<void> _shareInvite(Map<String, dynamic> ch) async {
    final id = (ch['id'] as num?)?.toInt();
    if (id == null) return;
    try {
      final j = await _api.channelShareLink(id);
      final url = '${j['url'] ?? ''}';
      if (url.isEmpty) return;
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        builder: (_) => _InviteSheet(url: url, name: '${ch['name'] ?? ''}'),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.discoverTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: t.discoverSearchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _search),
              ),
            ),
          ),
          _categoryBar(t),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _search, child: _body(t)),
          ),
        ],
      ),
    );
  }

  Widget _categoryBar(AppLocalizations t) {
    String label(String k) {
      switch (k) {
        case 'news':
          return t.channelCatNews;
        case 'religion':
          return t.channelCatReligion;
        case 'entertainment':
          return t.channelCatEntertainment;
        case 'education':
          return t.channelCatEducation;
        case 'sports':
          return t.channelCatSports;
        case 'business':
          return t.channelCatBusiness;
        case 'local':
          return t.channelCatLocal;
      }
      return k;
    }

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: FilterChip(
              selected: _category.isEmpty,
              label: Text(t.discoverAll),
              onSelected: (_) {
                setState(() => _category = '');
                _search();
              },
            ),
          ),
          for (final c in msgrChannelCategories)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: FilterChip(
                selected: _category == c,
                label: Text(label(c)),
                onSelected: (_) {
                  setState(() => _category = (_category == c) ? '' : c);
                  _search();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(AppLocalizations t) {
    final hasQuery = _query.text.trim().isNotEmpty || _category.isNotEmpty;
    if (_results.isEmpty && _suggested.isEmpty) {
      return ListView(children: [
        const SizedBox(height: Gap.xxl * 2),
        MsgrEmptyState(
          icon: Icons.travel_explore,
          title: t.discoverEmptyTitle,
          body: _backendReady ? t.discoverEmptyBody : t.channelsBackendSoon,
        ),
      ]);
    }
    return ListView(
      children: [
        if (hasQuery && _results.isNotEmpty) ...[
          _sectionHeader(t.discoverResults),
          for (final ch in _results) _tile(ch),
        ],
        if (_suggested.isNotEmpty) ...[
          _sectionHeader(t.discoverSuggestedByAssisto),
          for (final ch in _suggested) _tile(ch),
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(
              t.discoverSuggestedSourceNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
        if (!hasQuery && _results.isNotEmpty) ...[
          _sectionHeader(t.discoverPopular),
          for (final ch in _results) _tile(ch),
        ],
      ],
    );
  }

  Widget _tile(Map<String, dynamic> ch) {
    final id = (ch['id'] as num?)?.toInt();
    return MsgrChannelTile(
      channel: ch,
      onTap: () => _open(ch),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _t.channelShareLink,
            icon: const Icon(Icons.ios_share),
            onPressed: () => _shareInvite(ch),
          ),
          MsgrFollowButton(
            following: ch['my_following'] == true,
            busy: id != null && _busy.contains(id),
            onPressed: () => _follow(ch),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

/// Invite sheet: a shareable link + its real QR code (qr_flutter) + copy /
/// share-to-other-apps. Matches the app's existing
/// invite-sheet convention.
class _InviteSheet extends StatelessWidget {
  final String url;
  final String name;
  const _InviteSheet({required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.discoverInviteTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            Center(
              // seam audit: a REAL scannable QR of the invite link (was an
              // icon). White quiet zone so it scans in dark mode too.
              child: Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: QrImageView(
                    key: const Key('discover-invite-qr'), data: url, size: 160),
              ),
            ),
            const SizedBox(height: Gap.lg),
            SelectableText(url,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Gap.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(t.channelLinkCopied)));
                      }
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(t.channelCopyLink),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Share.share(url),
                    icon: const Icon(Icons.ios_share),
                    label: Text(t.channelShareLink),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
