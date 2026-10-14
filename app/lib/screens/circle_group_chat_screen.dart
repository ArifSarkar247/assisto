import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_group_poll.dart';
import 'circle_group_info_screen.dart';

/// End-to-end-encrypted GROUP chat (M2 item 7).
///
/// E2E FAN-OUT (software fallback): a group message is encrypted ONCE PER
/// RECIPIENT with crypto/e2e.dart (the pairwise fallback) and relayed as a
/// single envelope carrying a {recipient_id: {ciphertext,nonce}} map
/// (per_recipient). The server stores ciphertext only and never holds a group
/// key — exactly like 1:1. When OpenMLS lands it replaces fan-out with one
/// group ciphertext; the envelope shape is unchanged (see
/// core/logic/circle_groups.build_group_fanout + the E2E/GROUP-KEY statement).
///
/// Features wired here: post (announcements-only gate for members), @mentions,
/// reply, reactions, polls, pinned, leave, report, and the group voice/video
/// call launch (video requires a Premium initiator — reuses
/// core/logic/circle_calls.can_place_call via can_place_group_call).
///
/// Backend seam (integrator wires these — see MIGRATION NOTE in the report):
///   GET  /circle/groups/<id>/messages        -> ciphertext envelopes
///   POST /circle/groups/<id>/messages         -> send (per_recipient fan-out)
///   POST /circle/groups/<id>/messages/<m>/react
///   POST /circle/groups/<id>/messages/<m>/pin  (admin)
///   POST /circle/groups/<id>/leave
///   POST /circle/groups/<id>/report
///   POST /circle/groups/<id>/call              -> {kind: voice|video}
///   GET  /circle/groups/<id>/members           -> members (+role, +public_key)
class CircleGroupChatScreen extends StatefulWidget {
  final Map<String, dynamic> group;
  final IdentityKeyPair identity;
  final List<Map<String, dynamic>> circleMembers;
  const CircleGroupChatScreen({
    super.key,
    required this.group,
    required this.identity,
    this.circleMembers = const [],
  });

  @override
  State<CircleGroupChatScreen> createState() => _CircleGroupChatScreenState();
}

class _CircleGroupChatScreenState extends State<CircleGroupChatScreen> {
  final _e2e = SoftwareE2E();
  final _input = TextEditingController();
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _sending = false;
  Map<String, dynamic>? _replyTo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  String get _groupId => '${widget.group['id']}';

  /// The current user's role in this group (admin|member). Defaults to member.
  String get _myRole => '${widget.group['my_role'] ?? 'member'}';

  bool get _announcementsOnly => widget.group['announcements_only'] == true;

  /// In announcements-only mode only admins may post (mirrors
  /// core/logic/circle_groups.can_post).
  bool get _canPost => !_announcementsOnly || _myRole == 'admin';

  Future<void> _load() async {
    try {
      final mem = await _api.getJson('/circle/groups/$_groupId/members');
      _members = ((mem['results'] ?? mem['members'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      final msg = await _api.getJson('/circle/groups/$_groupId/messages');
      _messages = ((msg['results'] ?? msg['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      _members = [];
      _messages = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  /// My member id in this group, resolved from the roster (is_self) and falling
  /// back to the group-level my_member_id the backend attaches per viewer.
  String get _myMemberId {
    for (final m in _members) {
      if (m['is_self'] == true) return '${_idOf(m)}';
    }
    return '${widget.group['my_member_id'] ?? ''}';
  }

  /// Recipients = every ACTIVE member except me. Excludes my own roster row
  /// (is_self / my_member_id) rather than guessing by key_id, so I never
  /// encrypt a copy addressed to myself.
  List<Map<String, dynamic>> get _recipients {
    final mine = _myMemberId;
    return _members
        .where((m) =>
            m['is_self'] != true &&
            '${_idOf(m)}' != mine &&
            m['public_key'] != null)
        .toList();
  }

  /// Encrypt [plaintext] ONCE PER RECIPIENT (fallback fan-out) and POST a single
  /// envelope with a per_recipient ciphertext map. The server stores ciphertext
  /// only. Mirrors core/logic/circle_groups.build_group_fanout.
  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || !_canPost) return;
    setState(() => _sending = true);
    final perRecipient = <String, dynamic>{};
    final recipientIds = <int>[];
    for (final r in _recipients) {
      try {
        final pub = base64Decode('${r['public_key']}');
        final ct = _e2e.encrypt(
          self: widget.identity,
          recipientPublicKey: Uint8List.fromList(pub),
          plaintext: text,
        );
        final id = _idOf(r);
        recipientIds.add(id);
        perRecipient['$id'] = {
          'ciphertext': ct.ciphertextB64,
          'nonce': ct.nonceB64,
        };
      } catch (_) {}
    }
    final mentions = _parseMentions(text);
    try {
      await _api.postJson('/circle/groups/$_groupId/messages', {
        'recipient_ids': recipientIds,
        'per_recipient': perRecipient,
        'sender_key_id': widget.identity.keyId,
        'scheme': _e2e.scheme,
        if (mentions.isNotEmpty) 'mentions': mentions,
        if (_replyTo != null) 'reply_to': '${_replyTo!['id']}',
        'client_msg_id': DateTime.now().microsecondsSinceEpoch.toString(),
      });
    } catch (_) {}
    _input.clear();
    _replyTo = null;
    if (mounted) setState(() => _sending = false);
    await _load();
  }

  /// Parse @mentions into MEMBER IDS (never names leave the device as plaintext
  /// routing — the server only gets ids).
  ///
  /// A token is resolved only on an EXACT (case-insensitive) name match against
  /// the roster — never a startsWith prefix, which could mention the wrong
  /// member (e.g. "@Sa" hitting "Sabrina" instead of "Sadia"). If a token is
  /// ambiguous (matches >1 member) or matches none, it is left as plain text.
  ///
  /// TODO(M2): replace free-text parsing with an inline @-picker — on "@", show
  /// the member roster and insert the chosen member's id as a mention token.
  /// That removes name collisions entirely and is the right UX; left as a
  /// follow-up to keep this change focused.
  List<int> _parseMentions(String text) {
    final out = <int>[];
    final re = RegExp(r'@([^\s@]+)');
    for (final match in re.allMatches(text)) {
      final token = match.group(1)!.toLowerCase();
      if (token.isEmpty) continue;
      final matches = _members
          .where((m) => '${m['name'] ?? ''}'.toLowerCase() == token)
          .toList();
      if (matches.length != 1) continue; // skip ambiguous / unmatched
      final id = _idOf(matches.first);
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }

  Future<void> _react(Map<String, dynamic> msg, String emoji) async {
    try {
      await _api.postJson(
          '/circle/groups/$_groupId/messages/${msg['id']}/react',
          {'emoji': emoji});
    } catch (_) {}
    await _load();
  }

  Future<void> _togglePin(Map<String, dynamic> msg) async {
    if (_myRole != 'admin') return; // admin-only (server re-enforces)
    final pinned = msg['pinned'] == true;
    try {
      await _api.postJson('/circle/groups/$_groupId/messages/${msg['id']}/pin',
          {'pin': !pinned});
    } catch (_) {}
    await _load();
  }

  Future<void> _call(String kind) async {
    // Group VOICE is free; group VIDEO requires a Premium initiator. The server
    // is the authority (can_place_group_call); the client shows the result.
    try {
      final r = await _api
          .postJson('/circle/groups/$_groupId/call', {'kind': kind});
      if (!mounted) return;
      if (r['allowed'] == false && r['needs_video_plan'] == true) {
        _showVideoUpgrade();
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t.circleGroupCallStarting)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_t.circleBackendPending)));
      }
    }
  }

  void _showVideoUpgrade() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.circleGroupVideoPremiumTitle),
        content: Text(_t.circleGroupVideoPremiumBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(_t.circleGroupGetPremium)),
        ],
      ),
    );
  }

  Future<void> _createPoll() async {
    final poll = await showCircleGroupPollComposer(context);
    if (poll == null || !mounted) return;
    // The question + option labels are USER TEXT -> encrypted per recipient,
    // like a message. The server tallies by option INDEX only (never reads a
    // label). Backend contract (core/logic/circle_groups.new_poll): a
    // per-recipient map keyed by member id —
    //   question_ct : { "<member_id>": {ciphertext,nonce} }
    //   options_ct  : { "<member_id>": [ {ciphertext,nonce}, ... ] }  (index-aligned)
    // which the backend stores as the GroupPoll question_ct / options_ct JSON.
    final questionCt = <String, dynamic>{};
    final optionsCt = <String, dynamic>{};
    final recipientIds = <int>[];
    for (final r in _recipients) {
      try {
        final pub = Uint8List.fromList(base64Decode('${r['public_key']}'));
        final id = _idOf(r);
        recipientIds.add(id);
        final q = _e2e.encrypt(
            self: widget.identity,
            recipientPublicKey: pub,
            plaintext: poll.question);
        questionCt['$id'] = {'ciphertext': q.ciphertextB64, 'nonce': q.nonceB64};
        final opts = <Map<String, dynamic>>[];
        for (var i = 0; i < poll.options.length; i++) {
          final o = _e2e.encrypt(
              self: widget.identity,
              recipientPublicKey: pub,
              plaintext: poll.options[i]);
          opts.add({'ciphertext': o.ciphertextB64, 'nonce': o.nonceB64});
        }
        optionsCt['$id'] = opts;
      } catch (_) {}
    }
    try {
      await _api.postJson('/circle/groups/$_groupId/polls', {
        'recipient_ids': recipientIds,
        'option_count': poll.options.length,
        'multi': poll.multi,
        'question_ct': questionCt,
        'options_ct': optionsCt,
        'sender_key_id': widget.identity.keyId,
      });
    } catch (_) {}
    await _load();
  }

  Future<void> _vote(Map<String, dynamic> poll, List<int> choices) async {
    try {
      await _api.postJson('/circle/groups/$_groupId/polls/${poll['id']}/vote',
          {'choices': choices});
    } catch (_) {}
    await _load();
  }

  int _idOf(Map<String, dynamic> m) {
    final raw = m['id'] ?? m['member_id'] ?? 0;
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  void _openInfo() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleGroupInfoScreen(
        group: widget.group,
        identity: widget.identity,
        circleMembers: widget.circleMembers,
      ),
    )).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final pinned =
        _messages.where((m) => m['pinned'] == true).toList();
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _openInfo,
          child: Text('${widget.group['name'] ?? ''}'),
        ),
        actions: [
          IconButton(
            tooltip: _t.circleGroupVoiceCall,
            icon: const Icon(Icons.call_outlined),
            onPressed: () => _call('voice'),
          ),
          IconButton(
            tooltip: _t.circleGroupVideoCall,
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => _call('video'),
          ),
          IconButton(
            tooltip: _t.circleGroupInfo,
            icon: const Icon(Icons.info_outline),
            onPressed: _openInfo,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (pinned.isNotEmpty) _pinnedBar(pinned),
                Expanded(child: _messageList()),
                if (_replyTo != null) _replyPreview(),
                _composer(),
              ],
            ),
    );
  }

  Widget _pinnedBar(List<Map<String, dynamic>> pinned) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        children: [
          const Icon(Icons.push_pin_outlined, size: 16),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              _t.circleGroupPinnedCount('${pinned.length}'),
              style: Theme.of(context).textTheme.labelLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageList() {
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Text(_t.circleGroupNoMessages,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(Gap.md),
      itemCount: _messages.length,
      itemBuilder: (_, i) => _messageItem(_messages[i]),
    );
  }

  Widget _messageItem(Map<String, dynamic> msg) {
    // A poll message renders the poll widget; otherwise a decrypted text bubble.
    if (msg['kind'] == 'poll' || msg['poll'] != null) {
      final poll = (msg['poll'] as Map?)?.cast<String, dynamic>() ?? msg;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: CircleGroupPollCard(
          poll: poll,
          onVote: (choices) => _vote(poll, choices),
        ),
      );
    }
    final text = _decryptForMe(msg) ?? '';
    final senderName = _senderName(msg);
    final announcement = msg['announcement'] == true;
    return GestureDetector(
      onLongPress: () => _showActions(msg),
      child: Card(
        color: announcement
            ? Theme.of(context).colorScheme.tertiaryContainer
            : null,
        margin: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (announcement) ...[
                    const Icon(Icons.campaign_outlined, size: 16),
                    const SizedBox(width: Gap.xs),
                  ],
                  Text(senderName,
                      style: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(
                              color: Theme.of(context).colorScheme.primary)),
                  if (msg['pinned'] == true) ...[
                    const SizedBox(width: Gap.xs),
                    const Icon(Icons.push_pin, size: 12),
                  ],
                ],
              ),
              const SizedBox(height: Gap.xs),
              _highlightMentions(text),
              _reactionRow(msg),
            ],
          ),
        ),
      ),
    );
  }

  /// Render @mentions with emphasis (over already-decrypted text).
  Widget _highlightMentions(String text) {
    final spans = <TextSpan>[];
    final re = RegExp(r'(@[^\s@]+)');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(TextSpan(
        text: m.group(0),
        style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return RichText(
      text: TextSpan(
        style: Theme.of(context).textTheme.bodyMedium,
        children: spans,
      ),
    );
  }

  Widget _reactionRow(Map<String, dynamic> msg) {
    final reactions =
        (msg['reactions'] as Map?)?.cast<String, dynamic>() ?? {};
    if (reactions.isEmpty) return const SizedBox.shrink();
    final counts = <String, int>{};
    for (final v in reactions.values) {
      counts['$v'] = (counts['$v'] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Wrap(
        spacing: Gap.xs,
        children: [
          for (final e in counts.entries)
            Chip(
              label: Text('${e.key} ${e.value}'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
    );
  }

  void _showActions(Map<String, dynamic> msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Wrap(
                spacing: Gap.md,
                children: [
                  for (final e in const ['👍', '❤️', '😂', '😮', '😢', '🙏'])
                    InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _react(msg, e);
                      },
                      child: Text(e, style: const TextStyle(fontSize: 28)),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.reply_outlined),
              title: Text(_t.circleReply),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyTo = msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: Text(_t.copy),
              onTap: () {
                Clipboard.setData(
                    ClipboardData(text: _decryptForMe(msg) ?? ''));
                Navigator.pop(ctx);
              },
            ),
            if (_myRole == 'admin')
              ListTile(
                leading: Icon(msg['pinned'] == true
                    ? Icons.push_pin
                    : Icons.push_pin_outlined),
                title: Text(msg['pinned'] == true
                    ? _t.circleGroupUnpin
                    : _t.circleGroupPin),
                onTap: () {
                  Navigator.pop(ctx);
                  _togglePin(msg);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _replyPreview() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        children: [
          const Icon(Icons.reply, size: 16),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              _decryptForMe(_replyTo!) ?? _t.circleReply,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    if (!_canPost) {
      return SafeArea(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.lg),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.campaign_outlined, size: 18),
              const SizedBox(width: Gap.sm),
              Flexible(
                child: Text(_t.circleGroupOnlyAdminsPost,
                    style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.xs),
        child: Row(
          children: [
            IconButton(
              tooltip: _t.circleGroupCreatePoll,
              icon: const Icon(Icons.poll_outlined),
              onPressed: _createPoll,
            ),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: _t.circleGroupMessageHint,
                  border: const OutlineInputBorder(
                      borderRadius:
                          BorderRadius.all(Radius.circular(Radii.pill))),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: Gap.lg, vertical: Gap.sm),
                ),
              ),
            ),
            IconButton.filled(
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }

  String _senderName(Map<String, dynamic> msg) {
    final sid = '${msg['sender_id'] ?? ''}';
    for (final m in _members) {
      if ('${_idOf(m)}' == sid) return '${m['name'] ?? ''}';
    }
    return '${msg['sender_name'] ?? ''}';
  }

  /// Decrypt the per-recipient blob addressed to me. The fallback fan-out ships
  /// a per_recipient map; my entry is keyed by my member id. On MLS this would
  /// be a single group ciphertext decrypted with the group key.
  String? _decryptForMe(Map<String, dynamic> msg) {
    try {
      final per = (msg['per_recipient'] as Map?)?.cast<String, dynamic>();
      // Resolve MY entry only: prefer the per-message my_member_id, else the
      // roster-derived id. NEVER fall back to another recipient's blob — that
      // is sealed to a different key and can only fail (and would be a privacy
      // smell). Fail to null loudly in debug so a mis-keyed fan-out is visible.
      final myId = '${msg['my_member_id'] ?? _myMemberId}';
      Map<String, dynamic>? blob;
      if (per != null && per.isNotEmpty) {
        blob = (per[myId] as Map?)?.cast<String, dynamic>();
        if (blob == null && kDebugMode) {
          debugPrint(
              'circle_group_chat: no per_recipient blob for my_member_id=$myId '
              '(keys=${per.keys.toList()}) — dropping to null, not decrypting '
              "another recipient's envelope.");
        }
      } else {
        blob = {
          'ciphertext': msg['ciphertext'],
          'nonce': msg['nonce'],
        };
      }
      if (blob == null || blob['ciphertext'] == null) return null;
      final senderPub = _senderPublicKey(msg);
      if (senderPub == null) return null;
      final pt = _e2e.decrypt(
        self: widget.identity,
        senderPublicKey: senderPub,
        ct: Ciphertext(
          scheme: '${msg['scheme'] ?? _e2e.scheme}',
          ciphertextB64: '${blob['ciphertext']}',
          nonceB64: '${blob['nonce']}',
          senderKeyId: '${msg['sender_key_id'] ?? ''}',
        ),
      );
      return pt;
    } catch (_) {
      return null;
    }
  }

  Uint8List? _senderPublicKey(Map<String, dynamic> msg) {
    final sid = '${msg['sender_id'] ?? ''}';
    for (final m in _members) {
      if ('${_idOf(m)}' == sid && m['public_key'] != null) {
        try {
          return Uint8List.fromList(base64Decode('${m['public_key']}'));
        } catch (_) {}
      }
    }
    return null;
  }
}
