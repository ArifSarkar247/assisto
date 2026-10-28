import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../dues_api.dart';
import '../l10n/app_localizations.dart';
import '../meter/meter_logic.dart'
    show kBkashPackage, kBkashUssd, kNagadPackage, kNagadUssd;
import '../messaging/date_separators.dart' show fmtDate, localDigits;
import '../services/error_kind.dart' show honestFailText;
import '../services/error_report.dart';
import '../state.dart';
import '../theme.dart';
import '../voice/va_native.dart' show VaNative;
import '../widgets/skeleton.dart';
import 'business/business_common.dart' show pair;
import 'business/khata_chat_screen.dart';

/// Rocket (DBBL) — same "open the app, else its Play page" path as bKash /
/// Nagad on the prepaid-meter pay sheet.
const String kRocketPackage = 'com.dbbl.mbs.apps.main';
const String kRocketUssd = '*322#';

/// tagada2 — one shop in "My Dues": what I owe there, the shop's recent
/// entries for me, how to pay (bKash / Nagad / Rocket steps — Assisto never
/// takes or moves money), chat with the shop, mute / block. No ads.
class MyDuesShopScreen extends StatefulWidget {
  final int businessId;
  final String shopName;
  const MyDuesShopScreen(
      {super.key, required this.businessId, required this.shopName});

  @override
  State<MyDuesShopScreen> createState() => _MyDuesShopScreenState();
}

class _MyDuesShopScreenState extends State<MyDuesShopScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  Object? _fail;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _d == null;
      _fail = null;
    });
    try {
      _d = await context.read<AppState>().api.myDuesShop(widget.businessId);
    } catch (e) {
      _fail = e;
      reportNonFatal('dues.shop', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  String get _name {
    final s = _d?['shop'];
    final n = s is Map ? '${s['name'] ?? ''}' : '';
    return n.isNotEmpty ? n : widget.shopName;
  }

  String _dg(Object v) =>
      localDigits('$v', Localizations.localeOf(context).languageCode);

  Future<void> _setPref({bool? muted, bool? blocked}) async {
    final t = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final r = await context
          .read<AppState>()
          .api
          .myDuesPrefs(widget.businessId, muted: muted, blocked: blocked);
      if (!mounted) return;
      setState(() {
        _d = {...?_d, 'muted': r['muted'] == true, 'blocked': r['blocked'] == true};
      });
    } catch (e) {
      reportNonFatal('dues.prefs', e);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(honestFailText(t, e, otherwise: t.tg2SaveFailed))));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _toggleBlock(bool block) async {
    final t = AppLocalizations.of(context);
    if (block) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true, // insets: 200% text / keyboard
          title: Text(t.tg2BlockConfirmTitle(_name)),
          content: Text(t.tg2BlockConfirmBody(_name)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.cancel)),
            FilledButton(
                key: const ValueKey('tg2-block-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.tg2BlockAction)),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    await _setPref(blocked: block);
  }

  Future<void> _chat() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => KhataChatScreen(
            side: ChatSide.customer,
            businessId: widget.businessId,
            title: _name)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_fail != null || _d == null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: _name,
        message: honestFailText(t, _fail),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    final d = _d!;
    final scheme = Theme.of(context).colorScheme;
    final blocked = d['blocked'] == true;
    final muted = d['muted'] == true;
    final owes = ((d['balance_poisha'] as num?)?.toInt() ?? 0) > 0;
    final entries = ((d['entries'] ?? const []) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final methods = (((d['pay'] is Map) ? (d['pay'] as Map)['methods'] : null) ??
            const [])
        as List;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pair(context, d['status']), style: AType.bodyMedium),
                    const SizedBox(height: Gap.xs),
                    Text(pair(context, d['balance_display']),
                        key: const ValueKey('tg2-shop-balance'),
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                                fontFeatures: AFonts.tabular,
                                fontWeight: FontWeight.w700,
                                color: owes
                                    ? scheme.error
                                    : AssistoTokens.of(context).success)),
                    const SizedBox(height: Gap.md),
                    Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                      FilledButton.tonalIcon(
                        key: const ValueKey('tg2-shop-chat'),
                        style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48)),
                        icon: const Icon(Icons.forum_rounded),
                        label: Text(t.tg2ChatWithShop),
                        onPressed: blocked ? null : _chat,
                      ),
                    ]),
                    if (blocked) ...[
                      const SizedBox(height: Gap.sm),
                      Text(t.tg2BlockedNote,
                          style: AType.bodySmall
                              .copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ]),
            ),
          ),
          if (owes) ...[
            const SizedBox(height: Gap.lg),
            Semantics(
              header: true,
              child: Text(t.tg2PayTitle,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: Gap.xs),
            Text(t.tg2PayNever,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            if (methods.isEmpty)
              Text(t.tg2PayNoNumber,
                  key: const ValueKey('tg2-pay-none'), style: AType.bodyMedium)
            else
              for (final m in methods.whereType<Map>())
                _PayCard(
                    method: m.cast<String, dynamic>(),
                    amount: pair(context, d['balance_display'])),
          ],
          const SizedBox(height: Gap.lg),
          Semantics(
            header: true,
            child: Text(t.tg2ShopEntries,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: Gap.sm),
          if (entries.isEmpty)
            Text(t.tg2ShopNoEntries, style: AType.bodyMedium)
          else
            for (final e in entries) _entry(t, e),
          const SizedBox(height: Gap.lg),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              SwitchListTile(
                key: const ValueKey('tg2-mute'),
                value: muted,
                onChanged: _saving || blocked
                    ? null
                    : (v) => _setPref(muted: v),
                title: Text(t.tg2Mute),
                subtitle: Text(t.tg2MuteSub),
              ),
              const Divider(height: 1),
              SwitchListTile(
                key: const ValueKey('tg2-block'),
                value: blocked,
                onChanged: _saving ? null : _toggleBlock,
                title: Text(t.tg2Block),
                subtitle: Text(t.tg2BlockSub),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _entry(AppLocalizations t, Map<String, dynamic> e) {
    final scheme = Theme.of(context).colorScheme;
    final due = e['kind'] == 'due';
    final lang = Localizations.localeOf(context).languageCode;
    final at = DateTime.tryParse('${e['at'] ?? ''}')?.toLocal();
    final note = '${e['note'] ?? ''}'.trim();
    final sub = [
      if (at != null) fmtDate('d MMM yyyy', at, lang),
      if (note.isNotEmpty) note,
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(due ? Icons.add_circle_outline_rounded : Icons.payments_rounded,
          color: due ? scheme.error : AssistoTokens.of(context).success),
      title: Text(due ? t.tg2EntryDue : t.tg2EntryPaid),
      subtitle: sub.isEmpty ? null : Text(_dg(sub)),
      trailing: Text(pair(context, e['amount_display']),
          style: const TextStyle(
              fontFeatures: AFonts.tabular, fontWeight: FontWeight.w600)),
    );
  }
}

/// One wallet's pay steps. Only well-known menu paths (Send Money /
/// Payment / Merchant Pay) — the number copied first, the wallet app opened
/// (no undocumented deep link), the USSD code as the no-internet path.
class _PayCard extends StatelessWidget {
  final Map<String, dynamic> method;
  final String amount;
  const _PayCard({required this.method, required this.amount});

  Future<void> _copy(String n) async {
    try {
      await Clipboard.setData(ClipboardData(text: n));
    } catch (_) {} // best-effort: the steps still say to type the number
  }

  Future<void> _openApp(BuildContext context, String pkg, String number) async {
    final t = AppLocalizations.of(context);
    await _copy(number);
    var ok = false;
    try {
      ok = await VaNative.launchApp(pkg);
    } catch (_) {} // best-effort: falls through to the Play page
    if (!ok) {
      try {
        ok = await launchUrl(
            Uri.parse('https://play.google.com/store/apps/details?id=$pkg'),
            mode: LaunchMode.externalApplication);
      } catch (_) {} // best-effort: ok stays false -> honest snackbar
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(
            content: Text(ok ? t.tg2PayCopied : t.tg2PayOpenFailed)));
    }
  }

  Future<void> _dial(String code) async {
    try {
      await launchUrl(Uri(scheme: 'tel', path: code));
    } catch (_) {} // best-effort: the code is printed on the button to dial by hand
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final provider = '${method['provider'] ?? ''}';
    final number = '${method['number'] ?? ''}';
    final merchant = method['kind'] == 'merchant';
    final lang = Localizations.localeOf(context).languageCode;
    final (String name, String pkg, String ussd) = switch (provider) {
      'nagad' => (t.mtrNagad, kNagadPackage, kNagadUssd),
      'rocket' => (t.tg2Rocket, kRocketPackage, kRocketUssd),
      _ => (t.mtrBkash, kBkashPackage, kBkashUssd),
    };
    final menuStep = !merchant
        ? t.tg2PayStepSendMoney
        : (provider == 'nagad' ? t.tg2PayStepMerchantPay : t.tg2PayStepPayment);
    final shownNumber = localDigits(number, lang);
    final steps = [
      t.tg2PayStepOpen(name),
      menuStep,
      t.tg2PayStepNumber(shownNumber),
      t.tg2PayStepAmount(amount),
      t.tg2PayStepPin,
      t.tg2PayStepTell,
    ];
    return Card(
      key: ValueKey('tg2-pay-$provider'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(
            header: true,
            child: Text('$name · ${merchant ? t.tg2PayMerchant : t.tg2PayPersonal}',
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: Gap.xs),
          SelectableText(shownNumber,
              style: AType.titleMedium.copyWith(fontFeatures: AFonts.tabular)),
          const SizedBox(height: Gap.sm),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ExcludeSemantics(
                  child: CircleAvatar(
                    radius: 11,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(localDigits('${i + 1}', lang),
                        style: AType.bodySmall
                            .copyWith(color: scheme.onPrimaryContainer)),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(steps[i], style: AType.bodyMedium)),
              ]),
            ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            FilledButton.tonalIcon(
              key: ValueKey('tg2-pay-open-$provider'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _openApp(context, pkg, number),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(t.tg2PayCopyOpen(name)),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _dial(ussd),
              icon: const Icon(Icons.dialpad_rounded, size: 18),
              label: Text(t.tg2PayDial(ussd)),
            ),
          ]),
        ]),
      ),
    );
  }
}
