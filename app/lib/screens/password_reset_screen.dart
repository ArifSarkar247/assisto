import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/reset_options.dart';
import 'password_reset_confirm_screen.dart';
import '../otp_api.dart';
import 'otp/otp_login_screen.dart';
import '../theme.dart';

/// Password reset — request step (SPEC v2.1 §21, account recovery ADVANCED).
///
/// ADVANCED upgrades over the old single-field screen:
///  - Recovery CHANNEL chooser: EMAIL works now; SMS code recovery is 🔑
///    key-gated (shown honestly as "available when an SMS gateway is added");
///    security-question recovery is listed honestly as opt-in / not configured.
///  - Honest RATE-LIMIT handling: a 429 from the reset scope (6/min) surfaces a
///    "too many attempts, wait a minute" banner instead of a silent failure.
///  - Anti-enumeration preserved: success ALWAYS shows the same neutral message
///    whether or not an account exists, and offers an "I already have a code"
///    path to the confirm screen.
///  - Full §21 states: empty (chooser), loading (spinner), error (rate-limit /
///    generic), neutral-sent success. Bilingual via ARB; zero Bangla here.
class PasswordResetScreen extends StatefulWidget {
  /// o1-otp: injectable for widget tests; defaults to the real API.
  final OtpBackend? otpBackend;
  const PasswordResetScreen({super.key, this.otpBackend});
  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _email = TextEditingController();
  RecoveryChannel _channel = RecoveryChannel.email;
  bool _sending = false;
  bool _rateLimited = false;
  String? _emailError;
  String? _neutralMessage; // shown after submit (same regardless of existence)
  bool _smsReady = false; // o1-otp: SMS gateway connected -> SMS reset works

  @override
  void initState() {
    super.initState();
    _loadOtpStatus();
  }

  OtpBackend get _otp =>
      widget.otpBackend ?? ApiOtpBackend(context.read<AppState>().api);

  Future<void> _loadOtpStatus() async {
    try {
      final st = await _otp.status();
      if (mounted && st.smsEnabled) setState(() => _smsReady = true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  bool _looksLikeEmail(String s) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _emailError = t.resetEmailRequired);
      return;
    }
    if (!_looksLikeEmail(email)) {
      setState(() => _emailError = t.resetEmailInvalid);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _rateLimited = false;
      _emailError = null;
    });
    try {
      final r = await context.read<AppState>().api.requestPasswordReset(email);
      setState(() =>
          _neutralMessage = (r['message'] as String?) ?? t.resetNeutralSent);
    } on ApiException catch (e) {
      if (e.status == 429) {
        // Honest: the server throttled us. Do NOT retry silently.
        setState(() => _rateLimited = true);
      } else {
        // Any other failure still collapses to the neutral message so we never
        // leak whether the account exists or whether sending failed.
        setState(() => _neutralMessage = t.resetNeutralSent);
      }
    } catch (_) {
      setState(() => _neutralMessage = t.resetNeutralSent);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.resetTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text(t.resetIntro, style: AType.bodyMedium),
          const SizedBox(height: Gap.lg),

          // ---- success (neutral, anti-enumeration) ----
          if (_neutralMessage != null) ...[
            Card(
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Icon(Icons.mark_email_read_outlined,
                      color: scheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_neutralMessage!,
                        style: TextStyle(color: scheme.onSecondaryContainer)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.md),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PasswordResetConfirmScreen(token: ''))),
              icon: const Icon(Icons.vpn_key_outlined),
              label: Text(t.resetHaveCode),
            ),
          ] else ...[
            // ---- rate-limit banner (honest 429) ----
            if (_rateLimited) ...[
              const ResetRateLimitBanner(),
              const SizedBox(height: Gap.md),
            ],

            // ---- channel chooser ----
            Text(t.resetChooseChannel,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.sm),
            ResetChannelTile(
              channel: RecoveryChannel.email,
              available: true,
              selected: _channel == RecoveryChannel.email,
              onTap: () => setState(() => _channel = RecoveryChannel.email),
            ),
            // NO SHOWPIECES: SMS reset is listed only once the owner has
            // connected an SMS gateway; the security-question channel has no
            // setup flow yet, so it is not listed at all (no locked rows).
            if (_smsReady)
              ResetChannelTile(
                key: const Key('reset-sms-tile'),
                channel: RecoveryChannel.sms,
                available: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => OtpResetScreen(backend: widget.otpBackend))),
              ),
            const SizedBox(height: Gap.lg),

            // ---- email entry (the one working channel) ----
            TextField(
              controller: _email,
              enabled: !_sending,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              onChanged: (_) {
                if (_emailError != null) setState(() => _emailError = null);
              },
              decoration: InputDecoration(
                labelText: t.resetEmailLabel,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.email_outlined),
                errorText: _emailError,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _sending ? null : _submit,
                icon: _sending
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_outlined),
                label: Text(_sending ? t.resetSending : t.resetSendLink),
              ),
            ),
            const SizedBox(height: Gap.sm),
            // "I already have a code/link" shortcut into the confirm screen.
            TextButton.icon(
              onPressed: _sending
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          const PasswordResetConfirmScreen(token: ''))),
              icon: const Icon(Icons.vpn_key_outlined),
              label: Text(t.resetHaveCode),
            ),
          ],

          const SizedBox(height: 20),
          Text(t.resetSecurityNote,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
