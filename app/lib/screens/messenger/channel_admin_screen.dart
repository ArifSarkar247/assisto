import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_channel_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_channel_common.dart';
import '../../widgets/msgr_channel_post_card.dart';
import 'channel_list_screen.dart' show msgrChannelCategories;

/// Assisto Messenger — CHANNEL admin console (Step 3).
///
/// Admin-only: edit the channel profile (name / description / category /
/// language), compose posts (text / photo / video / link / poll), view
/// COUNTS-ONLY analytics (views / reactions / follower growth — no PII, no
/// per-follower listing), manage admins (owner-only), set the follower-list
/// visibility (owner-only) and REQUEST verification (owner-only; the badge is
/// operator-granted — there is no self-verify anywhere). Original Assisto
/// identity throughout.
///
/// Backend seam:
///   POST /channels/<id>                 -> edit (whitelisted fields)
///   POST /channels/<id>/posts           -> create post (e2e rejected server-side)
///   GET  /channels/<id>/analytics       -> counts only
///   GET/POST /channels/<id>/admins       -> owner-only
///   POST /channels/<id>/list-visibility -> owner-only
///   POST /channels/<id>/verify/request  -> owner-only -> pending
class ChannelAdminScreen extends StatefulWidget {
  final int channelId;
  const ChannelAdminScreen({super.key, required this.channelId});
  @override
  State<ChannelAdminScreen> createState() => _ChannelAdminScreenState();
}

class _ChannelAdminScreenState extends State<ChannelAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  bool _loading = true;
  Map<String, dynamic> _channel = {};
  List<Map<String, dynamic>> _posts = [];

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);
  bool get _isOwner => _channel['is_owner'] == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final j = await _api.channelGet(widget.channelId);
      _channel = (j['channel'] ?? {}).cast<String, dynamic>();
      _posts = ((j['posts'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.channelManage),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            Tab(child: Text(t.channelTabPosts, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.channelTabProfile, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.channelAnalytics, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.channelTabAdmins, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _PostsTab(
                    channelId: widget.channelId,
                    posts: _posts,
                    canPublish: _channel['can_publish'] != false,
                    onChanged: _load),
                _ProfileTab(channel: _channel, onChanged: _load),
                _AnalyticsTab(channelId: widget.channelId),
                _AdminsTab(
                    channel: _channel,
                    isOwner: _isOwner,
                    onChanged: _load),
              ],
            ),
    );
  }
}

// ============================ POSTS + COMPOSER =============================

class _PostsTab extends StatefulWidget {
  final int channelId;
  final List<Map<String, dynamic>> posts;
  final bool canPublish;
  final VoidCallback onChanged;
  const _PostsTab({
    required this.channelId,
    required this.posts,
    required this.canPublish,
    required this.onChanged,
  });
  @override
  State<_PostsTab> createState() => _PostsTabState();
}

class _PostsTabState extends State<_PostsTab> {
  ApiClient get _api => context.read<AppState>().api;

  Future<void> _compose() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PostComposerSheet(channelId: widget.channelId),
    );
    if (created == true) widget.onChanged();
  }

  Future<void> _togglePin(int postId, bool pinned) async {
    // Unpinning removes the highlighted post from the top — confirm it (§21).
    if (!pinned) {
      final t = AppLocalizations.of(context);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.channelUnpinTitle),
          content: Text(t.channelUnpinConfirm),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.channelCancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.channelUnpin)),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await _api.channelPinPost(
          id: widget.channelId, postId: postId, pinned: pinned);
      widget.onChanged();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).channelActionFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      floatingActionButton: widget.canPublish
          ? FloatingActionButton.extended(
              onPressed: _compose,
              icon: const Icon(Icons.edit_outlined),
              label: Text(t.channelPost))
          : null,
      body: widget.posts.isEmpty
          ? MsgrEmptyState(
              icon: Icons.post_add,
              title: t.channelNoPostsTitle,
              body: t.channelComposeFirstBody,
              action: widget.canPublish
                  ? FilledButton.icon(
                      onPressed: _compose,
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(t.channelPost))
                  : null,
            )
          : ListView(
              children: [
                for (final p in widget.posts)
                  MsgrChannelPostCard(
                    post: p,
                    // Admin preview: show per-post views + a pin control; the
                    // composer side never reacts, so onReact stays null.
                    showViews: true,
                    onTogglePin: (pinned) =>
                        _togglePin((p['id'] as num).toInt(), pinned),
                  ),
                const SizedBox(height: Gap.xxl * 2),
              ],
            ),
    );
  }
}

class _PostComposerSheet extends StatefulWidget {
  final int channelId;
  const _PostComposerSheet({required this.channelId});
  @override
  State<_PostComposerSheet> createState() => _PostComposerSheetState();
}

class _PostComposerSheetState extends State<_PostComposerSheet> {
  String _kind = 'text';
  final _text = TextEditingController();
  final _link = TextEditingController();
  final _pollQ = TextEditingController();
  final _pollOptions = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];
  bool _pollMulti = false;
  bool _saving = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void dispose() {
    _text.dispose();
    _link.dispose();
    _pollQ.dispose();
    for (final c in _pollOptions) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _saving = true);
    try {
      final options = _pollOptions
          .map((c) => c.text.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      // Channel posts are plaintext-moderatable by design — we NEVER set e2e.
      await _api.channelCreatePost(
        id: widget.channelId,
        kind: _kind,
        text: _text.text.trim(),
        linkUrl: _kind == 'link' ? _link.text.trim() : null,
        pollQuestion: _kind == 'poll' ? _pollQ.text.trim() : null,
        pollOptions: _kind == 'poll' ? options : const [],
        pollMulti: _pollMulti,
        // media_refs would be attached after an upload step; not simulated here.
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).channelActionFailed)));
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
            Text(t.channelPost,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            Wrap(
              spacing: Gap.sm,
              children: [
                _kindChip('text', t.channelPostText, Icons.notes),
                // Photo / video posts are hidden: the server has no channel
                // media upload yet, so an "attach" button would do nothing.
                _kindChip('link', t.channelPostLink, Icons.link),
                _kindChip('poll', t.channelPostPoll, Icons.poll_outlined),
              ],
            ),
            const SizedBox(height: Gap.md),
            if (_kind != 'poll')
              TextField(
                controller: _text,
                decoration: InputDecoration(
                  labelText: _kind == 'link'
                      ? t.channelComposeCaption
                      : t.channelComposeText,
                ),
                maxLines: 4,
                minLines: 2,
              ),
            if (_kind == 'link') ...[
              const SizedBox(height: Gap.md),
              TextField(
                controller: _link,
                decoration: InputDecoration(labelText: t.channelComposeLink),
                keyboardType: TextInputType.url,
              ),
            ],
            if (_kind == 'poll') _pollEditor(t),
            const SizedBox(height: Gap.xl),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.channelPost),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kindChip(String kind, String label, IconData icon) {
    return ChoiceChip(
      selected: _kind == kind,
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onSelected: (_) => setState(() => _kind = kind),
    );
  }

  Widget _pollEditor(AppLocalizations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _pollQ,
          decoration: InputDecoration(labelText: t.channelPollQuestion),
        ),
        const SizedBox(height: Gap.md),
        for (var i = 0; i < _pollOptions.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pollOptions[i],
                    decoration: InputDecoration(
                        labelText: t.channelPollOption),
                  ),
                ),
                if (_pollOptions.length > 2)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(
                        () => _pollOptions.removeAt(i).dispose()),
                  ),
              ],
            ),
          ),
        TextButton.icon(
          onPressed: _pollOptions.length >= 10
              ? null
              : () => setState(
                  () => _pollOptions.add(TextEditingController())),
          icon: const Icon(Icons.add),
          label: Text(t.channelPollAddOption),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _pollMulti,
          title: Text(t.channelPollMulti),
          onChanged: (v) => setState(() => _pollMulti = v),
        ),
      ],
    );
  }
}

// ============================ PROFILE EDIT =================================

class _ProfileTab extends StatefulWidget {
  final Map<String, dynamic> channel;
  final VoidCallback onChanged;
  const _ProfileTab({required this.channel, required this.onChanged});
  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  late final _name =
      TextEditingController(text: '${widget.channel['name'] ?? ''}');
  late final _desc =
      TextEditingController(text: '${widget.channel['description'] ?? ''}');
  late String _category = '${widget.channel['category'] ?? ''}';
  late String _language = '${widget.channel['language'] ?? ''}';
  bool _saving = false;

  ApiClient get _api => context.read<AppState>().api;
  int get _id => (widget.channel['id'] as num).toInt();

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Never send verified / verified_by / follower_count — server strips
      // them anyway; the editor only exposes whitelisted fields.
      await _api.channelEdit(
        _id,
        name: _name.text.trim(),
        description: _desc.text.trim(),
        category: _category,
        language: _language,
      );
      widget.onChanged();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).channelProfileSaved)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).channelActionFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _requestVerification() async {
    try {
      final j = await _api.channelRequestVerification(_id);
      widget.channel.addAll((j['channel'] ?? {}).cast<String, dynamic>());
      widget.onChanged();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context).channelVerificationPending)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).channelActionFailed)));
      }
    }
  }

  String _catLabel(AppLocalizations t, String k) {
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

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final verified = widget.channel['is_verified'] == true;
    final state = '${widget.channel['verification_state'] ?? 'none'}';
    final isOwner = widget.channel['is_owner'] == true;
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        TextField(
          controller: _name,
          decoration: InputDecoration(labelText: t.channelName),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _desc,
          decoration: InputDecoration(labelText: t.channelDescription),
          maxLines: 3,
        ),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<String>(
          initialValue: _category.isEmpty ? null : _category,
          decoration: InputDecoration(labelText: t.channelCategory),
          items: [
            for (final c in msgrChannelCategories)
              DropdownMenuItem(value: c, child: Text(_catLabel(t, c))),
          ],
          onChanged: (v) => setState(() => _category = v ?? ''),
        ),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<String>(
          initialValue: _language.isEmpty ? null : _language,
          decoration: InputDecoration(labelText: t.channelLanguage),
          items: [
            DropdownMenuItem(value: 'bn', child: Text(t.channelLangBn)),
            DropdownMenuItem(value: 'en', child: Text(t.channelLangEn)),
            DropdownMenuItem(value: 'other', child: Text(t.channelLangOther)),
          ],
          onChanged: (v) => setState(() => _language = v ?? ''),
        ),
        const SizedBox(height: Gap.xl),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.channelSaveProfile),
        ),
        const Divider(height: Gap.xxl),
        // Verification: owner can REQUEST only; the badge is operator-granted.
        Text(t.channelVerified,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        if (verified)
          Row(children: [
            const MsgrVerifiedBadge(size: 20),
            const SizedBox(width: Gap.sm),
            Text(t.channelVerifiedActive),
          ])
        else if (state == 'pending')
          Text(t.channelVerificationPending,
              style: Theme.of(context).textTheme.bodyMedium)
        else if (isOwner)
          OutlinedButton.icon(
            onPressed: _requestVerification,
            icon: const Icon(Icons.verified_outlined),
            label: Text(t.channelRequestVerification),
          ),
        const SizedBox(height: Gap.sm),
        Text(t.channelVerificationNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        if (isOwner) ...[
          const Divider(height: Gap.xxl),
          _FollowerListVisibility(
              channel: widget.channel, onChanged: widget.onChanged),
        ],
      ],
    );
  }
}

/// Owner control: make the follower LIST public or private. Private blocks
/// enumeration (count-only followers are never shown regardless) but the count
/// stays visible either way.
class _FollowerListVisibility extends StatefulWidget {
  final Map<String, dynamic> channel;
  final VoidCallback onChanged;
  const _FollowerListVisibility(
      {required this.channel, required this.onChanged});
  @override
  State<_FollowerListVisibility> createState() =>
      _FollowerListVisibilityState();
}

class _FollowerListVisibilityState extends State<_FollowerListVisibility> {
  late String _vis = '${widget.channel['list_visibility'] ?? 'private'}';
  bool _busy = false;

  ApiClient get _api => context.read<AppState>().api;
  int get _id => (widget.channel['id'] as num).toInt();

  Future<void> _set(String v) async {
    setState(() {
      _vis = v;
      _busy = true;
    });
    try {
      await _api.channelListVisibility(_id, v);
      widget.onChanged();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).channelActionFailed)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.channelListVisibility,
            style: Theme.of(context).textTheme.titleMedium),
        RadioListTile<String>(
          contentPadding: EdgeInsets.zero,
          value: 'private',
          groupValue: _vis,
          title: Text(t.channelListPrivate),
          onChanged: _busy ? null : (v) => _set(v!),
        ),
        RadioListTile<String>(
          contentPadding: EdgeInsets.zero,
          value: 'public',
          groupValue: _vis,
          title: Text(t.channelListPublic),
          onChanged: _busy ? null : (v) => _set(v!),
        ),
        Text(t.channelListVisibilityNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

// ============================ ANALYTICS ===================================

class _AnalyticsTab extends StatefulWidget {
  final int channelId;
  const _AnalyticsTab({required this.channelId});
  @override
  State<_AnalyticsTab> createState() => _AnalyticsTabState();
}

class _AnalyticsTabState extends State<_AnalyticsTab> {
  bool _loading = true;
  Map<String, dynamic> _data = {};

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _data = await _api.channelAnalytics(widget.channelId);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = msgrIsBn(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final views = (_data['total_views'] as num?)?.toInt() ?? 0;
    final reactions = (_data['total_reactions'] as num?)?.toInt() ?? 0;
    final growth = ((_data['follower_growth'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Row(
          children: [
            Expanded(
                child: _statCard(
                    t.channelAnalyticsViews,
                    msgrLocalizeDigits(views.toString(), bn),
                    Icons.visibility_outlined)),
            const SizedBox(width: Gap.md),
            Expanded(
                child: _statCard(
                    t.channelAnalyticsReactions,
                    msgrLocalizeDigits(reactions.toString(), bn),
                    Icons.favorite_outline)),
          ],
        ),
        const SizedBox(height: Gap.lg),
        Text(t.channelAnalyticsGrowth,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        if (growth.isEmpty)
          Text(t.channelAnalyticsNoData,
              style: Theme.of(context).textTheme.bodyMedium)
        else
          for (final g in growth)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.trending_up),
              title: Text('${g['day'] ?? ''}'),
              trailing: Text(msgrLocalizeDigits(
                  '${(g['count'] as num?)?.toInt() ?? 0}', bn)),
            ),
        const SizedBox(height: Gap.lg),
        // Analytics are aggregates only — never a per-follower listing.
        Row(
          children: [
            Icon(Icons.lock_outline,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.channelAnalyticsNoPii,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: Gap.sm),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

// ============================ ADMINS ======================================

class _AdminsTab extends StatefulWidget {
  final Map<String, dynamic> channel;
  final bool isOwner;
  final VoidCallback onChanged;
  const _AdminsTab(
      {required this.channel, required this.isOwner, required this.onChanged});
  @override
  State<_AdminsTab> createState() => _AdminsTabState();
}

class _AdminsTabState extends State<_AdminsTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _admins = [];

  ApiClient get _api => context.read<AppState>().api;
  int get _id => (widget.channel['id'] as num).toInt();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await _api.channelAdmins(_id);
      _admins = ((j['admins'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final t = AppLocalizations.of(context);
    final controller = TextEditingController();
    final userId = await showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.channelAddAdmin),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: t.channelAdminUserId),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.channelCancel)),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text.trim())),
            child: Text(t.channelAddAdmin),
          ),
        ],
      ),
    );
    if (userId == null) return;
    try {
      await _api.channelSetAdmin(id: _id, userId: userId, action: 'add');
      await _load();
      widget.onChanged();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).channelActionFailed)));
      }
    }
  }

  Future<void> _remove(int userId, String name) async {
    final t = AppLocalizations.of(context);
    // §21 destructive-action confirm gate.
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.channelRemoveAdminTitle),
        content: Text(t.channelRemoveAdminConfirm(name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.channelCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.channelRemoveAdmin),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.channelSetAdmin(id: _id, userId: userId, action: 'remove');
      await _load();
      widget.onChanged();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).channelActionFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      floatingActionButton: widget.isOwner
          ? FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.person_add_alt),
              label: Text(t.channelAddAdmin))
          : null,
      body: ListView(
        children: [
          for (final a in _admins)
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text('${a['name'] ?? a['user_id'] ?? ''}'),
              subtitle: a['is_owner'] == true ? Text(t.channelOwner) : null,
              trailing: (widget.isOwner && a['is_owner'] != true)
                  ? IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _remove(
                          (a['user_id'] as num).toInt(),
                          '${a['name'] ?? a['user_id'] ?? ''}'),
                    )
                  : null,
            ),
          if (!widget.isOwner)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(t.channelAdminsOwnerOnly,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}
