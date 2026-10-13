import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';

/// Password reset — request step (launch gap A). The user enters the email on
/// their account; the backend sends a reset link. To avoid user-enumeration
/// leaks, the screen ALWAYS shows the same neutral confirmation whether or not
/// an account exists — it never reveals "no such user".
///
/// SMS reset is designed but gated off until an SMS gateway is connected:
/// the screen shows an "Available when SMS gateway added" note instead of a
/// working SMS option.
class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key});
  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _email = TextEditingController();
  bool _sending = false;
  String? _neutralMessage; // shown after submit (same regardless of existence)

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    final t = AppLocalizations.of(context);
    try {
      final r = await context.read<AppState>().api.requestPasswordReset(email);
      // Backend returns a neutral message; fall back to a local neutral string.
      setState(() => _neutralMessage =
          (r['message'] as String?) ?? t.resetNeutralSent);
    } catch (_) {
      // Even on error we show the SAME neutral message — never leak whether
      // the account exists or whether sending failed.
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
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.resetIntro, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 16),
          if (_neutralMessage != null)
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
            )
          else ...[
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: t.resetEmailLabel,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.email_outlined),
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
                label: Text(t.resetSendLink),
              ),
            ),
          ],
          const SizedBox(height: 20),
          // SMS reset — key-gated until an SMS gateway is connected.
          Card(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                const Icon(Icons.sms_outlined),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(t.resetSmsUnavailable,
                        style: const TextStyle(fontSize: 13))),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Text(t.resetSecurityNote,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
