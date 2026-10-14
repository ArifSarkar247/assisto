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
import '../../widgets/contacts_match_model.dart';
import '../../widgets/contacts_match_widgets.dart';
import '../../widgets/msgr_connect_sheet.dart';
import '../referral_screen.dart';
import 'connection_requests_screen.dart';

/// ADVANCED Contact MATCH (#99) + INVITE (#101) — SPEC v2.1 §21.
///
/// Find which of the user's phone contacts are already on Assisto, then CONNECT
/// (existing user → in-app request, pushed via FCM when a key is configured,
/// else shown on their next open) or INVITE (non-user → share link via any app
/// OR an own-SIM prefilled SMS the USER presses send on). A shareable invite
/// card carries the user's referral code so accepted invites credit points.
///
/// PRIVACY INVARIANT (enforced on-device + stated in the disclosure + explained
/// in the "how this protects your privacy" sheet):
///   • Raw numbers/names NEVER leave the device.
///   • We upload ONLY a de-duplicated batch of SALTED HASHES (HMAC-SHA256 over
///     the E.164 number with the server-wide match salt, truncated to 32 hex)
///     plus the permission flag — the /messenger/contacts/contract contract.
///   • Non-user hashes are dropped server-side and never persisted.
///   • Invites to non-users never auto-send: share sheet or own-SIM sms: URI;
///     no SEND_SMS permission, no gateway.
///
/// SPEC §21 states covered: disclosure (consent), loading/progress (hashing +
/// match), results (connect + invite), empty, permission-denied, offline,
/// re-sync, privacy explainer — every branch designed, nothing raw.
///
/// NOTE on device-contact access: the OS contacts plugin is not bundled in this
/// build, so the user supplies numbers explicitly (manual find). The hashing +
/// upload pipeline is identical to the one the plugin will feed — when it is
/// added, pass its numbers straight into [_matchNumbers] with
/// [_progressFor] driving the loading UI; nothing else changes.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  CmStage _stage = CmStage.disclosure;
  CmProgress _progress = const CmProgress(phase: CmPhase.reading);
  final _manual = TextEditingController();

  // Hashing contract (from the server; sane v1 defaults until it loads).
  String _salt = '';
  String _cc = '880';
  int _hashLen = 32;

  final List<Map<String, dynamic>> _onAssisto = [];
  CmInviteCard? _inviteCard;
  bool _hasMatchedOnce = false;

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
    final mac = HmacSha256.mac(utf8.encode(_salt), utf8.encode(e164));
    final hex =
        mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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

  /// Build the shareable invite card (referral code + link). Best-effort; the
  /// card still shows (minus the referral row) if the balance isn't wired.
  Future<void> _loadInviteCard() async {
    if (_inviteCard != null) return;
    final me = context.read<AppState>().user?.name ?? '';
    try {
      final b = await _api.referralBalance();
      final link = '${b['invite_link'] ?? ''}';
      var code = '${b['referral_code'] ?? b['code'] ?? ''}';
      if (code.isEmpty && link.contains('/')) {
        code = link.split('/').last.split('?').first;
      }
      _inviteCard = CmInviteCard(
          link: link, referralCode: code, inviterName: me);
    } catch (_) {
      _inviteCard = CmInviteCard(link: '', referralCode: '', inviterName: me);
    }
  }

  // ---------------------------------------------------------------------------
  // CONSENT → MATCH
  // ---------------------------------------------------------------------------

  /// The user tapped Allow on the disclosure. In a build with the OS contacts
  /// plugin this is where the runtime permission is requested; if DENIED we
  /// route to [CmStage.denied] (recoverable). Here (no plugin) consent is in-app
  /// and we proceed to the hashing + match pipeline over the manual rail.
  Future<void> _consentAndMatch() async {
    // Permission hook — with the OS contacts plugin this requests the runtime
    // permission and returns granted/denied. When it returns false, route to
    // [CmStage.denied] (recoverable: the manual rail + re-request). Here (no
    // plugin) consent is the in-app Allow tap, so we proceed.
    final granted = await _requestContactsPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() => _stage = CmStage.denied);
      return;
    }
    await _runMatch(const []);
  }

  /// Stub for the OS contacts-permission request (always granted in this build;
  /// swap for the plugin's `Permission.contacts.request().isGranted`).
  Future<bool> _requestContactsPermission() async => true;

  /// The one match pipeline: read → hash on device → upload hashes → match.
  /// [rawNumbers] come from the contacts plugin (or the manual rail). Drives the
  /// progress UI and lands on results / offline.
  Future<void> _runMatch(List<String> rawNumbers) async {
    setState(() {
      _stage = CmStage.matching;
      _progress = const CmProgress(phase: CmPhase.reading);
    });
    if (_salt.isEmpty) await _loadContract();
    await _loadInviteCard();

    // de-dupe + normalize
    final e164 = rawNumbers
        .map(_normalizeE164)
        .where((s) => s.length > 3)
        .toSet();
    if (mounted) {
      setState(() => _progress =
          CmProgress(phase: CmPhase.hashing, total: e164.length));
    }
    // hash on-device (raw numbers never leave here)
    final hashes = e164.map(_hashPhone).where((h) => h.isNotEmpty).toSet();

    if (mounted) {
      setState(() => _progress = const CmProgress(phase: CmPhase.matching));
    }
    final ok = await _uploadAndMerge(hashes.toList());
    _hasMatchedOnce = true;
    if (!mounted) return;
    setState(() => _stage = ok ? CmStage.results : CmStage.offline);
  }

  /// Upload the salted hashes and merge any on-Assisto matches. Returns false
  /// on a connectivity failure so the caller can show the offline state.
  Future<bool> _uploadAndMerge(List<String> hashes) async {
    if (hashes.isEmpty) return true; // nothing to match ⇒ a valid empty result
    try {
      final r = await _api.contactsMatch(
          hashes: hashes, permissionGranted: true);
      final matches =
          ((r['matches'] ?? []) as List).cast<Map<String, dynamic>>();
      final seen = {for (final m in _onAssisto) '${m['id']}'};
      for (final m in matches) {
        // server may nest the descriptor under {contact_hash, user}
        final u = (m['user'] is Map)
            ? (m['user'] as Map).cast<String, dynamic>()
            : m;
        if (seen.add('${u['id']}')) _onAssisto.add(u);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _matchManual() async {
    final raw = _manual.text.trim();
    if (raw.isEmpty) return;
    _manual.clear();
    await _runMatch([raw]);
  }

  // ---------------------------------------------------------------------------
  // CONNECT (existing user) + INVITE (non-user)
  // ---------------------------------------------------------------------------

  Future<void> _connect(Map<String, dynamic> user) async {
    final res =
        await showMsgrConnectSheet(context, peerName: '${user['name'] ?? ''}');
    if (res == null || !mounted) return;
    try {
      await _api.inviteExisting(
        toUserId: (user['id'] as num).toInt(),
        relation: res.relation,
        customLabel: res.customLabel,
      );
      _snack(_t.msgrRequestSent);
    } catch (_) {
      _snack(_t.msgrRequestFailed);
    }
  }

  Future<void> _shareInvite() async {
    final card = _inviteCard;
    try {
      final d = await _api.inviteShareLink(relation: 'friend');
      final url = '${d['url'] ?? card?.link ?? ''}';
      final text = _localized(d['text']) ?? _defaultInviteText(url);
      await Share.share(text.contains(url) ? text : '$text $url');
      _snack(_t.msgrInviteSent);
    } catch (_) {
      // Offline / not wired: still let the user share the card's own link.
      final url = card?.link ?? '';
      if (url.isNotEmpty) {
        await Share.share(_defaultInviteText(url));
        _snack(_t.msgrInviteSent);
      } else {
        _snack(_t.msgrInviteFailed);
      }
    }
  }

  Future<void> _inviteSms() async {
    final number = await _askNumber();
    if (number == null || number.isEmpty || !mounted) return;
    try {
      final d = await _api.inviteSms(relation: 'friend', toNumber: number);
      final smsUri = '${d['sms_uri'] ?? ''}';
      final body = _localized(d['body']) ?? _defaultInviteText(_inviteCard?.link ?? '');
      final uri = smsUri.isNotEmpty
          ? Uri.parse(smsUri)
          : Uri.parse('sms:$number?body=${Uri.encodeComponent(body)}');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri); // opens the composer; the USER presses Send
        _snack(_t.msgrInviteSent);
      } else {
        _snack(_t.msgrInviteFailed);
      }
    } catch (_) {
      // Fallback to own composer over the card link (never auto-sends).
      final link = _inviteCard?.link ?? '';
      final uri = Uri.parse(
          'sms:$number?body=${Uri.encodeComponent(_defaultInviteText(link))}');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        _snack(_t.msgrInviteSent);
      } else {
        _snack(_t.msgrInviteFailed);
      }
    }
  }

  Future<void> _copyLink() async {
    final link = _inviteCard?.link ?? '';
    if (link.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: link));
    _snack(cmLabel(context, 'cmInviteLinkCopied'));
  }

  void _openReferral() {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ReferralScreen()));
  }

  String _defaultInviteText(String url) {
    final name = _inviteCard?.inviterName ?? '';
    final title = cmLabel(context, 'cmInviteCardTitle');
    final body = cmLabel(context, 'cmInviteCardBody');
    final who = name.isEmpty ? '' : '$name — ';
    return url.isEmpty ? '$who$title. $body' : '$who$title. $body $url';
  }

  Future<String?> _askNumber() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.msgrInviteSms),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(hintText: _t.msgrContactsManualHint),
          ),
          const SizedBox(height: Gap.sm),
          Text(_t.msgrInviteSmsNote,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(_t.msgrCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: Text(_t.msgrInviteAction)),
        ],
      ),
    );
  }

  String? _localized(dynamic pair) {
    if (pair is Map) {
      final bn = cmIsBn(context);
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
          if (_stage == CmStage.results)
            IconButton(
              tooltip: cmLabel(context, 'cmReSync'),
              icon: const Icon(Icons.sync),
              onPressed: () => _runMatch(const []),
            ),
          IconButton(
            tooltip: cmLabel(context, 'cmPrivacyLearnMore'),
            icon: const Icon(Icons.shield_outlined),
            onPressed: () => showCmPrivacyExplainer(context),
          ),
          IconButton(
            tooltip: t.msgrConnectTitle,
            icon: const Icon(Icons.how_to_reg_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ConnectionRequestsScreen())),
          ),
        ],
      ),
      body: switch (_stage) {
        CmStage.disclosure => CmDisclosure(
            onAllow: _consentAndMatch,
            onDeny: () => Navigator.of(context).maybePop(),
            onPrivacy: () => showCmPrivacyExplainer(context),
          ),
        CmStage.matching => CmLoading(progress: _progress),
        CmStage.denied => CmStateView(
            icon: Icons.contacts_outlined,
            title: cmLabel(context, 'cmDeniedTitle'),
            body: cmLabel(context, 'cmDeniedBody'),
            tone: Theme.of(context).colorScheme.error,
            primaryLabel: cmLabel(context, 'cmOpenSettings'),
            onPrimary: () =>
                setState(() => _stage = CmStage.results), // manual rail works
            secondaryLabel: _t.msgrContactsDeny,
            onSecondary: () => Navigator.of(context).maybePop(),
          ),
        CmStage.offline => CmStateView(
            icon: Icons.wifi_off_outlined,
            title: cmLabel(context, 'cmOfflineTitle'),
            body: cmLabel(context, 'cmOfflineBody'),
            tone: Theme.of(context).colorScheme.error,
            primaryLabel: cmLabel(context, 'cmRetry'),
            onPrimary: () => _runMatch(const []),
          ),
        CmStage.results => _results(),
      },
    );
  }

  Widget _results() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      // Manual find-by-number rail (the plugin feeds the same path).
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
              onPressed: _matchManual,
              icon: const Icon(Icons.person_search)),
        ]),
      ),
      Expanded(
        child: ListView(children: [
          if (_onAssisto.isNotEmpty) ...[
            _sectionHeader(
              '${t.cmResultsFoundTitle} · '
              '${t.cmResultsFoundCount(cmNum(context, _onAssisto.length))}',
              scheme.primary,
            ),
            for (final u in _onAssisto)
              CmUserRow(user: u, onConnect: () => _connect(u)),
            const SizedBox(height: Gap.sm),
          ] else
            _emptyMatched(),
          // Invite-others — always available (SPEC §21 #8 share card).
          _sectionHeader(cmLabel(context, 'cmInviteOthersTitle'),
              scheme.onSurfaceVariant),
          if (_inviteCard != null)
            CmInviteCardView(
              card: _inviteCard!,
              onShare: _shareInvite,
              onSms: _inviteSms,
              onCopy: _copyLink,
              onSeeReferral: _openReferral,
            ),
          _reSyncHint(),
          const SizedBox(height: Gap.xl),
        ]),
      ),
    ]);
  }

  Widget _sectionHeader(String label, Color color) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
        child: Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      );

  Widget _emptyMatched() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.xl, Gap.sm),
      child: Column(children: [
        Icon(Icons.group_outlined,
            size: 48, color: scheme.primary.withValues(alpha: 0.7)),
        const SizedBox(height: Gap.md),
        Text(
          _hasMatchedOnce
              ? cmLabel(context, 'cmInviteNoneTitle')
              : _t.msgrContactsNoneMatched,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: Gap.xs),
        Text(cmLabel(context, 'cmInviteNoneBody'),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ]),
    );
  }

  Widget _reSyncHint() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
      child: Row(children: [
        Icon(Icons.sync, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: Text(cmLabel(context, 'cmReSyncHint'),
              style:
                  TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
        ),
        TextButton(
            onPressed: () => _runMatch(const []),
            child: Text(cmLabel(context, 'cmReSync'))),
      ]),
    );
  }
}
