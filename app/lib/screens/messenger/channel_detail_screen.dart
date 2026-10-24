import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_admin_api.dart';
import '../../messenger_channel_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_channel_common.dart';
import '../../widgets/msgr_channel_post_card.dart';
import '../../widgets/msgr_mod_report_sheet.dart';
import 'channel_admin_screen.dart';
import '../../ads/sponsor_widgets.dart' show SponsoredPostSlot; // p2-money
import '../../services/error_kind.dart' show honestFailText; // f6

/// Assisto Messenger — CHANNEL detail (Step 3).
///
/// The one-to-many broadcast surface a FOLLOWER sees: the channel header, its
/// posts (text / photo / video / link / poll) and a clear "not end-to-end
/// encrypted — public" label. Followers can REACT (our own reaction set) and
/// VOTE on polls by index — but there is deliberately NO reply box, NO comment
/// field and NO "message admin" affordance anywhere (the server has no such
/// path). Followers can mute / unfollow / share and change their own follower
/// visibility (count-only by default). Original Assisto identity throughout.
///
/// Backend seam:
///   GET  /channels/<id>            -> {channel, posts, can_publish}
///   POST /channels/<id>/posts/<pid>/react|view
///   POST /channels/<id>/polls/<pid>/vote
///   POST /channels/<id>/mute | /unfollow | /my-visibility
///   GET  /channels/<id>/share-link
class ChannelDetailScreen extends StatefulWidget {
  final int channelId;
  final bool startAsAdmin;
  const ChannelDetailScreen({
    super.key,
    required this.channelId,
    this.startAsAdmin = false,
  });
  @override
  State<ChannelDetailScreen> createState() => _ChannelDetailScreenState();
}

class _ChannelDetailScreenState extends State<ChannelDetailScreen> {
  bool _loading = true;
  bool _backendReady = true;
  Object? _failCause; // f6: 5xx = our server, not the internet
  bool _loadError = false;
  Map<String, dynamic> _channel = {};
  List<Map<String, dynamic>> _posts = [];
  final _viewed = <int>{};

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  bool get _isAdmin =>
      _channel['is_admin'] == true || _channel['is_owner'] == true;
  bool get _following => _channel['my_following'] == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final j = await _api.channelGet(widget.channelId);
      _channel = (j['channel'] ?? {}).cast<String, dynamic>();
      _posts = ((j['posts'] ?? []) as List).cast<Map<String, dynamic>>();
      _backendReady = true;
      _loadError = false;
      _recordViews();
    } on ApiException catch (e) {
      _failCause = e;
      _backendReady = true;
      _loadError = true;
    } catch (_) {
      _backendReady = false;
      _loadError = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // Record a view once per post (aggregate; the server stores no viewer id).
  void _recordViews() {
    for (final p in _posts) {
      final pid = (p['id'] as num?)?.toInt();
      if (pid == null || _viewed.contains(pid)) continue;
      _viewed.add(pid);
      _api
          .channelRecordView(id: widget.channelId, postId: pid)
          .catchError((_) => <String, dynamic>{});
    }
  }

  Future<void> _react(int postId, String emoji, bool on) async {
    try {
      final j = await _api.channelReact(
          id: widget.channelId, postId: postId, emoji: emoji, on: on);
      final updated = (j['post'] ?? j).cast<String, dynamic>();
      setState(() {
        final i = _posts.indexWhere((p) => (p['id'] as num?)?.toInt() == postId);
        if (i >= 0 && updated.isNotEmpty) {
          _posts[i] = {..._posts[i], ...updated};
        }
      });
    } catch (_) {
      _toast(_t.channelActionFailed);
    }
  }

  Future<void> _vote(Map<String, dynamic> post, List<int> choices) async {
    final poll = (post['poll'] as Map?)?.cast<String, dynamic>();
    final pollId = (poll?['id'] as num?)?.toInt();
    if (pollId == null) return;
    try {
      final j = await _api.channelPollVote(
          id: widget.channelId, pollId: pollId, choices: choices);
      final updated = (j['poll'] ?? j).cast<String, dynamic>();
      setState(() {
        final i = _posts.indexWhere((p) => p['id'] == post['id']);
        if (i >= 0) {
          _posts[i] = {..._posts[i], 'poll': {...?poll, ...updated}};
        }
      });
    } catch (_) {
      _toast(_t.channelActionFailed);
    }
  }

  Future<void> _toggleMute() async {
    final muted = _channel['my_muted'] == true;
    try {
      final j = await _api.channelSetMuted(widget.channelId, !muted);
      _channel = (j['channel'] ?? _channel).cast<String, dynamic>();
      if (mounted) setState(() {});
    } catch (_) {
      _toast(_t.channelActionFailed);
    }
  }

  Future<void> _unfollow() async {
    // §21 destructive-action confirm gate: unfollowing leaves the channel.
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.channelUnfollowTitle),
        content: Text(_t.channelUnfollowConfirm('${_channel['name'] ?? ''}')),
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
    try {
      await _api.channelUnfollow(widget.channelId);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      _toast(_t.channelActionFailed);
    }
  }

  Future<void> _share() async {
    try {
      final j = await _api.channelShareLink(widget.channelId);
      final url = '${j['url'] ?? ''}';
      if (url.isEmpty) return;
      await Share.share(url);
    } catch (_) {
      _toast(_t.channelActionFailed);
    }
  }

  Future<void> _editMyVisibility() async {
    final current = '${_channel['my_visibility'] ?? 'count_only'}';
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _MyVisibilitySheet(current: current),
    );
    if (chosen == null || chosen == current) return;
    try {
      final j = await _api.channelMyVisibility(widget.channelId, chosen);
      _channel = (j['channel'] ?? _channel).cast<String, dynamic>();
      _channel['my_visibility'] = chosen;
      if (mounted) setState(() {});
    } catch (_) {
      _toast(_t.channelActionFailed);
    }
  }

  void _showInfo() {
    final desc = '${_channel['description'] ?? ''}';
    final handle = '${_channel['handle'] ?? ''}';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_channel['name'] ?? _t.channelsTitle}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (handle.isNotEmpty) Text('@$handle'),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(desc),
            ],
            const SizedBox(height: Gap.sm),
            Text(_t.channelReplyDisabledNote,
                style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
        ],
      ),
    );
  }

  void _openAdmin() {
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) =>
                ChannelAdminScreen(channelId: widget.channelId)))
        .then((_) => _load());
  }

  Future<void> _requestVerify() async {
    try {
      final j = await _api.channelRequestVerification(widget.channelId);
      _channel = (j['channel'] ?? _channel).cast<String, dynamic>();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.channelVerifyRequested)));
      }
    } catch (_) {
      _toast(_t.channelActionFailed);
    }
  }

  Future<void> _report() async {
    await MsgrReportSheet.show(
      context,
      targetKind: ModTargets.channel,
      targetId: '${widget.channelId}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final verifyState = '${_channel['verification_state'] ?? ''}';
    return Scaffold(
      appBar: AppBar(
        title: Text('${_channel['name'] ?? t.channelsTitle}'),
        actions: [
          IconButton(
            tooltip: t.channelShareLink,
            icon: const Icon(Icons.share_outlined),
            onPressed: _share,
          ),
          // Unified channel ⋮ — only the actions that apply to this viewer.
          PopupMenuButton<String>(
            tooltip: t.grpMenuMore,
            onSelected: (v) {
              switch (v) {
                case 'info':
                  _showInfo();
                case 'manage':
                  _openAdmin();
                case 'verify':
                  _requestVerify();
                case 'mute':
                  _toggleMute();
                case 'visibility':
                  _editMyVisibility();
                case 'unfollow':
                  _unfollow();
                case 'report':
                  _report();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'info', child: Text(t.channelInfo)),
              // Admin-only: manage (edit / post / analytics) + verify request.
              if (_isAdmin)
                PopupMenuItem(value: 'manage', child: Text(t.channelManage)),
              if (_isAdmin && verifyState != 'verified')
                PopupMenuItem(
                    value: 'verify', child: Text(t.channelRequestVerify)),
              // Follower-only: mute / follower-privacy / unfollow.
              if (_following)
                PopupMenuItem(
                  value: 'mute',
                  child: Text(_channel['my_muted'] == true
                      ? t.channelUnmute
                      : t.channelMute),
                ),
              if (_following)
                PopupMenuItem(
                    value: 'visibility', child: Text(t.channelMyVisibility)),
              if (_following)
                PopupMenuItem(
                    value: 'unfollow', child: Text(t.channelUnfollow)),
              PopupMenuItem(value: 'report', child: Text(t.channelReport)),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError
              ? RefreshIndicator(onRefresh: _load, child: _errorRetry(t))
              : RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _errorRetry(AppLocalizations t) {
    return ListView(
      children: [
        const SizedBox(height: Gap.xxl * 2),
        MsgrEmptyState(
          icon: Icons.cloud_off_outlined,
          title: t.channelLoadError,
          body: honestFailText(t, _failCause, otherwise: t.checkInternetRetry),
          action: FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(t.retry),
          ),
        ),
      ],
    );
  }

  Widget _body(AppLocalizations t) {
    return ListView(
      children: [
        _header(t),
        const MsgrNotEncryptedBanner(),
        // Followers can react, but NEVER reply / comment / message the admin.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.channelReplyDisabledNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant)),
              ),
            ],
          ),
        ),
        if (_posts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xxl),
            child: MsgrEmptyState(
              icon: Icons.campaign_outlined,
              title: t.channelNoPostsTitle,
              body: _backendReady
                  ? t.channelNoPostsBody
                  : t.checkInternetRetry,
            ),
          )
        else
          for (final p in _posts)
            MsgrChannelPostCard(
              post: p,
              // READ + REACT only for followers (no reply affordance anywhere).
              onReact: (emoji, on) =>
                  _react((p['id'] as num).toInt(), emoji, on),
              onVote: (choices) => _vote(p, choices),
              // Followers never see per-post views or a pin control.
              showViews: false,
            ),
        // p2-money: one Telegram-style "Sponsored" post at the end of a
        // LARGE channel (server checks Free plan + follower threshold + cap;
        // never in the admin's own channel). Renders nothing otherwise.
        if (_posts.isNotEmpty && !_isAdmin)
          SponsoredPostSlot(ctxKind: 'channel', ctxId: widget.channelId),
        const SizedBox(height: Gap.xxl),
      ],
    );
  }

  Widget _header(AppLocalizations t) {
    final bn = msgrIsBn(context);
    final name = '${_channel['name'] ?? ''}';
    final handle = '${_channel['handle'] ?? ''}';
    final desc = '${_channel['description'] ?? ''}';
    final verified = _channel['is_verified'] == true;
    final count = (_channel['follower_count'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MsgrChannelAvatar(name: name, size: 64),
              const SizedBox(width: Gap.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (verified) ...[
                          const SizedBox(width: Gap.xs),
                          const MsgrVerifiedBadge(size: 20),
                        ],
                      ],
                    ),
                    if (handle.isNotEmpty)
                      Text('@$handle',
                          style: Theme.of(context).textTheme.bodyMedium),
                    Text(
                      msgrLocalizeDigits(
                          t.channelFollowerCount(count.toString()), bn),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (desc.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(desc, style: Theme.of(context).textTheme.bodyMedium),
          ],
          const SizedBox(height: Gap.md),
          _followRow(t),
        ],
      ),
    );
  }

  Widget _followRow(AppLocalizations t) {
    if (_following) {
      return Row(
        children: [
          OutlinedButton.icon(
            onPressed: _toggleMute,
            icon: Icon(_channel['my_muted'] == true
                ? Icons.notifications_off_outlined
                : Icons.notifications_active_outlined),
            label: Text(
                _channel['my_muted'] == true ? t.channelUnmute : t.channelMute),
          ),
          const SizedBox(width: Gap.sm),
          OutlinedButton.icon(
            onPressed: _editMyVisibility,
            icon: const Icon(Icons.visibility_outlined),
            label: Text(t.channelMyVisibility),
          ),
        ],
      );
    }
    return FilledButton.icon(
      onPressed: () async {
        try {
          final j = await _api.channelFollow(widget.channelId);
          _channel = (j['channel'] ?? _channel).cast<String, dynamic>();
          _channel['my_following'] = true;
          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(t.channelFollowedCountOnlyToast)));
          }
        } catch (_) {
          _toast(t.channelActionFailed);
        }
      },
      icon: const Icon(Icons.add),
      label: Text(t.channelFollow),
    );
  }
}

/// Follower-visibility chooser: "Show that I follow" vs "Count me only"
/// (default count-only). Makes clear count-only followers are never shown to
/// anyone — not even the owner — while still counting toward the total.
class _MyVisibilitySheet extends StatelessWidget {
  final String current;
  const _MyVisibilitySheet({required this.current});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.channelMyVisibility,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            RadioListTile<String>(
              value: 'count_only',
              groupValue: current,
              title: Text(t.channelVisCountOnly),
              subtitle: Text(t.channelVisCountOnlyHint),
              onChanged: (v) => Navigator.of(context).pop(v),
            ),
            RadioListTile<String>(
              value: 'show',
              groupValue: current,
              title: Text(t.channelVisShow),
              onChanged: (v) => Navigator.of(context).pop(v),
            ),
            const SizedBox(height: Gap.sm),
            Text(t.channelVisDefaultNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Helper so other screens can copy a share link to the clipboard too.
Future<void> msgrCopyShareLink(BuildContext context, String url) async {
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).channelLinkCopied)));
  }
}
