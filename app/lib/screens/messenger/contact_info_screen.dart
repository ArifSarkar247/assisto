import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../widgets/msgr_avatar.dart';
import '../../api.dart';
import '../../calls/call_sound_tiles.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_chat_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../../widgets/chat_menu_pickers.dart';
import '../../widgets/circle_relation.dart';
import '../../messaging/presence_label.dart';
import '../../realtime/realtime_channel.dart';
import 'starred_messages_screen.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// CONTACT INFO screen for a 1:1 chat (.phaseB/MESSENGER_UI_FULL.md §4).
///
/// Shows: photo, name, about, phone, media/links/docs, starred, mute, custom
/// notifications, disappearing, chat lock, encryption note, groups in common,
/// relationship (Connected circle), Block, Report. Original Assisto identity.
///
/// Facts come from GET /circle/<peer>/info (fields the owner hid are already
/// filtered server-side via circle_privacy.can_see_field). Each control is
/// LIVE or shows an honest "backend pending" state — NO dead taps. All copy is
/// AppLocalizations; zero Bangla here.
class ContactInfoScreen extends StatefulWidget {
  final Map<String, dynamic> member;

  /// Returns the last-five DECRYPTED messages (newest last) for a Report, built
  /// on-device by the chat screen (the server holds ciphertext only).
  final List<Map<String, dynamic>> Function()? decryptedLastFive;

  const ContactInfoScreen({
    super.key,
    required this.member,
    this.decryptedLastFive,
  });

  @override
  State<ContactInfoScreen> createState() => _ContactInfoScreenState();
}

class _ContactInfoScreenState extends State<ContactInfoScreen> {
  Map<String, dynamic> _info = const {};
  bool _loading = true;
  bool _loadFailed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  // Local mirrors (confirmed from server payload on load).
  bool _muted = false;
  int _disappearingSec = 0;
  bool _blocked = false;

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);
  int get _peerId => (widget.member['id'] as int?) ?? 0;
  String get _name => '${widget.member['name'] ?? ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.contactInfo(_peerId);
      _info = r;
      _muted = r['muted_until'] != null;
      _disappearingSec = (r['disappearing_sec'] as int?) ?? 0;
      _blocked = r['blocked'] == true;
      _loadFailed = false;
    } catch (e) {
      // Honest: show a retry, never a made-up profile.
      _loadFailed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  void _fail(Object e) => _toast(e is ApiException && e.message.isNotEmpty
      ? e.message
      : _t.grpActionFailed);

  // --- controls ---------------------------------------------------------
  Future<void> _toggleMute(bool on) async {
    if (!on) {
      try {
        await _api.setChatMute(_peerId, null);
        if (mounted) setState(() => _muted = false);
      } catch (e) {
        _fail(e);
      }
      return;
    }
    final d = await showMutePicker(context);
    if (d == null || !mounted) return;
    final until = d == Duration.zero
        ? DateTime.utc(2099).toIso8601String()
        : DateTime.now().toUtc().add(d).toIso8601String();
    try {
      await _api.setChatMute(_peerId, until);
      if (mounted) setState(() => _muted = true);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _editDisappearing() async {
    final sec = await showDisappearingPicker(context, _disappearingSec);
    if (sec == null || !mounted) return;
    try {
      await _api.setDisappearing(_peerId, sec);
      if (mounted) setState(() => _disappearingSec = sec);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _toggleBlock() async {
    final next = !_blocked;
    try {
      await _api.blockContact(_peerId, on: next);
      if (mounted) setState(() => _blocked = next);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _report() async {
    final res = await showChatReportPicker(context);
    if (res == null || !mounted) return;
    final last5 = widget.decryptedLastFive?.call() ?? const [];
    try {
      await _api.reportLast5(
        peerId: _peerId,
        reason: res.reason,
        decryptedLastFive: last5,
      );
      if (res.alsoBlock) {
        await _api.blockContact(_peerId, on: true);
        if (mounted) setState(() => _blocked = true);
      }
      if (mounted) _toast(_t.msgrChatReportSent);
    } catch (e) {
      _fail(e);
    }
  }

  String _disappearingLabel(int sec) {
    switch (sec) {
      case 86400:
        return _t.msgrChatDisap24h;
      case 604800:
        return _t.msgrChatDisap7d;
      case 7776000:
        return _t.msgrChatDisap90d;
      default:
        return _t.msgrChatDisapOff;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final about = '${_info['about'] ?? ''}';
    final phone = '${_info['phone'] ?? ''}';
    final relation = '${_info['relation'] ?? widget.member['relation'] ?? 'friend'}';
    final mediaCount = (_info['media_count'] as int?) ?? 0;
    final linkCount = (_info['link_count'] as int?) ?? 0;
    final docCount = (_info['doc_count'] as int?) ?? 0;
    final starredCount = (_info['starred_count'] as int?) ?? 0;
    final groupsInCommon =
        ((_info['groups_in_common'] as List?) ?? const []).cast<dynamic>();
    final fingerprint = (_info['encryption'] is Map)
        ? '${_info['encryption']['fingerprint'] ?? ''}'
        : '';

    return Scaffold(
      appBar: AppBar(title: Text(_t.msgrChatContactInfo)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(honestFailText(_t, _failCause, otherwise: _t.msgLoadFailed), textAlign: TextAlign.center),
                      const SizedBox(height: Gap.md),
                      FilledButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: Text(_t.retry),
                        onPressed: () {
                          setState(() => _loading = true);
                          _load();
                        },
                      ),
                    ]),
                  ),
                )
              : ListView(
              children: [
                _header(scheme, about),
                const SizedBox(height: Gap.sm),

                // About / phone
                if (about.isNotEmpty)
                  _tile(Icons.info_outline, _t.msgrContactAbout, about),
                if (phone.isNotEmpty)
                  _tile(Icons.phone_outlined, _t.msgrContactPhone, phone),

                const Divider(),

                // Media / links / docs
                ListTile(
                  leading: const Icon(Icons.perm_media_outlined),
                  title: Text(_t.msgrContactMediaLinksDocs),
                  subtitle: Text(notifLocalizeDigits(context, '$mediaCount · $linkCount · $docCount')),
                ),
                // Starred
                ListTile(
                  leading: const Icon(Icons.star_outline),
                  title: Text(_t.msgrContactStarred),
                  subtitle: Text(notifLocalizeDigits(context, '$starredCount')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => StarredMessagesScreen(
                          members: [widget.member]))),
                ),

                const Divider(),

                // Mute
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_off_outlined),
                  title: Text(_t.msgrChatMute),
                  value: _muted,
                  onChanged: _toggleMute,
                ),
                // Disappearing
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(_t.msgrChatDisappearing),
                  subtitle: Text(_disappearingLabel(_disappearingSec)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _editDisappearing,
                ),

                const Divider(),

                // Encryption note
                ListTile(
                  leading: Icon(Icons.verified_user_outlined,
                      color: scheme.primary),
                  title: Text(_t.msgrContactEncryption),
                  subtitle: Text(fingerprint.isEmpty
                      ? _t.msgrContactEncryptionHint
                      : fingerprint),
                ),

                // Relationship (Connected circle)
                _tile(
                  Icons.diversity_3_outlined,
                  _t.msgrContactRelationship,
                  CircleRelation.labelFor(_t, relation,
                      custom: '${_info['custom_label'] ?? widget.member['custom_label'] ?? ''}'),
                ),

                // Groups in common
                if (groupsInCommon.isNotEmpty) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Gap.lg, Gap.sm, Gap.lg, Gap.xs),
                    child: Text(_t.msgrContactGroupsInCommon,
                        style: Theme.of(context).textTheme.labelLarge),
                  ),
                  for (final g in groupsInCommon)
                    ListTile(
                      leading: const Icon(Icons.groups_outlined),
                      title: Text('${(g is Map ? g['name'] : g) ?? ''}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],

                // c2-calls: per-contact ringtone (the phone's own picker)
                if (_peerId > 0) ...[
                  const Divider(),
                  SoundPickTile(
                      kind: SoundPickKind.contact, chatId: '$_peerId'),
                ],

                const Divider(),

                // Block / Report
                ListTile(
                  leading: Icon(Icons.block, color: scheme.error),
                  title: Text(_blocked ? _t.circleUnblock : _t.circleBlock,
                      style: TextStyle(color: scheme.error)),
                  onTap: _toggleBlock,
                ),
                ListTile(
                  leading: Icon(Icons.flag_outlined, color: scheme.error),
                  title: Text(_t.circleReport,
                      style: TextStyle(color: scheme.error)),
                  onTap: _report,
                ),
                const SizedBox(height: Gap.xl),
              ],
            ),
    );
  }

  Widget _header(ColorScheme scheme, String about) {
    final photo = '${widget.member['photo_link'] ?? widget.member['photo'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.lg),
      child: Column(
        children: [
          // x2-ticks (A3): cached real photo (signed link resolved,
          // refreshed when the contact changes it), initials otherwise.
          MsgrAvatar(
            key: const Key('x2-info-avatar'),
            name: _name,
            radius: 44,
            photoUrl: photo,
            photoV: '${widget.member['photo_v'] ?? ''}',
          ),
          const SizedBox(height: Gap.md),
          Text(_name,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center),
          // mr1: the same full last-seen line as the chat header (live;
          // hidden by privacy -> no line).
          ValueListenableBuilder<Map<String, RtChatState>>(
            valueListenable: RealtimeChannel.instance.states,
            builder: (ctx, _, __) {
              final p = presenceLabel(
                  _t, RealtimeChannel.instance.stateOf('member', _peerId),
                  lang: Localizations.localeOf(ctx).languageCode,
                  use24h: MediaQuery.of(ctx).alwaysUse24HourFormat);
              if (p == null || p.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(p,
                    key: const Key('mr1-info-last-seen'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _tile(IconData icon, String label, String value) => ListTile(
        leading: Icon(icon),
        title: Text(value),
        subtitle: Text(label),
      );
}
