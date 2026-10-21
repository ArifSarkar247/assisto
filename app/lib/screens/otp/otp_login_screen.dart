import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../otp_api.dart';
import '../../state.dart';
import '../../widgets/password_field.dart';
import 'otp_verify_screen.dart';

/// o1-otp — phone entry shared by "Sign in with SMS" and "Reset by SMS".
class _PhoneField extends StatelessWidget {
  final TextEditingController controller;
  final String? errorText;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  const _PhoneField(
      {required this.controller, this.errorText, this.enabled = true, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return TextField(
      key: const Key('otp-phone'),
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.phone,
      autofillHints: const [AutofillHints.telephoneNumber],
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: t.otpPhoneLabel,
        hintText: t.otpPhoneHint,
        prefixIcon: const Icon(Icons.phone_iphone_outlined),
        errorText: errorText,
        errorMaxLines: 3,
      ),
    );
  }
}

OtpBackend _defaultBackend(BuildContext context) =>
    ApiOtpBackend(context.read<AppState>().api);

/// Sign in with a one-time SMS code. Password sign-in stays on LoginScreen.
class OtpLoginScreen extends StatefulWidget {
  final OtpBackend? backend;
  const OtpLoginScreen({super.key, this.backend});

  @override
  State<OtpLoginScreen> createState() => _OtpLoginScreenState();
}

class _OtpLoginScreenState extends State<OtpLoginScreen> {
  final _phone = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final t = AppLocalizations.of(context);
    final phone = _phone.text.trim();
    if (!looksLikeBdMobile(phone)) {
      setState(() => _error = t.otpPhoneInvalid);
      return;
    }
    final backend = widget.backend ?? _defaultBackend(context);
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    setState(() {
      _error = null;
      _busy = true;
    });
    final proof = await OtpVerifyScreen.run(context,
        backend: backend,
        purpose: 'login',
        phone: phone,
        title: t.otpLoginTitle);
    if (!mounted) return;
    if (proof == null) {
      setState(() => _busy = false);
      return;
    }
    final res = await backend.loginWithProof(phone, proof);
    if (!mounted) return;
    if (res == null) {
      setState(() {
        _busy = false;
        _error = t.otpLoginFailed;
      });
      return;
    }
    await app.adoptSession(res.token, res.user);
    if (!mounted) return;
    nav.popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.otpLoginTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.otpLoginIntro, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 20),
                  _PhoneField(
                    controller: _phone,
                    enabled: !_busy,
                    errorText: _error,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const Key('otp-send'),
                    onPressed: _busy ? null : _go,
                    icon: const Icon(Icons.sms_outlined),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(t.otpSendCode),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Forgot password by SMS: phone -> code -> new password.
class OtpResetScreen extends StatefulWidget {
  final OtpBackend? backend;
  const OtpResetScreen({super.key, this.backend});

  @override
  State<OtpResetScreen> createState() => _OtpResetScreenState();
}

class _OtpResetScreenState extends State<OtpResetScreen> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  String? _proof;
  String? _error;
  String? _done;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  OtpBackend get _backend => widget.backend ?? _defaultBackend(context);

  Future<void> _getCode() async {
    final t = AppLocalizations.of(context);
    final phone = _phone.text.trim();
    if (!looksLikeBdMobile(phone)) {
      setState(() => _error = t.otpPhoneInvalid);
      return;
    }
    setState(() => _error = null);
    final proof = await OtpVerifyScreen.run(context,
        backend: _backend,
        purpose: 'password_reset',
        phone: phone,
        title: t.otpResetTitle);
    if (!mounted || proof == null) return;
    setState(() => _proof = proof);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await _backend.resetPassword(_phone.text.trim(), _proof!, _password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _done = t.otpResetDone;
      } else if (r.reason == 'weak_password') {
        _error = r.message.isNotEmpty ? r.message : t.otpErrGeneric;
      } else if (r.reason == 'network') {
        _error = t.otpErrNetwork;
      } else {
        // proof expired / used -> must start again
        _proof = null;
        _error = t.otpResetFailed;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.otpResetTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_done != null) ...[
              Card(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Icon(Icons.check_circle_outline,
                        color: scheme.onSecondaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(_done!,
                            style: TextStyle(color: scheme.onSecondaryContainer))),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                child: Text(t.otpBackToLogin),
              ),
            ] else if (_proof == null) ...[
              Text(t.otpResetIntro, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 20),
              _PhoneField(controller: _phone, errorText: _error),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('otp-send'),
                onPressed: _getCode,
                icon: const Icon(Icons.sms_outlined),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(t.otpSendCode),
                ),
              ),
            ] else ...[
              Row(children: [
                Icon(Icons.verified_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(t.otpVerified)),
              ]),
              const SizedBox(height: 16),
              ObscureTextField(
                key: const Key('otp-new-password'),
                controller: _password,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: t.otpResetNewPassword,
                  errorText: _error,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('otp-save-password'),
                onPressed: _busy ? null : _save,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.otpResetSave),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
