import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../crypto/device_link.dart';
import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_counter.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import '../widgets/permission_reason.dart';
import '../widgets/qr_scan_view.dart';

/// circle-extras (row 50) — the NEW phone's side of "link a phone"
/// (sign-in page → "Link to my main phone"). No password / SMS: the main
/// phone (already signed in) shows a QR + 8-character code, this phone scans
/// or types it, both phones show the SAME 6 digits, the owner taps "Link
/// this phone" on the main phone and this phone is signed in with the main
/// phone's encryption key (design: lib/crypto/device_link.dart).
class LinkPhoneScreen extends StatefulWidget {
  const LinkPhoneScreen({super.key, this.startWithCamera = true});

  /// false = no "Scan the code" button (tests / previews): the code field only.
  final bool startWithCamera;

  @override
  State<LinkPhoneScreen> createState() => _LinkPhoneScreenState();
}

enum _Stage { enter, wait, done }

class _LinkPhoneScreenState extends State<LinkPhoneScreen> {
  late NewPhoneLink _link;
  final _code = TextEditingController();
  _Stage _stage = _Stage.enter;
  bool _camera = true;
  bool _cameraDenied = false;
  bool _cameraGone = false; // no camera / camera error on this phone
  bool _busy = false;
  String? _error;
  Timer? _poll;
  DateTime? _deadline;

  @override
  void initState() {
    super.initState();
    _camera = false; // the camera opens only after "Scan the code" + the reason
    final api = context.read<AppState>().api;
    _link = NewPhoneLink(post: (p, b) => api.postJsonRaw(p, b));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _code.dispose();
    super.dispose();
  }

  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _submit(String raw) async {
    if (_busy) return;
    final t = _t;
    final ok = DeviceLinkCrypto.isOurQr(raw) ||
        (!raw.contains(':') && DeviceLinkCrypto.codeComplete(raw));
    if (!ok) {
      // a scanned QR that is not ours (a shop / Wi-Fi code) or a short code
      setState(() {
        _error = (_camera || raw.contains(':')) ? t.dlkNotOurQr : t.dlkCodeIncomplete;
        _camera = false; // "Scan the code" re-opens a fresh scanner
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    LinkClaim? c;
    try {
      c = await _link.claimCode(raw);
    } catch (_) {
      c = null;
      _link.error = t.checkInternetRetry;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (c == null) {
        _error = (_link.error ?? '').isEmpty ? t.dlkLinkFailed : _link.error;
        _camera = false; // let them type / retry
      } else {
        _stage = _Stage.wait;
        _deadline = DateTime.now().add(const Duration(minutes: 5));
        _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
      }
    });
  }

  /// Play disclosure: say why the camera is needed BEFORE Android asks.
  Future<void> _openScanner() async {
    if (!await showPermissionReason(context, PermKind.camera)) return;
    if (!mounted) return;
    setState(() {
      _camera = true;
      _error = null;
    });
  }

  bool _ticking = false;
  Future<void> _tick() async {
    if (_ticking || !mounted) return;
    _ticking = true;
    try {
      final r = await _link.pollOnce();
      if (!mounted) return;
      switch (r.outcome) {
        case LinkClaimOutcome.waiting:
          if (_deadline != null && DateTime.now().isAfter(_deadline!)) {
            _fail(_t.dlkExpiredNew);
          }
          break;
        case LinkClaimOutcome.rejected:
          _fail(_t.dlkRejected);
          break;
        case LinkClaimOutcome.expired:
          _fail(_t.dlkExpiredNew);
          break;
        case LinkClaimOutcome.failed:
          _fail(_t.dlkLinkFailed);
          break;
        case LinkClaimOutcome.approved:
          _poll?.cancel();
          setState(() => _stage = _Stage.done);
          final app = context.read<AppState>();
          final nav = Navigator.of(context);
          await app.adoptSession(r.token!, AppUser.fromJson(r.user!));
          if (mounted) nav.popUntil((route) => route.isFirst);
          break;
      }
    } finally {
      _ticking = false;
    }
  }

  void _fail(String msg) {
    _poll?.cancel();
    final api = context.read<AppState>().api;
    setState(() {
      _stage = _Stage.enter;
      _error = msg;
      _camera = false;
      // a fresh one-time key for the next try
      _link = NewPhoneLink(post: (p, b) => api.postJsonRaw(p, b));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.dlkNewTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: switch (_stage) {
          _Stage.enter => _enter(t),
          _Stage.wait => _wait(t),
          _Stage.done => [
              const SizedBox(height: Gap.xxl),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: Gap.lg),
              Text(t.dlkDoneNew, key: const Key('dlk-done'),
                  textAlign: TextAlign.center, style: AType.titleMedium),
            ],
        },
      ),
    );
  }

  List<Widget> _enter(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return [
      Text(t.dlkNewStep1, style: AType.bodyLarge),
      const SizedBox(height: Gap.sm),
      Text(t.dlkNewStep2, style: AType.bodyLarge),
      const SizedBox(height: Gap.lg),
      if (_camera)
        Center(
          child: QrScanView(
            key: const Key('dlk-scanner'),
            onCode: _submit,
            onUnavailable: (denied) {
              if (!mounted) return;
              setState(() {
                _camera = false;
                _cameraDenied = denied;
                _cameraGone = !denied;
              });
            },
          ),
        )
      else ...[
        if (_cameraDenied || _cameraGone)
          Text(_cameraDenied ? t.dlkCameraDenied : t.dlkCameraOff,
              key: const Key('dlk-camera-off'),
              style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
        const SizedBox(height: Gap.sm),
        TextField(
          key: const Key('dlk-code-field'),
          controller: _code,
          maxLength: 9,
          buildCounter: localCounter,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          style: AType.headlineSmall.copyWith(letterSpacing: 3, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            labelText: t.dlkCodeLabel,
            hintText: 'ABCD-EFGH',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: _submit,
        ),
        const SizedBox(height: Gap.md),
        DsButton(
          buttonKey: const Key('dlk-continue'),
          label: t.dlkContinue,
          icon: Icons.link_rounded,
          expand: true,
          busy: _busy,
          onPressed: _busy ? null : () => _submit(_code.text),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: Gap.md),
        Text(_error!, key: const Key('dlk-error'),
            style: AType.bodyMedium.copyWith(color: scheme.error)),
      ],
      const SizedBox(height: Gap.lg),
      if (_camera)
        TextButton.icon(
          key: const Key('dlk-type-instead'),
          onPressed: () => setState(() => _camera = false),
          icon: const Icon(Icons.keyboard_rounded),
          label: Text(t.dlkTypeInstead),
        )
      else if (widget.startWithCamera && !_cameraDenied && !_cameraGone)
        TextButton.icon(
          key: const Key('dlk-scan'),
          onPressed: _openScanner,
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: Text(t.dlkScanInstead),
        ),
      const SizedBox(height: Gap.md),
      Text(t.dlkHonest, style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
    ];
  }

  List<Widget> _wait(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final digits = notifLocalizeDigits(
        context, DeviceLinkCrypto.spaced(_link.claim?.verify ?? ''));
    return [
      const SizedBox(height: Gap.lg),
      Text(t.dlkWaitTitle, style: AType.titleLarge, textAlign: TextAlign.center),
      const SizedBox(height: Gap.md),
      Text(t.dlkWaitBody, textAlign: TextAlign.center, style: AType.bodyLarge),
      const SizedBox(height: Gap.lg),
      Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.md),
          decoration: BoxDecoration(
            color: scheme.ds.cardHighest,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Text(digits,
              key: const Key('dlk-verify'),
              semanticsLabel: digits,
              style: AType.displaySmall.copyWith(fontWeight: FontWeight.w700, letterSpacing: 4)),
        ),
      ),
      const SizedBox(height: Gap.xl),
      const Center(child: CircularProgressIndicator()),
      const SizedBox(height: Gap.lg),
      DsButton.secondary(
        label: t.dlkCancel,
        expand: true,
        onPressed: () {
          _poll?.cancel();
          Navigator.of(context).maybePop();
        },
      ),
    ];
  }
}
