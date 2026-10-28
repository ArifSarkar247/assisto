import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../business_khata_api.dart';
import '../../dues_api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show fmtDate;
import '../../services/error_kind.dart' show honestFailText;
import '../../services/error_report.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'khata_invite_sheet.dart';

/// tagada2 — the in-app "shop ↔ customer" thread of the digital khata.
///
/// ONE widget for both sides:
///  * [ChatSide.shop]: the shop owner / staff, opened from a khata customer
///    (only works when the customer is an Assisto user matched by a VERIFIED
///    phone; otherwise an invite prompt).
///  * [ChatSide.customer]: the customer, opened from My Dues.
///
/// Free (no SMS). Tagada reminders sent "in Assisto" land here too, tagged.
/// Honest: the thread is stored on Assisto's server (not end-to-end
/// encrypted) — the screen says so. Blocked → the shop sees only "not
/// reachable". No ads on this screen.
enum ChatSide { shop, customer }

class KhataChatScreen extends StatefulWidget {
  final ChatSide side;
  final int businessId;

  /// Shop side: the khata party id. Ignored on the customer side.
  final int partyId;

  /// The other party's name (customer name for the shop, shop name for the
  /// customer).
  final String title;
  const KhataChatScreen(
      {super.key,
      required this.side,
      required this.businessId,
      this.partyId = 0,
      required this.title});

  @override
  State<KhataChatScreen> createState() => _KhataChatScreenState();
}

class _KhataChatScreenState extends State<KhataChatScreen> {
  final _text = TextEditingController();
  List<Map<String, dynamic>> _msgs = [];
  bool _loading = true;
  bool _sending = false;
  Object? _fail;
  bool _assistoUser = true;
  bool _reachable = true;
  bool _blocked = false;
  String _sendError = '';

  bool get _shop => widget.side == ChatSide.shop;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _msgs.isEmpty;
      _fail = null;
    });
    final api = context.read<AppState>().api;
    try {
      final r = _shop
          ? await api.khataChat(widget.businessId, widget.partyId)
          : await api.myDuesChat(widget.businessId);
      _msgs = ((r['messages'] ?? const []) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      _assistoUser = r['assisto_user'] != false;
      _reachable = r['reachable'] != false;
      _blocked = r['blocked'] == true;
    } catch (e) {
      _fail = e;
      reportNonFatal('khata.chatLoad', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _sendError = '';
    });
    final api = context.read<AppState>().api;
    try {
      final r = _shop
          ? await api.khataChatSend(widget.businessId, widget.partyId, text)
          : await api.myDuesChatSend(widget.businessId, text);
      if (!mounted) return;
      if (r['ok'] == true) {
        final m = r['message'];
        _text.clear();
        setState(() {
          if (m is Map) {
            _msgs = [..._msgs, m.cast<String, dynamic>()];
          }
        });
      } else {
        final reason = '${r['reason'] ?? ''}';
        setState(() {
          if (reason == 'not_reachable') _reachable = false;
          if (reason == 'not_assisto_user') _assistoUser = false;
          if (reason == 'blocked') _blocked = true;
          _sendError = reason == 'not_reachable'
              ? t.tg2NotReachable
              : '${r['detail'] ?? t.tg2ChatFailed}';
        });
      }
    } catch (e) {
      reportNonFatal('khata.chatSend', e);
      if (mounted) setState(() => _sendError = t.tg2ChatFailed);
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.tg2ChatTitle(widget.title),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: t.retry,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_fail != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.tg2ChatTitle(widget.title),
        message: honestFailText(t, _fail),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_shop && !_assistoUser) {
      return StateMessage(
        icon: Icons.person_add_alt_1_rounded,
        title: t.tg2InvTitle,
        message: t.tg2ChatNotOnAssisto(widget.title),
        action: FilledButton.icon(
          key: const ValueKey('tg2-chat-invite'),
          icon: const Icon(Icons.send_rounded),
          label: Text(t.tg2InviteFree),
          onPressed: () => showKhataInviteSheet(context,
              businessId: widget.businessId,
              partyId: widget.partyId,
              name: widget.title),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final canSend = _shop ? _reachable : !_blocked;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
        child: Row(children: [
          Icon(Icons.info_outline_rounded,
              size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(t.tg2ChatPrivacy,
                style: AType.bodySmall
                    .copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
      Expanded(
        child: _msgs.isEmpty
            ? StateMessage(
                icon: Icons.chat_bubble_outline_rounded,
                title: t.tg2ChatEmpty)
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.builder(
                  padding: const EdgeInsets.all(Gap.lg),
                  itemCount: _msgs.length,
                  itemBuilder: (_, i) => _bubble(t, _msgs[i]),
                ),
              ),
      ),
      if (!canSend)
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _shop ? t.tg2NotReachable : t.tg2ChatBlockedYou,
              key: const ValueKey('tg2-chat-cant'),
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        )
      else
        _composer(t),
    ]);
  }

  Widget _composer(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_sendError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Semantics(
              liveRegion: true,
              child: Text(_sendError,
                  style: AType.bodySmall.copyWith(color: scheme.error)),
            ),
          ),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              key: const ValueKey('tg2-chat-input'),
              controller: _text,
              minLines: 1,
              maxLines: 4,
              maxLength: 1000,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                  hintText: t.tg2ChatHint, counterText: ''),
            ),
          ),
          const SizedBox(width: Gap.sm),
          IconButton.filled(
            key: const ValueKey('tg2-chat-send'),
            tooltip: t.tg2ChatSend,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
          ),
        ]),
      ]),
    );
  }

  Widget _bubble(AppLocalizations t, Map<String, dynamic> m) {
    final scheme = Theme.of(context).colorScheme;
    final mine = _shop ? m['from'] == 'shop' : m['from'] == 'customer';
    final isTagada = m['kind'] == 'tagada';
    final lang = Localizations.localeOf(context).languageCode;
    final at = DateTime.tryParse('${m['at'] ?? ''}')?.toLocal();
    final when = at == null ? '' : fmtDate('d MMM, h:mm a', at, lang);
    final bg = mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    return Align(
      alignment:
          mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        child: Container(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
              color: bg, borderRadius: BorderRadius.circular(Radii.md)),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isTagada)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.xs),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.campaign_rounded, size: 16, color: fg),
                      const SizedBox(width: Gap.xs),
                      Flexible(
                        child: Text(t.tg2ChatReminderTag,
                            style: AType.bodySmall.copyWith(
                                color: fg, fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  ),
                Text('${m['text'] ?? ''}',
                    style: AType.bodyMedium.copyWith(color: fg)),
                if (when.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  Text(when,
                      style: AType.bodySmall
                          .copyWith(color: fg.withValues(alpha: 0.8))),
                ],
              ]),
        ),
      ),
    );
  }
}
