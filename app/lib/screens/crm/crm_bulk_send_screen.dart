import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../services/error_kind.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'crm100_api.dart';
import '../../widgets/local_counter.dart';

/// crm100 — a message to several customers, done the only honest way: ONE
/// card per customer, each with their own name filled in and their own
/// WhatsApp / phone SMS / Assisto SMS buttons. The seller taps each one; a
/// live sent / skipped / waiting tally. Nothing is ever sent in one go.
class CrmBulkSendScreen extends StatefulWidget {
  final int? business;

  /// Rows from the customer list (key, phone_key, party_id, lead_id, name).
  final List<Map<String, dynamic>> customers;
  const CrmBulkSendScreen({super.key, this.business, required this.customers});

  @override
  State<CrmBulkSendScreen> createState() => _CrmBulkSendScreenState();
}

enum _St { waiting, opened, sent, skipped, failed }

class _Card {
  final Map<String, dynamic> c;
  _St st = _St.waiting;
  String detail = '';
  bool busy = false;
  _Card(this.c);
  CustomerTarget get target {
    final t = (c['target'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CustomerTarget(
        phone: t['phone'] as String?,
        party: (t['party'] as num?)?.toInt(),
        lead: (t['lead'] as num?)?.toInt());
  }

  Map<String, dynamic> get sms => (c['sms'] as Map?)?.cast<String, dynamic>() ?? const {};
}

class _CrmBulkSendScreenState extends State<CrmBulkSendScreen> {
  final _text = TextEditingController();
  List<_Card> _cards = [];
  String _bulkId = '';
  bool _busy = false;
  Object? _fail;
  bool _built = false;
  int _stopped = 0; // gap-bizai: customers left out because they said STOP
  int _notFound = 0; // gap-bizai: targets the server could not find

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_text.text.isEmpty) _text.text = AppLocalizations.of(context).c100BulkDefault('{name}');
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _d(Object v) =>
      localDigits('$v', Localizations.localeOf(context).languageCode);

  Future<void> _build() async {
    final txt = _text.text.trim();
    if (txt.isEmpty) return;
    setState(() {
      _busy = true;
      _fail = null;
    });
    try {
      final r = await Crm100Api.of(context)
          .sendBulk([for (final c in widget.customers) CustomerTarget.fromRow(c)], txt,
              business: widget.business,
              lang: Localizations.localeOf(context).languageCode)
          .timeout(const Duration(seconds: 25));
      _bulkId = '${r['bulk_id'] ?? ''}';
      _stopped = (r['opted_out'] as num?)?.toInt() ?? 0;
      _notFound = ((r['skipped'] ?? const []) as List)
          .where((x) => x is Map && x['reason'] == 'not_found')
          .length;
      _cards = [
        for (final c in ((r['cards'] ?? []) as List).cast<Map<String, dynamic>>()) _Card(c)
      ];
      _built = true;
    } catch (e) {
      _fail = e;
      reportNonFatal('crm100.bulk', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _open(_Card k, String url, String channel) async {
    final t = AppLocalizations.of(context);
    setState(() => k.busy = true);
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (e) {
      reportNonFatal('crm100.bulkOpen', e);
    }
    if (ok && mounted) {
      try {
        await Crm100Api.of(context).sendLog(k.target, channel, '${k.c['text'] ?? ''}',
            business: widget.business, bulkId: _bulkId);
      } catch (e) {
        reportNonFatal('crm100.bulkLog', e);
      }
    }
    if (!mounted) return;
    setState(() {
      k.busy = false;
      k.st = ok ? _St.opened : _St.failed;
      k.detail = ok
          ? (channel == 'whatsapp_link' ? t.c100OpenedWa : t.c100OpenedSms)
          : t.c100CantOpen;
    });
  }

  Future<void> _assisto(_Card k) async {
    final t = AppLocalizations.of(context);
    final credits = (k.sms['credits'] as num?)?.toInt() ?? 1;
    final bal = (k.sms['balance'] as num?)?.toInt() ?? 0;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.c100SmsConfirmTitle),
        content: Text(t.c100SmsConfirmBody('${k.c['name'] ?? ''}', _d(credits), _d(bal))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.c100SmsSend)),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => k.busy = true);
    try {
      final r = await Crm100Api.of(context).sendSms(k.target, '${k.c['text'] ?? ''}', credits,
          business: widget.business,
          lang: Localizations.localeOf(context).languageCode,
          bulkId: _bulkId);
      final left = (r['balance'] as num?)?.toInt();
      if (left != null) {
        for (final c in _cards) {
          final m = c.c['sms'];
          if (m is Map) m['balance'] = left;
        }
      }
      k.st = _St.sent;
      k.detail = t.c100SmsSent(_d((r['credits'] as num?)?.toInt() ?? credits), _d(left ?? bal));
    } catch (e) {
      final body = e is ApiException ? e.body : null;
      k.st = _St.failed;
      k.detail = '${body?['detail'] ?? ''}'.isNotEmpty
          ? '${body!['detail']}'
          : honestFailText(t, e, otherwise: t.c100SmsFailed);
    }
    if (mounted) setState(() => k.busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.c100BulkTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _built ? _cardsView(t) : _compose(t),
    );
  }

  Widget _compose(AppLocalizations t) {
    final ds = Theme.of(context).colorScheme.ds;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      // who it goes to (the big count) as the soft hero, then the message
      DsHeroCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DsAvatar(child: Icon(Icons.groups_rounded, size: 22, color: ds.primaryInk)),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DsNumber(_d(widget.customers.length), small: true),
              Text(t.c100BulkIntro(_d(widget.customers.length)),
                  style: AType.bodyMedium.copyWith(color: ds.text)),
              const SizedBox(height: Gap.xs),
              Text(t.c100NeverAuto, style: AType.bodySmall.copyWith(color: ds.muted)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: Gap.lg),
      TextField(
        controller: _text,
        minLines: 3,
        maxLines: 6,
        maxLength: 600,
        buildCounter: localCounter,
        decoration: InputDecoration(
            labelText: t.c100MessageLabel,
            helperText: t.c100NameHint('{name}'),
            helperMaxLines: 2),
      ),
      const SizedBox(height: Gap.md),
      if (_fail != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Text(
              failKindOf(_fail!) == FailKind.network
                  ? t.c100Offline
                  : honestFailText(t, _fail, otherwise: t.c100PreviewFailed),
              style: AType.bodyMedium.copyWith(color: ds.dangerInk)),
        ),
      DsButton(
        onPressed: _busy ? null : _build,
        busy: _busy,
        icon: Icons.view_agenda_rounded,
        label: t.c100BulkMakeCards,
        expand: true,
      ),
    ]);
  }

  Widget _cardsView(AppLocalizations t) {
    if (_cards.isEmpty) {
      return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        DsEmptyState(icon: Icons.people_outline_rounded, title: t.c100BulkNoCards),
        if (_stopped > 0) _stoppedNote(t),
        if (_notFound > 0) _notFoundNote(t),
      ]);
    }
    final sent = _cards.where((c) => c.st == _St.sent || c.st == _St.opened).length;
    final skipped = _cards.where((c) => c.st == _St.skipped).length;
    final waiting = _cards.where((c) => c.st == _St.waiting).length;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
      itemCount: _cards.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              // the run's live tally as the soft hero
              child: DsHeroCard(
                child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  _tally(t.c100TallyDone(_d(sent)), Theme.of(context).colorScheme.ds.successInk),
                  _tally(t.c100TallySkipped(_d(skipped)), null),
                  _tally(t.c100TallyWaiting(_d(waiting)), Theme.of(context).colorScheme.ds.primaryInk),
                  if (_stopped > 0) _stoppedNote(t),
                  if (_notFound > 0) _notFoundNote(t),
                ]),
              ),
            ),
          );
        }
        return _card(t, _cards[i - 1]);
      },
    );
  }

  /// gap-bizai P0: who was left out because they said STOP (no card at all).
  Widget _stoppedNote(AppLocalizations t) => Padding(
        key: const ValueKey('gbz-bulk-stopped'),
        padding: const EdgeInsets.only(top: Gap.xs),
        child: Row(children: [
          const Icon(Icons.block_rounded, size: 18),
          const SizedBox(width: Gap.xs),
          Expanded(child: Text(t.gbzBulkStopped(_d(_stopped)), style: AType.bodyMedium)),
        ]),
      );

  Widget _notFoundNote(AppLocalizations t) => Padding(
        key: const ValueKey('gbz-bulk-notfound'),
        padding: const EdgeInsets.only(top: Gap.xs),
        child: Row(children: [
          const Icon(Icons.person_off_rounded, size: 18),
          const SizedBox(width: Gap.xs),
          Expanded(child: Text(t.gbzBulkNotFound(_d(_notFound)), style: AType.bodyMedium)),
        ]),
      );

  Widget _tally(String label, Color? ink) {
    final ds = Theme.of(context).colorScheme.ds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: ink == null ? ds.cardHighest : ink.withValues(alpha: ds.isDark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label,
          style: AType.bodyMedium.copyWith(
              fontWeight: FontWeight.w600, fontFeatures: AFonts.tabular, color: ink ?? ds.text)),
    );
  }

  Widget _card(AppLocalizations t, _Card k) {
    final scheme = Theme.of(context).colorScheme;
    final c = k.c;
    final phoneOk = c['phone_ok'] == true;
    final smsOk = k.sms['available'] == true;
    return Padding(padding: const EdgeInsets.only(bottom: Gap.md), child: DsCard(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            DsAvatar(name: '${c['name'] ?? ''}', size: 40),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text('${c['name'] ?? ''}'.isEmpty ? _d('${c['phone'] ?? ''}') : '${c['name']}',
                  style: AType.titleMedium.copyWith(
                      color: scheme.ds.text, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          // the exact message, as a soft quote
          DsSurface(
            flat: true,
            color: scheme.ds.cardAlt,
            borderColor: scheme.ds.border,
            padding: const EdgeInsets.all(Gap.md),
            child: Text('${c['text'] ?? ''}',
                style: AType.bodyMedium.copyWith(color: scheme.ds.text)),
          ),
          if (k.detail.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(k.detail,
                style: AType.bodySmall
                    .copyWith(color: k.st == _St.failed ? scheme.ds.dangerInk : scheme.ds.primaryInk)),
          ],
          if (!phoneOk) ...[
            const SizedBox(height: Gap.xs),
            Text(t.c100NoPhone, style: AType.bodySmall.copyWith(color: scheme.ds.dangerInk)),
          ],
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            FilledButton.tonalIcon(
              onPressed: phoneOk && !k.busy
                  ? () => _open(k, '${c['wa_url']}', 'whatsapp_link')
                  : null,
              icon: const Icon(Icons.chat_rounded),
              label: Text(t.c100WayWa),
            ),
            OutlinedButton.icon(
              onPressed:
                  phoneOk && !k.busy ? () => _open(k, '${c['sms_uri']}', 'sms_app') : null,
              icon: const Icon(Icons.sms_rounded),
              label: Text(t.c100WaySms),
            ),
            if (smsOk)
              OutlinedButton.icon(
                onPressed: k.busy || k.st == _St.sent ? null : () => _assisto(k),
                icon: const Icon(Icons.outgoing_mail),
                label: Text(t.c100WayAssistoShort(_d((k.sms['credits'] as num?)?.toInt() ?? 1))),
              ),
            TextButton(
              onPressed: k.st == _St.waiting
                  ? () => setState(() {
                        k.st = _St.skipped;
                        k.detail = t.c100Skipped;
                      })
                  : null,
              child: Text(t.c100Skip),
            ),
          ]),
        ]),
      ));
  }
}
