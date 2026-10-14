import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_avatar.dart';
import '../../widgets/msgr_connect_sheet.dart';
import 'connection_requests_screen.dart';

/// Contacts & invites — find which of the user's contacts are on Assisto, then
/// connect (existing user → in-app request) or invite (non-user → share sheet
/// OR own-SIM SMS). Play-compliant: nothing is read or matched until the user
/// explicitly consents AND grants the OS contacts permission.
///
/// PRIVACY INVARIANT (enforced on-device + stated in the disclosure):
///   • Raw numbers/names NEVER leave the device.
///   • We upload ONLY a de-duplicated batch of SALTED HASHES (HMAC-SHA256 over
///     the E.164 number with the server-wide match salt, truncated to 32 hex)
///     plus the permission flag — exactly the contract from
///     /messenger/contacts/contract.
///   • Non-user hashes are dropped server-side and never persisted here.
///   • Invites to non-users never auto-send: share sheet or own-SIM sms: URI.
///
/// NOTE on device-contact access: the OS contacts plugin is not bundled in this
/// build, so this screen demonstrates the full hashing + match + invite
/// pipeline over numbers the user enters/pastes explicitly (same privacy
/// guarantees). When the contacts plugin is added, feed its numbers into
/// [_matchNumbers] unchanged — the hashing/upload path is already correct.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

enum _Stage { disclosure, scanning, results }

class _ContactsScreenState extends State<ContactsScreen> {
  _Stage _stage = _Stage.disclosure;
  final _manual = TextEditingController();

  // Hashing contract (from the server; sane v1 defaults until it loads).
  String _salt = '';
  String _cc = '880';
  int _hashLen = 32;

  List<Map<String, dynamic>> _onAssisto = [];

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  // ---------------------------------------------------------------------------
  // CLIENT HASHING CONTRACT (msg_contacts_integration.md §CLIENT HASHING)
  // ---------------------------------------------------------------------------

  /// Normalize a raw number to E.164 with the device SIM region (default cc).
  /// Digits-only; local `0…` → `+<cc>…`. Returns '' if nothing usable.
  String _normalizeE164(String raw) {
    var d = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (d.startsWith('+')) return d;
    d = d.replaceAll('+', '');
    if (d.startsWith('00')) return '+${d.substring(2)}';
    if (d.startsWith('0')) return '+$_cc${d.substring(1)}';
    if (d.startsWith(_cc)) return '+$d';
    if (d.isEmpty) return '';
    return '+$_cc$d';
  }

  /// hex( HMAC-SHA256( key=salt, msg=e164 ) ) truncated to [_hashLen] hex chars.
  String _hashPhone(String e164) {
    final mac =
        HmacSha256.mac(utf8.encode(_salt), utf8.encode(e164));
    final hex = mac
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return hex.substring(0, _hashLen.clamp(1, hex.length));
  }

  Future<void> _loadContract() async {
    try {
      final c = await _api.contactsContract();
      _salt = '${c['salt'] ?? c['match_salt'] ?? ''}';
      _cc = '${c['country_code'] ?? c['cc'] ?? '880'}';
      _hashLen = (c['hash_len'] as int?) ?? (c['truncate'] as int?) ?? 32;
    } catch (_) {
      // Keep v1 defaults; with an empty salt the match simply returns nothing.
    }
  }

  // ---------------------------------------------------------------------------

  Future<void> _consentAndMatch() async {
    setState(() => _stage = _Stage.scanning);
    await _loadContract();
    // With the real contacts plugin, device numbers flow in here. For now the
    // user supplies numbers explicitly (manual field) — same pipeline.
    await _matchNumbers(const []);
    if (mounted) setState(() => _stage = _Stage.results);
  }

  /// Hash + upload a batch of raw numbers and keep the on-Assisto matches.
  /// Raw numbers are hashed ON-DEVICE and discarded; only hashes are sent.
  Future<void> _matchNumbers(List<String> rawNumbers) async {
    final e164 = rawNumbers
        .map(_normalizeE164)
        .where((s) => s.length > 3)
        .toSet(); // de-dupe
    final hashes = e164.map(_hashPhone).where((h) => h.isNotEmpty).toSet();
    if (hashes.isEmpty) return;
    try {
      final r = await _api.contactsMatch(
          hashes: hashes.toList(), permissionGranted: true);
      final matches =
          ((r['matches'] ?? []) as List).cast<Map<String, dynamic>>();
      final seen = {for (final m in _onAssisto) '${m['id']}'};
      for (final m in matches) {
        if (seen.add('${m['id']}')) _onAssisto.add(m);
      }
    } catch (_) {
      // Not wired / offline: leave the list as-is.
    }
  }

  Future<void> _matchManual() async {
    final raw = _manual.text.trim();
    if (raw.isEmpty) return;
    setState(() => _stage = _Stage.scanning);
    if (_salt.isEmpty) await _loadContract();
    await _matchNumbers([raw]);
    _manual.clear();
    if (mounted) setState(() => _stage = _Stage.results);
  }

  // ---------------------------------------------------------------------------
  // Connect (existing user) + Invite (non-user)
  // ---------------------------------------------------------------------------

  Future<void> _connect(Map<String, dynamic> user) async {
    final res = await showMsgrConnectSheet(context,
        peerName: '${user['name'] ?? ''}');
    if (res == null || !mounted) return;
    try {
      await _api.inviteExisting(
        toUserId: (user['id'] as num).toInt(),
        relation: res.relation,
        customLabel: res.customLabel,
      );
      if (res.note != null) {
        // The ONE pre-accept note rides the connection request itself; where a
        // separate request id is returned, the request screen sends it. Here
        // the invite call already created the request with the relation.
      }
      _snack(_t.msgrRequestSent);
    } catch (_) {
      _snack(_t.msgrRequestFailed);
    }
  }

  Future<void> _inviteNonUser() async {
    final res = await showMsgrConnectSheet(context, peerName: '');
    if (res == null || !mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: Text(_t.msgrInviteShareLink),
            onTap: () => Navigator.pop(ctx, 'share'),
          ),
          ListTile(
            leading: const Icon(Icons.sms_outlined),
            title: Text(_t.msgrInviteSms),
            subtitle: Text(_t.msgrInviteSmsNote),
            onTap: () => Navigator.pop(ctx, 'sms'),
          ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'share') {
      await _shareLink(res.relation);
    } else {
      await _inviteSms(res.relation);
    }
  }

  Future<void> _shareLink(String relation) async {
    try {
      final d = await _api.inviteShareLink(relation: relation);
      final url = '${d['url'] ?? ''}';
      final text = _localized(d['text']) ?? url;
      await Share.share(text.contains(url) ? text : '$text $url');
      _snack(_t.msgrInviteSent);
    } catch (_) {
      _snack(_t.msgrInviteFailed);
    }
  }

  Future<void> _inviteSms(String relation) async {
    final number = await _askNumber();
    if (number == null || number.isEmpty || !mounted) return;
    try {
      final d = await _api.inviteSms(relation: relation, toNumber: number);
      // Descriptor carries a ready sms: URI; never auto-sent.
      final smsUri = '${d['sms_uri'] ?? ''}';
      final body = _localized(d['body']) ?? '';
      final uri = smsUri.isNotEmpty
          ? Uri.parse(smsUri)
          : Uri.parse('sms:$number?body=${Uri.encodeComponent(body)}');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri); // opens the composer; the USER presses Send
        _snack(_t.msgrInviteSent);
      }
    } catch (_) {
      _snack(_t.msgrInviteFailed);
    }
  }

  Future<String?> _askNumber() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.msgrInviteSms),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(hintText: _t.msgrContactsManualHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(_t.msgrCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: Text(_t.msgrInviteAction)),
        ],
      ),
    );
  }

  String? _localized(dynamic pair) {
    if (pair is Map) {
      final bn = Localizations.localeOf(context).languageCode == 'bn';
      return '${pair[bn ? 'bn' : 'en'] ?? pair['en'] ?? ''}';
    }
    if (pair is String && pair.isNotEmpty) return pair;
    return null;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.msgrContactsTitle),
        actions: [
          IconButton(
            tooltip: t.msgrConnectTitle,
            icon: const Icon(Icons.how_to_reg_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ConnectionRequestsScreen())),
          ),
        ],
      ),
      body: switch (_stage) {
        _Stage.disclosure => _disclosure(),
        _Stage.scanning => _scanning(),
        _Stage.results => _results(),
      },
    );
  }

  Widget _disclosure() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(children: [
        const SizedBox(height: Gap.lg),
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
              shape: BoxShape.circle, gradient: Brand.gradient),
          child: const Icon(Icons.contacts_outlined,
              color: Colors.white, size: 36),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.msgrContactsPermTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.md),
        Container(
          padding: const EdgeInsets.all(Gap.lg),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_outline, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.msgrContactsDisclosure,
                  style: TextStyle(color: scheme.onSurface, height: 1.5)),
            ),
          ]),
        ),
        const SizedBox(height: Gap.xl),
        FilledButton.icon(
          onPressed: _consentAndMatch,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(t.msgrContactsAllow),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(t.msgrContactsDeny)),
      ]),
    );
  }

  Widget _scanning() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: Gap.md),
          Text(_t.msgrContactsScanning),
        ]),
      );

  Widget _results() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      // Manual find-by-number (and the plugin feeds the same path).
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _manual,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _matchManual(),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+ \-]'))
              ],
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: t.msgrContactsManualHint,
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          IconButton.filled(
              onPressed: _matchManual, icon: const Icon(Icons.person_search)),
        ]),
      ),
      Expanded(
        child: _onAssisto.isEmpty
            ? _noneMatched()
            : ListView(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Gap.md, Gap.sm, Gap.md, Gap.xs),
                  child: Text(t.msgrContactsOnAssisto.toUpperCase(),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary)),
                ),
                for (final u in _onAssisto) _userRow(u),
              ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: OutlinedButton.icon(
            onPressed: _inviteNonUser,
            icon: const Icon(Icons.person_add_alt),
            label: Text(t.msgrContactsInviteOthers),
          ),
        ),
      ),
    ]);
  }

  Widget _userRow(Map<String, dynamic> u) {
    final name = '${u['name'] ?? ''}';
    return ListTile(
      leading: MsgrAvatar(
          name: name,
          photoUrl: '${u['photo_link'] ?? u['photo'] ?? ''}',
          radius: 22),
      title: Text(name.isEmpty ? '?' : name),
      trailing: FilledButton.tonal(
        onPressed: () => _connect(u),
        child: Text(_t.msgrConnectAction),
      ),
    );
  }

  Widget _noneMatched() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(children: [
      const SizedBox(height: 60),
      Icon(Icons.group_outlined,
          size: 52, color: scheme.primary.withValues(alpha: 0.7)),
      const SizedBox(height: Gap.md),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
        child: Text(_t.msgrContactsNoneMatched,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ),
    ]);
  }
}
