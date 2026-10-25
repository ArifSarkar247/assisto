import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_channel_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_channel_common.dart';
import 'channel_admin_screen.dart';
import 'channel_detail_screen.dart';
import 'discover_screen.dart';
import '../../services/error_kind.dart' show honestFailText; // f6

/// Assisto Messenger — CHANNELS list (Step 3).
///
/// The hub for the shell's "Updates" / channels tab: the channels I follow plus
/// a few suggested ones, each showing a follower COUNT and a verified badge only
/// when operator-granted. Original Assisto identity — our own tokens, icons and
/// wording; nothing copied from WhatsApp / Meta. Backend seam:
///   GET  /channels                 -> {following:[], suggested:[]}
///   POST /channels                 -> create (owner + first admin)
///   POST /channels/<id>/follow     -> follow (default count-only)
/// Until live, a friendly empty state renders (no crash).
class ChannelListScreen extends StatefulWidget {
  const ChannelListScreen({super.key});
  @override
  State<ChannelListScreen> createState() => _ChannelListScreenState();
}

class _ChannelListScreenState extends State<ChannelListScreen> {
  bool _loading = true;
  bool _backendReady = true;
  Object? _failCause; // f6: 5xx = our server, not the internet
  bool _loadError = false;
  List<Map<String, dynamic>> _following = [];
  List<Map<String, dynamic>> _suggested = [];
  final _busy = <int>{};

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final j = await _api.channelList();
      _following =
          ((j['following'] ?? []) as List).cast<Map<String, dynamic>>();
      _suggested =
          ((j['suggested'] ?? []) as List).cast<Map<String, dynamic>>();
      _backendReady = true;
      _loadError = false;
    } on ApiException catch (e) {
      _failCause = e;
      _backendReady = true;
      _loadError = true;
      _following = [];
      _suggested = [];
    } catch (_) {
      _backendReady = false;
      _loadError = false;
      _following = [];
      _suggested = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggleFollow(Map<String, dynamic> ch) async {
    final id = (ch['id'] as num?)?.toInt();
    if (id == null) return;
    final following = ch['my_following'] == true;
    // §21 confirm gate for the destructive side (unfollow).
    if (following) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_t.channelUnfollowTitle),
          content: Text(_t.channelUnfollowConfirm('${ch['name'] ?? ''}')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(_t.channelCancel)),
            FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.channelUnfollow),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy.add(id));
    try {
      final updated = following
          ? await _api.channelUnfollow(id)
          : await _api.channelFollow(id);
      final c = (updated['channel'] ?? updated).cast<String, dynamic>();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(following
            ? _t.channelUnfollowedToast
            : _t.channelFollowedCountOnlyToast),
      ));
      await _load();
      if (c.isEmpty) return;
    } catch (_) {
      _toast(_t.channelActionFailed);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  void _openChannel(Map<String, dynamic> ch) {
    final id = (ch['id'] as num?)?.toInt();
    if (id == null) return;
    final isAdmin = ch['is_admin'] == true || ch['is_owner'] == true;
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => ChannelDetailScreen(
              channelId: id, startAsAdmin: isAdmin),
        ))
        .then((_) => _load());
  }

  Future<void> _create() async {
    final created = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CreateChannelSheet(),
    );
    if (created == null) return;
    final id = (created['id'] as num?)?.toInt();
    await _load();
    if (id != null && mounted) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChannelAdminScreen(channelId: id),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.channelsTitle),
        actions: [
          IconButton(
            tooltip: t.discoverTitle,
            icon: const Icon(Icons.explore_rounded),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => const DiscoverScreen()))
                .then((_) => _load()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: Text(t.channelCreate),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _body(t),
            ),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loadError && _following.isEmpty && _suggested.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: Gap.xxl * 2),
          MsgrEmptyState(
            icon: Icons.cloud_off_rounded,
            title: t.channelLoadError,
            body: honestFailText(t, _failCause, otherwise: t.checkInternetRetry),
            action: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.retry),
            ),
          ),
        ],
      );
    }
    if (_following.isEmpty && _suggested.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: Gap.xxl * 2),
          MsgrEmptyState(
            icon: Icons.campaign_rounded,
            title: t.channelsEmptyTitle,
            body: _backendReady
                ? t.channelsEmptyBody
                : t.checkInternetRetry,
            action: FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.channelCreate),
            ),
          ),
        ],
      );
    }
    return ListView(
      children: [
        if (_following.isNotEmpty) ...[
          _sectionHeader(t.channelFollowingSection),
          for (final ch in _following)
            MsgrChannelTile(
              channel: ch,
              onTap: () => _openChannel(ch),
              trailing: MsgrFollowButton(
                following: true,
                busy: _busy.contains((ch['id'] as num?)?.toInt()),
                onPressed: () => _toggleFollow(ch),
              ),
            ),
        ],
        if (_suggested.isNotEmpty) ...[
          _sectionHeader(t.channelSuggestedSection),
          for (final ch in _suggested)
            MsgrChannelTile(
              channel: ch,
              onTap: () => _openChannel(ch),
              trailing: MsgrFollowButton(
                following: ch['my_following'] == true,
                busy: _busy.contains((ch['id'] as num?)?.toInt()),
                onPressed: () => _toggleFollow(ch),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(
              t.channelSuggestedSourceNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
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

/// Create-channel composer. Requires name + handle (the server raises
/// name_required / handle_required otherwise). Category / language are optional.
class _CreateChannelSheet extends StatefulWidget {
  const _CreateChannelSheet();
  @override
  State<_CreateChannelSheet> createState() => _CreateChannelSheetState();
}

class _CreateChannelSheetState extends State<_CreateChannelSheet> {
  final _name = TextEditingController();
  final _handle = TextEditingController();
  final _desc = TextEditingController();
  String _category = '';
  String _language = '';
  bool _saving = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void dispose() {
    _name.dispose();
    _handle.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty || _handle.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.channelNameHandleRequired)));
      return;
    }
    setState(() => _saving = true);
    try {
      final created = await _api.channelCreate(
        name: _name.text.trim(),
        handle: _handle.text.trim(),
        description: _desc.text.trim(),
        category: _category,
        language: _language,
      );
      if (mounted) {
        Navigator.of(context)
            .pop((created['channel'] ?? created).cast<String, dynamic>());
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).channelActionFailed)));
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.channelCreate,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: t.channelName),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _handle,
              decoration: InputDecoration(
                labelText: t.channelHandle,
                prefixText: '@',
                helperText: t.channelHandleHint,
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _desc,
              decoration: InputDecoration(labelText: t.channelDescription),
              maxLines: 2,
            ),
            const SizedBox(height: Gap.md),
            _CategoryDropdown(
              value: _category,
              onChanged: (v) => setState(() => _category = v),
            ),
            const SizedBox(height: Gap.md),
            _LanguageDropdown(
              value: _language,
              onChanged: (v) => setState(() => _language = v),
            ),
            const SizedBox(height: Gap.xl),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.channelCreate),
            ),
          ],
        ),
      ),
    );
  }
}

/// Category keys mirror the server enum; labels come from AppLocalizations.
const msgrChannelCategories = [
  'news',
  'religion',
  'entertainment',
  'education',
  'sports',
  'business',
  'local',
];

class _CategoryDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _CategoryDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
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

    return DropdownButtonFormField<String>(
      initialValue: value.isEmpty ? null : value,
      decoration: InputDecoration(labelText: t.channelCategory),
      items: [
        for (final c in msgrChannelCategories)
          DropdownMenuItem(value: c, child: Text(label(c))),
      ],
      onChanged: (v) => onChanged(v ?? ''),
    );
  }
}

class _LanguageDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _LanguageDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DropdownButtonFormField<String>(
      initialValue: value.isEmpty ? null : value,
      decoration: InputDecoration(labelText: t.channelLanguage),
      items: [
        DropdownMenuItem(value: 'bn', child: Text(t.channelLangBn)),
        DropdownMenuItem(value: 'en', child: Text(t.channelLangEn)),
        DropdownMenuItem(value: 'other', child: Text(t.channelLangOther)),
      ],
      onChanged: (v) => onChanged(v ?? ''),
    );
  }
}
