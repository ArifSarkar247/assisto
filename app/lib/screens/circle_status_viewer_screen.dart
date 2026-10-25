import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../messaging/media/media_store.dart';
import '../p3/p3_api.dart';
import '../p3/story_crypto.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'circle_status_composer_screen.dart' show kStoryBgs;

/// Full-screen story viewer (owner P3) — WhatsApp-style.
///
/// Each story arrives as MY OWN ciphertext copy (sealed to me on the author's
/// phone); it is decrypted here. A photo story's file is fetched through the
/// E2E media path and decrypted with the key from that copy. Viewing records
/// a view (the server honours read receipts); replies go privately to the
/// author's 1:1 chat; mute keeps the author out of my tray without telling
/// them. For my own stories: viewers list + delete.
class CircleStatusViewerScreen extends StatefulWidget {
  final IdentityKeyPair identity;
  final int authorId; // the author's USER id
  final String authorName;
  final Uint8List? authorKey;
  final bool mine;

  /// Tests / gallery: stories already fetched (skips the network).
  final List<Map<String, dynamic>>? preloaded;

  const CircleStatusViewerScreen({
    super.key,
    required this.identity,
    required this.authorId,
    required this.authorName,
    required this.authorKey,
    this.mine = false,
    this.preloaded,
  });

  @override
  State<CircleStatusViewerScreen> createState() => _CircleStatusViewerScreenState();
}

class _CircleStatusViewerScreenState extends State<CircleStatusViewerScreen> {
  final _e2e = SoftwareE2E();
  bool _loading = true;
  List<Map<String, dynamic>> _stories = [];
  final Map<int, StoryContent?> _content = {};
  final Map<String, File?> _files = {};
  int _index = 0;
  Timer? _advance;
  bool _paused = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _advance?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final pre = widget.preloaded;
      if (pre != null) {
        _stories = pre;
      } else {
        final r = widget.mine ? await _api.myStories() : await _api.storiesOf(widget.authorId);
        _stories = ((r['results'] ?? r['statuses'] ?? []) as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {
      _stories = [];
    }
    final keys = <Uint8List>[
      if (widget.mine) widget.identity.publicKey,
      if (widget.authorKey != null) widget.authorKey!,
    ];
    for (final st in _stories) {
      final pt = openSealed(e2e: _e2e, me: widget.identity, senderKeys: keys, row: st);
      _content[(st['id'] as num).toInt()] = pt == null ? null : StoryContent.parse(pt);
    }
    // start at the first unseen story (WhatsApp)
    final firstUnseen = _stories.indexWhere((s) => s['seen'] != true);
    _index = widget.mine || firstUnseen < 0 ? 0 : firstUnseen;
    if (!mounted) return;
    setState(() => _loading = false);
    if (_stories.isNotEmpty) _onShow();
  }

  StoryContent? get _cur =>
      _stories.isEmpty ? null : _content[(_stories[_index]['id'] as num).toInt()];

  void _onShow() {
    final st = _stories[_index];
    if (!widget.mine && widget.preloaded == null) {
      unawaited(_api.seeStory((st['id'] as num).toInt()).then((_) {}, onError: (_) {}));
    }
    final photo = _cur?.photo;
    if (photo != null && !_files.containsKey(photo.ref)) {
      _files[photo.ref] = MediaCache.instance.cachedSync(photo);
      if (_files[photo.ref] == null && widget.preloaded == null) {
        MediaCache.instance.fetch(photo).then((f) {
          if (mounted) setState(() => _files[photo.ref] = f);
        });
      }
    }
    _scheduleAdvance();
  }

  void _scheduleAdvance() {
    _advance?.cancel();
    if (widget.preloaded != null) return; // gallery: hold still
    _advance = Timer(const Duration(seconds: 6), _next);
  }

  void _pause(bool on) {
    _advance?.cancel();
    setState(() => _paused = on);
    if (!on) _scheduleAdvance();
  }

  void _next() {
    if (_paused) return;
    if (_index < _stories.length - 1) {
      setState(() => _index++);
      _onShow();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _prev() {
    if (_index > 0) {
      setState(() => _index--);
      _onShow();
    }
  }

  Future<void> _reply() async {
    _pause(true);
    final t = AppLocalizations.of(context);
    final controller = TextEditingController();
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: Gap.lg, right: Gap.lg, top: Gap.sm,
            bottom: MediaQuery.viewInsetsOf(ctx).bottom + Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(
                hintText: t.statusReplyPrivately, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(ctx).pop(true),
              icon: const Icon(Icons.send_rounded),
              label: Text(t.statusSendReply),
            ),
          ),
        ]),
      ),
    );
    final body = controller.text.trim();
    controller.dispose();
    if (sent == true && body.isNotEmpty && widget.authorKey != null) {
      try {
        final ct = _e2e.encrypt(
            self: widget.identity, recipientPublicKey: widget.authorKey!, plaintext: body);
        await _api.replyToStatus(
            statusId: '${_stories[_index]['id']}', authorId: widget.authorId, ciphertext: ct);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.p3ReplySent)));
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.p3SendFailed)));
        }
      }
    }
    if (mounted) _pause(false);
  }

  Future<void> _mute() async {
    _pause(true);
    final s = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.statusMute),
        content: Text(s.statusMuteConfirm(widget.authorName)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(s.statusMute)),
        ],
      ),
    );
    if (ok != true) {
      if (mounted) _pause(false);
      return;
    }
    var muted = true;
    try {
      await _api.muteStories(widget.authorId, true);
    } catch (_) {
      muted = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(muted ? s.statusMuted : s.grpActionFailed)));
    Navigator.of(context).maybePop();
  }

  Future<void> _delete() async {
    _pause(true);
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.p3DeleteStory),
        content: Text(t.p3DeleteStoryBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t.p3Delete)),
        ],
      ),
    );
    if (ok != true) {
      if (mounted) _pause(false);
      return;
    }
    try {
      await _api.deleteStory((_stories[_index]['id'] as num).toInt());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.p3SaveFailed)));
        _pause(false);
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _stories.removeAt(_index);
      if (_index >= _stories.length) _index = _stories.length - 1;
    });
    if (_stories.isEmpty) {
      Navigator.of(context).maybePop();
    } else {
      _pause(false);
    }
  }

  void _showViewers() {
    _pause(true);
    final st = _stories[_index];
    final named = ((st['named_viewers'] ?? []) as List).cast<Map<String, dynamic>>();
    final count = (st['viewer_count'] as num?)?.toInt() ?? named.length;
    final anon = (st['anonymous_count'] as num?)?.toInt() ?? 0;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final s = AppLocalizations.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.remove_red_eye_rounded),
                  const SizedBox(width: Gap.sm),
                  Text(count == 0
                          ? s.statusNoViewsYet
                          : s.statusSeenBy(notifLocalizeDigits(ctx, '$count')),
                      style: Theme.of(ctx).textTheme.titleMedium),
                ]),
                if (anon > 0) ...[
                  const SizedBox(height: Gap.xs),
                  Text(s.statusReceiptsOff,
                      style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                ],
                const SizedBox(height: Gap.sm),
                for (final v in named)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                        child: Text('${v['name'] ?? '?'}'.isEmpty
                            ? '?'
                            : '${v['name']}'.characters.first.toUpperCase())),
                    title: Text('${v['name'] ?? ''}'),
                    subtitle: v['at'] == null
                        ? null
                        : Text(MaterialLocalizations.of(ctx).formatTimeOfDay(TimeOfDay.fromDateTime(
                            DateTime.tryParse('${v['at']}')?.toLocal() ?? DateTime.now()))),
                  ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      if (mounted) _pause(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    if (_loading) {
      return const Scaffold(
          backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));
    }
    if (_stories.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white),
        body: Center(child: Text(s.statusNoUpdates, style: const TextStyle(color: Colors.white70))),
      );
    }
    final c = _cur;
    final photo = c?.photo;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onTapUp: (d) {
            final w = MediaQuery.sizeOf(context).width;
            if (d.globalPosition.dx < w / 3) {
              _prev();
            } else {
              _next();
            }
          },
          onLongPress: () => _pause(true),
          onLongPressUp: () => _pause(false),
          child: Stack(children: [
            Positioned.fill(child: _contentView(s, c, photo)),
            Positioned(
              top: Gap.sm,
              left: Gap.sm,
              right: Gap.sm,
              child: Row(children: [
                for (var i = 0; i < _stories.length; i++)
                  Expanded(
                    child: Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: i <= _index ? Colors.white : Colors.white38,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ]),
            ),
            Positioned(
              top: Gap.lg,
              left: Gap.sm,
              right: Gap.sm,
              child: Row(children: [
                CircleAvatar(
                  backgroundColor: Colors.white24,
                  child: Text(
                      widget.authorName.isEmpty ? '?' : widget.authorName.characters.first.toUpperCase(),
                      style: const TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.authorName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    Text(
                        MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(
                            DateTime.tryParse('${_stories[_index]['created_at']}')?.toLocal() ??
                                DateTime.now())),
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ]),
                ),
                PopupMenuButton<String>(
                  iconColor: Colors.white,
                  onOpened: () => _pause(true),
                  onCanceled: () => _pause(false),
                  onSelected: (v) {
                    if (v == 'mute') _mute();
                    if (v == 'delete') _delete();
                  },
                  itemBuilder: (_) => [
                    if (!widget.mine) PopupMenuItem(value: 'mute', child: Text(s.statusMute)),
                    if (widget.mine) PopupMenuItem(value: 'delete', child: Text(s.p3DeleteStory)),
                  ],
                ),
                IconButton(
                  tooltip: s.p3Close,
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ]),
            ),
            Positioned(
              bottom: Gap.lg,
              left: Gap.lg,
              right: Gap.lg,
              child: widget.mine ? _viewerButton(s) : _replyButton(s),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _contentView(AppLocalizations s, StoryContent? c, dynamic photo) {
    if (c == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xxl),
          child: Text(s.p3StoryCantOpen,
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
        ),
      );
    }
    if (c.photo != null) {
      final f = _files[c.photo!.ref];
      return Stack(fit: StackFit.expand, children: [
        if (f != null)
          Image.file(f, fit: BoxFit.contain)
        else if (c.photo!.thumb != null)
          Image.memory(c.photo!.thumb!, fit: BoxFit.contain, gaplessPlayback: true)
        else
          const Center(child: CircularProgressIndicator()),
        if (c.text.isNotEmpty)
          Positioned(
            left: Gap.lg,
            right: Gap.lg,
            bottom: 88,
            child: Container(
              padding: const EdgeInsets.all(Gap.sm),
              color: Colors.black54,
              child: Text(c.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
      ]);
    }
    return Container(
      color: kStoryBgs[c.bg.abs() % kStoryBgs.length],
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Gap.xxl),
      child: Text(c.text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600, height: 1.35)),
    );
  }

  Widget _replyButton(AppLocalizations s) => FilledButton.icon(
        style: FilledButton.styleFrom(
            backgroundColor: Colors.white24,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48)),
        onPressed: widget.authorKey == null ? null : _reply,
        icon: const Icon(Icons.reply_rounded),
        label: Text(s.statusReplyPrivately),
      );

  Widget _viewerButton(AppLocalizations s) {
    final st = _stories[_index];
    final count = (st['viewer_count'] as num?)?.toInt() ?? 0;
    return FilledButton.icon(
      key: const ValueKey('p3-story-viewers'),
      style: FilledButton.styleFrom(
          backgroundColor: Colors.white24,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48)),
      onPressed: _showViewers,
      icon: const Icon(Icons.remove_red_eye_rounded),
      label: Text(count == 0 ? s.statusNoViewsYet : s.statusSeenBy(notifLocalizeDigits(context, '$count'))),
    );
  }
}
