import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../services/security_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart';
import '../widgets/password_field.dart';

/// Secure, Play-compliant "Delete my profile & all data".
///
/// HONESTY (the copy the user sees reflects this):
///   * Deletion is PERMANENT only after a 7-day grace period; until then the
///     account is fully recoverable — the owner (or a trusted contact with the
///     "this wasn't me" token) can cancel it from anywhere.
///   * A thief who just snatched an unlocked phone CANNOT wipe the account: a
///     recent theft signal blocks the request (HTTP 423), and even a successful
///     request is delayed + alerted + cancellable.
///
/// This screen REPLACES the old one-tap delete. It never calls the instant
/// `AppState.deleteAccount()` wipe; it schedules the deletion server-side and
/// leaves the user logged in so they can still cancel during the grace period.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

enum _Phase { loading, preview, verify, pending, blocked }

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  _Phase _phase = _Phase.loading;

  // Preview.
  Map<String, int> _counts = const {};
  bool _exportDownloaded = false;

  // Pending.
  DateTime? _effectiveAt;
  String? _blockedReason; // 'theft_signal' | 'frozen'

  // Verify inputs.
  final _password = TextEditingController();
  final _otp = TextEditingController();
  bool _hasPin = false; // user HAS a Security PIN -> biometric + PIN required.
  String? _securityPin; // captured via askPin after biometric.
  bool _otpSent = false;
  bool _otpOff = false; // SMS provider off -> OTP satisfied-if-absent.

  bool _busy = false;
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _password.dispose();
    _otp.dispose();
    super.dispose();
  }

  AppState get _app => context.read<AppState>();

  // --- bootstrap: pending banner first, else preview -----------------------
  Future<void> _bootstrap() async {
    // 1) Is there already a pending request? Show it (banner-first) if so.
    try {
      final st = await _app.api.accountDeleteStatus();
      if (!mounted) return;
      if ('${st['state']}' == 'pending') {
        setState(() {
          _effectiveAt = _parseDate(st['effective_at']);
          _phase = _Phase.pending;
        });
        return;
      }
    } catch (_) {
      // Non-fatal — fall through to preview.
    }

    // 2) Does the user have a Security PIN? (biometric + PIN only if so).
    try {
      final sec = await _app.api.securityState();
      _hasPin = sec['has_pin'] == true;
    } catch (_) {
      _hasPin = false;
    }

    // 3) Preview — what will be deleted.
    await _loadPreview();
  }

  Future<void> _loadPreview() async {
    setState(() {
      _busy = true;
      _inlineError = null;
    });
    try {
      final p = await _app.api.accountDeletePreview();
      final raw = (p['counts'] as Map?) ?? const {};
      final counts = <String, int>{};
      raw.forEach((k, v) {
        final n = v is int ? v : int.tryParse('$v') ?? 0;
        if (n > 0) counts['$k'] = n;
      });
      if (!mounted) return;
      setState(() {
        _counts = counts;
        _exportDownloaded = p['export_downloaded'] == true;
        _phase = _Phase.preview;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _inlineError = AppLocalizations.of(context).delAcctLoadFailed('$e');
        _phase = _Phase.preview;
        _busy = false;
      });
    }
  }

  // --- export (reuses the existing "Download my data" JSON export) ---------
  Future<void> _downloadMyData() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final raw = await _app.api.exportRaw();
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/assisto-export.json');
      await f.writeAsString(raw);
      if (!mounted) return;
      setState(() {
        _exportDownloaded = true; // optimistic — nudge stops showing.
        _busy = false;
      });
      messenger.showSnackBar(SnackBar(content: Text(t.savedToPath(f.path))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(t.exportFailed(e))));
    }
  }

  // --- OTP (reuses the existing auth/otp/request endpoint) -----------------
  Future<void> _sendOtp() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ident = _app.user?.phone?.trim().isNotEmpty == true
        ? _app.user!.phone!.trim()
        : (_app.user?.email?.trim() ?? '');
    setState(() => _busy = true);
    try {
      final r = await _app.api.requestOtp(ident);
      if (!mounted) return;
      final smsOff = r['sms_enabled'] == false;
      setState(() {
        _otpSent = true;
        _otpOff = smsOff;
        _busy = false;
      });
      messenger.showSnackBar(SnackBar(
          content: Text(smsOff ? t.delAcctOtpOff : t.delAcctOtpSent(ident))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(t.exportFailed(e))));
    }
  }

  // --- verify PIN (biometric then askPin) ----------------------------------
  Future<void> _capturePin() async {
    final t = AppLocalizations.of(context);
    const guard = SecurityGuard();
    final bio = await guard.ensureBiometric(context);
    if (!mounted) return;
    if (!bio) {
      setState(() => _inlineError = t.delAcctBiometricFailed);
      return;
    }
    final pin = await guard.askPin(context, t);
    if (!mounted) return;
    if (pin == null || pin.isEmpty) return; // cancelled — no error.
    setState(() {
      _securityPin = pin;
      _inlineError = null;
    });
  }

  // --- submit the deletion request -----------------------------------------
  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _inlineError = null;
    });

    final pos = await _bestEffortPosition();

    Map<String, dynamic> resp;
    try {
      resp = await _app.api.accountDeleteRequest(
        password: _password.text,
        otp: _otp.text.trim(),
        securityPin: _hasPin ? _securityPin : null,
        lat: pos?.latitude,
        lng: pos?.longitude,
      );
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _inlineError = t.delAcctRequestError;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _inlineError = t.delAcctRequestError;
      });
      return;
    }
    if (!mounted) return;

    final status = resp['_status'] as int?;
    final state = '${resp['state'] ?? ''}';
    final reason = '${resp['reason'] ?? ''}';

    // 423 — safety block (theft signal / freeze). Do NOT delete.
    if (status == 423 || state == 'blocked') {
      setState(() {
        _busy = false;
        _blockedReason = reason.isEmpty ? 'theft_signal' : reason;
        _phase = _Phase.blocked;
      });
      return;
    }

    // 400/403 — bad credential. Inline error, let them retry.
    if (status == 400 || status == 403 || resp['ok'] == false) {
      String msg;
      switch (reason) {
        case 'bad_password':
          msg = t.delAcctBadPassword;
          break;
        case 'bad_otp':
          msg = t.delAcctBadOtp;
          break;
        case 'bad_pin':
          msg = t.delAcctBadPin;
          break;
        case 'locked':
          msg = t.delAcctPinLocked;
          break;
        default:
          msg = t.delAcctRequestError;
      }
      setState(() {
        _busy = false;
        _inlineError = msg;
      });
      return;
    }

    // pending — scheduled. Stay logged in so the user can still cancel.
    if (state == 'pending') {
      setState(() {
        _busy = false;
        _effectiveAt = _parseDate(resp['effective_at']);
        _phase = _Phase.pending;
      });
      return;
    }

    setState(() {
      _busy = false;
      _inlineError = t.delAcctRequestError;
    });
  }

  // --- cancel a pending deletion -------------------------------------------
  Future<void> _cancel() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final r = await _app.api.accountDeleteCancel();
      if (!mounted) return;
      if (r['ok'] == true || '${r['state']}' == 'cancelled') {
        messenger.showSnackBar(SnackBar(content: Text(t.delAcctCancelled)));
        // Back to normal — reload the preview so the screen is reusable.
        _effectiveAt = null;
        await _loadPreview();
        return;
      }
      setState(() {
        _busy = false;
        _inlineError = t.delAcctRequestError;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _inlineError = t.delAcctRequestError;
      });
    }
  }

  Future<Position?> _bestEffortPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // UI
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.delAcctTitle)),
      body: SafeArea(
        child: _phase == _Phase.loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(Gap.lg),
                child: _body(t),
              ),
      ),
    );
  }

  Widget _body(AppLocalizations t) {
    switch (_phase) {
      case _Phase.pending:
        return _pendingBody(t);
      case _Phase.blocked:
        return _blockedBody(t);
      case _Phase.verify:
        return _verifyBody(t);
      case _Phase.preview:
      default:
        return _previewBody(t);
    }
  }

  // --- Step 0: preview ------------------------------------------------------
  Widget _previewBody(AppLocalizations t) {
    final entries = _counts.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _warnCard(
          icon: Icons.warning_amber_rounded,
          color: Brand.danger,
          title: t.delAcctPreviewTitle,
          body: t.delAcctPreviewBody,
        ),
        const SizedBox(height: Gap.lg),
        Text(t.delAcctWhatDeleted,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        if (entries.isEmpty)
          Text(t.delAcctNothingToDelete)
        else
          Card(
            child: Column(
              children: [
                for (final e in entries)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.delete_outline, size: 20),
                    title: Text(_prettyType(e.key)),
                    trailing: Text(fmtInt(context, e.value),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Gap.lg),
        // Prominent "Download my data first" — always offered; nudge if not done.
        OutlinedButton.icon(
          onPressed: _busy ? null : _downloadMyData,
          icon: const Icon(Icons.download_outlined),
          label: Text(t.delAcctDownloadFirst),
        ),
        if (!_exportDownloaded) ...[
          const SizedBox(height: Gap.xs),
          Text(t.delAcctExportNudge,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Brand.warning)),
        ] else ...[
          const SizedBox(height: Gap.xs),
          Row(children: [
            const Icon(Icons.check_circle, color: Brand.success, size: 16),
            const SizedBox(width: 6),
            Text(t.delAcctExportDone,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ],
        const SizedBox(height: Gap.xl),
        if (_inlineError != null) ...[
          _inlineErr(_inlineError!),
          const SizedBox(height: Gap.sm),
        ],
        if (_inlineError != null)
          // Preview failed to load — offer a retry instead of continuing.
          OutlinedButton.icon(
            onPressed: _busy ? null : _loadPreview,
            icon: const Icon(Icons.refresh),
            label: Text(t.delAcctTryAgain),
          )
        else
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.danger),
            onPressed: _busy
                ? null
                : () => setState(() {
                      _inlineError = null;
                      _phase = _Phase.verify;
                    }),
            child: Text(t.delAcctContinue),
          ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: Text(t.delAcctKeepAccount),
        ),
      ],
    );
  }

  // --- Step 1: verify (multi-factor) ---------------------------------------
  Widget _verifyBody(AppLocalizations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _warnCard(
          icon: Icons.lock_outline,
          color: Brand.blue,
          title: t.delAcctVerifyTitle,
          body: t.delAcctVerifyBody,
        ),
        const SizedBox(height: Gap.lg),

        // Password.
        ObscureTextField(
          controller: _password,
          autofillHints: const [AutofillHints.password],
          decoration: InputDecoration(
            labelText: t.delAcctPasswordLabel,
            prefixIcon: const Icon(Icons.key_outlined),
          ),
        ),
        const SizedBox(height: Gap.lg),

        // OTP.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _otp,
                keyboardType: TextInputType.number,
                maxLength: 8,
                enabled: !_otpOff,
                decoration: InputDecoration(
                  labelText: t.delAcctOtpLabel,
                  prefixIcon: const Icon(Icons.sms_outlined),
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: OutlinedButton(
                onPressed: _busy ? null : _sendOtp,
                child: Text(_otpSent ? t.delAcctResendOtp : t.delAcctSendOtp),
              ),
            ),
          ],
        ),
        if (_otpOff)
          Text(t.delAcctOtpOff,
              style: Theme.of(context).textTheme.bodySmall),

        // Security PIN (only when the user HAS one): biometric + PIN.
        if (_hasPin) ...[
          const SizedBox(height: Gap.lg),
          Card(
            child: ListTile(
              leading: Icon(
                _securityPin != null
                    ? Icons.verified_user
                    : Icons.fingerprint,
                color: _securityPin != null ? Brand.success : null,
              ),
              title: Text(t.delAcctPinTitle),
              subtitle: Text(_securityPin != null
                  ? t.delAcctPinCaptured
                  : t.delAcctPinSubtitle),
              trailing: TextButton(
                onPressed: _busy ? null : _capturePin,
                child: Text(_securityPin != null
                    ? t.delAcctPinRedo
                    : t.delAcctPinVerify),
              ),
            ),
          ),
        ],

        const SizedBox(height: Gap.xl),
        if (_inlineError != null) ...[
          _inlineErr(_inlineError!),
          const SizedBox(height: Gap.sm),
        ],
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Brand.danger),
          onPressed: _busy || !_canSubmit() ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.delAcctScheduleDeletion),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed:
              _busy ? null : () => setState(() => _phase = _Phase.preview),
          child: Text(t.delAcctBack),
        ),
      ],
    );
  }

  bool _canSubmit() {
    if (_password.text.isEmpty) return false;
    if (_hasPin && _securityPin == null) return false;
    return true;
  }

  // --- pending state --------------------------------------------------------
  Widget _pendingBody(AppLocalizations t) {
    final when = _fmtWhen(_effectiveAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Banner at the TOP: scheduled + "this wasn't me" cancel.
        Card(
          color: Brand.warning.withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.schedule, color: Brand.warning),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(t.delAcctScheduledTitle,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ]),
                const SizedBox(height: Gap.sm),
                Text(t.delAcctScheduledBody(when)),
                const SizedBox(height: Gap.sm),
                Text(t.delAcctAlertedContacts,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.xl),
        if (_inlineError != null) ...[
          _inlineErr(_inlineError!),
          const SizedBox(height: Gap.sm),
        ],
        FilledButton.icon(
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.undo),
          label: Text(t.delAcctCancelNotMe),
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: Brand.success),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: Text(t.delAcctClose),
        ),
      ],
    );
  }

  // --- blocked (423) state --------------------------------------------------
  Widget _blockedBody(AppLocalizations t) {
    final frozen = _blockedReason == 'frozen';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _warnCard(
          icon: Icons.shield_outlined,
          color: Brand.blue,
          title: t.delAcctBlockedTitle,
          body: frozen ? t.delAcctBlockedFrozen : t.delAcctBlockedTheft,
        ),
        const SizedBox(height: Gap.xl),
        FilledButton(
          onPressed: () => setState(() {
            _blockedReason = null;
            _phase = _Phase.verify;
          }),
          child: Text(t.delAcctTryAgain),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: Text(t.delAcctClose),
        ),
      ],
    );
  }

  // --- small helpers --------------------------------------------------------
  Widget _warnCard({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) {
    return Card(
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: Gap.xs),
                  Text(body),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inlineErr(String msg) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: Brand.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          const Icon(Icons.error_outline, color: Brand.danger, size: 18),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(msg, style: const TextStyle(color: Brand.danger))),
        ]),
      );

  String _fmtWhen(DateTime? dt) {
    if (dt == null) return '';
    final locale = Localizations.localeOf(context).toLanguageTag();
    // Localized long date + time; Bangla locale renders Bangla digits/month.
    return DateFormat.yMMMMd(locale).add_jm().format(dt);
  }

  /// Best-effort humanisation of a backend reverse-relation accessor name
  /// (e.g. "reminder_set" -> "Reminders"). Localized labels aren't available
  /// per-type, so we present the server's key in a readable form.
  String _prettyType(String key) {
    var s = key.replaceAll('_set', '').replaceAll('_', ' ').trim();
    if (s.isEmpty) return key;
    return s[0].toUpperCase() + s.substring(1);
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    return DateTime.tryParse('$v')?.toLocal();
  }
}
