import 'dart:async';

import 'package:flutter/material.dart';
import '../ds/ds.dart';
import '../theme.dart' show AType;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_digits.dart' show ld;
import '../widgets/ladder_common.dart' show fmtInt;
import 'phonecam_api.dart';
import '../screens/watchman/watchman_source.dart' show wmError; // gap-cctv

/// gap-cctv: the one-line installer of the Linux / Raspberry Pi Guard Box
/// (edge/shopbox/linux/install.sh, GitHub release `guardbox-linux`). The box
/// then asks for the SAME short code this sheet shows (shop/phonecam/claim).
const kGuardBoxLinuxInstall =
    'curl -fsSL https://github.com/ArifSarkar247/assisto/releases/download/guardbox-linux/install.sh | sudo sh';
const kGuardBoxLinuxSetup = 'sudo assisto-guardbox setup';

/// cctvphone — VIEWER side of pairing: show a QR (an https App Link) and the
/// same code in big type. The old phone scans it with its own camera /
/// Google Lens (Assisto opens on the pairing screen) or types the code. This
/// sheet polls the server and turns green when the new camera appears.
Future<void> showPhoneCamPairSheet(BuildContext context, int siteId,
    {Future<void> Function()? onPaired}) async {
  final api = context.read<AppState>().api;
  await showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => PhoneCamPairSheet(load: () => api.phoneCamPair(siteId)),
  );
  await onPaired?.call();
}

class PhoneCamPairSheet extends StatefulWidget {
  final Future<Map<String, dynamic>> Function() load;
  final Duration pollEvery;
  const PhoneCamPairSheet(
      {super.key, required this.load, this.pollEvery = const Duration(seconds: 4)});

  @override
  State<PhoneCamPairSheet> createState() => _PhoneCamPairSheetState();
}

class _PhoneCamPairSheetState extends State<PhoneCamPairSheet> {
  Map<String, dynamic>? _d;
  String? _error;
  Set<int>? _known; // camera ids present when the sheet opened
  Map<String, dynamic>? _paired;
  bool _pollFailed = false; // gap-cctv: offline after the code is shown
  Timer? _poll;
  Timer? _tick;
  int _left = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(widget.pollEvery, (_) => _load());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _left > 0) setState(() => _left--);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_paired != null) return;
    try {
      final d = await widget.load();
      if (!mounted) return;
      final cams = ((d['cameras'] ?? const []) as List).whereType<Map>().toList();
      final ids = {for (final c in cams) (c['id'] as num?)?.toInt() ?? 0};
      Map<String, dynamic>? fresh;
      if (_known == null) {
        _known = ids;
      } else {
        for (final c in cams) {
          if (!_known!.contains((c['id'] as num?)?.toInt() ?? 0)) {
            fresh = c.cast<String, dynamic>();
            break;
          }
        }
      }
      setState(() {
        _d = d;
        _error = null;
        _pollFailed = false;
        _left = (d['valid_s'] as num?)?.toInt() ?? 0;
        if (fresh != null) {
          _paired = fresh;
          _poll?.cancel();
        }
      });
    } catch (e) {
      if (!mounted) return;
      // gap-cctv: a plain message in the user's language (never a raw
      // "SocketException…"); once the code is on screen, a poll failure
      // shows an offline line with Retry instead of an endless spinner.
      final t = AppLocalizations.of(context);
      setState(() {
        _error = wmError(e) ?? t.wmLoadErrorBody;
        _pollFailed = _d != null;
      });
    }
  }

  /// mm:ss in the user's digits (Bangla digits in Bangla).
  String _mmss(int s) {
    String two(int v) =>
        v < 10 ? '${fmtInt(context, 0)}${fmtInt(context, v)}' : fmtInt(context, v);
    return '${two(s ~/ 60)}:${two(s % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final d = _d;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.pcPairTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(t.pcPairBenefit, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          if (_paired != null) ...[
            Icon(Icons.check_circle_rounded, size: 64, color: Colors.green.shade700),
            const SizedBox(height: 8),
            Text(t.pcPairDone((_paired!['name'] ?? '').toString()),
                key: const Key('pcPairDone'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(t.pcPairDoneNext, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(t.pcDone),
            ),
          ] else if (d == null && _error == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (d == null)
            Column(children: [
              Text(_error ?? '', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _load,
                  child: Text(t.retry)),
            ])
          else ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                // a QR needs a light quiet zone in dark mode too
                decoration: BoxDecoration(
                    color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: Semantics(
                  label: t.pcQrA11y,
                  child: SizedBox.square(
                      dimension: 200,
                      child: QrImageView(data: (d['link'] ?? '').toString(), size: 200)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(t.pcOrTypeCode, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            // Bangla digits on a Bangla screen (launchsweep2); the old phone's
            // code box accepts both (normalizePairCode), Copy keeps Latin.
            SelectableText(ld(context, d['code'] ?? ''),
                key: const Key('pcPairCode'),
                textAlign: TextAlign.center,
                style: AType.bodyMedium.copyWith(
                    fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 3)),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.copy_rounded),
              label: Text(t.pcCopyCode),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: (d['code'] ?? '').toString()));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)
                      ?.showSnackBar(SnackBar(content: Text(t.gcvLinuxCopied)));
                }
              },
            ),
            Text(t.pcCodeValid(_mmss(_left)),
                textAlign: TextAlign.center,
                style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
            const SizedBox(height: 16),
            Text(t.pcStepsTitle, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final (i, s) in [t.pcStep1, t.pcStep2, t.pcStep3].indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('${fmtInt(context, i + 1)}. $s'),
              ),
            if (d['extra_needs_credits'] == true) ...[
              const SizedBox(height: 10),
              Text(
                  t.pcExtraCameraNote(
                      fmtInt(context, (d['extra_camera_credits'] as num?)?.toInt() ?? 0)),
                  style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
            ],
            const SizedBox(height: 12),
            if (_pollFailed)
              Row(key: const Key('pcPairOffline'), children: [
                Icon(Icons.cloud_off_rounded, color: scheme.error),
                const SizedBox(width: 10),
                Expanded(child: Text(t.gcvPairOffline)),
                TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _load,
                    child: Text(t.retry)),
              ])
            else
              Row(children: [
                const SizedBox.square(
                    dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(child: Text(t.pcWaiting)),
              ]),
            // gap-cctv: Windows is never required — the same code pairs a
            // Raspberry Pi / Linux mini PC Guard Box (spec V3 A4).
            const SizedBox(height: 12),
            const GuardBoxLinuxSteps(),
          ],
        ]),
      ),
    );
  }
}

/// gap-cctv: "Use a Raspberry Pi or Linux mini PC instead" — folded by
/// default; the install line and the setup line each have a Copy button.
class GuardBoxLinuxSteps extends StatelessWidget {
  /// true inside the pairing sheet (the code is just above); false elsewhere
  /// (the step says where to get the code).
  final bool codeAbove;
  final bool initiallyExpanded; // gallery shot of the open steps
  const GuardBoxLinuxSteps({super.key, this.codeAbove = true, this.initiallyExpanded = false});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget cmd(String key, String text) => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 4, 4),
          decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Expanded(
              child: SelectableText(text,
                  key: Key(key),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ),
            IconButton(
              tooltip: t.gcvLinuxCopy,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.copy_rounded),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)
                      ?.showSnackBar(SnackBar(content: Text(t.gcvLinuxCopied)));
                }
              },
            ),
          ]),
        );
    return DsCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        key: const Key('pcLinuxBox'),
        initiallyExpanded: initiallyExpanded,
        leading: const Icon(Icons.developer_board_rounded),
        title: Text(t.gcvLinuxTitle),
        subtitle: Text(t.gcvLinuxSub),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${fmtInt(context, 1)}. ${t.gcvLinuxStep1}'),
          const SizedBox(height: 6),
          Text('${fmtInt(context, 2)}. ${t.gcvLinuxStep2}'),
          cmd('pcLinuxInstall', kGuardBoxLinuxInstall),
          Text('${fmtInt(context, 3)}. ${t.gcvLinuxStep3}'),
          cmd('pcLinuxSetup', kGuardBoxLinuxSetup),
          Text('${fmtInt(context, 4)}. ${codeAbove ? t.gcvLinuxStep4 : t.gcvLinuxStep4Where}'),
          const SizedBox(height: 6),
          Text(t.gcvLinuxPrivacy,
              style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
        ],
      ),
    );
  }
}
