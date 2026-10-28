import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../otp_api.dart';
import '../../theme.dart';
import '../../widgets/otp_code_input.dart';

/// smsotp — "Email for sign-in codes" (Settings). The user adds an email and
/// proves it with a 6-digit code; only a verified email can later receive
/// login / reset codes when an SMS doesn't arrive. Honest off-state when the
/// server can't send email yet. No ads are ever sent to this address.
class EmailVerifyScreen extends StatefulWidget {
  final OtpBackend backend;
  const EmailVerifyScreen({super.key, required this.backend});

  @override
  State<EmailVerifyScreen> createState() => _EmailVerifyScreenState();
}

class _EmailVerifyScreenState extends State<EmailVerifyScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  EmailState? _state;
  bool _busy = false;
  bool _codeSent = false;
  String? _error;
  String? _note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await widget.backend.emailState();
    if (!mounted) return;
    setState(() {
      _state = s;
      if (_email.text.isEmpty) _email.text = s.email;
    });
  }

  String _err(AppLocalizations t, OtpResult r) {
    switch (r.reason) {
      case 'bad_email':
        return t.smsotpEmailInvalid;
      case 'email_not_configured':
        return t.smsotpEmailOff;
      case 'email_daily_cap':
        return t.smsotpEmailCap;
      case 'cooldown':
        return t.otpErrCooldown;
      case 'rate_limited':
        return t.otpErrRateLimited;
      case 'invalid_code':
        final left = r.attemptsLeft;
        return left != null ? t.otpErrInvalid(left) : t.otpErrInvalidPlain;
      case 'expired':
        return t.otpErrExpired;
      case 'locked':
        return t.otpErrLocked(((r.retryAfter ?? 60) / 60).ceil());
      case 'no_active_code':
      case 'bad_otp':
        return t.otpErrNoActive;
      case 'network':
        return t.otpErrNetwork;
      default:
        return t.otpErrGeneric;
    }
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final email = _email.text.trim();
    if (!looksLikeEmail(email)) {
      setState(() => _error = t.smsotpEmailInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    final r = await widget.backend.requestEmail('email_verify', email: email);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok || r.reason == 'cooldown') {
        _codeSent = true;
        _code.clear();
        _note = t.smsotpEmailSentTo(
            r.emailMasked.isNotEmpty ? r.emailMasked : email);
      }
      if (!r.ok) _error = _err(t, r);
    });
  }

  Future<void> _confirm([String? value]) async {
    final t = AppLocalizations.of(context);
    final code = value ?? _code.text;
    if (code.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.backend.confirmEmail(_email.text.trim(), code);
    if (!mounted) return;
    if (r.ok) {
      setState(() {
        _busy = false;
        _codeSent = false;
        _note = null;
        _state = EmailState(
            email: '${r.data['email'] ?? _email.text.trim()}',
            verified: true,
            enabled: _state?.enabled ?? true);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.smsotpEmailDone)));
      return;
    }
    setState(() {
      _busy = false;
      _code.clear();
      _error = _err(t, r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final s = _state;
    return Scaffold(
      appBar: AppBar(title: Text(t.smsotpEmailTitle)),
      body: SafeArea(
        child: s == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(Gap.lg),
                children: [
                  Text(t.smsotpEmailIntro, style: text.bodyMedium),
                  const SizedBox(height: Gap.lg),
                  if (!s.enabled)
                    Card(
                      key: const Key('email-off'),
                      color: scheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.lg),
                        child: Row(children: [
                          Icon(Icons.info_outline_rounded,
                              color: scheme.onSecondaryContainer),
                          const SizedBox(width: Gap.sm),
                          Expanded(
                            child: Text(t.smsotpEmailOff,
                                style: TextStyle(
                                    color: scheme.onSecondaryContainer)),
                          ),
                        ]),
                      ),
                    )
                  else ...[
                    if (s.email.isNotEmpty)
                      Semantics(
                        container: true,
                        label: '${s.email}, ${s.verified ? t.smsotpEmailVerified : t.smsotpEmailNotVerified}',
                        excludeSemantics: true,
                        child: ListTile(
                          key: const Key('email-status'),
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                              s.verified
                                  ? Icons.verified_rounded
                                  : Icons.mark_email_unread_rounded,
                              color: s.verified ? scheme.primary : scheme.outline),
                          title: Text(s.email,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(s.verified
                              ? t.smsotpEmailVerified
                              : t.smsotpEmailNotVerified),
                        ),
                      ),
                    const SizedBox(height: Gap.sm),
                    TextField(
                      key: const Key('email-field'),
                      controller: _email,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _send(),
                      onChanged: (_) => setState(() {
                        _codeSent = false;
                        _error = null;
                      }),
                      decoration: InputDecoration(
                        labelText: t.smsotpEmailLabel,
                        prefixIcon: const Icon(Icons.email_outlined),
                      ),
                    ),
                    const SizedBox(height: Gap.md),
                    FilledButton(
                      key: const Key('email-send'),
                      onPressed: _busy ? null : _send,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.md),
                        child: Text(_codeSent ? t.otpResend : t.smsotpEmailSend),
                      ),
                    ),
                    if (_note != null) ...[
                      const SizedBox(height: Gap.md),
                      Text(_note!,
                          key: const Key('email-note'),
                          textAlign: TextAlign.center,
                          style: text.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                    if (_codeSent) ...[
                      const SizedBox(height: Gap.lg),
                      Text(t.smsotpEmailCodeHint,
                          textAlign: TextAlign.center, style: text.titleSmall),
                      const SizedBox(height: Gap.md),
                      OtpCodeInput(
                        controller: _code,
                        enabled: !_busy,
                        hasError: _error != null,
                        semanticsLabel: t.otpCodeFieldLabel,
                        onChanged: (_) => setState(() => _error = null),
                        onCompleted: _confirm,
                      ),
                      const SizedBox(height: Gap.md),
                      FilledButton.tonal(
                        key: const Key('email-verify'),
                        onPressed: (!_busy && _code.text.length == 6)
                            ? () => _confirm()
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: Gap.md),
                          child: Text(t.smsotpEmailVerify),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: Gap.md),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline_rounded,
                              size: 18, color: scheme.error),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(_error!,
                                key: const Key('email-error'),
                                style: TextStyle(color: scheme.error)),
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
      ),
    );
  }
}
