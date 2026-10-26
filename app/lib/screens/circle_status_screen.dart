import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../p3/p3_api.dart';
import '../services/action_feedback.dart';
import '../p3/story_crypto.dart';
import '../p3/story_privacy_sheet.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_status_ring.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'circle_status_composer_screen.dart';
import 'circle_status_viewer_screen.dart';

/// My Circle STORIES (24 h) + profile NOTES — the Updates tab (owner P3).
///
/// End-to-end encrypted: every story / note is sealed on the author's phone
/// once per allowed viewer; the server returns each viewer only their own
/// copy and re-checks the audience (block both ways, mute, privacy mode,
/// 24 h expiry) on every read. See .phaseB/P3_DESIGN.md §5.
class CircleStatusScreen extends StatefulWidget {
  /// The caller's on-device identity (private key never leaves the device).
  final IdentityKeyPair identity;

  /// Accepted circle members [{id, name, peer_user_id, public_key, ...}].
  final List<Map<String, dynamic>> members;

  const CircleStatusScreen({
    super.key,
    required this.identity,
    required this.members,
  });

  @override
  State<CircleStatusScreen> createState() => _CircleStatusScreenState();
}

class _CircleStatusScreenState extends State<CircleStatusScreen> {
  final _e2e = SoftwareE2E();
  bool _loading = true;
  bool _errored = false;
  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _muted = [];
  Map<String, dynamic>? _mine;
  String? _myNote; // decrypted
  StoryPrivacy _notePrivacy = StoryPrivacy.contacts;
  List<({int author, String name, String text})> _notes = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _myId => context.read<AppState>().user?.id ?? -1;

  Map<String, dynamic>? _memberOf(int userId) {
    for (final m in widget.members) {
      if (peerUserId(m) == userId) return m;
    }
    return null;
  }

  String _nameOf(int userId, String fallback) {
    final n = '${_memberOf(userId)?['name'] ?? ''}'.trim();
    return n.isNotEmpty ? n : fallback;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errored = false;
    });
    final api = context.read<AppState>().api;
    try {
      final r = await api.storyTray();
      _entries = ((r['entries'] ?? []) as List).cast<Map<String, dynamic>>();
      _muted = ((r['muted'] ?? []) as List).cast<Map<String, dynamic>>();
      _mine = (r['mine'] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      _entries = [];
      _muted = [];
      _mine = null;
      _errored = true;
    }
    try {
      final n = await api.notes();
      final me = (n['mine'] as Map?)?.cast<String, dynamic>();
      _myNote = me == null
          ? null
          : openSealed(e2e: _e2e, me: widget.identity, senderKeys: [widget.identity.publicKey], row: me);
      _notePrivacy = StoryPrivacy.fromJson(me?['visibility']);
      final list = <({int author, String name, String text})>[];
      for (final x in ((n['notes'] ?? []) as List).cast<Map<String, dynamic>>()) {
        final aid = (x['author_id'] as num?)?.toInt() ?? 0;
        final k = keyOf(_memberOf(aid));
        if (k == null) continue;
        final txt = openSealed(e2e: _e2e, me: widget.identity, senderKeys: [k], row: x);
        if (txt == null || txt.trim().isEmpty) continue;
        list.add((author: aid, name: _nameOf(aid, '${x['name'] ?? ''}'), text: txt));
      }
      _notes = list;
    } catch (_) { // best-effort: notes are optional; the stories still show
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openComposer() async {
    final posted = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => CircleStatusComposerScreen(
          identity: widget.identity, members: widget.members),
    ));
    if (posted == true) _load();
  }

  Future<void> _openAuthor(int authorId, String name) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleStatusViewerScreen(
        identity: widget.identity,
        authorId: authorId,
        authorName: name,
        authorKey: keyOf(_memberOf(authorId)),
      ),
    ));
    _load();
  }

  Future<void> _openMine() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleStatusViewerScreen(
        identity: widget.identity,
        authorId: _myId,
        authorName: AppLocalizations.of(context).statusMine,
        authorKey: widget.identity.publicKey,
        mine: true,
      ),
    ));
    _load();
  }

  Future<void> _privacy() async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    StoryPrivacy cur = StoryPrivacy.contacts;
    try {
      cur = StoryPrivacy.fromJson((await api.privacyDefaults())['status']);
    } catch (_) {} // best-effort: the sheet opens on "My contacts" and saving still reports
    if (!mounted) return;
    final p = await showStoryPrivacySheet(context,
        members: widget.members, initial: cur, title: t.p3PrivStoryTitle);
    if (p == null) return;
    try {
      await api.savePrivacyDefaults({'status': p.toJson(), 'note': p.toJson()});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.p3PrivSaved)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.p3SaveFailed)));
      }
    }
  }

  Future<void> _editNote() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => NoteSheet(
        identity: widget.identity,
        members: widget.members,
        current: _myNote,
        privacy: _notePrivacy,
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _muteMenu(int authorId, String name, bool muted) async {
    final t = AppLocalizations.of(context);
    final go = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListTile(
          leading: Icon(muted ? Icons.notifications_active_rounded : Icons.notifications_off_rounded),
          title: Text(muted ? t.p3UnmuteStories(name) : t.p3MuteStories(name)),
          subtitle: Text(t.p3MuteNote),
          onTap: () => Navigator.pop(ctx, true),
        ),
      ),
    );
    if (go != true || !mounted) return;
    try {
      await context.read<AppState>().api.muteStories(authorId, !muted);
    } catch (e) {
      if (mounted) showActionFailed(context, 'p3.story.mute', e);
      return;
    }
    _load();
  }

  String _initials(String name) {
    final p = name.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
    return p.isEmpty ? '?' : p.first.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final myName = '${context.read<AppState>().user?.name ?? ''}';
    final unseen = _entries.where((e) => e['has_unseen'] == true).toList();
    final seen = _entries.where((e) => e['has_unseen'] != true).toList();
    Widget tile(Map<String, dynamic> e, {bool muted = false}) {
      final id = (e['author_id'] as num?)?.toInt() ?? 0;
      final name = _nameOf(id, '${e['name'] ?? ''}');
      return ListTile(
        key: ValueKey('p3-story-$id'),
        leading: CircleStatusRing(
          label: _initials(name),
          hasUnseen: e['has_unseen'] == true && !muted,
          segments: (e['count'] as num?)?.toInt() ?? 1,
        ),
        title: Text(name, overflow: TextOverflow.ellipsis),
        subtitle: e['latest_at'] == null
            ? null
            : Text(_ago(context, DateTime.tryParse('${e['latest_at']}'))),
        onTap: muted ? null : () => _openAuthor(id, name),
        onLongPress: () => _muteMenu(id, name, muted),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t.statusTitle),
        actions: [
          IconButton(
            key: const ValueKey('p3-privacy-btn'),
            tooltip: t.p3PrivStoryTitle,
            icon: const Icon(Icons.lock_person_rounded),
            onPressed: _privacy,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openComposer,
        icon: const Icon(Icons.add_rounded),
        label: Text(t.statusAdd),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errored
              ? _ErrorRetry(message: t.statusLoadFailed, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 96),
                    children: [
                      // ---- Notes strip (Instagram-style, 24 h) ----
                      SizedBox(
                        // a11y1: ~46 dp of the strip is text (2 note lines +
                        // the name); it grows with the phone's font size
                        // (128 at 1.0; overflowed at 1.3).
                        height: 128 +
                            (MediaQuery.textScalerOf(context).scale(11) - 11) / 11 * 46,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.sm),
                          children: [
                            _NoteBubble(
                              key: const ValueKey('p3-my-note'),
                              initials: _initials(myName),
                              name: t.p3YourNote,
                              text: _myNote ?? t.p3AddNote,
                              placeholder: _myNote == null,
                              onTap: _editNote,
                            ),
                            for (final n in _notes)
                              _NoteBubble(
                                initials: _initials(n.name),
                                name: n.name,
                                text: n.text,
                                onTap: () => showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(n.name),
                                    content: Text(n.text),
                                    actions: [
                                      TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: Text(t.p3Done)),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        key: const ValueKey('p3-my-status'),
                        leading: CircleStatusRing(
                          label: _initials(myName.isEmpty ? '?' : myName),
                          hasUnseen: false,
                          segments: (_mine?['count'] as num?)?.toInt() ?? 1,
                          icon: _mine == null ? Icons.add_rounded : null,
                        ),
                        title: Text(t.statusMine),
                        subtitle: Text(_mine == null
                            ? t.statusTapToAdd
                            : t.statusSeenBy(notifLocalizeDigits(
                                context, '${_mine!['viewer_count'] ?? 0}'))),
                        onTap: _mine == null ? _openComposer : _openMine,
                        trailing: IconButton(
                          tooltip: t.statusAdd,
                          icon: const Icon(Icons.add_circle_outline_rounded),
                          onPressed: _openComposer,
                        ),
                      ),
                      const Divider(),
                      if (_entries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(Gap.xxl),
                          child: Column(children: [
                            Icon(Icons.auto_awesome_rounded, size: 48, color: scheme.outline),
                            const SizedBox(height: Gap.md),
                            Text(t.statusNoUpdates,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant)),
                          ]),
                        ),
                      if (unseen.isNotEmpty) _header(t.statusRecentUpdates, scheme),
                      for (final e in unseen) tile(e),
                      if (seen.isNotEmpty) _header(t.p3ViewedUpdates, scheme),
                      for (final e in seen) tile(e),
                      if (_muted.isNotEmpty)
                        ExpansionTile(
                          title: Text(t.p3MutedUpdates(
                              notifLocalizeDigits(context, '${_muted.length}'))),
                          children: [
                            for (final m in _muted)
                              tile({...m, 'has_unseen': false}, muted: true),
                          ],
                        ),
                      Padding(
                        padding: const EdgeInsets.all(Gap.lg),
                        child: Row(children: [
                          Icon(Icons.lock_outline_rounded, size: 16, color: scheme.primary),
                          const SizedBox(width: Gap.sm),
                          Expanded(
                            child: Text(t.p3StoriesE2e,
                                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                          ),
                        ]),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _header(String s, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
        child: Text(s, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      );
}

String _ago(BuildContext context, DateTime? at) {
  if (at == null) return '';
  final l = MaterialLocalizations.of(context);
  return l.formatTimeOfDay(TimeOfDay.fromDateTime(at.toLocal()));
}

class _NoteBubble extends StatelessWidget {
  final String initials;
  final String name;
  final String text;
  final bool placeholder;
  final VoidCallback onTap;
  const _NoteBubble({
    super.key,
    required this.initials,
    required this.name,
    required this.text,
    required this.onTap,
    this.placeholder = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: SizedBox(
        width: 92,
        child: Column(children: [
          Container(
            constraints: const BoxConstraints(minHeight: 34),
            width: 88,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    color: placeholder ? scheme.onSurfaceVariant : scheme.onSurface)),
          ),
          const SizedBox(height: 4),
          CircleAvatar(
            radius: 20,
            backgroundColor: scheme.primaryContainer,
            child: placeholder
                ? Icon(Icons.add_rounded, color: scheme.onPrimaryContainer)
                : Text(initials, style: TextStyle(color: scheme.onPrimaryContainer)),
          ),
          const SizedBox(height: 2),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11)),
        ]),
      ),
    );
  }
}

/// Write / replace / delete my profile Note (60 chars, 24 h, E2E per viewer).
class NoteSheet extends StatefulWidget {
  final IdentityKeyPair identity;
  final List<Map<String, dynamic>> members;
  final String? current;
  final StoryPrivacy privacy;
  const NoteSheet({
    super.key,
    required this.identity,
    required this.members,
    this.current,
    this.privacy = StoryPrivacy.contacts,
  });
  @override
  State<NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<NoteSheet> {
  final _e2e = SoftwareE2E();
  late final _text = TextEditingController(text: widget.current ?? '');
  late StoryPrivacy _privacy = widget.privacy;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final t = AppLocalizations.of(context);
    final body = _text.text.trim();
    if (body.isEmpty || _busy) return;
    setState(() => _busy = true);
    final app = context.read<AppState>();
    try {
      final per = sealForAudience(
        e2e: _e2e,
        me: widget.identity,
        myUserId: app.user?.id ?? -1,
        audience: audienceOf(widget.members, _privacy),
        plaintext: body,
      );
      await app.api.postNote({
        'per_recipient': per,
        'scheme': _e2e.scheme,
        'sender_key_id': widget.identity.keyId,
        'visibility': _privacy.toJson(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.p3SaveFailed)));
      }
    }
  }

  Future<void> _delete() async {
    try {
      await context.read<AppState>().api.clearNote();
    } catch (e) {
      if (mounted) showActionFailed(context, 'p3.note.delete', e);
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.p3NoteTitle, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(t.p3NoteSub, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              TextField(
                key: const ValueKey('p3-note-field'),
                controller: _text,
                autofocus: true,
                maxLength: 60,
                onChanged: (_) => setState(() {}),
                buildCounter: (ctx, {required currentLength, required isFocused, required maxLength}) =>
                    Text(notifLocalizeDigits(ctx, '$currentLength/${maxLength ?? 60}'),
                        style: Theme.of(ctx).textTheme.bodySmall),
                decoration: InputDecoration(
                    hintText: t.p3NoteHint, border: const OutlineInputBorder()),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: ActionChip(
                  avatar: const Icon(Icons.lock_person_rounded, size: 18),
                  label: Text(privacyLabel(t, _privacy, context)),
                  onPressed: () async {
                    final p = await showStoryPrivacySheet(context,
                        members: widget.members, initial: _privacy, title: t.p3PrivNoteTitle);
                    if (p != null) setState(() => _privacy = p);
                  },
                ),
              ),
              const SizedBox(height: Gap.md),
              FilledButton(
                key: const ValueKey('p3-note-share'),
                onPressed: _text.text.trim().isEmpty || _busy ? null : _share,
                child: Text(t.p3NoteShare),
              ),
              if (widget.current != null)
                TextButton(onPressed: _delete, child: Text(t.p3NoteDelete)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Honest error state with a Retry (§21).
class _ErrorRetry extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off_rounded, size: 48, color: scheme.outline),
          const SizedBox(height: Gap.md),
          Text(message, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          FilledButton.tonalIcon(
              onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: Text(s.retry)),
        ]),
      ),
    );
  }
}

