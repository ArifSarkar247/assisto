import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../m3_circle_api.dart';
import '../../services/contacts_source.dart';
import '../../services/phone_canon.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/m3_circle_widgets.dart';
import '../../widgets/msgr_avatar.dart';
import 'contacts_screen.dart';

/// m3-circle — "Add to My Circle" (WhatsApp-like, owner order 21 Oct).
///
///  1. Type a number in ANY format (01…, +880…, 880…, spaces, dashes, Bangla
///     digits) -> Find (POST /messenger/contacts/lookup, canonical E.164).
///  2. Found -> choose relation (Family / Friend / Colleague / Custom) ->
///     Send request (POST /circle/request) -> clear success.
///     Not on Assisto -> clear message + Invite them (SMS / WhatsApp / share).
///  3. Other ways: pick from phone contacts, show MY QR / share link, or paste
///     someone's invite link (POST /circle/invite/redeem).
/// Every failure shows a clear bn/en error with a way forward. Nothing silent.
class M3AddToCircleScreen extends StatefulWidget {
  const M3AddToCircleScreen({super.key, this.initialNumber, this.contactsSource});

  final String? initialNumber;

  /// Injected for tests (the phone-contacts picker).
  final ContactsSource? contactsSource;

  @override
  State<M3AddToCircleScreen> createState() => _M3AddToCircleScreenState();
}

enum _St { idle, searching, found, notFound, self, error, sent }

class _M3AddToCircleScreenState extends State<M3AddToCircleScreen> {
  final _number = TextEditingController();
  _St _st = _St.idle;
  String? _fieldError;
  String? _error;
  String _canon = '';
  Map<String, dynamic>? _user;
  M3Relation? _rel;
  bool _relTried = false;
  bool _sending = false;
  bool _accepted = false; // mutual add -> connected right away
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    if ((widget.initialNumber ?? '').isNotEmpty) {
      _number.text = widget.initialNumber!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _find());
    }
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _find() async {
    final raw = _number.text.trim();
    final canon = PhoneCanon.canonical(raw);
    if (canon == null) {
      setState(() {
        _fieldError = raw.isEmpty ? _t.m3EnterNumber : _t.c1SearchInvalid;
        _st = _St.idle;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _fieldError = null;
      _error = null;
      _st = _St.searching;
      _canon = canon;
      _user = null;
      _rel = null;
      _relTried = false;
    });
    try {
      final r = await _api.m3Lookup(canon);
      if (!mounted) return;
      setState(() {
        _canon = '${r['phone'] ?? canon}';
        if (r['is_self'] == true) {
          _st = _St.self;
        } else if (r['found'] == true && r['user'] is Map) {
          _user = (r['user'] as Map).cast<String, dynamic>();
          _st = _St.found;
        } else {
          _st = _St.notFound;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _st = _St.error;
        _error = m3ErrorText(_t, e);
      });
    }
  }

  String get _circleState {
    final c = _user?['circle'];
    return c is Map ? '${c['state'] ?? 'none'}' : 'none';
  }

  Future<void> _send() async {
    final u = _user;
    if (u == null) return;
    if (_rel == null) {
      setState(() => _relTried = true);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final m = await _api.m3SendRequest(
        toUserId: (u['id'] as num?)?.toInt(),
        phone: _canon,
        relation: _rel!.code,
        customLabel: _rel!.customLabel,
      );
      if (!mounted) return;
      _changed = true;
      setState(() {
        _accepted = '${m['state'] ?? ''}' == 'accepted';
        _st = _St.sent;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = m3ErrorText(_t, e));
      m3Snack(context, _error!, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// They already asked me -> accepting from here.
  Future<void> _acceptIncoming() async {
    final c = _user?['circle'];
    final mid = c is Map ? (c['member_id'] as num?)?.toInt() : null;
    if (mid == null) return;
    setState(() => _sending = true);
    try {
      await _api.m3Act(mid, 'accept');
      if (!mounted) return;
      _changed = true;
      setState(() {
        _accepted = true;
        _st = _St.sent;
      });
    } catch (e) {
      if (mounted) m3Snack(context, m3ErrorText(_t, e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickContact() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ContactsScreen(source: widget.contactsSource)));
    _changed = true; // the contacts list can add people itself
  }

  Future<void> _showMyQr() async {
    final t = _t;
    String link;
    try {
      final r = await _api.m3MyInvite();
      link = '${r['link'] ?? r['qr'] ?? ''}';
      if (link.isEmpty) throw StateError('no link');
    } catch (e) {
      if (mounted) m3Snack(context, m3ErrorText(t, e), error: true);
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('m3-qr-dialog'),
        title: Text(t.m3MyQrTitle),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(Gap.sm),
              child: QrImageView(data: link, size: 200),
            ),
            const SizedBox(height: Gap.md),
            Text(t.m3MyQrBody, textAlign: TextAlign.center),
            const SizedBox(height: Gap.sm),
            SelectableText(link,
                style: const TextStyle(fontSize: 12), textAlign: TextAlign.center),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (ctx.mounted) m3Snack(ctx, t.circleLinkCopied);
            },
            child: Text(t.m3CopyLink),
          ),
          FilledButton.icon(
            onPressed: () async {
              try {
                await Share.share('${t.m3InviteDefaultText} $link');
              } catch (e) {
                if (ctx.mounted) m3Snack(ctx, t.msgrInviteFailed, error: true);
              }
            },
            icon: const Icon(Icons.share_outlined, size: 18),
            label: Text(t.m3InviteShare),
          ),
        ],
      ),
    );
  }

  Future<void> _pasteLink() async {
    final t = _t;
    final c = TextEditingController();
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final v = clip?.text ?? '';
      if (v.contains('/i/')) c.text = v.trim();
    } catch (_) {
      // Clipboard unavailable: the user just types/pastes the link.
    }
    if (!mounted) return;
    final link = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.m3PasteLinkTitle),
        content: TextField(
          key: const Key('m3-paste-field'),
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: t.m3PasteLinkHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.msgrCancel)),
          FilledButton(
              key: const Key('m3-paste-go'),
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: Text(t.m3Join)),
        ],
      ),
    );
    if (link == null || link.isEmpty || !mounted) return;
    try {
      final r = await _api.m3Redeem(link);
      if (!mounted) return;
      _changed = true;
      final name = '${(r['inviter'] as Map?)?['name'] ?? ''}'.trim();
      m3Snack(context, t.m3ConnectedWith(name.isEmpty ? t.circleSomeone : name));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) m3Snack(context, m3ErrorText(t, e), error: true);
    }
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final t = _t;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(t.m3AddToCircle)),
        body: _st == _St.sent ? _sentView() : _form(),
      ),
    );
  }

  Widget _form() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      key: const Key('m3-add-list'),
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Text(t.m3AddLead, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.md),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              key: const Key('m3-number'),
              controller: _number,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _find(),
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                    RegExp(r'[0-9+ ()\-.\u09E6-\u09EF]')),
              ],
              decoration: InputDecoration(
                labelText: t.m3NumberLabel,
                hintText: t.m3NumberHint,
                hintMaxLines: 2,
                errorText: _fieldError,
                errorMaxLines: 3,
                prefixIcon: const Icon(Icons.phone_outlined),
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: FilledButton(
              key: const Key('m3-find'),
              onPressed: _st == _St.searching ? null : _find,
              child: _st == _St.searching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.m3Find),
            ),
          ),
        ]),
        const SizedBox(height: Gap.md),
        ..._resultCard(),
        const SizedBox(height: Gap.lg),
        Text(t.m3OtherWays, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: Gap.xs),
        Card(
          child: Column(children: [
            ListTile(
              key: const Key('m3-pick-contacts'),
              leading: const Icon(Icons.contacts_outlined),
              title: Text(t.m3PickContacts),
              subtitle: Text(t.m3PickContactsSub),
              onTap: _pickContact,
            ),
            const Divider(height: 1),
            ListTile(
              key: const Key('m3-my-qr'),
              leading: const Icon(Icons.qr_code_2),
              title: Text(t.m3MyQr),
              subtitle: Text(t.m3MyQrSub),
              onTap: _showMyQr,
            ),
            const Divider(height: 1),
            ListTile(
              key: const Key('m3-paste'),
              leading: const Icon(Icons.link),
              title: Text(t.m3PasteLink),
              subtitle: Text(t.m3PasteLinkSub),
              onTap: _pasteLink,
            ),
          ]),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.m3ScanLater,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
        const SizedBox(height: Gap.xl),
      ],
    );
  }

  List<Widget> _resultCard() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    final local = _canon.isEmpty ? '' : PhoneCanon.localForm(_canon);
    switch (_st) {
      case _St.idle:
      case _St.searching:
      case _St.sent:
        return const [];
      case _St.error:
        return [
          Card(
            key: const Key('m3-error'),
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Row(children: [
                Icon(Icons.error_outline, color: scheme.onErrorContainer),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(_error ?? t.c1SearchFailed,
                        style: TextStyle(color: scheme.onErrorContainer))),
                TextButton(onPressed: _find, child: Text(t.retry)),
              ]),
            ),
          ),
        ];
      case _St.self:
        return [
          Card(
            key: const Key('m3-self'),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(t.c1SearchSelf),
            ),
          ),
        ];
      case _St.notFound:
        return [
          Card(
            key: const Key('m3-notfound'),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.person_off_outlined, color: scheme.primary),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(t.m3NotOnAssisto(local),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: Gap.xs),
                Text(t.m3NotOnAssistoBody,
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
                const SizedBox(height: Gap.sm),
                Text(t.m3InviteThem, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Gap.xs),
                M3InviteButtons(phone: _canon),
              ]),
            ),
          ),
        ];
      case _St.found:
        final u = _user!;
        final name = '${u['name'] ?? ''}'.trim();
        final st = _circleState;
        return [
          Card(
            key: const Key('m3-found'),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  MsgrAvatar(
                      name: name.isEmpty ? '?' : name,
                      photoUrl: '${u['photo_link'] ?? u['photo'] ?? ''}',
                      radius: 26),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name.isEmpty ? t.circleSomeone : name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 17)),
                      Text(t.m3OnAssistoNumber(local),
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ]),
                  ),
                ]),
                const SizedBox(height: Gap.md),
                if (st == 'accepted')
                  Text(t.c1InYourCircle,
                      key: const Key('m3-already'),
                      style: TextStyle(color: scheme.primary))
                else if (st == 'pending')
                  Text(t.m3AlreadyRequested,
                      key: const Key('m3-pending'),
                      style: TextStyle(color: scheme.onSurfaceVariant))
                else if (st == 'incoming') ...[
                  Text(t.c1WantsToConnect),
                  const SizedBox(height: Gap.sm),
                  FilledButton.icon(
                    key: const Key('m3-accept-found'),
                    onPressed: _sending ? null : _acceptIncoming,
                    icon: const Icon(Icons.check),
                    label: Text(t.circleAccept),
                  ),
                ] else ...[
                  M3RelationPicker(onChanged: (r) => setState(() => _rel = r)),
                  if (_relTried && _rel == null)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs),
                      child: Text(t.msgrRelationRequired,
                          style: TextStyle(color: scheme.error, fontSize: 12)),
                    ),
                  const SizedBox(height: Gap.md),
                  FilledButton.icon(
                    key: const Key('m3-send'),
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    label: Text(t.msgrSendRequest),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs),
                      child: Text(_error!,
                          key: const Key('m3-send-error'),
                          style: TextStyle(color: scheme.error)),
                    ),
                ],
              ]),
            ),
          ),
        ];
    }
  }

  Widget _sentView() {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    final name = '${_user?['name'] ?? ''}'.trim();
    final who = name.isEmpty ? t.circleSomeone : name;
    return Center(
      key: const Key('m3-sent'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: Brand.success,
            child: const Icon(Icons.check, color: Colors.white, size: 40),
          ),
          const SizedBox(height: Gap.lg),
          Text(_accepted ? t.m3ConnectedWith(who) : t.m3RequestSentTo(who),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(_accepted ? t.c1Accepted : t.m3RequestSentBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.lg),
          FilledButton(
            key: const Key('m3-done'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.done),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            key: const Key('m3-add-another'),
            onPressed: () => setState(() {
              _st = _St.idle;
              _number.clear();
              _user = null;
              _rel = null;
              _error = null;
            }),
            child: Text(t.m3AddAnother),
          ),
        ]),
      ),
    );
  }
}
