import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../c1_contacts_api.dart';
import '../../crypto/e2e.dart';
import '../../crypto/identity_vault.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_api.dart';
import '../../messaging/msg_request_widgets.dart'; // mr1
import '../../services/contacts_source.dart';
import '../../services/phone_canon.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/c1_contacts_widgets.dart';
import '../../widgets/contacts_match_model.dart';
import '../../widgets/contacts_match_widgets.dart';
import '../../widgets/m3_circle_widgets.dart';
import '../circle_call_screen.dart';
import '../circle_chat_screen.dart';
import '../referral_screen.dart';
import 'connection_requests_screen.dart';

/// "Contacts on Assisto" — WhatsApp-style (c1-contacts, owner bug fix).
///
/// * "On Assisto" first (Add to My Circle / Requested / Accept / Message +
///   Call), then everyone else in the phonebook with Invite.
/// * A prominent disclosure is shown BEFORE the OS permission prompt: we only
///   send hashed numbers to find who is on Assisto.
/// * Numbers are canonicalised + hashed ON DEVICE ([PhoneCanon], mirror of
///   backend/core/phone.py) with the salt from /messenger/contacts/contract;
///   only hashes are uploaded to /messenger/contacts/match.
/// * Re-sync on pull-to-refresh and whenever [ContactsSource.changes] fires.
/// * Find-by-number (/messenger/contacts/lookup) accepts ANY format.
///
/// HONESTY: the phonebook comes from a [ContactsSource] (the real
/// flutter_contacts reader since build 176). Only when this phone truly can't
/// open its contacts (no reader, or the OS/plugin refused to start it) the
/// screen says so plainly ("couldn't read contacts on this phone") and offers
/// search by number — it never pretends it read the phonebook and never
/// promises a future update (NO SHOWPIECES rule).
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.source, this.title, this.header});

  /// Injected for tests; defaults to [ContactsSources.create] (lazy).
  final ContactsSource? source;

  /// m3-circle: the same screen is My Circle's "New chat" — a different title
  /// and the WhatsApp-style actions (Add to My Circle, New group, New
  /// community, Invite a friend) on top of the "On Assisto" list.
  final String? title;
  final Widget? header;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

/// One phonebook person after canonicalisation (raw numbers stay on device).
class _PbEntry {
  _PbEntry(this.name, this.numbers);
  final String name;
  final List<String> numbers; // canonical E.164
}

const _kConsentKey = 'c1_contacts_consent_v1';
const _kChunk = 1000;

class _ContactsScreenState extends State<ContactsScreen> {
  late final ContactsSource _source =
      widget.source ?? ContactsSources.create();
  StreamSubscription<void>? _changesSub;
  Timer? _debounce;

  CmStage _stage = CmStage.matching;
  CmProgress _progress = const CmProgress(phase: CmPhase.reading);
  bool _syncing = false;
  bool _synced = false; // the phonebook was really read at least once
  // The reader exists but the OS/plugin could not start it on this phone
  // (status/request came back `unavailable`). Shown as an honest reason
  // instead of an Allow button that would loop.
  bool _cantRead = false;

  // Hashing contract (from the server).
  String _salt = '';
  int _hashLen = 32;

  final List<_PbEntry> _phonebook = [];
  // user id -> {user: descriptor, contact: phonebook name}
  final Map<String, Map<String, dynamic>> _onAssisto = {};
  final Set<String> _matchedNumbers = {};
  final Set<String> _busy = {};

  // Manual search
  final _search = TextEditingController();
  bool _searching = false;
  String? _searchError;
  Map<String, dynamic>? _searchResult;

  CmInviteCard? _inviteCard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _changesSub?.cancel();
    _search.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  // ---------------------------------------------------------------------------
  // FLOW
  // ---------------------------------------------------------------------------

  Future<void> _init() async {
    if (!mounted) return;
    unawaited(_loadInviteCard());
    if (!_source.available) {
      setState(() => _stage = CmStage.results);
      return;
    }
    var consent = false;
    try {
      final p = await SharedPreferences.getInstance();
      consent = p.getBool(_kConsentKey) ?? false;
    } catch (_) {}
    if (!mounted) return;
    if (!consent) {
      setState(() => _stage = CmStage.disclosure);
      return;
    }
    ContactsPermission st;
    try {
      st = await _source.status();
    } catch (_) {
      st = ContactsPermission.unavailable;
    }
    if (!mounted) return;
    if (st == ContactsPermission.granted) {
      await _sync();
    } else if (st == ContactsPermission.unavailable) {
      setState(() {
        _cantRead = true;
        _stage = CmStage.results;
      });
    } else {
      setState(() => _stage = CmStage.disclosure);
    }
  }

  /// The user tapped Allow on the disclosure -> only NOW ask the OS.
  Future<void> _allow() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kConsentKey, true);
    } catch (_) {}
    ContactsPermission st;
    try {
      st = await _source.request();
    } catch (_) {
      st = ContactsPermission.unavailable;
    }
    if (!mounted) return;
    switch (st) {
      case ContactsPermission.granted:
        await _sync();
      case ContactsPermission.denied:
      case ContactsPermission.permanentlyDenied:
        setState(() => _stage = CmStage.denied);
      case ContactsPermission.unavailable:
        setState(() {
          _cantRead = true;
          _stage = CmStage.results;
        });
    }
  }

  void _listenForChanges() {
    if (_changesSub != null) return;
    try {
      _changesSub = _source.changes.listen((_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 2), () {
          if (mounted && !_syncing && _stage == CmStage.results) _sync();
        });
      }, onError: (_) {});
    } catch (_) {}
  }

  Future<bool> _loadContract() async {
    try {
      final c = await _api.contactsContract();
      _salt = '${c['salt'] ?? c['match_salt'] ?? ''}';
      _hashLen = (c['hash_len'] as num?)?.toInt() ?? 32;
    } catch (_) {}
    return _salt.isNotEmpty;
  }

  /// Read the phonebook -> canonicalise + hash on device -> upload hashes ->
  /// map matches back to phonebook entries. Pull-to-refresh calls this too.
  Future<void> _sync() async {
    if (_syncing || !_source.available) return;
    _syncing = true;
    final firstRun = !_synced;
    if (firstRun && mounted) {
      setState(() {
        _stage = CmStage.matching;
        _progress = const CmProgress(phase: CmPhase.reading);
      });
    }
    try {
      List<DeviceContact> raw;
      try {
        raw = await _source.read();
      } catch (_) {
        raw = const [];
      }
      final book = <_PbEntry>[];
      for (final c in raw) {
        final nums = <String>{};
        for (final n in c.numbers) {
          final canon = PhoneCanon.canonical(n);
          if (canon != null) nums.add(canon);
        }
        if (nums.isNotEmpty) book.add(_PbEntry(c.name.trim(), nums.toList()));
      }
      if (mounted && firstRun) {
        setState(() => _progress =
            CmProgress(phase: CmPhase.hashing, total: book.length));
      }
      if (_salt.isEmpty && !await _loadContract()) {
        if (mounted) setState(() => _stage = CmStage.offline);
        return;
      }
      final byHash = <String, _PbEntry>{};
      final numByHash = <String, String>{};
      for (final e in book) {
        for (final n in e.numbers) {
          final h = PhoneCanon.hashCanonical(n, _salt, hashLen: _hashLen);
          byHash.putIfAbsent(h, () => e);
          numByHash.putIfAbsent(h, () => n);
        }
      }
      if (mounted && firstRun) {
        setState(() => _progress = const CmProgress(phase: CmPhase.matching));
      }
      final hashes = byHash.keys.toList();
      final found = <String, Map<String, dynamic>>{};
      final matched = <String>{};
      for (var i = 0; i < hashes.length; i += _kChunk) {
        final end = i + _kChunk > hashes.length ? hashes.length : i + _kChunk;
        final r = await _api.contactsMatch(
            hashes: hashes.sublist(i, end), permissionGranted: true);
        for (final m in ((r['matches'] ?? []) as List).whereType<Map>()) {
          final h = '${m['contact_hash'] ?? ''}';
          final u = (m['user'] is Map)
              ? (m['user'] as Map).cast<String, dynamic>()
              : m.cast<String, dynamic>();
          final n = numByHash[h];
          if (n != null) matched.add(n);
          found.putIfAbsent('${u['id']}',
              () => {'user': u, 'contact': byHash[h]?.name ?? ''});
        }
      }
      if (!mounted) return;
      book.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _phonebook
          ..clear()
          ..addAll(book);
        _onAssisto
          ..clear()
          ..addAll(found);
        _matchedNumbers
          ..clear()
          ..addAll(matched);
        _synced = true;
        _stage = CmStage.results;
      });
      _listenForChanges();
    } catch (_) {
      if (mounted) {
        if (_synced) {
          _snack(cmLabel(context, 'cmOfflineBody'));
        } else {
          setState(() => _stage = CmStage.offline);
        }
      }
    } finally {
      _syncing = false;
    }
  }

  // ---------------------------------------------------------------------------
  // MANUAL SEARCH (any format)
  // ---------------------------------------------------------------------------

  Future<void> _runSearch() async {
    final raw = _search.text.trim();
    // db1: an empty search now shows the "enter a number" hint (was a dead tap).
    final canon = PhoneCanon.canonical(raw);
    if (canon == null) {
      setState(() {
        _searchError = _t.c1SearchInvalid;
        _searchResult = null;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searchError = null;
      _searchResult = null;
    });
    try {
      final r = await _api.contactsLookup(canon);
      if (!mounted) return;
      setState(() => _searchResult = r);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _searchError = e.status == 400
          ? _t.c1SearchInvalid
          : e.status == 429
              ? _t.c1SearchLimited
              : _t.c1SearchFailed);
    } catch (_) {
      if (mounted) setState(() => _searchError = _t.c1SearchFailed);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  // ---------------------------------------------------------------------------
  // ACTIONS
  // ---------------------------------------------------------------------------

  void _setCircle(String userId, Map<String, dynamic> circle) {
    setState(() {
      final e = _onAssisto[userId];
      if (e != null) {
        (e['user'] as Map<String, dynamic>)['circle'] = circle;
      }
      final s = _searchResult;
      if (s != null && s['user'] is Map && '${s['user']['id']}' == userId) {
        (s['user'] as Map)['circle'] = circle;
      }
    });
  }

  Future<void> _addToCircle(Map<String, dynamic> user) async {
    // m3-circle: Family / Friend / Colleague / Custom with SERVER relation
    // codes (the old sheet sent "family", which the server stored as an
    // unnamed "custom" relation).
    final res =
        await showM3RelationSheet(context, peerName: '${user['name'] ?? ''}');
    if (res == null || !mounted) return;
    final (rel, note) = res;
    final id = '${user['id']}';
    setState(() => _busy.add(id));
    try {
      final m = await _api.circleAddByUser(
        toUserId: (user['id'] as num).toInt(),
        relation: rel.code,
        customLabel: rel.customLabel,
        note: note,
      );
      final st = '${m['state'] ?? 'pending'}';
      _setCircle(id, {
        'state': st,
        'member_id': m['id'],
        'member': st == 'accepted' ? m : null,
      });
      _snack(st == 'accepted' ? _t.c1Accepted : _t.c1RequestSent);
    } catch (e) {
      _snack(m3ErrorText(_t, e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _accept(Map<String, dynamic> user) async {
    final c = user['circle'];
    final mid = c is Map ? (c['member_id'] as num?)?.toInt() : null;
    if (mid == null) return;
    final id = '${user['id']}';
    setState(() => _busy.add(id));
    try {
      final m = await _api.circleAcceptRequest(mid);
      _setCircle(id, {'state': 'accepted', 'member_id': mid, 'member': m});
      _snack(_t.c1Accepted);
    } catch (_) {
      _snack(_t.c1RequestFailed);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Map<String, dynamic>? _memberOf(Map<String, dynamic> user) {
    final c = user['circle'];
    if (c is! Map) return null;
    final m = c['member'];
    if (m is Map && m['id'] != null) return m.cast<String, dynamic>();
    final mid = c['member_id'];
    if (mid == null) return null;
    return {
      'id': mid,
      'name': user['name'] ?? '',
      'photo': user['photo'] ?? '',
      'state': 'accepted',
    };
  }

  /// The on-device E2E identity via [IdentityVault] (never null; the key is
  /// published at sign-in and on every app start).
  Future<IdentityKeyPair?> _identity() => IdentityVault.instance.get();

  Future<void> _message(Map<String, dynamic> user) async {
    final c = user['circle'];
    final st = c is Map ? '${c['state'] ?? 'none'}' : 'none';
    if (st != 'accepted') {
      // mr1: not connected yet -> a message request (texts go out now).
      await openMessageRequestChat(context,
          toUserId: (user['id'] as num?)?.toInt());
      return;
    }
    final member = _memberOf(user);
    if (member == null) return;
    final id = await _identity();
    if (!mounted) return;
    if (id == null) {
      _snack(_t.c1ChatOpenFailed);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CircleChatScreen(member: member, identity: id)));
  }

  Future<void> _call(Map<String, dynamic> user) async {
    final member = _memberOf(user);
    if (member == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CircleCallScreen(member: member, kind: 'voice')));
  }

  // ---------------------------------------------------------------------------
  // INVITE (non-user) — share link or own-SIM SMS; never auto-sends.
  // ---------------------------------------------------------------------------

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
      _inviteCard =
          CmInviteCard(link: link, referralCode: code, inviterName: me);
    } catch (_) {
      _inviteCard = CmInviteCard(link: '', referralCode: '', inviterName: me);
    }
    if (mounted) setState(() {});
  }

  Future<void> _shareInvite() async {
    final card = _inviteCard;
    try {
      final d = await _api.inviteShareLink(relation: 'friend');
      // m3-circle: the server returns `link` + `share_text` (the old code read
      // `url` / `text`, so the server's invite link was never used).
      final url = '${d['link'] ?? d['url'] ?? card?.link ?? ''}';
      final text = _localized(d['share_text'] ?? d['text']) ??
          _defaultInviteText(url);
      await Share.share(text.contains(url) ? text : '$text $url');
      _snack(_t.msgrInviteSent);
    } catch (_) {
      final url = card?.link ?? '';
      if (url.isNotEmpty) {
        await Share.share(_defaultInviteText(url));
        _snack(_t.msgrInviteSent);
      } else {
        _snack(_t.msgrInviteFailed);
      }
    }
  }

  Future<void> _inviteSms([String? prefilled]) async {
    final number = (prefilled == null || prefilled.isEmpty)
        ? await _askNumber()
        : PhoneCanon.localForm(prefilled);
    if (number == null || number.isEmpty || !mounted) return;
    Uri uri;
    try {
      final d = await _api.inviteSms(relation: 'friend', toNumber: number);
      final smsUri = '${d['sms_uri'] ?? ''}';
      final body = _localized(d['body']) ??
          _defaultInviteText(_inviteCard?.link ?? '');
      uri = smsUri.isNotEmpty
          ? Uri.parse(smsUri)
          : Uri.parse('sms:$number?body=${Uri.encodeComponent(body)}');
    } catch (_) {
      final link = _inviteCard?.link ?? '';
      uri = Uri.parse(
          'sms:$number?body=${Uri.encodeComponent(_defaultInviteText(link))}');
    }
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri); // opens the composer; the USER presses Send
        _snack(_t.msgrInviteSent);
      } else {
        _snack(_t.msgrInviteFailed);
      }
    } catch (_) {
      _snack(_t.msgrInviteFailed);
    }
  }

  Future<void> _copyLink() async {
    final link = _inviteCard?.link ?? '';
    if (link.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: link));
    _snack(cmLabel(context, 'cmInviteLinkCopied'));
  }

  void _openReferral() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const ReferralScreen()));

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? t.msgrContactsTitle),
        actions: [
          IconButton(
            tooltip: cmLabel(context, 'cmPrivacyLearnMore'),
            icon: const Icon(Icons.shield_rounded),
            onPressed: () => showCmPrivacyExplainer(context),
          ),
          IconButton(
            tooltip: t.msgrConnectTitle,
            icon: const Icon(Icons.how_to_reg_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ConnectionRequestsScreen())),
          ),
        ],
      ),
      body: _withHeader(switch (_stage) {
        CmStage.disclosure => C1Disclosure(
            onAllow: _allow,
            onDeny: () => setState(() => _stage = CmStage.results),
            onPrivacy: () => showCmPrivacyExplainer(context),
          ),
        CmStage.matching => CmLoading(progress: _progress),
        CmStage.denied => CmStateView(
            icon: Icons.contacts_rounded,
            title: cmLabel(context, 'cmDeniedTitle'),
            body: cmLabel(context, 'cmDeniedBody'),
            tone: Theme.of(context).colorScheme.error,
            primaryLabel: cmLabel(context, 'cmOpenSettings'),
            onPrimary: () async {
              try {
                await _source.openSettings();
              } catch (_) {}
            },
            secondaryLabel: t.c1SearchInstead,
            onSecondary: () => setState(() => _stage = CmStage.results),
          ),
        CmStage.offline => CmStateView(
            icon: Icons.wifi_off_rounded,
            title: cmLabel(context, 'cmOfflineTitle'),
            body: cmLabel(context, 'cmOfflineBody'),
            tone: Theme.of(context).colorScheme.error,
            primaryLabel: cmLabel(context, 'cmRetry'),
            onPrimary: _sync,
            secondaryLabel: t.c1SearchInstead,
            onSecondary: () => setState(() => _stage = CmStage.results),
          ),
        CmStage.results => _results(),
      }),
    );
  }

  /// The New-chat actions sit on top of every stage (inside the results list
  /// so they scroll with it; above the disclosure / denied / offline views).
  Widget _withHeader(Widget body) {
    final h = widget.header;
    if (h == null || _stage == CmStage.results) return body;
    return Column(children: [h, Expanded(child: body)]);
  }

  Widget _searchBar() {
    final t = _t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: TextField(
            key: const Key('c1-search'),
            controller: _search,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _runSearch(),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                  RegExp(r'[0-9+ ()\-.\u09E6-\u09EF]')),
            ],
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: t.c1SearchHint,
              hintMaxLines: 2,
              errorText: _searchError,
              errorMaxLines: 3,
            ),
          ),
        ),
        const SizedBox(width: Gap.sm),
        IconButton.filled(
          key: const Key('c1-search-go'),
          tooltip: t.c1SearchHint,
          onPressed: _searching ? null : _runSearch,
          icon: _searching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.person_search_rounded),
        ),
      ]),
    );
  }

  Widget? _searchCard() {
    final r = _searchResult;
    if (r == null) return null;
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    final canon = '${r['phone'] ?? ''}';
    final local = PhoneCanon.localForm(canon);
    if (r['found'] == true && r['user'] is Map) {
      final u = (r['user'] as Map).cast<String, dynamic>();
      return Card(
        key: const Key('c1-search-found'),
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
        child: C1AssistoUserRow(
          user: u,
          busy: _busy.contains('${u['id']}'),
          onAdd: () => _addToCircle(u),
          onAccept: () => _accept(u),
          onMessage: () => _message(u),
          onCall: () => _call(u),
        ),
      );
    }
    final self = r['is_self'] == true;
    return Card(
      key: const Key('c1-search-notfound'),
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(self ? t.c1SearchSelf : t.c1SearchNotFound(local),
              style: TextStyle(color: scheme.onSurface, height: 1.4)),
          if (!self) ...[
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              FilledButton.tonalIcon(
                onPressed: () => _inviteSms(canon),
                icon: const Icon(Icons.sms_rounded, size: 18),
                label: Text(t.c1Invite),
              ),
              OutlinedButton.icon(
                onPressed: _shareInvite,
                icon: const Icon(Icons.share_rounded, size: 18),
                label: Text(cmLabel(context, 'cmShareCard')),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _foundRow(Map<String, dynamic> f) {
    final u = (f['user'] as Map).cast<String, dynamic>();
    return C1AssistoUserRow(
      key: Key('c1-on-${u['id']}'),
      user: u,
      contactName: '${f['contact'] ?? ''}',
      busy: _busy.contains('${u['id']}'),
      onAdd: () => _addToCircle(u),
      onAccept: () => _accept(u),
      onMessage: () => _message(u),
      onCall: () => _call(u),
    );
  }

  Widget _results() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    final others = _phonebook
        .where((e) => !e.numbers.any(_matchedNumbers.contains))
        .toList();
    final found = _onAssisto.values.toList()
      ..sort((a, b) => '${a['contact']}'
          .toLowerCase()
          .compareTo('${b['contact']}'.toLowerCase()));
    final searchCard = _searchCard();
    final children = <Widget>[
      if (widget.header != null) widget.header!,
      _searchBar(),
      if (searchCard != null) searchCard,
      if (!_source.available || _cantRead)
        C1InfoBanner(
          key: const Key('c1-unavailable'),
          icon: Icons.contacts_rounded,
          title: t.c1PhonebookCantReadTitle,
          body: t.c1PhonebookCantReadBody,
        ),
      if (_source.available && !_cantRead && !_synced)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
          child: OutlinedButton.icon(
            onPressed: () => setState(() => _stage = CmStage.disclosure),
            icon: const Icon(Icons.contacts_rounded),
            label: Text(t.msgrContactsAllow),
          ),
        ),
      if (_synced) ...[
        C1SectionHeader(
            '${t.c1OnAssistoTitle} · ${cmNum(context, found.length)}',
            key: const Key('c1-section-on')),
        if (found.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.md, vertical: Gap.sm),
            child: Text(t.c1NoneOnAssisto,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        for (final f in found) _foundRow(f),
        C1SectionHeader(t.c1InviteTitle,
            key: const Key('c1-section-invite'),
            color: scheme.onSurfaceVariant),
        for (final e in others)
          C1InviteRow(
            name: e.name,
            number: PhoneCanon.localForm(e.numbers.first),
            onInvite: () => _inviteSms(e.numbers.first),
          ),
      ],
      if (_inviteCard != null) ...[
        if (!_synced)
          C1SectionHeader(t.c1InviteTitle, color: scheme.onSurfaceVariant),
        CmInviteCardView(
          card: _inviteCard!,
          onShare: _shareInvite,
          onSms: () => _inviteSms(),
          onCopy: _copyLink,
          onSeeReferral: _openReferral,
        ),
      ],
      if (_synced)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
          child: Text(
            '${t.c1CheckedCount(cmNum(context, _phonebook.length))} '
            '${t.c1PullToRefresh}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
      const SizedBox(height: Gap.xl),
    ];
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
    );
    if (!_source.available || _cantRead) return list;
    return RefreshIndicator(onRefresh: _sync, child: list);
  }
}
