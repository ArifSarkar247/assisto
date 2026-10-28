import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../services/error_kind.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'crm100_api.dart';

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
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Text(t.c100BulkIntro(_d(widget.customers.length)), style: AType.bodyMedium),
      const SizedBox(height: Gap.xs),
      Text(t.c100NeverAuto,
          style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _text,
        minLines: 3,
        maxLines: 6,
        maxLength: 600,
        decoration: InputDecoration(
            labelText: t.c100MessageLabel,
            helperText: t.c100NameHint('{name}'),
            helperMaxLines: 2,
            border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.md),
      if (_fail != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Text(
              failKindOf(_fail!) == FailKind.network
                  ? t.c100Offline
                  : honestFailText(t, _fail, otherwise: t.c100PreviewFailed),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      FilledButton.icon(
        onPressed: _busy ? null : _build,
        icon: _busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.view_agenda_rounded),
        label: Text(t.c100BulkMakeCards),
      ),
    ]);
  }

  Widget _cardsView(AppLocalizations t) {
    if (_cards.isEmpty) {
      return StateMessage(icon: Icons.people_outline_rounded, title: t.c100BulkNoCards);
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
              child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                Chip(label: Text(t.c100TallyDone(_d(sent)))),
                Chip(label: Text(t.c100TallySkipped(_d(skipped)))),
                Chip(label: Text(t.c100TallyWaiting(_d(waiting)))),
              ]),
            ),
          );
        }
        return _card(t, _cards[i - 1]);
      },
    );
  }

  Widget _card(AppLocalizations t, _Card k) {
    final scheme = Theme.of(context).colorScheme;
    final c = k.c;
    final phoneOk = c['phone_ok'] == true;
    final smsOk = k.sms['available'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${c['name'] ?? ''}'.isEmpty ? _d('${c['phone'] ?? ''}') : '${c['name']}',
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text('${c['text'] ?? ''}', style: AType.bodyMedium),
          if (k.detail.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(k.detail,
                style: AType.bodySmall
                    .copyWith(color: k.st == _St.failed ? scheme.error : scheme.primary)),
          ],
          if (!phoneOk) ...[
            const SizedBox(height: Gap.xs),
            Text(t.c100NoPhone, style: AType.bodySmall.copyWith(color: scheme.error)),
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
      ),
    );
  }
}
