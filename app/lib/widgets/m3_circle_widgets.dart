import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../m3_circle_api.dart';
import '../services/phone_canon.dart';
import '../state.dart';
import '../theme.dart';
import 'loading_gate.dart';
import 'msgr_avatar.dart';

/// m3-circle — shared pieces for My Circle home + "Add to My Circle".
/// No hard-coded copy (AppLocalizations only).

// ---------------------------------------------------------------------------
// Errors: one honest bn/en sentence for any failure (never silent).
// ---------------------------------------------------------------------------
String m3ErrorText(AppLocalizations t, Object e) {
  if (e is TimeoutException) return t.m3ErrTimeout;
  if (e is ApiException) {
    final s = e.status ?? 0;
    final m = e.message.trim();
    if (m == 'bad_phone') return t.c1SearchInvalid;
    if (m == 'self_request') return t.c1SearchSelf;
    if (s == 429) return t.c1SearchLimited;
    if (s == 401 || s == 403) return t.m3ErrNotAllowed;
    if (s >= 500 || s == 0) return t.m3ErrServer;
    // A server sentence (bilingual detail) is shown as-is; machine codes never.
    if (s == 400 && m.contains(' ') && !m.startsWith('{')) return m;
    return t.c1RequestFailed;
  }
  return t.m3ErrOffline;
}

void m3Snack(BuildContext context, String msg, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  final scheme = Theme.of(context).colorScheme;
  m.hideCurrentSnackBar(); // the newest result wins (no stale queue)
  m.showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? scheme.error : null,
  ));
}

// ---------------------------------------------------------------------------
// Relation: Family / Friend / Colleague / Custom (+ optional family sub).
// Server codes (core/logic/circle.RELATIONS): family -> the sub when chosen,
// else "relative"; custom -> "custom" + custom_label.
// ---------------------------------------------------------------------------
class M3Relation {
  const M3Relation(this.code, {this.customLabel});
  final String code;
  final String? customLabel;
}

const List<String> kM3Relations = ['family', 'friend', 'colleague', 'custom'];
const List<String> kM3FamilySubs = [
  'father', 'mother', 'brother', 'sister', 'husband', 'wife', 'child'
];

String m3RelationLabel(AppLocalizations t, String code) => switch (code) {
      'family' => t.msgrRelationFamily,
      'friend' => t.circleRelFriend,
      'colleague' => t.circleRelColleague,
      'custom' => t.circleRelCustom,
      'father' => t.circleRelFather,
      'mother' => t.circleRelMother,
      'brother' => t.circleRelBrother,
      'sister' => t.circleRelSister,
      'husband' => t.circleRelHusband,
      'wife' => t.circleRelWife,
      'child' => t.circleRelChild,
      _ => t.circleRelRelative,
    };

class M3RelationPicker extends StatefulWidget {
  const M3RelationPicker({super.key, required this.onChanged});

  /// Null while incomplete (nothing chosen, or Custom with no text).
  final ValueChanged<M3Relation?> onChanged;

  @override
  State<M3RelationPicker> createState() => _M3RelationPickerState();
}

class _M3RelationPickerState extends State<M3RelationPicker> {
  String? _rel;
  String? _sub;
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _emit() {
    M3Relation? r;
    switch (_rel) {
      case 'family':
        r = M3Relation(_sub ?? 'relative');
      case 'custom':
        final c = _custom.text.trim();
        r = c.isEmpty ? null : M3Relation('custom', customLabel: c);
      case null:
        r = null;
      default:
        r = M3Relation(_rel!);
    }
    widget.onChanged(r);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const Key('m3-relation'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.m3ChooseRelation, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final r in kM3Relations)
            ChoiceChip(
              key: Key('m3-rel-$r'),
              label: Text(m3RelationLabel(t, r)),
              selected: _rel == r,
              onSelected: (_) {
                setState(() {
                  _rel = r;
                  if (r != 'family') _sub = null;
                });
                _emit();
              },
            ),
        ]),
        if (_rel == 'family') ...[
          const SizedBox(height: Gap.sm),
          Text(t.msgrFamilySubLabel,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final s in kM3FamilySubs)
              ChoiceChip(
                label: Text(m3RelationLabel(t, s)),
                selected: _sub == s,
                onSelected: (_) {
                  setState(() => _sub = _sub == s ? null : s);
                  _emit();
                },
              ),
          ]),
        ],
        if (_rel == 'custom') ...[
          const SizedBox(height: Gap.sm),
          TextField(
            key: const Key('m3-rel-custom-text'),
            controller: _custom,
            maxLength: 60,
            decoration: InputDecoration(
              isDense: true,
              hintText: t.circleCustomRelationHint,
            ),
            onChanged: (_) => _emit(),
          ),
        ],
      ],
    );
  }
}

/// Bottom sheet: relation (+ optional note) -> Send. Used where a person was
/// already picked (phone contacts list).
Future<(M3Relation, String?)?> showM3RelationSheet(BuildContext context,
    {required String peerName}) {
  return showModalBottomSheet<(M3Relation, String?)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _RelationSheet(peerName: peerName),
  );
}

class _RelationSheet extends StatefulWidget {
  const _RelationSheet({required this.peerName});
  final String peerName;
  @override
  State<_RelationSheet> createState() => _RelationSheetState();
}

class _RelationSheetState extends State<_RelationSheet> {
  M3Relation? _rel;
  bool _tried = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.m3AddToCircle, style: Theme.of(context).textTheme.titleLarge),
            Text(widget.peerName, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            M3RelationPicker(onChanged: (r) => setState(() => _rel = r)),
            if (_tried && _rel == null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.msgrRelationRequired,
                    style: TextStyle(color: scheme.error, fontSize: 12)),
              ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _note,
              maxLength: 280,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                  labelText: t.msgrNoteOptional, hintText: t.msgrNoteHint),
            ),
            FilledButton.icon(
              key: const Key('m3-sheet-send'),
              icon: const Icon(Icons.send),
              label: Text(t.msgrSendRequest),
              onPressed: () {
                if (_rel == null) {
                  setState(() => _tried = true);
                  return;
                }
                final n = _note.text.trim();
                Navigator.pop(context, (_rel!, n.isEmpty ? null : n));
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Invite a non-user: share sheet / SMS / WhatsApp (user always presses send).
// ---------------------------------------------------------------------------
String _pairText(BuildContext context, dynamic v) {
  if (v is Map) {
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    return '${v[bn ? 'bn' : 'en'] ?? v['en'] ?? ''}';
  }
  return v is String ? v : '';
}

/// Fetch the invite text + link (server: /messenger/invite/share-link).
Future<(String text, String link)> m3InviteText(BuildContext context) async {
  final api = context.read<AppState>().api;
  final d = await api.m3ShareLink();
  final link = '${d['link'] ?? d['url'] ?? ''}';
  if (!context.mounted) return ('', link);
  var text = _pairText(context, d['share_text'] ?? d['text']);
  if (text.isEmpty) text = AppLocalizations.of(context).m3InviteDefaultText;
  if (link.isNotEmpty && !text.contains(link)) text = '$text $link';
  return (text, link);
}

enum M3InviteVia { share, sms, whatsapp }

/// Invite someone not on Assisto. [phone] (canonical E.164) pre-fills SMS /
/// WhatsApp. Shows a clear success or error — never silent.
Future<bool> m3Invite(BuildContext context, M3InviteVia via, {String? phone}) async {
  final t = AppLocalizations.of(context);
  try {
    final (text, _) = await m3InviteText(context);
    if (!context.mounted) return false;
    switch (via) {
      case M3InviteVia.share:
        await Share.share(text);
      case M3InviteVia.sms:
        final to = phone == null ? '' : PhoneCanon.localForm(phone);
        final uri = Uri.parse('sms:$to?body=${Uri.encodeComponent(text)}');
        if (!await launchUrl(uri)) throw StateError('no sms app');
      case M3InviteVia.whatsapp:
        final digits = (phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
        final uri = Uri.parse(
            'https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw StateError('no whatsapp');
        }
    }
    if (context.mounted) m3Snack(context, t.m3InviteOpened);
    return true;
  } catch (e) {
    if (context.mounted) {
      m3Snack(context,
          via == M3InviteVia.whatsapp && e is StateError
              ? t.m3InviteNoWhatsapp
              : '${t.msgrInviteFailed}. ${m3ErrorText(t, e)}',
          error: true);
    }
    return false;
  }
}

/// SMS / WhatsApp / Share buttons for a number that is not on Assisto.
class M3InviteButtons extends StatelessWidget {
  const M3InviteButtons({super.key, this.phone});
  final String? phone;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
      FilledButton.tonalIcon(
        key: const Key('m3-invite-sms'),
        onPressed: () => m3Invite(context, M3InviteVia.sms, phone: phone),
        icon: const Icon(Icons.sms_outlined, size: 18),
        label: Text(t.m3InviteSms),
      ),
      FilledButton.tonalIcon(
        key: const Key('m3-invite-whatsapp'),
        onPressed: () => m3Invite(context, M3InviteVia.whatsapp, phone: phone),
        icon: const Icon(Icons.chat_outlined, size: 18),
        label: Text(t.m3InviteWhatsapp),
      ),
      OutlinedButton.icon(
        key: const Key('m3-invite-share'),
        onPressed: () => m3Invite(context, M3InviteVia.share, phone: phone),
        icon: const Icon(Icons.share_outlined, size: 18),
        label: Text(t.m3InviteShare),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// "New chat" header actions (WhatsApp order).
// ---------------------------------------------------------------------------
class M3NewChatActions extends StatelessWidget {
  const M3NewChatActions({
    super.key,
    required this.onAdd,
    required this.onNewGroup,
    required this.onNewCommunity,
    required this.onInvite,
  });

  final VoidCallback onAdd;
  final VoidCallback onNewGroup;
  final VoidCallback onNewCommunity;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget tile(Key key, IconData icon, String title, VoidCallback onTap) =>
        ListTile(
          key: key,
          leading: CircleAvatar(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            child: Icon(icon),
          ),
          title: Text(title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          onTap: onTap,
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      tile(const Key('m3-new-add'), Icons.person_add_alt_1, t.m3AddToCircle, onAdd),
      tile(const Key('m3-new-group'), Icons.group_add_outlined,
          t.msgrHubNewGroup, onNewGroup),
      tile(const Key('m3-new-community'), Icons.groups_2_outlined,
          t.msgrHubNewCommunity, onNewCommunity),
      tile(const Key('m3-new-invite'), Icons.share_outlined, t.m3InviteFriend,
          onInvite),
      const Divider(height: Gap.md),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Requests (incoming at the TOP of My Circle; Accept / Decline + badge).
// ---------------------------------------------------------------------------
class M3RequestTile extends StatelessWidget {
  const M3RequestTile({
    super.key,
    required this.request,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
    required this.onCancel,
  });

  final Map<String, dynamic> request;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = request;
    final name =
        '${r['display_name'] ?? r['name'] ?? r['sender_name'] ?? ''}'.trim();
    final note = '${r['note'] ?? ''}'.trim();
    final incoming = m3IsIncoming(r);
    final rel = '${r['relation_label'] ?? ''}'.trim();
    return Card(
      key: Key('m3-req-${r['id']}'),
      margin: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            MsgrAvatar(
                name: name.isEmpty ? '?' : name,
                photoUrl: '${r['photo'] ?? ''}',
                radius: 22),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name.isEmpty ? t.circleSomeone : name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 16)),
                Text(incoming ? t.m3WantsToAdd : t.m3RequestWaiting,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                if (rel.isNotEmpty)
                  Text(rel,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              ]),
            ),
          ]),
          if (note.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text('"$note"', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.sm),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Gap.sm,
            runSpacing: Gap.xs,
            children: incoming
                ? [
                    OutlinedButton(
                      key: Key('m3-decline-${r['id']}'),
                      onPressed: busy ? null : onDecline,
                      child: Text(t.circleDecline),
                    ),
                    FilledButton.icon(
                      key: Key('m3-accept-${r['id']}'),
                      onPressed: busy ? null : onAccept,
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.check, size: 18),
                      label: Text(t.circleAccept),
                    ),
                  ]
                : [
                    OutlinedButton.icon(
                      key: Key('m3-cancel-${r['id']}'),
                      onPressed: busy ? null : onCancel,
                      icon: const Icon(Icons.close, size: 18),
                      label: Text(t.circleCancelRequest),
                    ),
                  ],
          ),
        ]),
      ),
    );
  }
}

/// Loads /circle/requests and owns accept / decline / cancel with honest
/// feedback. Used by the banner at the top of My Circle and the full
/// Requests screen.
mixin M3RequestsLogic<W extends StatefulWidget> on State<W> {
  List<Map<String, dynamic>> requests = [];
  bool reqLoading = true;
  Object? reqError;
  final Set<String> reqBusy = {};

  /// Called after a successful accept/decline/cancel (hub reloads members).
  void onRequestsChanged(int incomingCount, {bool accepted = false}) {}

  int get incomingCount => requests.where(m3IsIncoming).length;

  Future<void> loadRequests() async {
    if (mounted) {
      setState(() {
        reqLoading = true;
        reqError = null;
      });
    }
    try {
      final r = await context.read<AppState>().api.m3Requests();
      if (!mounted) return;
      setState(() {
        requests = r;
        reqLoading = false;
      });
      onRequestsChanged(incomingCount);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        reqError = e;
        reqLoading = false;
      });
    }
  }

  Future<void> actOn(Map<String, dynamic> r, String event) async {
    final t = AppLocalizations.of(context);
    final id = (r['id'] as num?)?.toInt();
    if (id == null) return;
    final name =
        '${r['display_name'] ?? r['name'] ?? ''}'.trim().isEmpty
            ? t.circleSomeone
            : '${r['display_name'] ?? r['name']}'.trim();
    setState(() => reqBusy.add('$id'));
    try {
      await context.read<AppState>().api.m3Act(id, event);
      if (!mounted) return;
      setState(() => requests.removeWhere((x) => x['id'] == r['id']));
      m3Snack(
          context,
          switch (event) {
            'accept' => t.m3AcceptedName(name),
            'decline' => t.m3Declined,
            _ => t.m3Cancelled,
          });
      onRequestsChanged(incomingCount, accepted: event == 'accept');
    } catch (e) {
      if (mounted) m3Snack(context, m3ErrorText(t, e), error: true);
    } finally {
      if (mounted) setState(() => reqBusy.remove('$id'));
    }
  }
}

/// The banner at the top of My Circle: incoming requests with Accept /
/// Decline and a count badge. Hidden when there is nothing to act on; a load
/// failure shows a compact error with Retry (never silent).
class M3RequestsBanner extends StatefulWidget {
  const M3RequestsBanner({
    super.key,
    this.onChanged,
    this.onSeeAll,
    this.maxShown = 3,
  });

  final void Function(int incoming, bool accepted)? onChanged;
  final VoidCallback? onSeeAll;
  final int maxShown;

  @override
  State<M3RequestsBanner> createState() => M3RequestsBannerState();
}

class M3RequestsBannerState extends State<M3RequestsBanner>
    with M3RequestsLogic<M3RequestsBanner> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => loadRequests());
  }

  /// Public so the hub can refresh it (pull-to-refresh, back from a screen).
  Future<void> reload() => loadRequests();

  @override
  void onRequestsChanged(int incomingCount, {bool accepted = false}) =>
      widget.onChanged?.call(incomingCount, accepted);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (reqLoading) return const SizedBox.shrink();
    if (reqError != null) {
      return LoadErrorRetry(
          compact: true, body: t.m3RequestsLoadFailed, onRetry: loadRequests);
    }
    final inc = requests.where(m3IsIncoming).toList();
    if (inc.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('m3-requests-banner'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
          child: Row(children: [
            Badge(
              label: Text('${inc.length}'),
              child: Icon(Icons.person_add_alt_1, color: scheme.primary),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(t.m3RequestsTitle,
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: scheme.primary)),
            ),
            if (widget.onSeeAll != null)
              TextButton(onPressed: widget.onSeeAll, child: Text(t.m3SeeAll)),
          ]),
        ),
        for (final r in inc.take(widget.maxShown))
          M3RequestTile(
            request: r,
            busy: reqBusy.contains('${r['id']}'),
            onAccept: () => actOn(r, 'accept'),
            onDecline: () => actOn(r, 'decline'),
            onCancel: () => actOn(r, 'cancel'),
          ),
        const Divider(height: Gap.md),
      ],
    );
  }
}
