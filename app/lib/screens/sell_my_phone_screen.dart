import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../services/security_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show taka, takaToPoisha, fmtInt;
import 'registry_imei.dart';
import 'report_stolen_screen.dart';
import 'used_phone_check_screen.dart' show copyToClipboard;
import 'package:assisto/widgets/app_sheet.dart';
import '../services/action_feedback.dart'; // db1

/// Sell-my-phone safely (Family & Safety). Two parts:
///   (a) a persisted guided checklist so a factory reset doesn't leave the
///       phone FRP-locked for the buyer (backup → remove Google + brand
///       account → disarm Assisto protection → remove device admin → remove
///       SIM/SD → factory reset LAST);
///   (b) a digital sale receipt: record the sale (saleCreate), show the
///       transfer token as a DISPLAY-ONLY QR + copyable text, then authorize
///       the transfer — gated THROUGH SecurityGuard.run('sell_transfer') BEFORE
///       any saleAuthorize call. A buyer-accept (paste token → saleAccept) and
///       a "My receipts" list (saleMine) round it out.
///
/// HONESTY: Assisto never blocks a phone at the network level. The disarm step
/// and the authorize gate are the server-side ownership/deterrent layer — see
/// the honest footer. No fake prices; the receipt moves no money.
class SellMyPhoneScreen extends StatefulWidget {
  const SellMyPhoneScreen({super.key});

  @override
  State<SellMyPhoneScreen> createState() => _SellMyPhoneScreenState();
}

class _SellMyPhoneScreenState extends State<SellMyPhoneScreen> {
  // Checklist steps — order matters (reset is LAST). Persisted per-step with
  // Settings.setBool, exactly like the phone-safety wizard.
  static const _steps = <_SellStep>[
    _SellStep('backup', Icons.cloud_upload_rounded),
    _SellStep('google', Icons.account_circle_rounded,
        link: 'https://myaccount.google.com/'),
    _SellStep('brand', Icons.badge_rounded),
    _SellStep('disarm', Icons.lock_open_rounded, disarm: true),
    _SellStep('admin', Icons.admin_panel_settings_rounded),
    _SellStep('sim', Icons.sim_card_rounded),
    _SellStep('reset', Icons.restart_alt_rounded),
  ];

  final Map<String, bool> _done = {};
  bool _loading = true;

  // Receipt form.
  final _imei = TextEditingController();
  final _model = TextEditingController();
  final _price = TextEditingController();
  final _buyerName = TextEditingController();
  final _buyerNid = TextEditingController();
  bool _hasVaultImei = false;

  // Created receipt state.
  int? _saleId;
  String? _token;
  String? _saleState;
  bool _creating = false;
  bool _authorizing = false;

  // Buyer-accept.
  final _acceptToken = TextEditingController();
  bool _accepting = false;

  // My receipts.
  List<Map<String, dynamic>> _asSeller = const [];
  List<Map<String, dynamic>> _asBuyer = const [];
  bool _loadingReceipts = false;

  @override
  void initState() {
    super.initState();
    _load();
    _probeVault();
    _loadReceipts();
  }

  @override
  void dispose() {
    _imei.dispose();
    _model.dispose();
    _price.dispose();
    _buyerName.dispose();
    _buyerNid.dispose();
    _acceptToken.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    for (final s in _steps) {
      _done[s.id] = await Settings.getBool(_key(s.id), false);
    }
    if (mounted) setState(() => _loading = false);
  }

  String _key(String id) => 'sellphone_$id';

  Future<void> _toggle(String id, bool v) async {
    setState(() => _done[id] = v);
    await Settings.setBool(_key(id), v);
  }

  int get _doneCount => _steps.where((s) => _done[s.id] == true).length;

  Future<void> _probeVault() async {
    final imei = await RegistryImei.fromVault(context);
    if (mounted && imei != null && imei.isNotEmpty) {
      setState(() {
        _hasVaultImei = true;
        if (_imei.text.trim().isEmpty) _imei.text = imei;
      });
    }
  }

  Future<void> _prefill() async {
    final imei = await RegistryImei.fromVault(context);
    if (imei != null && imei.isNotEmpty) setState(() => _imei.text = imei);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ---- checklist: the disarm step runs the Section-8 guard --------------

  Future<void> _runDisarm(String stepId) async {
    // Disarming Assisto protection is sensitive → SecurityGuard.run('disarm').
    // We only tick the step when the server returns APPLIED (immediate). For
    // pending/awaiting/blocked the guard already showed the message.
    try {
      final res = await const SecurityGuard().run(context, 'disarm');
      if (!mounted) return;
      if (res.state == SecActionState.applied) await _toggle(stepId, true);
    } catch (e) {
      showActionFailed(context, 'sellPhone.disarm', e); // db1
    }
  }

  // ---- receipt: create → QR token → authorize (guarded) -----------------

  Future<void> _createReceipt() async {
    final t = AppLocalizations.of(context);
    final imei = _imei.text.trim();
    final priceRaw = _price.text.trim();
    final buyer = _buyerName.text.trim();
    if (imei.isEmpty || priceRaw.isEmpty || buyer.isEmpty) {
      _snack(t.upReceiptNeedFields);
      return;
    }
    setState(() => _creating = true);
    final api = context.read<AppState>().api;
    try {
      final resp = await api.saleCreate(
        imei: imei,
        price: priceRaw,
        buyerName: buyer,
        model: _model.text.trim(),
        buyerNid: _buyerNid.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _saleId = _asInt(resp['id']);
        _token = '${resp['token'] ?? ''}';
        _saleState = '${resp['state'] ?? ''}';
      });
      _snack(t.upReceiptCreated);
      _loadReceipts();
    } on ApiException {
      if (mounted) _snack(t.upReceiptError);
    } catch (_) {
      if (mounted) _snack(t.upReceiptError);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _authorize() async {
    final t = AppLocalizations.of(context);
    final id = _saleId;
    if (id == null) return;
    // Section-8 gate FIRST. Only call saleAuthorize when the guard returns
    // APPLIED. For pending/awaiting/blocked/cancelled/error we show the guard's
    // own message (already surfaced) + a delay note, and STOP — no authorize.
    SecActionResult res;
    try {
      res = await const SecurityGuard().run(context, 'sell_transfer');
    } catch (_) {
      if (mounted) _snack(t.upAuthorizeError);
      return;
    }
    if (!mounted) return;
    if (res.state != SecActionState.applied) {
      if (res.state == SecActionState.pending ||
          res.state == SecActionState.awaitingApproval) {
        _snack(t.upAuthorizeDelayNote);
      }
      return; // guard already explained badPin/blocked/cancelled/error
    }

    setState(() => _authorizing = true);
    final api = context.read<AppState>().api;
    try {
      final resp = await api.saleAuthorize(id);
      if (!mounted) return;
      final status = resp['_status'] as int?;
      final state = '${resp['state'] ?? ''}';
      final reason = '${resp['reason'] ?? ''}';
      // Server-side re-check can still block on top of the guard.
      if (status == 409 || reason == 'reported_stolen' || state == 'blocked') {
        _snack(t.upAuthorizeBlockedStolen);
      } else if (status == 423 || reason == 'frozen') {
        _snack(t.upAuthorizeBlockedFrozen);
      } else {
        setState(() => _saleState = state.isNotEmpty ? state : _saleState);
        _snack(t.upAuthorizeApplied);
      }
      _loadReceipts();
    } on ApiException {
      if (mounted) _snack(t.upAuthorizeError);
    } catch (_) {
      if (mounted) _snack(t.upAuthorizeError);
    } finally {
      if (mounted) setState(() => _authorizing = false);
    }
  }

  // ---- buyer accept ------------------------------------------------------

  Future<void> _accept() async {
    final t = AppLocalizations.of(context);
    final tok = _acceptToken.text.trim();
    if (tok.isEmpty) {
      _snack(t.upBuyerAcceptNeedToken);
      return;
    }
    setState(() => _accepting = true);
    final api = context.read<AppState>().api;
    try {
      await api.saleAccept(tok);
      if (mounted) {
        _snack(t.upBuyerAccepted);
        _acceptToken.clear();
      }
      _loadReceipts();
    } on ApiException {
      if (mounted) _snack(t.upBuyerAcceptError);
    } catch (_) {
      if (mounted) _snack(t.upBuyerAcceptError);
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  // ---- my receipts (defensive against map OR list shapes) ---------------

  Future<void> _loadReceipts() async {
    setState(() => _loadingReceipts = true);
    final api = context.read<AppState>().api;
    try {
      final resp = await api.saleMine(); // api normalises to the map shape
      if (!mounted) return;
      setState(() {
        _asSeller = _asList(resp['as_seller']);
        _asBuyer = _asList(resp['as_buyer']);
      });
    } catch (_) {
      // leave lists as-is; non-fatal
    } finally {
      if (mounted) setState(() => _loadingReceipts = false);
    }
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.upSellTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.upSellTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Text(t.upSellIntro, style: const TextStyle(height: 1.35)),
          const SizedBox(height: Gap.lg),
          _sectionTitle(t.upSellStepsTitle,
              trailing: t.upSellStepsProgress(
                  fmtInt(context, _doneCount), fmtInt(context, _steps.length))),
          const SizedBox(height: Gap.sm),
          for (final s in _steps) _stepCard(t, s),
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.upReceiptTitle),
          const SizedBox(height: Gap.xs),
          Text(t.upReceiptIntro,
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          _receiptForm(t),
          if (_token != null && _token!.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            _tokenCard(t, scheme),
          ],
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.upBuyerAcceptTitle),
          const SizedBox(height: Gap.xs),
          Text(t.upBuyerAcceptIntro,
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          _buyerAccept(t),
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.upReceiptsTitle),
          const SizedBox(height: Gap.sm),
          _receiptsList(t, scheme),
          const SizedBox(height: Gap.xl),
          // Report-stolen cross-link (keeps it reachable without a 3rd entry).
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.report_gmailerrorred_rounded, size: 18),
              label: Text(t.upReportTitle),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ReportStolenScreen())),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(t.upHonestFooter,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, {String? trailing}) => Row(
        children: [
          Expanded(
            child: Text(text,
                style:
                    AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
          ),
          if (trailing != null)
            Text(trailing,
                style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );

  Widget _stepCard(AppLocalizations t, _SellStep s) {
    final scheme = Theme.of(context).colorScheme;
    final done = _done[s.id] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          leading: Icon(
            done ? Icons.check_circle_rounded : s.icon,
            color: done ? Brand.success : scheme.onSurfaceVariant,
          ),
          title: Text(s.title(t),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(s.why(t),
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          childrenPadding:
              const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
          children: [
            for (int i = 0; i < s.how(t).length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${fmtInt(context, i + 1)}.  ',
                          style: TextStyle(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700)),
                      Expanded(child: Text(s.how(t)[i])),
                    ]),
              ),
            if (s.link != null)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(t.upStepGoogleOpen),
                  onPressed: () => _openLink(s.link!),
                ),
              ),
            if (s.disarm)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.lock_open_rounded, size: 18),
                  label: Text(t.upStepDisarmButton),
                  onPressed: () => _runDisarm(s.id),
                ),
              ),
            const SizedBox(height: Gap.xs),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title:
                  Text(t.upStepConfirm, style: AType.bodyMedium),
              value: done,
              onChanged: (v) => _toggle(s.id, v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _receiptForm(AppLocalizations t) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(children: [
          TextField(
            controller: _imei,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t.upImeiLabel,
              helperText: t.upImeiHint,
              helperMaxLines: 3,
              prefixIcon: const Icon(Icons.smartphone_rounded),
            ),
          ),
          if (_hasVaultImei)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: Text(t.upPrefillFromVault),
                onPressed: _prefill,
              ),
            ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _model,
            decoration: InputDecoration(
                labelText: t.upFieldModel,
                prefixIcon: const Icon(Icons.phone_android_rounded)),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _price,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: t.upFieldPrice,
                prefixIcon: const Icon(Icons.payments_rounded)),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _buyerName,
            decoration: InputDecoration(
                labelText: t.upFieldBuyerName,
                prefixIcon: const Icon(Icons.person_outline_rounded)),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _buyerNid,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: t.upFieldBuyerNid,
                prefixIcon: const Icon(Icons.badge_rounded)),
          ),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _creating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.receipt_long_rounded),
              label: Text(t.upReceiptCreate),
              onPressed: _creating ? null : _createReceipt,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tokenCard(AppLocalizations t, ColorScheme scheme) {
    final token = _token!;
    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.upTokenTitle,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.sm),
            Text(t.upTokenHint, style: AType.bodySmall),
            const SizedBox(height: Gap.md),
            // DISPLAY-ONLY QR (pure Dart). White background so any scanner app
            // reads it reliably regardless of theme.
            Center(
              child: Container(
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: QrImageView(
                  data: token,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: Gap.md),
            SelectableText(token,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.sm),
            if (_saleState != null && _saleState!.isNotEmpty)
              Text(t.upStateLabel(_saleStateLabel(t, _saleState!)),
                  textAlign: TextAlign.center,
                  style: AType.bodySmall.copyWith(color: scheme.onSecondaryContainer)),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(t.upTokenCopy),
              onPressed: () async {
                await copyToClipboard(token);
                _snack(t.upTokenCopied);
              },
            ),
            const Divider(height: Gap.xl),
            Text(t.upAuthorizeTitle,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.xs),
            Text(t.upAuthorizeIntro, style: AType.bodySmall),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              icon: _authorizing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.verified_user_rounded),
              label: Text(t.upAuthorizeButton),
              onPressed: _authorizing ? null : _authorize,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buyerAccept(AppLocalizations t) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(children: [
          TextField(
            controller: _acceptToken,
            decoration: InputDecoration(
              labelText: t.upBuyerTokenLabel,
              prefixIcon: const Icon(Icons.qr_code_2_rounded),
            ),
          ),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _accepting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_done_rounded),
              label: Text(t.upBuyerAcceptButton),
              onPressed: _accepting ? null : _accept,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _receiptsList(AppLocalizations t, ColorScheme scheme) {
    if (_loadingReceipts && _asSeller.isEmpty && _asBuyer.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_asSeller.isEmpty && _asBuyer.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Text(t.upReceiptsEmpty,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    return Column(children: [
      if (_asSeller.isNotEmpty) ...[
        _subLabel(t.upReceiptsSelling),
        for (final r in _asSeller) _receiptRow(t, r, seller: true),
      ],
      if (_asBuyer.isNotEmpty) ...[
        _subLabel(t.upReceiptsBuying),
        for (final r in _asBuyer) _receiptRow(t, r, seller: false),
      ],
    ]);
  }

  Widget _subLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xs),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(text,
              style: AType.bodySmall.copyWith(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );

  Widget _receiptRow(AppLocalizations t, Map<String, dynamic> r,
      {required bool seller}) {
    final model = '${r['model'] ?? ''}'.trim();
    final modelText = model.isEmpty ? t.upFieldModel : model;
    final priceText = taka(context, _priceToPoisha(r));
    final state = '${r['state'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: Icon(seller ? Icons.sell_rounded : Icons.shopping_bag_rounded),
        title: Text(t.upReceiptRow(modelText, priceText)),
        subtitle: state.isEmpty
            ? null
            : Text(t.upStateLabel(_saleStateLabel(t, state))),
      ),
    );
  }

  // ---- helpers -----------------------------------------------------------

  String _saleStateLabel(AppLocalizations t, String state) {
    switch (state) {
      case 'created':
      case 'draft':
        return t.upSaleStateCreated;
      case 'pending':
        return t.upSaleStatePending;
      case 'awaiting_approval':
      case 'awaiting':
        return t.upSaleStateAwaiting;
      case 'authorized':
        return t.upSaleStateAuthorized;
      case 'accepted':
      case 'completed':
        return t.upSaleStateAccepted;
      case 'blocked':
        return t.upSaleStateBlocked;
      default:
        return state;
    }
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  static List<Map<String, dynamic>> _asList(dynamic v) {
    if (v is List) {
      return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  /// Receipts carry either integer poisha (`price_poisha`) or a taka price
  /// (`price`). Normalise both to poisha so [taka] renders Bangla digits.
  static int _priceToPoisha(Map<String, dynamic> r) {
    if (r['price_poisha'] != null) {
      return int.tryParse('${r['price_poisha']}') ?? 0;
    }
    return takaToPoisha('${r['price'] ?? ''}');
  }
}

/// One checklist step. [how] is a newline-joined localized block (split at
/// build time, like phone_safety_screen). [disarm] marks the Section-8 step;
/// [link] is a real launchable URL only.
class _SellStep {
  final String id;
  final IconData icon;
  final String? link;
  final bool disarm;
  const _SellStep(this.id, this.icon, {this.link, this.disarm = false});

  String title(AppLocalizations t) => switch (id) {
        'backup' => t.upStepBackupTitle,
        'google' => t.upStepGoogleTitle,
        'brand' => t.upStepBrandTitle,
        'disarm' => t.upStepDisarmTitle,
        'admin' => t.upStepAdminTitle,
        'sim' => t.upStepSimTitle,
        _ => t.upStepResetTitle,
      };

  String why(AppLocalizations t) => switch (id) {
        'backup' => t.upStepBackupWhy,
        'google' => t.upStepGoogleWhy,
        'brand' => t.upStepBrandWhy,
        'disarm' => t.upStepDisarmWhy,
        'admin' => t.upStepAdminWhy,
        'sim' => t.upStepSimWhy,
        _ => t.upStepResetWhy,
      };

  List<String> how(AppLocalizations t) => switch (id) {
        'backup' => t.upStepBackupHow.split('\n'),
        'google' => t.upStepGoogleHow.split('\n'),
        'brand' => t.upStepBrandHow.split('\n'),
        'disarm' => t.upStepDisarmHow.split('\n'),
        'admin' => t.upStepAdminHow.split('\n'),
        'sim' => t.upStepSimHow.split('\n'),
        _ => t.upStepResetHow.split('\n'),
      }
          .where((l) => l.trim().isNotEmpty)
          .toList();
}
