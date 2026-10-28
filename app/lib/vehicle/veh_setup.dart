import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'veh_format.dart';
import 'vehicle_api.dart';

/// veh100: tracker brands sold in Bangladesh -> the protocol our server
/// speaks for them. 'auto' = "not sure" (the server detects it).
const List<(String, String)> kVehBrands = [
  ('sinotrack', 'h02'),
  ('concox', 'gt06'),
  ('coban', 'tk103'),
  ('teltonika', 'teltonika'),
  ('auto', 'auto'),
];

/// Mobile operators -> setup-guide ids (the server fills the APN in).
const List<String> kVehOperators = ['gp', 'robi', 'airtel', 'banglalink', 'teletalk'];

String vehBrandLabel(AppLocalizations tr, String b) => switch (b) {
      'sinotrack' => 'Sinotrack (ST-901 / ST-906)',
      'concox' => 'Concox / GT06',
      'coban' => 'Coban TK103',
      'teltonika' => 'Teltonika FMB',
      _ => tr.v100BrandUnsure,
    };

String vehOperatorLabel(String o) => switch (o) {
      'gp' => 'Grameenphone',
      'robi' => 'Robi',
      'airtel' => 'Airtel',
      'banglalink' => 'Banglalink',
      _ => 'Teletalk',
    };

/// `sms:` link that opens the phone's SMS app with [body] for [number].
Uri vehSmsUri(String number, String body) =>
    Uri(scheme: 'sms', path: number, queryParameters: {'body': body});

/// The live "set up in under 3 minutes" screen shown right after pairing:
/// the brand's SMS commands in order (copy / send / QR for a second phone),
/// a pairing-window countdown and a live wait for the FIRST ping — polled
/// every 5 s, foreground only. Honest end states: connected, first location,
/// or "time is over" with a one-tap retry.
class VehSetupView extends StatefulWidget {
  final Map<String, dynamic> tracker;
  final String brand;
  final String operator;
  final String simNumber;
  final VoidCallback onClose;
  const VehSetupView({
    super.key,
    required this.tracker,
    required this.brand,
    required this.operator,
    this.simNumber = '',
    required this.onClose,
  });

  @override
  State<VehSetupView> createState() => _VehSetupViewState();
}

class _VehSetupViewState extends State<VehSetupView> {
  late Map<String, dynamic> _t = widget.tracker;
  Map<String, dynamic>? _guide;
  String? _guideErr;
  Timer? _poll, _clock;
  final _started = DateTime.now();
  Duration? _tookToConnect;
  bool _retrying = false;

  int get _id => vehInt(_t['id']) ?? 0;
  String get _state => '${_t['state']}';
  bool get _hasFix => vehMap(_t['live']).isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadGuide();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _check());
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _loadGuide() async {
    final brand = widget.brand == 'auto' ? 'concox' : widget.brand;
    try {
      final g = await context.read<AppState>().api.vehSetupGuide(brand, widget.operator);
      if (mounted) setState(() => _guide = g);
    } catch (e) {
      if (mounted) setState(() => _guideErr = vehReasonText(AppLocalizations.of(context), e));
    }
  }

  Future<void> _check() async {
    if (!mounted) return;
    try {
      final t = await context.read<AppState>().api.vehTracker(_id);
      if (!mounted) return;
      final wasPaired = _state == 'paired';
      setState(() => _t = t);
      if (!wasPaired && _state == 'paired') {
        // the status block below is a live region: TalkBack reads the change
        _tookToConnect = DateTime.now().difference(_started);
      }
      if (_state == 'paired' && _hasFix) _poll?.cancel();
    } catch (_) {}
  }

  Future<void> _retry() async {
    final tr = AppLocalizations.of(context);
    setState(() => _retrying = true);
    try {
      final r = await context.read<AppState>().api.vehPair('${_t['imei'] ?? ''}',
          name: '${_t['name'] ?? ''}', protocol: '${_t['protocol'] ?? 'auto'}');
      if (mounted) setState(() => _t = vehMap(r['tracker']));
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => _check());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(vehReasonText(tr, e))));
      }
    }
    if (mounted) setState(() => _retrying = false);
  }

  String _stepWhat(AppLocalizations tr, String what) => switch (what) {
        'apn' => tr.v100StepApn,
        'server' => tr.v100StepServer,
        'gprs_on' => tr.v100StepGprs,
        'interval' => tr.v100StepInterval,
        'reset' => tr.v100StepReset,
        _ => '',
      };

  String _mmss(BuildContext context, Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    return '${vehNumStr(context, s ~/ 60)}:${vehNumStr(context, s % 60).padLeft(2, vehNumStr(context, 0))}';
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final expires = vehDate(_t['pair_expires_at']);
    final left = expires == null ? Duration.zero : expires.difference(DateTime.now());
    final expired = _state == 'expired' || (_state == 'pending' && left.isNegative);
    final paired = _state == 'paired';
    final disabled = _state == 'disabled';
    final steps = vehList(_guide?['steps']);
    final idHint = '${_guide?['id_hint'] ?? ''}';

    final IconData icon;
    final Color tint;
    final String title, body;
    if (paired && _hasFix) {
      icon = Icons.check_circle_rounded;
      tint = Brand.success;
      title = tr.v100SetupFirstFix;
      body = _tookToConnect == null
          ? tr.v100SetupFirstFixBody
          : tr.v100SetupTook(_mmss(context, _tookToConnect!));
    } else if (paired) {
      icon = Icons.satellite_alt_rounded;
      tint = Brand.success;
      title = tr.v100SetupConnected;
      body = tr.v100SetupWaitingFix;
    } else if (disabled) {
      icon = Icons.error_outline_rounded;
      tint = scheme.error;
      title = tr.v100SetupDisabled;
      body = '${_t['disabled_reason']}' == 'no_credits' ? tr.vehErrNoCredits : tr.vehErrGeneric;
    } else if (expired) {
      icon = Icons.timer_off_rounded;
      tint = scheme.error;
      title = tr.v100SetupExpired;
      body = tr.v100SetupExpiredBody;
    } else {
      icon = Icons.wifi_tethering_rounded;
      tint = Brand.warning;
      title = tr.v100SetupWaiting;
      body = tr.v100SetupWaitingBody(_mmss(context, left));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        liveRegion: true,
        child: Column(children: [
          Icon(icon, size: 44, color: tint),
          const SizedBox(height: Gap.sm),
          Text(title,
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(body,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
        ]),
      ),
      if (!paired && !expired && !disabled) ...[
        const SizedBox(height: Gap.sm),
        const LinearProgressIndicator(),
        const SizedBox(height: Gap.xs),
        Text(tr.v100SetupElapsed(_mmss(context, DateTime.now().difference(_started))),
            textAlign: TextAlign.center,
            style: AType.bodySmall.copyWith(fontFeatures: AFonts.tabular)),
      ],
      if (expired) ...[
        const SizedBox(height: Gap.sm),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _retrying ? null : _retry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(tr.v100SetupRetry),
        ),
      ],
      if (!paired) ...[
        const SizedBox(height: Gap.md),
        Text(tr.v100SetupSendThese(vehOperatorLabel(widget.operator)),
            style: Theme.of(context).textTheme.titleMedium),
        if (idHint == 'id_10')
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(tr.v100SetupIdHint10,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
          ),
        if (_guideErr != null)
          Text(_guideErr!, style: TextStyle(color: scheme.error))
        else if (_guide == null)
          const Padding(
              padding: EdgeInsets.all(Gap.md),
              child: Center(child: CircularProgressIndicator()))
        else
          for (var i = 0; i < steps.length; i++)
            _stepCard(tr, scheme, i + 1, '${steps[i]['sms']}', '${steps[i]['what']}'),
        const SizedBox(height: Gap.sm),
        Text(tr.v100SetupReplyOk('${_guide?['reply_ok'] ?? 'OK'}'),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
      ],
      const SizedBox(height: Gap.md),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: widget.onClose,
        child: Text(paired ? tr.vehDone : tr.v100SetupLater),
      ),
    ]);
  }

  Widget _stepCard(AppLocalizations tr, ColorScheme scheme, int n, String sms, String what) {
    final hasSim = widget.simNumber.trim().isNotEmpty;
    return Card(
      margin: const EdgeInsets.only(top: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CircleAvatar(radius: 14, child: Text(vehNumStr(context, n))),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(_stepWhat(tr, what),
                    style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: Gap.xs),
          SelectableText(sms,
              style: AType.bodyMedium.copyWith(fontFamily: 'monospace')),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: sms));
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(SnackBar(content: Text(tr.vehCopied)));
              },
              icon: const Icon(Icons.copy_rounded),
              label: Text(tr.vehCopy),
            ),
            if (hasSim)
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () async {
                  try {
                    await launchUrl(vehSmsUri(widget.simNumber.trim(), sms));
                  } catch (_) {}
                },
                icon: const Icon(Icons.sms_rounded),
                label: Text(tr.v100SetupSendSms),
              ),
            if (hasSim)
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(tr.v100SetupQrTitle),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox.square(
                          dimension: 220,
                          child: QrImageView(
                              data: 'SMSTO:${widget.simNumber.trim()}:$sms',
                              size: 220,
                              backgroundColor: Colors.white)),
                      const SizedBox(height: Gap.sm),
                      Text(tr.v100SetupQrBody, textAlign: TextAlign.center),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx), child: Text(tr.vehDone)),
                    ],
                  ),
                ),
                icon: const Icon(Icons.qr_code_2_rounded),
                label: Text(tr.v100SetupQr),
              ),
          ]),
        ]),
      ),
    );
  }
}
