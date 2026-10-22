import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../config.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../messenger_admin_api.dart';
import '../messenger_group_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_group_poll.dart';
import '../messaging/chat_header.dart'; // t1-ticks
import '../messaging/date_separators.dart'; // t1-ticks
import '../messaging/mc_version_gate.dart'; // t1-ticks
import '../messaging/c3_api.dart';
import '../messaging/msg_notify.dart';
import '../messaging/msg_ticks.dart';
import '../messaging/msg_widgets.dart';
import '../messaging/presence_label.dart';
import '../messaging/unread_store.dart';
import '../realtime/realtime_channel.dart';
import '../widgets/group_menu_media.dart';
import '../widgets/group_export.dart';
import '../widgets/group_menu_sheet.dart';
import '../widgets/msgr_mod_report_sheet.dart';
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
  bool _loadFailed = false; // §21 honest load error + retry
  bool _sending = false;
  // §21 failed-send: the last text that could not be sent, kept so the user can
  // resend without retyping. Null when the last send succeeded.
  String? _failedText;
  Map<String, dynamic>? _replyTo;

  // Group ⋮ driven UI modes.
  bool _searching = false;
  String _searchQuery = '';
  bool _selecting = false;
  final Set<String> _selected = {};
  bool get _isFavourite => widget.group['favourite'] == true;

  // c3-msg: live typing (RealtimeChannel), seen on open, light poll while
  // open so ticks and new messages update without a manual refresh.
  final _rt = RealtimeChannel.instance;
  Timer? _poll;
  int get _gid => int.tryParse(_groupId) ?? 0;
  String get _chatKey => 'group:$_gid';

  @override
  void initState() {
    super.initState();
    MsgActiveChat.current = _chatKey;
    UnreadStore.instance.clear(_chatKey);
    unawaited(FlnMsgSink().cancel('group', _gid));
    _rt.acquire();
    _rt.states.addListener(_onRt);
    _load().then((_) => _markSeen());
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _pollMessages());
  }

  @override
  void dispose() {
    if (MsgActiveChat.current == _chatKey) MsgActiveChat.current = null;
    _poll?.cancel();
    _rt.states.removeListener(_onRt);
    _rt.typing('group', _gid, 'stop');
    _rt.release();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onRt() {
    if (mounted) setState(() {});
  }

  Future<void> _markSeen() async {
    final ls = WidgetsBinding.instance.lifecycleState;
    if (ls != null && ls != AppLifecycleState.resumed) return;
    UnreadStore.instance.clear(_chatKey);
    try {
      await _api.c3ChatSeen('group', _gid);
    } catch (_) {
      // Retried on the next poll tick / reopen; the local badge is already 0.
    }
  }

  bool _pollBusy = false;
  Future<void> _pollMessages() async {
    if (_pollBusy || _loading || !mounted) return;
    final ls = WidgetsBinding.instance.lifecycleState;
    if (ls != null && ls != AppLifecycleState.resumed) return;
    _pollBusy = true;
    try {
      final msg = await _api.getJson('/circle/groups/$_groupId/messages');
      final next = ((msg['results'] ?? msg['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      final known = _messages.map((m) => '${m['id']}').toSet();
      final fresh = next.any((m) => m['mine'] != true && !known.contains('${m['id']}'));
      final changed = next.length != _messages.length ||
          fresh ||
          [for (var i = 0; i < next.length && i < _messages.length; i++) i]
              .any((i) => '${next[i]['status']}' != '${_messages[i]['status']}');
      if (changed && mounted) setState(() => _messages = next);
      if (fresh) unawaited(_markSeen());
    } catch (_) {
    } finally {
      _pollBusy = false;
    }
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
    if (mounted && !_loading) setState(() => _loading = true);
    try {
      final mem = await _api.getJson('/circle/groups/$_groupId/members');
      _members = ((mem['results'] ?? mem['members'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      final msg = await _api.getJson('/circle/groups/$_groupId/messages');
      _messages = ((msg['results'] ?? msg['messages'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      _loadFailed = false;
    } catch (_) {
      // Keep any already-loaded messages visible; only flag the error so the
      // UI can offer Retry instead of silently showing an empty chat.
      _loadFailed = _messages.isEmpty;
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
  Future<void> _send({String? resendText}) async {
    final text = resendText ?? _input.text.trim();
    if (text.isEmpty || _sending || !_canPost) return;
    _rt.typing('group', _gid, 'stop');
    // §21: if there is no one to encrypt to, say so instead of a silent no-op.
    if (_recipients.isEmpty) {
      _toast(_t.grpNoRecipients);
      return;
    }
    setState(() {
      _sending = true;
      _failedText = null;
    });
    final perRecipient = <String, dynamic>{};
    final recipientIds = <int>[];
    var skipped = 0;
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
      } catch (_) {
        skipped++;
      }
    }
    // seam audit: a member whose key is broken used to be dropped silently.
    if (skipped > 0) _toast(_t.c3SkippedRecipients(skipped));
    final mentions = _parseMentions(text);
    var ok = true;
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
    } catch (_) {
      ok = false;
    }
    if (ok) {
      _input.clear();
      _replyTo = null;
      _failedText = null;
    } else {
      // §21 honest failed-send: keep the text so the user can resend, and
      // surface a failure banner (rendered above the composer).
      _failedText = text;
    }
    if (mounted) setState(() => _sending = false);
    if (ok) await _load();
  }

  /// Parse @mentions into MEMBER IDS (never names leave the device as plaintext
  /// routing — the server only gets ids).
  ///
  /// A token is resolved only on an EXACT (case-insensitive) name match against
  /// the roster — never a startsWith prefix, which could mention the wrong
  /// member (e.g. "@Sa" hitting "Sabrina" instead of "Sadia"). If a token is
  /// ambiguous (matches >1 member) or matches none, it is left as plain text.
  ///
  /// Works today from typed "@Name" text. Later UX upgrade (not a stub): an
  /// inline @-picker that inserts the member id directly, removing name
  /// collisions.
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
    } catch (e) {
      _fail(e);
    }
    await _load();
  }

  Future<void> _togglePin(Map<String, dynamic> msg) async {
    if (_myRole != 'admin') return; // admin-only (server re-enforces)
    final pinned = msg['pinned'] == true;
    try {
      await _api.postJson('/circle/groups/$_groupId/messages/${msg['id']}/pin',
          {'pin': !pinned});
    } catch (e) {
      _fail(e);
    }
    await _load();
  }

  Future<void> _call(String kind) async {
    // Group VOICE is free; group VIDEO requires a Premium initiator. The server
    // is the authority (can_place_group_call); the client shows the result.
    try {
      final r = await _api
          .postJson('/circle/groups/$_groupId/call', {'kind': kind});
      if (!mounted) return;
      if (r['allowed'] == false &&
          (r['upgrade_required'] == true || r['needs_video_plan'] == true)) {
        _showVideoUpgrade();
        return;
      }
      if (r['allowed'] == false) {
        _toast(_t.grpActionFailed);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t.circleGroupCallStarting)));
    } catch (e) {
      _fail(e);
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
    } catch (e) {
      _fail(e);
    }
    await _load();
  }

  Future<void> _vote(Map<String, dynamic> poll, List<int> choices) async {
    try {
      await _api.postJson('/circle/groups/$_groupId/polls/${poll['id']}/vote',
          {'choices': choices});
    } catch (e) {
      _fail(e);
    }
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

  // -------------------------------------------------------------------------
  // GROUP CHAT ⋮ menu (group-flavoured mirror of the 1:1 chat ⋮). Every item
  // routes to a real handler below — no dead taps.
  // -------------------------------------------------------------------------
  Future<void> _openMenu() async {
    final action =
        await showGroupMenuSheet(context, isFavourite: _isFavourite);
    if (action == null || !mounted) return;
    switch (action) {
      case GroupMenuAction.groupInfo:
        _openInfo();
      case GroupMenuAction.groupMedia:
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => GroupMediaScreen(groupId: _groupId)));
      case GroupMenuAction.search:
        setState(() => _searching = true);
      case GroupMenuAction.selectMessages:
        setState(() {
          _selecting = true;
          _selected.clear();
        });
      case GroupMenuAction.mute:
        await _chooseMute();
      case GroupMenuAction.disappearing:
        await _chooseDisappearing();
      case GroupMenuAction.chatTheme:
        await _chooseTheme();
      case GroupMenuAction.addToFavourites:
        await _toggleFavourite();
      case GroupMenuAction.exportChat:
        await _exportChat();
      case GroupMenuAction.sendCallLink:
        await _sendCallLink();
      case GroupMenuAction.scheduleCall:
        await _scheduleCall();
      case GroupMenuAction.newGroupCall:
        await _call('video'); // group video = Premium-gated at placement
      case GroupMenuAction.summarise:
        await _aiTask('summarise', _t.grpSummariseTitle);
      case GroupMenuAction.makeReminder:
        await _makeReminder();
      case GroupMenuAction.translate:
        await _translate();
      case GroupMenuAction.addMembers:
        _openInfo(); // add-members lives in Group info (circle-only, admin)
      case GroupMenuAction.exitGroup:
        await _exitGroup();
      case GroupMenuAction.reportGroup:
        await _reportGroup();
      case GroupMenuAction.clearChat:
        await _clearChat();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Honest failure: the server's own reason when it gave one, else a
  /// generic "couldn't do that". Never a fake "pending".
  void _fail(Object e) =>
      _toast(e is ApiException && e.message.isNotEmpty
          ? e.message
          : _t.grpActionFailed);

  Future<void> _chooseMute() async {
    final v = await showGroupOptionPicker(
      context,
      title: _t.grpMenuMute,
      current: '${widget.group['mute'] ?? 'off'}',
      options: [
        ('8h', _t.grpMute8h),
        ('1w', _t.grpMute1Week),
        ('always', _t.grpMuteAlways),
        if ('${widget.group['mute'] ?? 'off'}' != 'off')
          ('off', _t.msgGrpUnmute),
      ],
    );
    if (v == null) return;
    try {
      final r = await _api.groupSetMute(_groupId, v);
      setState(() => widget.group['mute'] = '${r['mute'] ?? v}');
      _toast(v == 'off' ? _t.msgGrpUnmuted : _t.grpMuted);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _chooseDisappearing() async {
    final v = await showGroupOptionPicker(
      context,
      title: _t.grpMenuDisappearing,
      current: '${widget.group['disappearing'] ?? 'off'}',
      options: [
        ('off', _t.grpDisappearOff),
        ('24h', _t.grpDisappear24h),
        ('7d', _t.grpDisappear7d),
        ('90d', _t.grpDisappear90d),
      ],
    );
    if (v == null) return;
    try {
      await _api.groupSetDisappearing(_groupId, v);
      setState(() => widget.group['disappearing'] = v);
      _toast(_t.grpDisappearingSet);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _chooseTheme() async {
    final v = await showGroupOptionPicker(
      context,
      title: _t.grpMenuChatTheme,
      current: '${widget.group['theme'] ?? 'default'}',
      options: [
        ('default', _t.grpThemeDefault),
        ('ocean', _t.grpThemeOcean),
        ('sunset', _t.grpThemeSunset),
        ('forest', _t.grpThemeForest),
      ],
    );
    if (v == null) return;
    try {
      await _api.groupSetTheme(_groupId, color: v);
      setState(() => widget.group['theme'] = v);
      _toast(_t.grpThemeSaved);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _toggleFavourite() async {
    final next = !_isFavourite;
    try {
      await _api.groupSetFavourite(_groupId, next);
      setState(() => widget.group['favourite'] = next);
      _toast(next ? _t.grpFavouriteAdded : _t.grpFavouriteRemoved);
    } catch (e) {
      _fail(e);
    }
  }

  /// Export: the server returns a SIGNED link to a JSON file of what it holds
  /// (metadata + my own ciphertext envelopes); this device decrypts it and
  /// shares the readable .txt. Plaintext never goes back to the server.
  Future<void> _exportChat() async {
    try {
      final r = await _api.groupExport(_groupId);
      final url = '${r['url'] ?? ''}';
      if (url.isEmpty) {
        _toast(_t.grpActionFailed);
        return;
      }
      final res = await http.get(Uri.parse(
          url.startsWith('http') ? url : '${AppConfig.apiBase}$url'));
      if (res.statusCode != 200) {
        _toast(_t.grpActionFailed);
        return;
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final text = buildGroupExportText(
        data,
        myUserId: _myUserId,
        decrypt: _decryptExportEnvelope,
        labels: GroupExportLabels(
          header: _t.msgExportHeader,
          unreadable: _t.msgExportUnreadable,
          deleted: _t.msgExportDeleted,
          media: _t.msgExportMedia,
          you: _t.msgExportYou,
        ),
      );
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/${exportFileName('${widget.group['name'] ?? ''}')}');
      await f.writeAsString(text);
      await Share.shareXFiles([XFile(f.path)]);
    } catch (e) {
      _fail(e);
    }
  }

  /// My User id (the roster row flagged is_self).
  int get _myUserId {
    for (final m in _members) {
      if (m['is_self'] == true) return (m['user_id'] as num?)?.toInt() ?? -1;
    }
    return -1;
  }

  String? _decryptExportEnvelope(
      Map<String, dynamic> env, int senderId, String senderKeyId) {
    try {
      // My own message: opened with MY key + the recipient's public key.
      final peerMember = env['peer_member_id'];
      Uint8List? pub;
      if (peerMember != null) {
        for (final m in _members) {
          if ('${m['member_id']}' == '$peerMember' && m['public_key'] != null) {
            pub = Uint8List.fromList(base64Decode('${m['public_key']}'));
          }
        }
      } else {
        pub = _senderPublicKey({'sender_id': senderId});
      }
      if (pub == null || env['ciphertext'] == null) return null;
      return _e2e.decrypt(
        self: widget.identity,
        senderPublicKey: pub,
        ct: Ciphertext(
          scheme: _e2e.scheme,
          ciphertextB64: '${env['ciphertext']}',
          nonceB64: '${env['nonce']}',
          senderKeyId: senderKeyId,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendCallLink() async {
    try {
      final r = await _api.groupCallLink(_groupId);
      final url = '${r['url'] ?? ''}';
      if (url.isNotEmpty) {
        await Share.share(url);
      } else {
        _toast(_t.grpActionFailed);
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _scheduleCall() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      initialDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    final at = DateTime(
        date.year, date.month, date.day, time.hour, time.minute);
    try {
      await _api.groupScheduleCall(_groupId, at: at.toUtc().toIso8601String());
      _toast(_t.grpCallScheduled);
    } catch (e) {
      _fail(e);
    }
  }

  /// Assisto extras (Summarise / Translate) — the AI runs ONLY on the group's
  /// already-decrypted messages collected on this device; the server AI never
  /// sees group ciphertext.
  Future<void> _aiTask(String task, String title, {String lang = ''}) async {
    final plain = _messages
        .map(_decryptForMe)
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (plain.isEmpty) {
      _toast(_t.grpNothingToProcess);
      return;
    }
    try {
      final r = await _api.groupAiTask(_groupId, task,
          messages: plain, targetLang: lang);
      if (r['allowed'] == false) {
        // Honest server state: no AI key / budget / not enough credits.
        _toast('${r['message'] ?? _t.grpActionFailed}');
        return;
      }
      var result = '${r['result'] ?? ''}';
      final rem = r['reminder'];
      if (task == 'reminder' && rem is Map) {
        result = _t.msgReminderSaved('${rem['title'] ?? ''}');
      }
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
              child: Text(result.isEmpty ? _t.grpNoResult : result)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: Text(_t.close)),
          ],
        ),
      );
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _translate() async {
    final lang = await showGroupOptionPicker(
      context,
      title: _t.grpMenuTranslate,
      options: [
        ('bn', _t.grpLangBangla),
        ('en', _t.grpLangEnglish),
      ],
    );
    if (lang == null) return;
    await _aiTask('translate', _t.grpTranslateTitle, lang: lang);
  }

  /// Make a reminder from the chat — route into the Assisto reminders flow via
  /// the extras AI task; the server returns a draft the reminders module books.
  Future<void> _makeReminder() async {
    await _aiTask('reminder', _t.grpMakeReminderTitle);
  }

  Future<void> _exitGroup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.grpMenuExitGroup),
        content: Text(_t.circleGroupLeaveConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.grpMenuExitGroup)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await _api.postJson('/circle/groups/$_groupId/leave', {});
      if (r['allowed'] == false || r['left'] == false) {
        _toast(_t.grpExitLastAdmin);
        return;
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      // LAST-ADMIN protection: the server answers 403 promote_before_leaving.
      if (e.status == 403) {
        _toast(_t.grpExitLastAdmin);
      } else {
        _fail(e);
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _reportGroup() async {
    // Funnels into the ONE moderation engine (/moderation/report) — no private
    // report path. The sheet collects categories + note and submits.
    await MsgrReportSheet.show(
      context,
      targetKind: ModTargets.group,
      targetId: _groupId,
    );
  }

  Future<void> _clearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.grpMenuClearChat),
        content: Text(_t.grpClearChatConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.grpMenuClearChat)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // Per-user marker on the server: hidden for me, kept for the others.
      await _api.groupClear(_groupId);
      if (mounted) setState(() => _messages = []);
    } catch (e) {
      _fail(e);
    }
  }

  // -------------------------------------------------------------------------
  // Select messages — multi-select then delete / forward / star / copy.
  // -------------------------------------------------------------------------
  void _toggleSelect(Map<String, dynamic> msg) {
    final id = '${msg['id']}';
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _exitSelect() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    // §21 confirm gate: deleting messages is destructive.
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.grpConfirmDeleteMsgsTitle),
        content: Text(_t.grpConfirmDeleteMsgsBody('$count')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.grpConfirmDelete)),
        ],
      ),
    );
    if (ok != true) return;
    var failed = 0;
    for (final id in _selected) {
      try {
        await _api
            .postJson('/circle/groups/$_groupId/messages/$id/delete', {});
      } catch (_) {
        failed++;
      }
    }
    _exitSelect();
    if (failed > 0) _toast(_t.grpActionFailed);
    await _load();
  }

  void _copySelected() {
    final text = _messages
        .where((m) => _selected.contains('${m['id']}'))
        .map((m) => _decryptForMe(m) ?? '')
        .where((s) => s.isNotEmpty)
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    _exitSelect();
    _toast(_t.copy);
  }

  Future<void> _starSelected() async {
    var failed = 0;
    for (final id in _selected) {
      try {
        await _api.postJson(
            '/circle/groups/$_groupId/messages/$id/star', {'starred': true});
      } catch (_) {
        failed++;
      }
    }
    _exitSelect();
    _toast(failed > 0 ? _t.grpActionFailed : _t.grpStarred);
  }

  // In-chat search over already-decrypted text (client-side).
  List<Map<String, dynamic>> get _visible {
    if (!_searching || _searchQuery.trim().isEmpty) return _messages;
    final terms = _searchQuery.toLowerCase().trim().split(RegExp(r'\s+'));
    return _messages.where((m) {
      final hay = (_decryptForMe(m) ?? '').toLowerCase();
      return terms.every((tk) => hay.contains(tk));
    }).toList();
  }

  PreferredSizeWidget _normalAppBar() => AppBar(
        titleSpacing: 0,
        // t1-ticks: WhatsApp-standard header — name line 1, line 2 = member
        // names ("Rahim, Karim, You") or "Rahim is typing…"; tap -> info.
        title: GroupHeaderTitle(
          name: '${widget.group['name'] ?? ''}',
          memberNames: [
            for (final m in _members)
              if (m['is_self'] != true && '${_idOf(m)}' != _myMemberId)
                '${m['name'] ?? ''}'
          ],
          activity: presenceLabel(_t, _rt.stateOf('group', _gid),
              lang: Localizations.localeOf(context).languageCode,
              isGroup: true),
          avatar: HeaderInitialAvatar(
              name: '${widget.group['name'] ?? ''}', group: true),
          onTap: _openInfo,
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
            tooltip: _t.grpMenuMore,
            icon: const Icon(Icons.more_vert),
            onPressed: _openMenu,
          ),
        ],
      );

  PreferredSizeWidget _searchAppBar() => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _searching = false;
            _searchQuery = '';
          }),
        ),
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(
              hintText: _t.grpMenuSearch, border: InputBorder.none),
          onChanged: (v) => setState(() => _searchQuery = v),
        ),
      );

  PreferredSizeWidget _selectAppBar() => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelect,
        ),
        title: Text(_t.grpSelectedCount('${_selected.length}')),
        actions: [
          IconButton(
            tooltip: _t.copy,
            icon: const Icon(Icons.copy_outlined),
            onPressed: _selected.isEmpty ? null : _copySelected,
          ),
          IconButton(
            tooltip: _t.grpStar,
            icon: const Icon(Icons.star_border),
            onPressed: _selected.isEmpty ? null : _starSelected,
          ),
          IconButton(
            tooltip: _t.grpDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: _selected.isEmpty ? null : _deleteSelected,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final pinned =
        _messages.where((m) => m['pinned'] == true).toList();
    return Scaffold(
      appBar: _selecting
          ? _selectAppBar()
          : _searching
              ? _searchAppBar()
              : _normalAppBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? _errorRetry()
              : Column(
                  children: [
                    // t1-ticks: min-version gate (never blocks sending).
                    if (!_searching && _gid > 0)
                      McVersionBanner(api: _api, kind: 'group', chatId: _gid),
                    if (pinned.isNotEmpty && !_searching && !_selecting)
                      _pinnedBar(pinned),
                    Expanded(child: _messageList()),
                    if (_failedText != null && !_searching && !_selecting)
                      _failedSendBanner(),
                    if (_replyTo != null && !_searching && !_selecting)
                      _replyPreview(),
                    if (!_searching && !_selecting) _composer(),
                  ],
                ),
    );
  }

  /// §21 load error: honest message + Retry (keeps any messages already shown).
  Widget _errorRetry() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(_t.msgLoadFailed,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              onPressed: _load,
              label: Text(_t.grpRetry),
            ),
          ],
        ),
      ),
    );
  }

  /// §21 failed-send banner: shown when the last send failed. Offers Resend
  /// (re-encrypts + re-posts the kept text) so a transient failure is recoverable.
  Widget _failedSendBanner() {
    final scheme = Theme.of(context).colorScheme;
    final text = _failedText ?? '';
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.lg, vertical: Gap.sm),
        child: Row(
          children: [
            Icon(Icons.error_outline,
                size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(_t.grpSendFailed,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
            TextButton(
              onPressed: _sending
                  ? null
                  : () => _send(resendText: text),
              child: Text(_t.grpSendRetry),
            ),
            IconButton(
              tooltip: _t.close,
              icon: Icon(Icons.close,
                  size: 18, color: scheme.onErrorContainer),
              onPressed: () => setState(() => _failedText = null),
            ),
          ],
        ),
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
    final items = _visible;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          // QA a6: match the 1:1 chat's empty state (icon + text).
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_searching ? Icons.search_off : Icons.forum_outlined,
                size: 44,
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.7)),
            const SizedBox(height: Gap.md),
            Text(
                _searching ? _t.grpSearchNoResults : _t.circleGroupNoMessages,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
    }
    // t1-ticks: date chips + floating date while scrolling.
    final rows = insertDateSeparators<Map<String, dynamic>>(items,
        (m) => DateTime.tryParse('${m['created_at'] ?? m['at'] ?? ''}'));
    return ChatDateScope(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(Gap.md),
        itemCount: rows.length,
        itemBuilder: (_, i) => buildChatRow(rows[i], _messageItem),
      ),
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
    final selected = _selecting && _selected.contains('${msg['id']}');
    return GestureDetector(
      onLongPress: _selecting ? null : () => _showActions(msg),
      onTap: _selecting ? () => _toggleSelect(msg) : null,
      child: Card(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : announcement
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
              // c3-msg: ticks on my own messages (all members delivered /
              // read → ✓✓ / blue ✓✓; long-press → Info per member).
              if (msg['mine'] == true)
                Align(
                  alignment: Alignment.centerRight,
                  child: TickIcon(
                      tick: tickFrom('${msg['status'] ?? 'sent'}'),
                      baseColor: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
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
            if (msg['mine'] == true)
              ListTile(
                key: const Key('c3-group-info'),
                leading: const Icon(Icons.info_outline),
                title: Text(_t.c3InfoTitle),
                onTap: () {
                  Navigator.pop(ctx);
                  showMessageInfoSheet(
                      context, () => _api.c3MessageInfo('${msg['id']}'));
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
                onChanged: (v) =>
                    _rt.typing('group', _gid, v.trim().isEmpty ? 'stop' : 'typing'),
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
      // c3-msg: MY OWN group message has no blob addressed to me (I never
      // encrypt to myself) — it used to render blank. ECDH is symmetric, so
      // any recipient's blob decrypts with THAT recipient's public key.
      if (msg['mine'] == true && per != null && per.isNotEmpty) {
        for (final e in per.entries) {
          final r = _members.firstWhere(
              (m) => '${_idOf(m)}' == e.key && '${m['public_key'] ?? ''}'.isNotEmpty,
              orElse: () => const {});
          if (r.isEmpty || e.value is! Map) continue;
          final b = (e.value as Map).cast<String, dynamic>();
          final pt = _e2e.decrypt(
            self: widget.identity,
            senderPublicKey: Uint8List.fromList(base64Decode('${r['public_key']}')),
            ct: Ciphertext(
              scheme: '${msg['scheme'] ?? _e2e.scheme}',
              ciphertextB64: '${b['ciphertext']}',
              nonceB64: '${b['nonce']}',
              senderKeyId: '${msg['sender_key_id'] ?? ''}',
            ),
          );
          if (pt != null) return pt;
        }
        return null;
      }
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
      // sender_id is a USER id; the roster carries it as user_id.
      if ('${m['user_id'] ?? _idOf(m)}' == sid && m['public_key'] != null) {
        try {
          return Uint8List.fromList(base64Decode('${m['public_key']}'));
        } catch (_) {}
      }
    }
    return null;
  }
}
