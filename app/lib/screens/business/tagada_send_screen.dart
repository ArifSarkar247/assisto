import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../business_khata_api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../services/action_feedback.dart';
import '../../services/error_kind.dart';
import '../../services/error_report.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'business_common.dart';
import '../crm/crm100_api.dart'; // crm100: tagada shows on the customer history

/// ledger100 — bulk tagada, done right: ONE SEPARATE reminder per customer
/// (their own due, the shop name, the optional pay-to number), sent one by
/// one with the owner's own tap on each — WhatsApp (wa.me), the phone's own
/// SMS composer, or Assisto SMS (credits, cost shown before sending, refused
/// at 0 credits). A live "sent / skipped / failed / waiting" tally; nothing
/// ever leaves without a tap (owner rule). Offline: the messages are built
/// from the saved khata so WhatsApp / phone SMS still work.
class TagadaSendScreen extends StatefulWidget {
  final Map<String, dynamic> business;

  /// The picked customers (party rows as the list shows them: id, name,
  /// phone, balance_poisha).
  final List<Map<String, dynamic>> parties;

  /// Scheduled reminders this send answers (acked once sent).
  final Map<int, int> scheduleByParty;
  const TagadaSendScreen(
      {super.key,
      required this.business,
      required this.parties,
      this.scheduleByParty = const {}});

  @override
  State<TagadaSendScreen> createState() => _TagadaSendScreenState();
}

enum _St { waiting, sentWa, sentSms, sentAssisto, skipped, failed }

class _Row {
  final Map<String, dynamic> r;
  _St st = _St.waiting;
  String detail = '';
  bool busy = false;
  _Row(this.r);
  int get partyId => (r['party_id'] as num?)?.toInt() ?? 0;
  int get credits => (r['sms_credits'] as num?)?.toInt() ?? 1;
}

class _TagadaSendScreenState extends State<TagadaSendScreen> {
  String _preset = 'polite';
  String _payMethod = 'bKash';
  final _payNumber = TextEditingController();
  bool _loading = true;
  Object? _fail;
  bool _offlineBuilt = false;
  List<_Row> _rows = [];
  List<Map<String, dynamic>> _noDue = [];
  Map<String, dynamic> _sms = const {};
  int _balance = 0;

  int get _bizId => (widget.business['id'] as num?)?.toInt() ?? 0;
  String get _payKey => 'khata_pay_hint_v1:$_bizId';

  @override
  void initState() {
    super.initState();
    _restorePay().then((_) => _load());
  }

  @override
  void dispose() {
    _payNumber.dispose();
    super.dispose();
  }

  Future<void> _restorePay() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getStringList(_payKey);
      if (v != null && v.length == 2) {
        _payMethod = v[0];
        _payNumber.text = v[1];
      }
    } catch (_) {/* best-effort: a remembered convenience only */}
  }

  Future<void> _savePay() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_payKey, [_payMethod, _payNumber.text.trim()]);
    } catch (_) {/* best-effort: a remembered convenience only */}
  }

  Map<String, String>? get _payHint {
    final n = _payNumber.text.trim();
    return n.isEmpty ? null : {'method': _payMethod, 'number': n};
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    final ids = [
      for (final p in widget.parties) (p['id'] as num?)?.toInt() ?? 0
    ];
    try {
      final r = await context
          .read<AppState>()
          .api
          .tagadaBulk(
              businessId: _bizId,
              partyIds: ids,
              preset: _preset,
              payHint: _payHint)
          .timeout(const Duration(seconds: 15));
      final old = {for (final x in _rows) x.partyId: x};
      _rows = [
        for (final m in ((r['reminders'] ?? []) as List)
            .cast<Map<String, dynamic>>())
          _carry(old, _Row(m))
      ];
      _noDue = ((r['skipped'] ?? []) as List).cast<Map<String, dynamic>>();
      _sms = ((r['sms'] ?? const {}) as Map).cast<String, dynamic>();
      _balance = (_sms['balance'] as num?)?.toInt() ?? 0;
      _offlineBuilt = false;
    } catch (e) {
      if (failKindOf(e) == FailKind.network && mounted) {
        _buildOffline();
      } else {
        _fail = e;
        reportNonFatal('khata.tagadaBulk', e);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  _Row _carry(Map<int, _Row> old, _Row n) {
    final o = old[n.partyId];
    if (o != null && o.st != _St.waiting) {
      n.st = o.st;
      n.detail = o.detail;
    }
    return n;
  }

  /// No internet: the same one-per-customer messages from the saved khata
  /// (the parties the list handed us). Assisto SMS needs the server → off.
  void _buildOffline() {
    final t = AppLocalizations.of(context);
    final shop = '${widget.business['name'] ?? ''}';
    final hint = _payHint;
    final old = {for (final x in _rows) x.partyId: x};
    final rows = <_Row>[];
    final noDue = <Map<String, dynamic>>[];
    for (final p in widget.parties) {
      final bal = (p['balance_poisha'] as num?)?.toInt() ?? 0;
      final id = (p['id'] as num?)?.toInt() ?? 0;
      if (bal <= 0) {
        noDue.add({'party_id': id, 'name': p['name'], 'reason': 'no_due'});
        continue;
      }
      final amount = pair(context, poishaToTaka(bal));
      var text = t.ldgLocalMsg('${p['name'] ?? ''}', shop, amount);
      if (hint != null) {
        text += t.ldgLocalPay(hint['method']!, _d(hint['number']!));
      }
      final phone = '${p['phone'] ?? ''}';
      final m = _msisdn(phone);
      rows.add(_carry(
          old,
          _Row({
            'party_id': id,
            'name': p['name'],
            'phone': phone,
            'phone_ok': m.isNotEmpty,
            'balance_poisha': bal,
            'balance_display': poishaToTaka(bal),
            'message': text,
            'wa_url': m.isEmpty
                ? ''
                : 'https://wa.me/$m?text=${Uri.encodeComponent(text)}',
            'sms_uri': m.isEmpty
                ? ''
                : 'sms:+$m?body=${Uri.encodeComponent(text)}',
          })));
    }
    _rows = rows;
    _noDue = noDue;
    _sms = const {'available': false, 'ready': false};
    _offlineBuilt = true;
  }

  /// Same rule as the server's khata.bd_msisdn (wa.me needs 8801…).
  static String _msisdn(String phone) {
    var d = phone.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('880')) {
      d = d.substring(3);
    } else if (d.startsWith('88') && d.length == 13) {
      d = d.substring(2);
    }
    if (d.length == 10 && d.startsWith('1')) d = '0$d';
    if (d.length == 11 && d.startsWith('01') && '3456789'.contains(d[2])) {
      return '88$d';
    }
    return '';
  }

  String _d(Object v) =>
      localDigits('$v', Localizations.localeOf(context).languageCode);

  Future<void> _ack(_Row row) async {
    final sid = widget.scheduleByParty[row.partyId];
    if (sid == null) return;
    try {
      await context.read<AppState>().api.tagadaAckSchedule(_bizId, sid);
    } catch (e) {
      reportNonFatal('khata.tagadaAck', e); // best-effort: the banner just stays
    }
  }

  Future<void> _open(_Row row, String url, _St st) async {
    final t = AppLocalizations.of(context);
    if (url.isEmpty) return;
    setState(() => row.busy = true);
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (e) {
      reportNonFatal('khata.tagadaOpen', e);
    }
    if (!mounted) return;
    setState(() {
      row.busy = false;
      row.st = ok ? st : _St.failed;
      row.detail = ok
          ? (st == _St.sentWa ? t.ldgStatusOpenedWa : t.ldgStatusOpenedSms)
          : t.actionCantOpen;
    });
    if (ok) {
      _ack(row);
      _logOpened(row, st == _St.sentWa ? 'whatsapp_link' : 'sms_app');
    }
  }

  /// crm100: record "opened WhatsApp / SMS app with the tagada" so the one
  /// customer history page shows it (best-effort; never blocks the send).
  Future<void> _logOpened(_Row row, String channel) async {
    if (_offlineBuilt) return;
    try {
      await Crm100Api(context.read<AppState>().api).sendLog(
          CustomerTarget(party: row.partyId), channel, '${row.r['message'] ?? ''}',
          business: _bizId, purpose: 'tagada');
    } catch (e) {
      reportNonFatal('khata.tagadaLog', e);
    }
  }

  Future<void> _share(_Row row) async {
    try {
      await Share.share('${row.r['message'] ?? ''}');
      if (!mounted) return;
      setState(() {
        row.st = _St.sentWa;
        row.detail = AppLocalizations.of(context).ldgStatusShared;
      });
      _ack(row);
    } catch (e) {
      if (mounted) showActionFailed(context, 'khata.tagadaShare', e, open: true);
    }
  }

  Future<void> _assisto(_Row row) async {
    final t = AppLocalizations.of(context);
    final name = '${row.r['name'] ?? ''}';
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.ldgSmsConfirmTitle),
        content: Text(
            t.ldgSmsConfirmBody(name, _d(row.credits), _d(_balance))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.ldgSmsSendNow)),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => row.busy = true);
    try {
      final r = await context.read<AppState>().api.tagadaSendSms(
          businessId: _bizId,
          partyId: row.partyId,
          preset: _preset,
          payHint: _payHint);
      if (!mounted) return;
      final left = (r['balance'] as num?)?.toInt();
      setState(() {
        row.busy = false;
        if (left != null) _balance = left;
        if (r['ok'] == true) {
          row.st = _St.sentAssisto;
          row.detail =
              t.ldgStatusSmsSent(_d((r['credits'] as num?)?.toInt() ?? row.credits));
        } else {
          row.st = _St.failed;
          row.detail = '${r['detail'] ?? t.ldgStatusFailed}';
        }
      });
      if (r['ok'] == true) _ack(row);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        row.busy = false;
        row.st = _St.failed;
        row.detail = honestFailText(t, e, otherwise: t.ldgStatusFailed);
      });
      reportNonFatal('khata.tagadaSms', e);
    }
  }

  void _skip(_Row row) => setState(() {
        row.st = _St.skipped;
        row.detail = AppLocalizations.of(context).ldgStatusSkipped;
      });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text(t.ldgSendTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading && _rows.isEmpty) return const SkeletonList();
    if (_fail != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.ldgSendTitle,
        message: honestFailText(t, _fail, otherwise: t.businessLoadFailed),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    final sent = _rows
        .where((r) =>
            r.st == _St.sentWa || r.st == _St.sentSms || r.st == _St.sentAssisto)
        .length;
    final skipped =
        _rows.where((r) => r.st == _St.skipped).length + _noDue.length;
    final failed = _rows.where((r) => r.st == _St.failed).length;
    final waiting = _rows.where((r) => r.st == _St.waiting).length;
    return CustomScrollView(slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
        sliver: SliverList.list(children: [
          Text(t.ldgSendIntro, style: AType.bodyMedium),
          const SizedBox(height: Gap.xs),
          Text(t.ldgNeverAuto,
              style: AType.bodySmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          _tones(t),
          const SizedBox(height: Gap.md),
          _payBox(t),
          const SizedBox(height: Gap.md),
          if (_offlineBuilt) ...[
            _note(Icons.cloud_off_rounded, t.ldgOfflineBuilt),
            const SizedBox(height: Gap.md),
          ] else
            _smsLine(t),
          Semantics(
            liveRegion: true,
            child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              _tally(t.ldgCountSent(_d(sent)), AssistoTokens.of(context).success),
              _tally(t.ldgCountSkipped(_d(skipped)), null),
              _tally(t.ldgCountFailed(_d(failed)),
                  Theme.of(context).colorScheme.error),
              _tally(t.ldgCountWaiting(_d(waiting)), null),
            ]),
          ),
          const SizedBox(height: Gap.md),
          if (_rows.isEmpty)
            SizedBox(
              height: 280,
              child: StateMessage(
                  icon: Icons.check_circle_outline_rounded,
                  title: t.ldgNoDueTitle,
                  message: t.ldgNoDueBody),
            ),
          if (_rows.isNotEmpty && waiting == 0)
            _note(Icons.done_all_rounded, t.ldgAllDone),
        ]),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xxl),
        sliver: SliverList.builder(
          itemCount: _rows.length,
          itemBuilder: (_, i) => _card(t, _rows[i]),
        ),
      ),
    ]);
  }

  Widget _note(IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text)),
      ]),
    );
  }

  Widget _tally(String label, Color? c) => Chip(
        label: Text(label,
            style: TextStyle(
                fontFeatures: AFonts.tabular,
                fontWeight: FontWeight.w600,
                color: c)),
        visualDensity: VisualDensity.compact,
      );

  Widget _tones(AppLocalizations t) => Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(t.ldgTone, style: Theme.of(context).textTheme.titleSmall),
          for (final (k, label) in [
            ('polite', t.tagadaTonePolite),
            ('reminder', t.tagadaToneReminder),
            ('firm', t.tagadaToneFirm),
          ])
            ChoiceChip(
              label: Text(label),
              selected: _preset == k,
              onSelected: _loading
                  ? null
                  : (_) {
                      setState(() => _preset = k);
                      _load();
                    },
            ),
        ],
      );

  Widget _payBox(AppLocalizations t) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.ldgPayInfo, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Gap.sm),
            Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final m in const ['bKash', 'Nagad', 'Rocket'])
                    ChoiceChip(
                      label: Text(m),
                      selected: _payMethod == m,
                      onSelected: (_) => setState(() => _payMethod = m),
                    ),
                ]),
            const SizedBox(height: Gap.sm),
            TextField(
              key: const ValueKey('ldg-pay-number'),
              controller: _payNumber,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                  labelText: t.ldgPayNumber,
                  prefixIcon: const Icon(Icons.account_balance_wallet_rounded)),
            ),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.ldgPayApply),
                onPressed: _loading
                    ? null
                    : () {
                        _savePay();
                        _load();
                      },
              ),
            ),
          ]),
        ),
      );

  Widget _smsLine(AppLocalizations t) {
    final String line;
    if (_sms['owner_only'] == true) {
      line = t.ldgSmsOwnerOnly;
    } else if (_sms['ready'] != true) {
      line = t.ldgSmsNotReady;
    } else {
      line = t.ldgSmsBalance(_d(_balance));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: _note(Icons.sms_outlined, line),
    );
  }

  Widget _card(AppLocalizations t, _Row row) {
    final scheme = Theme.of(context).colorScheme;
    final name = '${row.r['name'] ?? ''}';
    final amount = pair(context, row.r['balance_display']);
    final msg = '${row.r['message'] ?? ''}';
    final wa = '${row.r['wa_url'] ?? ''}';
    final sms = '${row.r['sms_uri'] ?? ''}';
    final done = row.st != _St.waiting;
    final smsOn = _sms['available'] == true;
    final enough = _balance >= row.credits;
    final statusColor = switch (row.st) {
      _St.failed => scheme.error,
      _St.skipped => scheme.onSurfaceVariant,
      _St.waiting => scheme.onSurfaceVariant,
      _ => AssistoTokens.of(context).success,
    };
    return Card(
      key: ValueKey('ldg-row-${row.partyId}'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(name,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis)),
            const SizedBox(width: Gap.sm),
            Text(amount,
                style: TextStyle(
                    fontFeatures: AFonts.tabular,
                    fontWeight: FontWeight.w700,
                    color: AssistoTokens.of(context).success)),
          ]),
          const SizedBox(height: Gap.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm)),
            child: Text(msg, style: AType.bodySmall),
          ),
          if (done) ...[
            const SizedBox(height: Gap.sm),
            Semantics(
              liveRegion: true,
              child: Row(children: [
                Icon(
                    row.st == _St.failed
                        ? Icons.error_outline_rounded
                        : (row.st == _St.skipped
                            ? Icons.remove_circle_outline_rounded
                            : Icons.check_circle_rounded),
                    size: 18,
                    color: statusColor),
                const SizedBox(width: Gap.xs),
                Expanded(
                    child: Text(row.detail,
                        style: TextStyle(color: statusColor))),
              ]),
            ),
          ],
          const SizedBox(height: Gap.sm),
          if (row.busy)
            const LinearProgressIndicator()
          else
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              if (wa.isNotEmpty)
                FilledButton.icon(
                  icon: const Icon(Icons.chat_rounded),
                  label: Text(t.ldgBtnWhatsApp),
                  onPressed: () => _open(row, wa, _St.sentWa),
                )
              else
                FilledButton.icon(
                  icon: const Icon(Icons.ios_share_rounded),
                  label: Text(t.ldgBtnShare),
                  onPressed: () => _share(row),
                ),
              if (sms.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.sms_rounded),
                  label: Text(t.ldgBtnPhoneSms),
                  onPressed: () => _open(row, sms, _St.sentSms),
                ),
              if (smsOn && row.r['phone_ok'] == true)
                OutlinedButton.icon(
                  key: ValueKey('ldg-assisto-${row.partyId}'),
                  icon: const Icon(Icons.outbox_rounded),
                  label: Text(enough
                      ? t.ldgBtnAssistoSms(_d(row.credits))
                      : t.ldgSmsNoCredits),
                  onPressed: enough && row.st != _St.sentAssisto
                      ? () => _assisto(row)
                      : null,
                ),
              if (!done)
                TextButton(
                    onPressed: () => _skip(row), child: Text(t.ldgBtnSkip)),
            ]),
          if (wa.isEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.ldgNoPhone,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }
}
