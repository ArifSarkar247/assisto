import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/password_field.dart';
import 'password_reset_screen.dart';
import '../otp_api.dart';
import 'otp/otp_login_screen.dart';
import 'otp/otp_verify_screen.dart';

class LoginScreen extends StatefulWidget {
  /// o1-otp: injectable for widget tests; defaults to the real API.
  final OtpBackend? otpBackend;
  const LoginScreen({super.key, this.otpBackend});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _register = false;
  bool _busy = false;
  String? _error;

  final _name = TextEditingController();
  final _identifier = TextEditingController(); // phone or email (login)
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _identifier.dispose();
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.read<AppState>();
    try {
      if (_register) {
        final t = AppLocalizations.of(context);
        final phone = _phone.text.trim();
        if (phone.isEmpty && _email.text.trim().isEmpty) {
          throw t.needPhoneOrEmail;
        }
        // o1-otp: verify the phone by SMS when a gateway is connected; when
        // the launch gate is closed (password-only sign-up OFF) it's required.
        final otpB = widget.otpBackend ?? ApiOtpBackend(app.api);
        final st = await otpB.status();
        if (!mounted) return;
        String? proof;
        if (st.smsEnabled && phone.isNotEmpty) {
          if (!looksLikeBdMobile(phone)) throw t.otpPhoneInvalid;
          proof = await OtpVerifyScreen.run(context,
              backend: otpB,
              purpose: 'signup',
              phone: phone,
              title: t.otpSignupVerifyTitle);
          if (proof == null) return; // backed out — no error
        } else if (!st.passwordOnlySignup) {
          throw st.smsEnabled ? t.otpSignupNeedPhone : t.otpSignupUnavailable;
        }
        await app.register(
          name: _name.text.trim(),
          phone: phone,
          email: _email.text.trim(),
          password: _password.text,
          otpProof: proof,
        );
      } else {
        await app.login(
          identifier: _identifier.text.trim(),
          password: _password.text,
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(26),
                      child: Image.asset('assets/branding/new_logo.png',
                          width: 104, height: 104, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Assisto',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(t.loginMotto, textAlign: TextAlign.center),
                  const SizedBox(height: 28),
                  Text(_register ? t.register : t.login,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  if (_register) ...[
                    TextField(
                      controller: _name,
                      decoration: InputDecoration(labelText: t.name),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(labelText: t.phoneOptional),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(labelText: t.emailOptional),
                    ),
                  ] else
                    TextField(
                      controller: _identifier,
                      decoration: InputDecoration(labelText: t.phoneOrEmail),
                    ),
                  const SizedBox(height: 12),
                  ObscureTextField(
                    controller: _password,
                    decoration: InputDecoration(labelText: t.password),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_register ? t.register : t.login),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _register = !_register;
                              _error = null;
                            }),
                    child: Text(_register ? t.haveAccount : t.noAccount),
                  ),
                  if (!_register)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const PasswordResetScreen())),
                      child: Text(t.resetForgotLink),
                    ),
                  if (!_register)
                    TextButton.icon(
                      key: const Key('login-with-sms'),
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  OtpLoginScreen(backend: widget.otpBackend))),
                      icon: const Icon(Icons.sms_outlined, size: 18),
                      label: Text(t.otpLoginWithSms),
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
