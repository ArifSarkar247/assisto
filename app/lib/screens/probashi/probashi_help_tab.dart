// p3guides (owner PART 3, flag official_corners): Probashi corner "Help" tab.
//
//  * SOS abroad -> Assisto's emergency hub (family SOS), never paywalled, no ads.
//  * Official helplines (Probash-Bondhu 16135 / from abroad, 999) — one tap
//    opens the phone dialer.
//  * Real cost of one transfer: fee + exchange-rate margin against a reference
//    rate the user reads on Bangladesh Bank's site, compared with the UN SDG
//    10.c 3% target — pure arithmetic on the user's own numbers (no scraped
//    prices). World Bank Remittance Prices Worldwide linked for comparison.
//  * Wage Earners' Welfare Board support, official sites, safety tips.
// Content comes from GET /official-info/probashi (server-localised, dated,
// cached for offline). All chrome copy via AppLocalizations.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/chatnav.dart';
import '../../widgets/guide_service_card.dart' show p3gDate;
import '../../widgets/local_digits.dart';
import '../../widgets/official_info_cache.dart';
import '../../widgets/skeleton.dart';

/// Result of [p3gRemitCost] (same maths as backend official_info.remit_cost).
class RemitCost {
  final double cost; // in the sending currency
  final double costPct;
  final double homeAmount; // Tk the family receives
  final double incentive; // Tk, government incentive on top
  final bool aboveSdg;
  const RemitCost(
      this.cost, this.costPct, this.homeAmount, this.incentive, this.aboveSdg);
}

/// Fee + FX margin vs a reference rate, as % of the amount sent (World Bank
/// RPW method). Null for impossible inputs.
RemitCost? p3gRemitCost(double? amount, double? fee, double? rateGot,
    double? rateRef, {double incentivePct = 2.5, double sdgPct = 3.0}) {
  final a = amount, r = rateGot, ref = rateRef, f = fee ?? 0;
  if (a == null || r == null || ref == null) return null;
  if (a <= 0 || r <= 0 || ref <= 0 || f < 0) return null;
  final cost = f + a * (ref - r) / ref;
  final pct = cost / a * 100;
  final home = a * r;
  return RemitCost(cost, pct, home, home * incentivePct / 100, pct > sdgPct);
}

/// Parses a number typed with Bangla or ASCII digits ('৩২.৫০' or '32.50').
double? p3gParse(String s) {
  final b = StringBuffer();
  for (final c in s.trim().codeUnits) {
    b.writeCharCode(c >= 0x09E6 && c <= 0x09EF ? 0x30 + (c - 0x09E6) : c);
  }
  return double.tryParse(b.toString().replaceAll(',', ''));
}

String _fmt(double v, {int digits = 2}) => v.toStringAsFixed(digits);

class ProbashiHelpTab extends StatefulWidget {
  const ProbashiHelpTab({super.key});
  @override
  State<ProbashiHelpTab> createState() => _ProbashiHelpTabState();
}

class _ProbashiHelpTabState extends State<ProbashiHelpTab>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _d;
  bool _loading = true, _fromCache = false;
  String _lang = '';

  final _amount = TextEditingController();
  final _fee = TextEditingController();
  final _rateGot = TextEditingController();
  final _rateRef = TextEditingController();
  RemitCost? _result;
  bool _invalid = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final lang = Localizations.localeOf(context).languageCode;
    if (lang != _lang) {
      _lang = lang;
      _load();
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _fee.dispose();
    _rateGot.dispose();
    _rateRef.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await loadOfficialInfo(context.read<AppState>().api, 'probashi', _lang);
    if (!mounted) return;
    setState(() {
      _d = r.data;
      _fromCache = r.fromCache;
      _loading = false;
    });
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    final ok = await canLaunchUrl(uri) &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      final tr = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.guideCouldNotOpen)));
    }
  }

  Future<void> _call(String dial) async {
    final uri = Uri(scheme: 'tel', path: dial);
    final ok = await canLaunchUrl(uri) && await launchUrl(uri);
    if (!ok && mounted) {
      final tr = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.p3gCallFailed)));
    }
  }

  void _check() {
    final remit = (_d?['remit'] as Map?) ?? const {};
    final inc = (remit['incentive_pct'] as num?)?.toDouble() ?? 2.5;
    final sdg = (remit['sdg_target_pct'] as num?)?.toDouble() ?? 3.0;
    final r = p3gRemitCost(p3gParse(_amount.text), p3gParse(_fee.text),
        p3gParse(_rateGot.text), p3gParse(_rateRef.text),
        incentivePct: inc, sdgPct: sdg);
    FocusScope.of(context).unfocus();
    setState(() {
      _result = r;
      _invalid = r == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const SkeletonList();
    final d = _d;
    final pad = withNavBarInset(context, const EdgeInsets.all(Gap.lg));
    // SOS never depends on the network: shown even before the info loads.
    final sos = _SosCard(onOpen: () => ChatNav.push(context, 'emergency_hub'));
    if (d == null) {
      return ListView(padding: pad, children: [
        sos,
        const SizedBox(height: Gap.lg),
        StateMessage(
          icon: Icons.cloud_download_rounded,
          title: tr.loadFailed,
          message: tr.p3gNeedNetOnce,
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr.retry),
          ),
        ),
      ]);
    }
    final remit = (d['remit'] as Map?)?.cast<String, dynamic>() ?? const {};
    final muted = AType.bodySmall.copyWith(color: scheme.onSurfaceVariant);
    return ListView(
      key: const ValueKey('p3g-probashi-help'),
      padding: pad,
      children: [
        if (_fromCache)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(tr.p3gFromCache, style: muted),
          ),
        sos,
        const SizedBox(height: Gap.lg),
        // ---- helplines ----
        _Head(icon: Icons.support_agent_rounded, text: tr.p3gHelplines),
        for (final h in (d['helplines'] as List? ?? const []).whereType<Map>())
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${h['name'] ?? ''}',
                    style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
                Text('${h['display'] ?? ''}',
                    style: AType.headlineSmall.copyWith(
                        color: scheme.primary, fontWeight: FontWeight.w800)),
                if ('${h['note'] ?? ''}'.isNotEmpty) Text('${h['note']}', style: muted),
                const SizedBox(height: Gap.sm),
                FilledButton.tonalIcon(
                  key: ValueKey('p3g-call-${h['id']}'),
                  onPressed: () => _call('${h['dial'] ?? ''}'),
                  icon: const Icon(Icons.call_rounded),
                  label: Text(tr.p3gCall),
                ),
              ]),
            ),
          ),
        const SizedBox(height: Gap.lg),
        // ---- remittance real cost ----
        _Head(icon: Icons.currency_exchange_rounded, text: tr.p3gRemitTitle),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr.p3gRemitIntro, style: AType.bodyMedium),
              const SizedBox(height: Gap.sm),
              _NumField(key: const ValueKey('p3g-amount'), ctrl: _amount, label: tr.p3gRemitAmount),
              _NumField(key: const ValueKey('p3g-fee'), ctrl: _fee, label: tr.p3gRemitFee),
              _NumField(key: const ValueKey('p3g-rate-got'), ctrl: _rateGot, label: tr.p3gRemitRateGot),
              _NumField(key: const ValueKey('p3g-rate-ref'), ctrl: _rateRef, label: tr.p3gRemitRateRef),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => _open('${remit['rate_source'] ?? ''}'),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(tr.p3gRemitBbRate),
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('p3g-check'),
                onPressed: _check,
                icon: const Icon(Icons.calculate_rounded),
                label: Text(tr.p3gRemitCheck),
              ),
              if (_invalid)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text(tr.p3gRemitInvalid,
                      style: AType.bodyMedium.copyWith(color: scheme.error)),
                ),
              if (_result != null) ...[
                const SizedBox(height: Gap.md),
                Text(tr.p3gRemitResult(ld(context, _fmt(_result!.costPct))),
                    key: const ValueKey('p3g-result'),
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                Text(_result!.aboveSdg ? tr.p3gRemitAboveSdg : tr.p3gRemitBelowSdg,
                    style: AType.bodyMedium.copyWith(
                        color: _result!.aboveSdg ? scheme.error : scheme.primary)),
                const SizedBox(height: Gap.xs),
                Text(tr.p3gRemitIncentive(ld(context, _fmt(_result!.incentive, digits: 0))),
                    style: AType.bodyMedium),
              ],
              const SizedBox(height: Gap.md),
              if ('${remit['incentive_note'] ?? ''}'.isNotEmpty)
                Text('${remit['incentive_note']}', style: muted),
              if ('${remit['sdg_note'] ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text('${remit['sdg_note']}', style: muted),
                ),
              if ('${remit['rpw_note'] ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text('${remit['rpw_note']}', style: muted),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => _open('${remit['rpw_source'] ?? ''}'),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(tr.p3gRemitWorldBank),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: Gap.lg),
        // ---- welfare ----
        _Head(icon: Icons.volunteer_activism_rounded, text: tr.p3gWelfareTitle),
        for (final w in (d['welfare'] as List? ?? const []).whereType<Map>())
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${w['title'] ?? ''}',
                    style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
                Text('${w['amount'] ?? ''}',
                    style: AType.titleMedium.copyWith(
                        color: scheme.primary, fontWeight: FontWeight.w800)),
                Text('${w['note'] ?? ''}', style: AType.bodyMedium),
              ]),
            ),
          ),
        if ('${d['welfare_basis'] ?? ''}'.isNotEmpty) Text('${d['welfare_basis']}', style: muted),
        const SizedBox(height: Gap.lg),
        // ---- official sites ----
        _Head(icon: Icons.account_balance_rounded, text: tr.p3gLinksTitle),
        for (final l in officialLinks(d['links']))
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => _open(l.url),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(l.label),
            ),
          ),
        const SizedBox(height: Gap.lg),
        // ---- safety tips ----
        _Head(icon: Icons.health_and_safety_rounded, text: tr.p3gSafetyTips),
        for (final t in (d['sos_tips'] as List? ?? const []))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.check_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text('$t', style: AType.bodyMedium)),
            ]),
          ),
        if ('${d['checked'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Text(tr.p3gLastChecked(ld(context, p3gDate('${d['checked']}'))),
                key: const ValueKey('p3g-checked'), style: muted),
          ),
      ],
    );
  }
}

class _SosCard extends StatelessWidget {
  final VoidCallback onOpen;
  const _SosCard({required this.onOpen});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr.p3gSosTitle,
              style: AType.titleMedium.copyWith(
                  color: scheme.onErrorContainer, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(tr.p3gSosBody,
              style: AType.bodyMedium.copyWith(color: scheme.onErrorContainer)),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            key: const ValueKey('p3g-sos'),
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () {
              HapticFeedback.mediumImpact();
              onOpen();
            },
            icon: const Icon(Icons.sos_rounded),
            label: Text(tr.p3gSosButton),
          ),
        ]),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Head({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Icon(icon, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Flexible(
          child: Text(text,
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }
}

class _NumField extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  const _NumField({super.key, required this.ctrl, required this.label});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: TextField(
        controller: ctrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}
