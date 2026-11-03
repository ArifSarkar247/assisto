import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../api.dart' show ApiException; // framebar
import '../l10n/app_localizations.dart';
import '../widgets/password_field.dart';
import 'password_reset_screen.dart';
import '../otp_api.dart';
import '../services/phone_canon.dart';
import 'otp/otp_login_screen.dart';
import 'otp/otp_verify_screen.dart';
import 'account_standing_screen.dart'; // adminsafe
import '../widgets/robo_id.dart';

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

  /// framebar: which one-time-code sign-in the server can do right now
  /// (SMS / email / none) — decides the honest button under the form.
  OtpStatus? _otp;

  @override
  void initState() {
    super.initState();
    _loadOtp();
  }

  Future<void> _loadOtp() async {
    try {
      final b = widget.otpBackend ?? ApiOtpBackend(context.read<AppState>().api);
      final st = await b.status();
      if (mounted) setState(() => _otp = st);
    } catch (_) {}
  }

  /// framebar: never show a raw Dart/HTTP error (English, even in Bangla
  /// mode). Server errors carry the server's localized text; anything else
  /// is a connection problem.
  String _errorText(Object e) {
    final t = AppLocalizations.of(context);
    if (e is String) return e;
    if (e is ApiException) {
      return e.message.trim().isEmpty ? t.qaActionFailed : e.message;
    }
    return t.otpErrNetwork;
  }

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
        // probashi-otp: SMS reaches Bangladeshi mobiles only. A valid number
        // abroad (+966, +44, ...) signs up with the password (the server
        // allows it while password-only sign-up is ON); it is never sent to
        // the BD SMS check, which would wrongly call it invalid.
        final abroad = phone.isNotEmpty &&
            !looksLikeBdMobile(phone) &&
            PhoneCanon.canonical(phone) != null;
        if (abroad && !st.passwordOnlySignup) throw t.otpPhoneInvalid;
        if (st.smsEnabled && phone.isNotEmpty && !abroad) {
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
      if (mounted) setState(() => _error = _errorText(e));
      // adminsafe: suspended / banned -> show the reason + appeal (no session)
      if (mounted && e is ApiException && e.reason == 'account_blocked' &&
          e.body?['appeal_token'] is String) {
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AccountStandingScreen(blockedBody: e.body)));
      }
      // offline at first paint: the OTP button may have been hidden
      if (_otp == null || (!_otp!.smsEnabled && !_otp!.emailEnabled)) {
        _loadOtp();
      }
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
                    // tl1: identifiers = Android resource-ids for Test Lab Robo.
                    RoboId(id: 'tl_login_id',
                      child: TextField(
                        controller: _identifier,
                        decoration: InputDecoration(labelText: t.phoneOrEmail),
                      ),
                    ),
                  const SizedBox(height: 12),
                  RoboId(id: 'tl_login_password',
                    child: ObscureTextField(
                      controller: _password,
                      decoration: InputDecoration(labelText: t.password),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(_error!,
                          key: const Key('login-error'),
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  RoboId(id: 'tl_login_submit',
                    child: FilledButton(
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
                  // framebar: honest one-time-code sign-in — SMS only when
                  // the gateway is live; email codes when SMS is off; no
                  // button at all when neither can send (never a dead end).
                  if (!_register && (_otp?.smsEnabled ?? false))
                    TextButton.icon(
                      key: const Key('login-with-sms'),
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  OtpLoginScreen(backend: widget.otpBackend))),
                      icon: const Icon(Icons.sms_rounded, size: 18),
                      label: Text(t.otpLoginWithSms),
                    )
                  else if (!_register && (_otp?.emailEnabled ?? false))
                    TextButton.icon(
                      key: const Key('login-with-email-code'),
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => OtpLoginScreen(
                                  backend: widget.otpBackend,
                                  emailMode: true))),
                      icon: const Icon(Icons.email_rounded, size: 18),
                      label: Text(t.fbLoginWithEmailCode),
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
