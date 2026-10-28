import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../plans_v2/upgrade_sheet.dart';
import '../../services/error_kind.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'crm100_api.dart';
import 'crm_common.dart';
import 'crm_send_sheet.dart';
import 'shop_quote_screens.dart';

/// crm100 — ONE customer, everything in one place (owner final order:
/// "no single customer history page" was the #1 gap vs WhatsApp Business).
/// Khata due + entries, shop sales, online orders with payment status, AI
/// sales chats, CRM leads / deals / tasks / notes, price quotes, messages
/// sent from the CRM and tagada SMS — from this shop's own data only.
/// Actions: message (WhatsApp / phone SMS / Assisto SMS), price quote, call,
/// add to CRM. Offline: the last copy seen opens, clearly marked as saved.
class CustomerHistoryScreen extends StatefulWidget {
  final CustomerTarget target;
  final String name;
  final int? business;
  const CustomerHistoryScreen(
      {super.key, required this.target, this.name = '', this.business});

  @override
  State<CustomerHistoryScreen> createState() => _CustomerHistoryScreenState();
}

/// Filter chip → the server's `kinds`.
const _filters = <String, String?>{
  'all': null,
  'khata': 'khata,sale',
  'orders': 'order,quote',
  'chats': 'chat',
  'crm': 'lead,deal,activity',
  'messages': 'message,sms',
};

class _CustomerHistoryScreenState extends State<CustomerHistoryScreen> {
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _items = [];
  String? _next;
  bool _loading = true;
  bool _more = false;
  Object? _fail;
  String? _savedAt; // set when showing the offline copy
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _d(Object v) =>
      localDigits('$v', Localizations.localeOf(context).languageCode);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    final api = Crm100Api.of(context);
    try {
      final r = await api
          .history(widget.target, business: widget.business, kinds: _filters[_filter])
          .timeout(const Duration(seconds: 20));
      _apply(r);
      _savedAt = null;
      if (_filter == 'all') CustomerHistoryCache.write(widget.target.cacheKey, r);
    } catch (e) {
      final cached = _filter == 'all' && failKindOf(e) == FailKind.network
          ? await CustomerHistoryCache.read(widget.target.cacheKey)
          : null;
      if (cached != null) {
        _apply(cached);
        _savedAt = '${cached['saved_at'] ?? ''}';
        _next = null; // no paging on the saved copy
      } else {
        _fail = e;
        reportNonFatal('crm100.history', e);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _apply(Map<String, dynamic> r) {
    final s = r['summary'];
    if (s is Map) _summary = s.cast<String, dynamic>();
    _items = ((r['items'] ?? []) as List).cast<Map<String, dynamic>>();
    _next = r['next_before'] as String?;
  }

  Future<void> _loadMore() async {
    if (_next == null || _more) return;
    setState(() => _more = true);
    try {
      final r = await Crm100Api.of(context).history(widget.target,
          business: widget.business, kinds: _filters[_filter], before: _next);
      _items = [..._items, ...((r['items'] ?? []) as List).cast<Map<String, dynamic>>()];
      _next = r['next_before'] as String?;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(honestFailText(AppLocalizations.of(context), e))));
      }
    }
    if (mounted) setState(() => _more = false);
  }

  String get _name {
    final n = '${_summary?['name'] ?? ''}'.trim();
    return n.isNotEmpty ? n : widget.name;
  }

  String get _phone => '${_summary?['phone'] ?? widget.target.phone ?? ''}';

  int? get _firstLead {
    final l = (_summary?['leads'] as List?) ?? const [];
    return l.isEmpty ? null : ((l.first as Map)['id'] as num?)?.toInt();
  }

  Future<void> _message() async {
    final t = AppLocalizations.of(context);
    final sent = await CrmSendSheet.show(context,
        target: widget.target,
        name: _name,
        business: widget.business,
        lead: _firstLead,
        initialText: t.c100DefaultText(_name.isEmpty ? t.c100Customer : _name));
    if (sent == true) _load();
  }

  Future<void> _quote() async {
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ShopQuoteBuilderScreen(
            business: widget.business,
            customerName: _name,
            customerPhone: _phone,
            lead: _firstLead)));
    if (made == true) _load();
  }

  Future<void> _call() async {
    final t = AppLocalizations.of(context);
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse('tel:$_phone'), mode: LaunchMode.externalApplication)
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (_) {
      // best-effort: ok stays false and the snackbar below says so
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.c100CantOpen)));
    }
  }

  Future<void> _addToCrm() async {
    final t = AppLocalizations.of(context);
    try {
      final orgs = await CrmApi.of(context).orgs();
      if (!mounted) return;
      if (orgs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.c100NoCrmOrg)));
        return;
      }
      await CrmApi.of(context).createLead({
        'org': orgs.first['id'],
        'name': _name,
        'phone': _phone,
        'source': 'manual',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.c100AddedToCrm)));
      _load();
    } catch (e) {
      if (!mounted) return;
      if (await UpgradeSheet.handle(context, e)) return; // plan limit: honest sheet
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(honestFailText(t, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final title = _name.isNotEmpty ? _name : (_phone.isNotEmpty ? _d(_phone) : t.c100Customer);
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading && _summary == null) return const SkeletonList();
    if (_fail != null && _summary == null) {
      final net = failKindOf(_fail!) == FailKind.network;
      return StateMessage(
        icon: net ? Icons.wifi_off_rounded : Icons.cloud_off_rounded,
        title: net ? t.c100OfflineTitle : t.loadFailed,
        message: net ? t.c100OfflineNoCopy : honestFailText(t, _fail),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    final s = _summary ?? const {};
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
          sliver: SliverList.list(children: [
            if (_savedAt != null) ...[
              _Banner(
                  icon: Icons.wifi_off_rounded,
                  text: t.c100SavedCopy(_savedAt!.isEmpty ? '—' : crmDate(context, _savedAt))),
              const SizedBox(height: Gap.md),
            ],
            _header(t, s),
            const SizedBox(height: Gap.md),
            if (s['opted_out'] == true) ...[
              _Banner(icon: Icons.block_rounded, text: t.c100OptedOutBanner),
              const SizedBox(height: Gap.md),
            ],
            _stats(t, s),
            const SizedBox(height: Gap.md),
            _actions(t, s),
            const SizedBox(height: Gap.lg),
            Text(t.c100Timeline, style: AType.titleMedium),
            const SizedBox(height: Gap.sm),
            _filterChips(t),
            const SizedBox(height: Gap.sm),
            if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xl),
                child: StateMessage(
                    icon: Icons.history_rounded,
                    title: _filter == 'all' ? t.c100EmptyTitle : t.c100EmptyFilter,
                    message: _filter == 'all' ? t.c100EmptyBody : null),
              ),
          ]),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          sliver: SliverList.builder(
            itemCount: _items.length,
            itemBuilder: (_, i) => _TimelineTile(item: _items[i]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xxl),
            child: _next == null
                ? const SizedBox.shrink()
                : OutlinedButton.icon(
                    onPressed: _more ? null : _loadMore,
                    icon: _more
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.expand_more_rounded),
                    label: Text(t.c100LoadOlder)),
          ),
        ),
      ]),
    );
  }

  Widget _header(AppLocalizations t, Map s) {
    final scheme = Theme.of(context).colorScheme;
    final sources = ((s['sources'] ?? const []) as List).map((e) => '$e').toList();
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Radii.lg)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: scheme.primaryContainer,
          child: Text(_name.isEmpty ? '#' : _name.characters.first.toUpperCase(),
              style: AType.titleLarge.copyWith(color: scheme.onPrimaryContainer)),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_name.isEmpty ? t.c100NoName : _name,
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
            if (_phone.isNotEmpty)
              Text(_d(_phone), style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
              for (final src in sources)
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(_sourceLabel(t, src)),
                ),
              if (sources.isEmpty) Text(t.c100NoSources, style: AType.bodySmall),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _stats(AppLocalizations t, Map s) {
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    final tiles = <Widget>[];
    void add(String label, String value, {bool warn = false}) =>
        tiles.add(_Stat(label: label, value: value, warn: warn));
    final due = n('khata_due_poisha');
    if ((s['sources'] as List? ?? const []).contains('khata')) {
      add(due >= 0 ? t.c100StatDue : t.c100StatAdvance, bdt(context, due.abs() / 100),
          warn: due > 0);
    }
    if (n('orders_count') > 0) {
      add(t.c100StatOrders, t.c100OrdersValue(_d(n('orders_count')), _d(n('orders_open'))));
    }
    if (n('orders_cod_to_collect_poisha') > 0) {
      add(t.c100StatCod, bdt(context, n('orders_cod_to_collect_poisha') / 100));
    }
    if (n('orders_returned') > 0) {
      add(t.c100StatReturned, _d(n('orders_returned')), warn: true);
    }
    if (n('orders_payment_to_check') > 0) {
      add(t.c100StatPayCheck, _d(n('orders_payment_to_check')), warn: true);
    }
    if (n('sales_count') > 0) {
      add(t.c100StatSales, bdt(context, n('sales_total_poisha') / 100));
    }
    if (n('deals_open') > 0 || n('tasks_open') > 0) {
      add(t.c100StatCrm, t.c100CrmValue(_d(n('deals_open')), _d(n('tasks_open'))));
    }
    if (n('quotes_open') > 0) add(t.c100StatQuotes, _d(n('quotes_open')));
    final last = '${s['last_contact_at'] ?? ''}';
    if (last.isNotEmpty) add(t.c100StatLast, crmDate(context, last));
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: tiles);
  }

  Widget _actions(AppLocalizations t, Map s) {
    final hasShop = s['has_business'] == true;
    final hasCrm = s['has_crm'] == true;
    final leads = (s['leads'] as List?) ?? const [];
    return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
      FilledButton.icon(
          onPressed: _message, icon: const Icon(Icons.send_rounded), label: Text(t.c100ActMessage)),
      if (hasShop)
        FilledButton.tonalIcon(
            onPressed: _quote,
            icon: const Icon(Icons.request_quote_rounded),
            label: Text(t.c100ActQuote)),
      if (_phone.isNotEmpty)
        OutlinedButton.icon(
            onPressed: _call, icon: const Icon(Icons.call_rounded), label: Text(t.c100ActCall)),
      if (hasCrm && leads.isEmpty && _savedAt == null)
        OutlinedButton.icon(
            onPressed: _addToCrm,
            icon: const Icon(Icons.person_add_alt_rounded),
            label: Text(t.c100ActAddCrm)),
    ]);
  }

  Widget _filterChips(AppLocalizations t) {
    final labels = {
      'all': t.c100FAll,
      'khata': t.c100FKhata,
      'orders': t.c100FOrders,
      'chats': t.c100FChats,
      'crm': t.c100FCrm,
      'messages': t.c100FMessages,
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final e in labels.entries)
          Padding(
            padding: const EdgeInsets.only(right: Gap.xs),
            child: ChoiceChip(
              label: Text(e.value),
              selected: _filter == e.key,
              onSelected: _savedAt != null
                  ? null
                  : (_) {
                      setState(() => _filter = e.key);
                      _load();
                    },
            ),
          ),
      ]),
    );
  }
}

String _sourceLabel(AppLocalizations t, String s) {
  switch (s) {
    case 'khata':
      return t.c100SrcKhata;
    case 'sale':
      return t.c100SrcSale;
    case 'order':
      return t.c100SrcOrder;
    case 'chat':
      return t.c100SrcChat;
    case 'crm':
      return t.c100SrcCrm;
    default:
      return s;
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;
  const _Stat({required this.label, required this.value, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          border: Border.all(color: warn ? scheme.error : scheme.outlineVariant),
          borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xxs),
        Text(value,
            style: AType.titleMedium.copyWith(
                fontWeight: FontWeight.w800, color: warn ? scheme.error : scheme.onSurface)),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Banner({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(children: [
        Icon(icon, size: 20, color: scheme.onSecondaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer))),
      ]),
    );
  }
}

/// One line of the timeline. Every word from ARB; amounts with ৳ and the
/// locale's digits; the date in the locale's format.
class _TimelineTile extends StatelessWidget {
  final Map<String, dynamic> item;
  const _TimelineTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final v = describeItem(context, t, item);
    final at = '${item['at'] ?? ''}';
    final d = DateTime.tryParse(at)?.toLocal();
    final when = d == null
        ? ''
        : DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(d);
    return Semantics(
      container: true,
      label: [v.title, v.subtitle, v.amount, when].where((x) => x.isNotEmpty).join(', '),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: v.bad ? scheme.errorContainer : scheme.primaryContainer,
                shape: BoxShape.circle),
            child: Icon(v.icon,
                size: 20, color: v.bad ? scheme.onErrorContainer : scheme.onPrimaryContainer),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v.title, style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
              if (v.subtitle.isNotEmpty)
                Text(v.subtitle,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              if (when.isNotEmpty)
                Text(when, style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          if (v.amount.isNotEmpty) ...[
            const SizedBox(width: Gap.sm),
            Text(v.amount,
                style: AType.titleSmall.copyWith(
                    fontWeight: FontWeight.w800, color: v.bad ? scheme.error : scheme.onSurface)),
          ],
        ]),
      ),
    );
  }
}

class ItemView {
  final IconData icon;
  final String title;
  final String subtitle;
  final String amount;
  final bool bad;
  const ItemView(this.icon, this.title, {this.subtitle = '', this.amount = '', this.bad = false});
}

String orderStatusLabel(AppLocalizations t, String s) {
  switch (s) {
    case 'new':
      return t.c100OsNew;
    case 'confirmed':
      return t.c100OsConfirmed;
    case 'packed':
      return t.c100OsPacked;
    case 'shipped':
      return t.c100OsShipped;
    case 'delivered':
      return t.c100OsDelivered;
    case 'returned':
      return t.c100OsReturned;
    case 'cancelled':
      return t.c100OsCancelled;
    default:
      return s;
  }
}

String payLabel(AppLocalizations t, String p) {
  switch (p) {
    case 'cod':
      return t.c100PayCod;
    case 'bkash':
      return t.c100PayBkash;
    case 'nagad':
      return t.c100PayNagad;
    case 'paid':
      return t.c100PayPaid;
    case 'cash':
      return t.c100PayCash;
    case 'due':
      return t.c100PayDue;
    default:
      return p;
  }
}

String quoteStateLabel(AppLocalizations t, String s) {
  switch (s) {
    case 'issued':
      return t.c100QsIssued;
    case 'viewed':
      return t.c100QsViewed;
    case 'accepted':
      return t.c100QsAccepted;
    case 'declined':
      return t.c100QsDeclined;
    case 'expired':
      return t.c100QsExpired;
    case 'revoked':
      return t.c100QsRevoked;
    default:
      return s;
  }
}

String _channelLabel(AppLocalizations t, String c) {
  switch (c) {
    case 'messenger':
      return t.c100ChMessenger;
    case 'instagram':
      return t.c100ChInstagram;
    case 'whatsapp_cloud':
      return t.c100ChWhatsapp;
    case 'website':
      return t.c100ChWebsite;
    default:
      return c;
  }
}

String _activityLabel(AppLocalizations t, String k) {
  switch (k) {
    case 'call':
      return t.c100AcCall;
    case 'meeting':
      return t.c100AcMeeting;
    case 'task':
      return t.c100AcTask;
    case 'note':
      return t.c100AcNote;
    case 'email':
      return t.c100AcEmail;
    case 'whatsapp':
      return t.c100AcWhatsapp;
    case 'stage':
      return t.c100AcStage;
    default:
      return t.c100AcSystem;
  }
}

/// Pure text for a timeline item (unit-tested in crm100_test.dart).
ItemView describeItem(BuildContext context, AppLocalizations t, Map<String, dynamic> it) {
  final lang = Localizations.localeOf(context).languageCode;
  String d(Object v) => localDigits('$v', lang);
  String money(Object? p) => bdt(context, ((p as num?) ?? 0) / 100);
  switch ('${it['kind']}') {
    case 'khata':
      final gave = it['dir'] == 'gave';
      return ItemView(gave ? Icons.north_east_rounded : Icons.south_west_rounded,
          gave ? t.c100KhataGave : t.c100KhataGot,
          subtitle: '${it['note'] ?? ''}', amount: money(it['amount_poisha']), bad: gave);
    case 'sale':
      final due = (it['due_poisha'] as num?)?.toInt() ?? 0;
      return ItemView(Icons.point_of_sale_rounded,
          it['voided'] == true ? t.c100SaleVoided : t.c100Sale,
          subtitle: [
            payLabel(t, '${it['payment'] ?? ''}'),
            if (due > 0) t.c100SaleDue(money(due)),
          ].join(' · '),
          amount: money(it['amount_poisha']));
    case 'order':
      final ps = '${it['payment_status'] ?? ''}';
      final st = '${it['status'] ?? ''}';
      return ItemView(Icons.local_shipping_rounded,
          t.c100OrderTitle(d('${it['ref']?['id'] ?? ''}')),
          subtitle: [
            orderStatusLabel(t, st),
            payLabel(t, '${it['payment'] ?? ''}'),
            if (ps == 'pending_verification') t.c100PayToCheck,
            if (ps == 'verified') t.c100PayVerified,
            if ('${it['first_item'] ?? ''}'.isNotEmpty) '${it['first_item']}',
          ].join(' · '),
          amount: money(it['amount_poisha']),
          bad: st == 'returned' || st == 'cancelled');
    case 'chat':
      return ItemView(Icons.forum_rounded,
          t.c100ChatTitle(_channelLabel(t, '${it['channel'] ?? ''}'),
              d((it['messages'] as num?)?.toInt() ?? 0)),
          subtitle: '${it['last_text'] ?? ''}');
    case 'lead':
      return ItemView(Icons.person_add_rounded, t.c100LeadAdded);
    case 'deal':
      final state = '${it['state'] ?? ''}';
      return ItemView(Icons.handshake_rounded, '${it['title'] ?? t.c100Deal}',
          subtitle: [
            if ('${it['stage'] ?? ''}'.isNotEmpty) '${it['stage']}',
            state == 'won'
                ? t.c100DealWon
                : state == 'lost'
                    ? t.c100DealLost
                    : t.c100DealOpen,
          ].join(' · '),
          amount: money(it['amount_poisha']),
          bad: state == 'lost');
    case 'activity':
      final sub = '${it['sub'] ?? ''}';
      final text = '${it['subject'] ?? ''}'.isNotEmpty ? '${it['subject']}' : '${it['body'] ?? ''}';
      return ItemView(
          sub == 'task' ? Icons.task_alt_rounded : Icons.sticky_note_2_rounded,
          _activityLabel(t, sub),
          subtitle: [
            if (text.isNotEmpty) text,
            if (sub == 'task') it['done'] == true ? t.c100TaskDone : t.c100TaskOpen,
          ].join(' · '));
    case 'quote':
      final st = '${it['state'] ?? ''}';
      return ItemView(Icons.request_quote_rounded, t.c100QuoteTitle,
          subtitle: quoteStateLabel(t, st),
          amount: money(it['amount_poisha']),
          bad: st == 'declined' || st == 'expired');
    case 'message':
      final ch = '${it['channel'] ?? ''}';
      final st = '${it['status'] ?? ''}';
      final how = ch == 'whatsapp_link'
          ? t.c100MsgWa
          : ch == 'sms_app'
              ? t.c100MsgSmsApp
              : st == 'sent'
                  ? t.c100MsgAssistoSent
                  : t.c100MsgAssistoBlocked;
      return ItemView(ch == 'whatsapp_link' ? Icons.chat_rounded : Icons.sms_rounded,
          it['purpose'] == 'tagada' ? t.c100TagadaPrefix(how) : how,
          subtitle: '${it['text'] ?? ''}', bad: st == 'blocked' || st == 'failed');
    case 'sms':
      final st = '${it['status'] ?? ''}';
      return ItemView(Icons.sms_rounded,
          st == 'sent' ? t.c100TagadaSmsSent : t.c100TagadaSmsBlocked,
          bad: st != 'sent');
    default:
      return ItemView(Icons.circle_outlined, '${it['kind'] ?? ''}');
  }
}
