import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api.dart';
import '../../crypto/device_link.dart';
import '../../crypto/identity_vault.dart';
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// circle-extras (row 50) — the MAIN phone's "Link a phone" sheet:
///   QR + "ABCD-EFGH" (2 minutes, live countdown) → the new phone claims it →
///   "Link Pixel 7? It must show 123 456" → Link this phone → this phone seals
///   its key ring to the new phone's one-time key and approves.
/// Pops with the linked phone's name (or null).
class LinkPhoneSheet extends StatefulWidget {
  const LinkPhoneSheet({super.key, required this.api, this.pollEvery, this.vault});
  final ApiClient api;

  /// Tests: an in-memory key store (the app uses IdentityVault.instance).
  final IdentityVault? vault;

  /// Tests: faster status polling.
  final Duration? pollEvery;

  @override
  State<LinkPhoneSheet> createState() => _LinkPhoneSheetState();
}

class _LinkPhoneSheetState extends State<LinkPhoneSheet> {
  late final MainPhoneLink _link = MainPhoneLink(
      get: (p) => widget.api.getJson(p),
      postJson: (p, b) => widget.api.postJson(p, b),
      vault: widget.vault);
  Map<String, dynamic>? _start;
  Map<String, dynamic>? _claimed;
  DateTime? _expires;
  Timer? _timer;
  bool _failed = false;
  bool _approving = false;
  bool _expired = false;
  int _left = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    _timer?.cancel();
    setState(() {
      _start = null;
      _claimed = null;
      _failed = false;
      _expired = false;
    });
    try {
      final s = await _link.start();
      if (!mounted) return;
      final ttl = (s['ttl_sec'] as num?)?.toInt() ?? 120;
      setState(() {
        _start = s;
        _expires = DateTime.now().add(Duration(seconds: ttl));
        _left = ttl;
      });
      _timer = Timer.periodic(widget.pollEvery ?? const Duration(seconds: 2), (_) => _tick());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  bool _busy = false;
  Future<void> _tick() async {
    if (!mounted || _busy || _claimed != null) return;
    final exp = _expires;
    if (exp != null) {
      final left = exp.difference(DateTime.now()).inSeconds;
      setState(() => _left = left < 0 ? 0 : left);
      if (left <= 0) {
        _timer?.cancel();
        setState(() => _expired = true);
        return;
      }
    }
    _busy = true;
    try {
      final st = await _link.status();
      if (!mounted) return;
      if (st['state'] == 'claimed') {
        _timer?.cancel();
        setState(() => _claimed = st);
      }
    } catch (_) {
      // offline for a moment: keep showing the code
    } finally {
      _busy = false;
    }
  }

  Future<void> _approve() async {
    final c = _claimed;
    if (c == null) return;
    setState(() => _approving = true);
    var ok = false;
    try {
      ok = await _link.approve((c['pair'] as num).toInt(), c);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop('${c['name'] ?? ''}');
    } else {
      setState(() {
        _approving = false;
        _failed = true;
      });
    }
  }

  Future<void> _reject() async {
    final c = _claimed;
    if (c != null) {
      try {
        await _link.reject((c['pair'] as num).toInt());
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final c = _claimed;
    final List<Widget> body;
    if (_failed) {
      body = [
        Text(t.dlkLinkFailed, key: const Key('dlk-sheet-failed'), style: AType.bodyLarge),
        const SizedBox(height: Gap.md),
        DsButton(label: t.dlkTryAgain, icon: Icons.refresh_rounded, onPressed: _begin),
      ];
    } else if (c != null) {
      final digits = MainPhoneLink.verifyOf(c) ?? '';
      final name = '${c['name'] ?? ''}'.trim();
      body = [
        Text(t.dlkConfirmTitle(name.isEmpty ? t.dlkUnnamedPhone : name),
            key: const Key('dlk-confirm-title'), style: AType.titleLarge),
        const SizedBox(height: Gap.md),
        Text(t.dlkConfirmBody, style: AType.bodyLarge),
        const SizedBox(height: Gap.md),
        Center(
          child: Text(notifLocalizeDigits(context, DeviceLinkCrypto.spaced(digits)),
              key: const Key('dlk-confirm-digits'),
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: 4)),
        ),
        const SizedBox(height: Gap.md),
        Text(t.dlkConfirmWarn, style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
        const SizedBox(height: Gap.lg),
        DsButton(
          buttonKey: const Key('dlk-allow'),
          label: t.dlkAllow,
          icon: Icons.verified_user_rounded,
          expand: true,
          busy: _approving,
          onPressed: _approving ? null : _approve,
        ),
        const SizedBox(height: Gap.sm),
        DsButton.secondary(
          buttonKey: const Key('dlk-deny'),
          label: t.dlkDeny,
          expand: true,
          onPressed: _approving ? null : _reject,
        ),
      ];
    } else if (_start == null) {
      body = [const SizedBox(height: Gap.xxl), const Center(child: CircularProgressIndicator())];
    } else {
      final s = _start!;
      body = [
        Text(t.dlkSheetTitle, style: AType.titleLarge),
        const SizedBox(height: Gap.sm),
        Text(t.dlkSheetBody, style: AType.bodyLarge),
        const SizedBox(height: Gap.lg),
        Center(
          child: _expired
              ? SizedBox(
                  height: 220,
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(t.dlkExpired, key: const Key('dlk-expired'), style: AType.bodyLarge),
                      const SizedBox(height: Gap.md),
                      DsButton(label: t.dlkNewCode, icon: Icons.refresh_rounded, onPressed: _begin),
                    ]),
                  ),
                )
              : Container(
                  key: const Key('dlk-qr'),
                  padding: const EdgeInsets.all(Gap.md),
                  // a QR must stay dark-on-white to scan, in dark mode too
                  color: Colors.white,
                  child: QrImageView(
                    data: '${s['qr']}',
                    size: 220,
                    backgroundColor: Colors.white,
                    semanticsLabel: t.dlkSheetTitle,
                  ),
                ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.dlkOrType, textAlign: TextAlign.center, style: AType.bodyMedium),
        const SizedBox(height: Gap.xs),
        Center(
          child: SelectableText('${s['code']}',
              key: const Key('dlk-code'),
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 3)),
        ),
        const SizedBox(height: Gap.xs),
        if (!_expired)
          Text(notifLocalizeDigits(context, t.dlkExpiresIn(_left)),
              textAlign: TextAlign.center,
              style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
        const SizedBox(height: Gap.md),
        Text(t.dlkHonest, style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
      ];
    }
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, Gap.xl),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: body),
      ),
    );
  }
}
