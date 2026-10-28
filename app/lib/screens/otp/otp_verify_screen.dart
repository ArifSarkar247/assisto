import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../otp_api.dart';
import '../../widgets/otp_code_input.dart';
import '../../widgets/subs_common.dart' show fmtInt;
import '../../theme.dart';

/// o1-otp — the shared "enter the code" step used by every OTP flow
/// (sign-up, login, forgot password, delete-account, Section 8).
///
/// Sends the code on open, shows a resend countdown, verifies on the 6th digit
/// and pops with the single-use `otp_proof` (or null if the user backs out).
/// When the SMS gateway isn't connected it shows the honest "not available"
/// state instead of pretending a code was sent.
///
/// smsotp: for login / password reset / delete-account / Section 8 the user
/// can choose "Send the code by email instead" (or gets it offered when SMS
/// is off or failed). The code is verified exactly like an SMS code.
class OtpVerifyScreen extends StatefulWidget {
  final OtpBackend backend;
  final String purpose;
  final String? phone; // null -> server uses the signed-in user's number
  final String title;
  final String? intro;

  const OtpVerifyScreen({
    super.key,
    required this.backend,
    required this.purpose,
    required this.title,
    this.phone,
    this.intro,
  });

  /// Push the step; resolves to the proof or null.
  static Future<String?> run(
    BuildContext context, {
    required OtpBackend backend,
    required String purpose,
    required String title,
    String? phone,
    String? intro,
  }) =>
      Navigator.of(context).push<String>(MaterialPageRoute(
          builder: (_) => OtpVerifyScreen(
              backend: backend,
              purpose: purpose,
              phone: phone,
              title: title,
              intro: intro)));

  @override
  State<OtpVerifyScreen> createState() => _OtpVerifyScreenState();
}

enum _Phase { sending, entering, smsOff }

class _OtpVerifyScreenState extends State<OtpVerifyScreen> {
  final _code = TextEditingController();
  _Phase _phase = _Phase.sending;
  bool _sent = false; // a code is live on the server
  bool _busy = false;
  String _masked = '';
  String? _error;
  bool _viaEmail = false; // smsotp: the live code went by email
  bool _emailAvailable = false; // the server can email codes right now
  String _emailNote = '';
  int _resendLeft = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Localizations aren't readable until after initState -> first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _send();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startTimer(int seconds) {
    _timer?.cancel();
    setState(() => _resendLeft = seconds);
    if (seconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendLeft = _resendLeft - 1);
      if (_resendLeft <= 0) t.cancel();
    });
  }

  String _errorText(AppLocalizations t, OtpResult r) {
    switch (r.reason) {
      case 'invalid_code':
        final left = r.attemptsLeft;
        return left != null ? t.otpErrInvalid(left) : t.otpErrInvalidPlain;
      case 'expired':
        return t.otpErrExpired;
      case 'locked':
        final mins = ((r.retryAfter ?? 60) / 60).ceil();
        return t.otpErrLocked(mins);
      case 'cooldown':
        return t.otpErrCooldown;
      case 'rate_limited':
        return t.otpErrRateLimited;
      case 'send_failed':
        return t.otpErrSendFailed;
      case 'no_active_code':
        return t.otpErrNoActive;
      case 'bad_phone':
        return t.otpPhoneInvalid;
      case 'phone_mismatch':
        return t.otpErrPhoneMismatch;
      case 'already_registered':
        return t.otpErrAlreadyRegistered;
      case 'network':
        return t.otpErrNetwork;
      case 'sms_daily_cap':
        return t.smsotpSmsCap;
      case 'email_not_configured':
        return t.smsotpEmailOff;
      case 'email_daily_cap':
        return t.smsotpEmailCap;
      case 'no_verified_email':
        return t.smsotpEmailNoVerified;
      default:
        return r.message.isNotEmpty ? r.message : t.otpErrGeneric;
    }
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
      if (!_sent) _phase = _Phase.sending;
    });
    final r = await widget.backend.request(widget.purpose, phone: widget.phone);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _emailAvailable = r.emailAvailable;
    });
    if (r.smsOff) {
      setState(() => _phase = _Phase.smsOff);
      return;
    }
    if (r.ok) {
      _code.clear();
      setState(() {
        _sent = true;
        _phase = _Phase.entering;
        _masked = r.phoneMasked;
      });
      _startTimer(r.resendIn ?? 60);
      return;
    }
    // A code is probably already live (recent send) -> still let them type it.
    if (r.reason == 'cooldown') {
      setState(() {
        _sent = true;
        _phase = _Phase.entering;
        _error = t.otpErrCooldown;
      });
      _startTimer(r.retryAfter ?? 60);
      return;
    }
    setState(() {
      _phase = _Phase.entering;
      _error = _errorText(t, r);
    });
    if (r.retryAfter != null) _startTimer(r.retryAfter!);
  }

  bool get _emailPurpose => otpEmailPurposes.contains(widget.purpose);

  /// smsotp — deliver the code by email instead (same verify step).
  Future<void> _sendEmail() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final r =
        await widget.backend.requestEmail(widget.purpose, phone: widget.phone);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      _code.clear();
      setState(() {
        _viaEmail = true;
        _sent = true;
        _phase = _Phase.entering;
        _emailNote = r.emailMasked.isNotEmpty
            ? t.smsotpEmailSentTo(r.emailMasked)
            : t.smsotpEmailSentNeutral;
      });
      _startTimer(r.resendIn ?? 60);
      return;
    }
    setState(() {
      if (r.emailOff || r.reason == 'email_daily_cap') _emailAvailable = false;
      if (_phase == _Phase.smsOff || _phase == _Phase.sending) {
        _phase = _Phase.entering;
      }
      _error = _errorText(t, r);
    });
    if (r.retryAfter != null && r.reason != 'email_daily_cap') {
      _startTimer(r.retryAfter!);
    }
  }

  Future<void> _verify([String? value]) async {
    final t = AppLocalizations.of(context);
    final code = value ?? _code.text;
    if (code.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.backend.verify(widget.purpose, code, phone: widget.phone);
    if (!mounted) return;
    if (r.ok && r.proof != null) {
      Navigator.of(context).pop(r.proof);
      return;
    }
    setState(() {
      _busy = false;
      _error = _errorText(t, r);
      if (r.reason == 'expired' || r.reason == 'locked' || r.reason == 'no_active_code') {
        _sent = false;
      }
      _code.clear();
    });
    if (r.reason == 'locked' && r.retryAfter != null) _startTimer(r.retryAfter!);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: switch (_phase) {
                _Phase.sending => Column(children: [
                    const SizedBox(height: 40),
                    const CircularProgressIndicator(),
                    const SizedBox(height: Gap.lg),
                    Text(t.otpSending, textAlign: TextAlign.center),
                  ]),
                _Phase.smsOff => _SmsOffCard(
                    onClose: () => Navigator.of(context).pop(),
                    onEmail: (_emailPurpose && _emailAvailable && !_busy)
                        ? _sendEmail
                        : null),
                _Phase.entering => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(_viaEmail ? Icons.email_rounded : Icons.sms_rounded,
                          size: 48, color: scheme.primary),
                      const SizedBox(height: Gap.md),
                      Text(t.otpTitle,
                          textAlign: TextAlign.center,
                          style: textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: Gap.sm),
                      if (widget.intro != null) ...[
                        Text(widget.intro!,
                            textAlign: TextAlign.center,
                            style: textTheme.bodyMedium),
                        const SizedBox(height: 6),
                      ],
                      if (_sent && _viaEmail)
                        Text(_emailNote,
                            key: const Key('otp-email-note'),
                            textAlign: TextAlign.center,
                            style: textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant))
                      else if (_sent && _masked.isNotEmpty)
                        Text(t.otpSentTo(_masked),
                            textAlign: TextAlign.center,
                            style: textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: Gap.xl),
                      OtpCodeInput(
                        controller: _code,
                        enabled: _sent && !_busy,
                        hasError: _error != null,
                        semanticsLabel: t.otpCodeFieldLabel,
                        onChanged: (_) => setState(() => _error = null),
                        onCompleted: _verify,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(_error!,
                                  key: const Key('otp-error'),
                                  style: TextStyle(color: scheme.error)),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: Gap.xl),
                      FilledButton(
                        onPressed: (_sent && !_busy && _code.text.length == 6)
                            ? () => _verify()
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: Gap.md),
                          child: _busy
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : Text(t.otpVerify),
                        ),
                      ),
                      const SizedBox(height: Gap.sm),
                      TextButton(
                        key: const Key('otp-resend'),
                        onPressed: (_resendLeft > 0 || _busy)
                            ? null
                            : (_viaEmail ? _sendEmail : _send),
                        child: Text(_resendLeft > 0
                            // qa1: int placeholder printed "60" in the Bangla UI
                            ? t.qa1OtpResendIn(fmtInt(context, _resendLeft))
                            : t.otpResend),
                      ),
                      if (_emailPurpose && _emailAvailable && !_viaEmail)
                        TextButton.icon(
                          key: const Key('otp-email'),
                          icon: const Icon(Icons.email_outlined),
                          onPressed: _busy ? null : _sendEmail,
                          label: Text(t.smsotpEmailInstead,
                              textAlign: TextAlign.center),
                        ),
                      const SizedBox(height: Gap.sm),
                      Text(t.otpNeverShare,
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Honest "SMS codes aren't available yet" state (no gateway connected).
class _SmsOffCard extends StatelessWidget {
  final VoidCallback onClose;
  final VoidCallback? onEmail; // smsotp: null = email codes not offered
  const _SmsOffCard({required this.onClose, this.onEmail});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.sms_failed_rounded, color: scheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(t.otpSmsOffTitle,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSecondaryContainer)),
                  ),
                ]),
                const SizedBox(height: Gap.sm),
                Text(t.otpSmsOffBody,
                    style: TextStyle(color: scheme.onSecondaryContainer)),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        if (onEmail != null) ...[
          FilledButton.icon(
            key: const Key('otp-email-get'),
            onPressed: onEmail,
            icon: const Icon(Icons.email_rounded),
            label: Text(t.smsotpEmailGet),
          ),
          const SizedBox(height: Gap.sm),
        ],
        OutlinedButton(onPressed: onClose, child: Text(t.otpClose)),
      ],
    );
  }
}
