import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../payments/play_restore.dart' show playManageUri;
import '../screens/support_center_screen.dart';
import '../screens/watchman/watchman_source.dart' show wmDigits, wmError, wmList, wmMap, wmStatus;
import '../state.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/ladder_common.dart' show fmtInt;
import 'cctv_plan_source.dart';

/// cctvprice — the CCTV plan screen (owner's CCTV order 3 Nov, section H):
/// tier picker 1..10 cameras with the exact price, yearly toggle (exactly
/// 12x, no free months), the 7-day free-trial badge (only when Google says
/// this account is eligible AND the server has no earlier CCTV purchase),
/// the video add-on per camera, and one clear "what happens if unpaid" line.
/// Every number comes from the server; the Play build buys through Google
/// Play; the website APK and "not on sale yet" say so honestly (no dead
/// buttons).
class CctvPlanScreen extends StatefulWidget {
  final CctvPlanApi? api;
  final CctvPlanBuyer? buyer;

  /// Tests / gallery: show this payload without the network.
  final Map<String, dynamic>? preview;

  /// Tests / gallery: Play's offers (null = ask the buyer).
  final Map<String, String>? previewOffers;
  const CctvPlanScreen({super.key, this.api, this.buyer, this.preview, this.previewOffers});

  /// Opens Google Play's subscription page. Tests replace it.
  static Future<bool> Function(Uri) launcher =
      (u) => launchUrl(u, mode: LaunchMode.externalApplication);

  @override
  State<CctvPlanScreen> createState() => _CctvPlanScreenState();
}

class _CctvPlanScreenState extends State<CctvPlanScreen> {
  late final CctvPlanApi _api = widget.api ?? ApiCctvPlanApi(context.read<AppState>().api);
  late final CctvPlanBuyer _buyer = widget.buyer ?? CctvPlanBuyer(_api);

  Map<String, dynamic>? _d;
  String? _error;
  bool _featureOff = false;
  bool _busy = false;
  bool _store = false;
  Map<String, String> _offers = const {};
  Map<String, String> _addonOffers = const {};

  int _cams = 2; // 11 = "more than 10"
  bool _yearly = false;
  int _addonDays = 7;
  int _addonCams = 1;
  bool _picked = false;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _apply(widget.preview!);
      _offers = widget.previewOffers ?? const {};
      _store = widget.previewOffers != null;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  void _apply(Map<String, dynamic> d) {
    _d = d;
    final st = wmMap(d['status']);
    if (!_picked) {
      final n = (st['cameras'] as num?)?.toInt() ?? 0;
      final used = (d['cameras_used'] as num?)?.toInt() ?? 0;
      _cams = n >= 2 ? n : (used >= 1 ? used.clamp(1, 10).toInt() : 2);
      _yearly = st['period'] == 'yearly';
      _addonCams = (n >= 1 ? n : 1).clamp(1, 10).toInt();
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _featureOff = false;
    });
    try {
      final d = await _api.load();
      final store = await _buyer.available();
      Map<String, String> offers = const {}, addon = const {};
      if (store && d['on_sale'] == true) {
        offers = await _buyer.offers('${d['product_id'] ?? ''}');
        addon = await _buyer.offers('${d['addon_product_id'] ?? ''}');
      }
      if (!mounted) return;
      setState(() {
        _apply(d);
        _store = store;
        _offers = offers;
        _addonOffers = addon;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (wmStatus(e) == 403) {
          _featureOff = true;
        } else {
          _error = wmError(e) ?? '';
        }
      });
    }
  }

  String _lang() => Localizations.localeOf(context).languageCode;
  String _n(int v) => fmtInt(context, v);
  String _date(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    return wmDigits(_lang(), MaterialLocalizations.of(context).formatMediumDate(d));
  }

  List<CctvTier> get _tiers => CctvTier.list(_d?['tiers']);
  CctvTier? _tier(int n) {
    for (final t in _tiers) {
      if (t.cameras == n) return t;
    }
    return null;
  }

  Map<String, dynamic> get _status => wmMap(_d?['status']);
  bool get _active => _status['status'] == 'active';
  String get _selectedPlan => cctvBasePlan(_cams, _yearly);
  bool get _trialEligible {
    final d = _d ?? const {};
    if (d['trial_available'] != true || _active) return false;
    if (!_store) return true; // shown as information only
    return _offers.containsKey('${d['trial_base_plan']}#${d['trial_offer_id']}');
  }

  Future<void> _buy(String productId, String basePlan, {String offerId = ''}) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final r = await _buyer.buy(
        productId: productId,
        basePlanId: basePlan,
        offerId: offerId,
        accountId: '${_d?['play_account_id'] ?? ''}');
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = switch (r) {
      CctvBuyStatus.done => t.cplDone,
      CctvBuyStatus.pending => t.cplPending,
      CctvBuyStatus.cancelled => t.cplCancelled,
      CctvBuyStatus.unavailable => t.cplUnavailable,
      CctvBuyStatus.failed => t.cplFailed,
    };
    messenger.showSnackBar(SnackBar(content: Text(msg)));
    if (r == CctvBuyStatus.done || r == CctvBuyStatus.pending) await _load();
  }

  Future<void> _restore() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final d = _d ?? const {};
    setState(() => _busy = true);
    final n = await _buyer.restore({'${d['product_id']}', '${d['addon_product_id']}'});
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
        content: Text(n > 0 ? t.cplRestored(wmDigits(_lang(), n)) : t.cplNothingToRestore)));
    if (n > 0) await _load();
  }

  Future<void> _manage() async {
    final d = _d ?? const {};
    final pkg = '${wmMap(d['status'])['package'] ?? 'com.assisto.assisto'}';
    await CctvPlanScreen.launcher(playManageUri('${d['product_id'] ?? ''}', pkg));
  }

  Future<void> _setAddonCamera(int id, bool on) async {
    final cur = [for (final i in (_d?['addon_cameras'] as List? ?? const [])) (i as num).toInt()];
    final next = on ? [id, ...cur.where((x) => x != id)] : cur.where((x) => x != id).toList();
    try {
      final saved = await _api.setAddonCameras(next);
      if (!mounted) return;
      setState(() => _d = {...?_d, 'addon_cameras': saved});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(wmError(e) ?? AppLocalizations.of(context).cplFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.cplTitle)),
      body: _body(t),
    );
  }

  Widget _message(IconData icon, String title, String body, Widget? action) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action],
          ]),
        ),
      );

  Widget _body(AppLocalizations t) {
    if (_featureOff) {
      return _message(Icons.lock_clock_outlined, t.wmFeatureOffTitle, t.wmFeatureOffBody,
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(t.cvvGoBack)));
    }
    if (_error != null) {
      return _message(Icons.cloud_off_rounded, t.cplTitle,
          _error!.isNotEmpty ? _error! : t.cplLoadError,
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
              onPressed: _load,
              child: Text(t.cplRetry)));
    }
    final d = _d;
    if (d == null) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    final notice = wmMap(d['notice']);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
        children: [
          if (notice.isNotEmpty) _noticeCard(t, notice, scheme),
          _statusCard(t, scheme),
          const SizedBox(height: 16),
          _pickerCard(t, scheme),
          const SizedBox(height: 16),
          _addonCard(t, scheme),
          const SizedBox(height: 16),
          _unpaidCard(t, scheme),
          if (_limitsLine(t) != null) ...[
            const SizedBox(height: 8),
            Text(_limitsLine(t)!, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (_store) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.restore_rounded),
                label: Text(t.cplRestore),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _noticeCard(AppLocalizations t, Map<String, dynamic> n, ColorScheme scheme) {
    final bn = _lang() != 'en';
    final hold = _status['status'] == 'hold';
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${bn ? n['title_bn'] : n['title_en']}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: scheme.onErrorContainer)),
          const SizedBox(height: 6),
          Text('${bn ? n['bn'] : n['en']}', style: TextStyle(color: scheme.onErrorContainer)),
          if (hold && _store) ...[
            const SizedBox(height: 10),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _manage,
              child: Text(t.cplFixPayment),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _statusCard(AppLocalizations t, ColorScheme scheme) {
    final st = _status;
    final tt = Theme.of(context).textTheme;
    if (!_active) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.videocam_outlined, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(t.cplNoPlan, style: tt.titleMedium)),
            ]),
            const SizedBox(height: 6),
            Text(t.cplNoPlanBody),
          ]),
        ),
      );
    }
    final n = (st['cameras'] as num?)?.toInt() ?? 0;
    final used = (_d?['cameras_used'] as num?)?.toInt() ?? 0;
    final over = (_d?['over_by'] as num?)?.toInt() ?? 0;
    final period = st['period'] == 'yearly' ? t.cplYearlyWord : t.cplMonthly;
    final date = _date('${st['expires_at'] ?? ''}');
    final when = st['in_trial'] == true
        ? t.cplInTrial(date)
        : (st['auto_renew'] == true ? t.cplRenews(date) : t.cplEnds(date));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cplCurrent, style: tt.labelLarge),
          const SizedBox(height: 4),
          Text(t.cplCurrentLine(wmDigits(_lang(), n), period), style: tt.titleLarge),
          if (date.isNotEmpty) Text(when),
          const SizedBox(height: 4),
          Text(t.cplUsed(wmDigits(_lang(), used), wmDigits(_lang(), n))),
          if (over > 0) ...[
            const SizedBox(height: 6),
            Text(t.cplOverBy(wmDigits(_lang(), over)), style: TextStyle(color: scheme.error)),
          ],
          if (_store)
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _manage,
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(t.cplManage),
            ),
        ]),
      ),
    );
  }

  Widget _pickerCard(AppLocalizations t, ColorScheme scheme) {
    final d = _d!;
    final tt = Theme.of(context).textTheme;
    final more = _cams > 10;
    final tier = more ? null : _tier(_cams);
    final current = _active && _status['base_plan'] == _selectedPlan;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cplHowManyCameras, style: tt.titleMedium),
          const SizedBox(height: 4),
          Text(t.cplHowPriced(_n((d['base_price'] as num?)?.toInt() ?? 0),
              _n((d['extra_camera_price'] as num?)?.toInt() ?? 0))),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 1; i <= 10; i++)
              ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 24),
                    child: Text(wmDigits(_lang(), i),
                        textAlign: TextAlign.center,
                        semanticsLabel: t.cplCamerasA11y(wmDigits(_lang(), i)))),
                selected: _cams == i,
                onSelected: (_) => setState(() {
                  _cams = i;
                  _picked = true;
                }),
              ),
            ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text(t.cplMoreThan10),
              selected: more,
              onSelected: (_) => setState(() {
                _cams = 11;
                _picked = true;
              }),
            ),
          ]),
          const SizedBox(height: 12),
          if (more) ...[
            Text(t.cplContactBody),
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.support_agent_rounded),
              label: Text(t.cplContactButton),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const SupportCenterScreen())),
            ),
          ] else if (tier != null) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _yearly,
              onChanged: (v) => setState(() {
                _yearly = v;
                _picked = true;
              }),
              title: Text(t.cplYearly),
              subtitle: Text(t.cplYearlySub),
            ),
            Text(_yearly ? t.cplPerYear(_n(tier.yearly)) : t.cplPerMonth(_n(tier.monthly)),
                style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            if (_yearly) Text(t.cplYearlyMath(_n(tier.monthly))),
            if (_cams == 1) ...[const SizedBox(height: 4), Text(t.cplOneCameraNote)],
            if (_trialEligible) ...[
              const SizedBox(height: 10),
              _trialBadge(t, scheme),
              if (_selectedPlan != '${d['trial_base_plan']}') ...[
                const SizedBox(height: 4),
                Text(t.cplTrialOnlyBase),
              ],
            ],
            const SizedBox(height: 12),
            _buyArea(t, tier, current),
          ],
        ]),
      ),
    );
  }

  Widget _trialBadge(AppLocalizations t, ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.card_giftcard_rounded, size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 6),
          Flexible(
              child: Text(t.cplTrialBadge,
                  style: TextStyle(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w600))),
        ]),
      );

  Widget _buyArea(AppLocalizations t, CctvTier tier, bool current) {
    final d = _d!;
    final price = _yearly ? t.cplPerYear(_n(tier.yearly)) : t.cplPerMonth(_n(tier.monthly));
    if (d['on_sale'] != true) return _info(t.cplSaleSoon);
    if (!_store) return _info(t.cplPlayOnly);
    if (current) {
      return Chip(
          avatar: const Icon(Icons.check_circle_rounded, size: 18),
          label: Text(t.cplCurrentBadge));
    }
    final product = '${d['product_id']}';
    final playPrice = _offers[_selectedPlan];
    final trial = _trialEligible && _selectedPlan == '${d['trial_base_plan']}';
    final label = _active
        ? t.cplChange(wmDigits(_lang(), _cams < 2 ? 2 : _cams), price)
        : (trial ? t.cplStartTrial : t.cplBuy(price));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        onPressed: _busy
            ? null
            : () => _buy(product, _selectedPlan,
                offerId: trial ? '${d['trial_offer_id']}' : ''),
        child: _busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(label, textAlign: TextAlign.center),
      ),
      const SizedBox(height: 6),
      if (trial) Text(t.cplTrialThen(price)),
      if (_active) Text(t.cplChangeNote),
      if (playPrice != null && playPrice.isNotEmpty)
        Text(t.cplPlayPrice(playPrice), style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  Widget _info(String s) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline_rounded),
          const SizedBox(width: 8),
          Expanded(child: Text(s)),
        ]),
      );

  Widget _addonCard(AppLocalizations t, ColorScheme scheme) {
    final d = _d!;
    final tt = Theme.of(context).textTheme;
    final ad = wmMap(d['addon']);
    final per = wmMap(ad['price_per_camera']);
    final p7 = (per['7'] as num?)?.toInt() ?? 0;
    final p30 = (per['30'] as num?)?.toInt() ?? 0;
    final planCams = (_status['cameras'] as num?)?.toInt() ?? 0;
    final a = wmMap(_status['addon']);
    final addonOn = a['status'] == 'active';
    final maxCams = planCams >= 1 ? planCams : 10;
    final n = _addonCams.clamp(1, maxCams).toInt();
    final total = (_addonDays == 30 ? p30 : p7) * n;
    final plan = cctvAddonPlan(_addonDays, n);
    final current = addonOn && a['base_plan'] == plan;
    final cams = wmList(d['cameras']);
    final chosen = {for (final i in (d['addon_cameras'] as List? ?? const [])) (i as num).toInt()};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.video_library_outlined, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(t.cplAddonTitle, style: tt.titleMedium)),
          ]),
          const SizedBox(height: 6),
          Text(t.cplAddonBody),
          if (addonOn) ...[
            const SizedBox(height: 8),
            Text(t.cplAddonActive(wmDigits(_lang(), (a['days'] as num?)?.toInt() ?? 0),
                wmDigits(_lang(), (a['cameras'] as num?)?.toInt() ?? 0)),
                style: tt.titleSmall),
            if (cams.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(t.cplAddonPick, style: tt.labelLarge),
              for (final c in cams)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: chosen.contains((c['id'] as num).toInt()),
                  onChanged: (v) => _setAddonCamera((c['id'] as num).toInt(), v == true),
                  title: Text('${c['name'] ?? ''}'.isEmpty
                      ? t.cplCameraN(wmDigits(_lang(), (c['id'] as num).toInt()))
                      : '${c['name']}'),
                ),
            ],
          ],
          const SizedBox(height: 8),
          RadioGroup<int>(
            groupValue: _addonDays,
            onChanged: (v) => setState(() => _addonDays = v ?? 7),
            child: Column(children: [
              RadioListTile<int>(
                contentPadding: EdgeInsets.zero,
                value: 7,
                title: Text(t.cplAddon7(_n(p7))),
              ),
              RadioListTile<int>(
                contentPadding: EdgeInsets.zero,
                value: 30,
                title: Text(t.cplAddon30(_n(p30))),
              ),
            ]),
          ),
          Row(children: [
            Expanded(child: Text(t.cplAddonCameras)),
            IconButton(
              tooltip: t.cplLess,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: n > 1 ? () => setState(() => _addonCams = n - 1) : null,
              icon: const Icon(Icons.remove_circle_outline_rounded),
            ),
            Text(wmDigits(_lang(), n), style: tt.titleMedium),
            IconButton(
              tooltip: t.cplMore,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: n < maxCams ? () => setState(() => _addonCams = n + 1) : null,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ]),
          Text(t.cplAddonTotal(_n(total)), style: tt.titleMedium),
          const SizedBox(height: 10),
          if (!_active)
            _info(t.cplAddonNeedsPlan)
          else if (d['on_sale'] != true)
            _info(t.cplSaleSoon)
          else if (!_store)
            _info(t.cplPlayOnly)
          else if (current)
            Chip(
                avatar: const Icon(Icons.check_circle_rounded, size: 18),
                label: Text(t.cplCurrentBadge))
          else
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _busy ? null : () => _buy('${d['addon_product_id']}', plan),
              child: Text(t.cplAddonBuy(t.cplPerMonth(_n(total))), textAlign: TextAlign.center),
            ),
          if (_addonOffers[plan] != null && _active && d['on_sale'] == true)
            Text(t.cplPlayPrice(_addonOffers[plan]!), style: tt.bodySmall),
        ]),
      ),
    );
  }

  Widget _unpaidCard(AppLocalizations t, ColorScheme scheme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.cplUnpaidTitle, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text('${_d?['unpaid_line'] ?? ''}'),
              ]),
            ),
          ]),
        ),
      );

  String? _limitsLine(AppLocalizations t) {
    final l = wmMap(_d?['limits']);
    if (l['owner_confirmed'] != true) return null; // a promise only once confirmed
    final mb = (l['relay_mb_per_camera'] as num?)?.toInt() ?? 0;
    final gb = (mb / 1000).toStringAsFixed(1);
    return t.cplLimitsLine(wmDigits(_lang(), gb),
        wmDigits(_lang(), (l['ai_checks_per_camera'] as num?)?.toInt() ?? 0));
  }
}
