import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';

/// Password reset — confirm step (launch gap A). Opened from the one-time link
/// in the reset email, carrying the raw token. The user sets a new password;
/// the backend validates the token (hashed, single-use, short expiry) and,
/// deliberately, reports only a single "invalid or expired" message for any
/// token failure so attackers learn nothing.
class PasswordResetConfirmScreen extends StatefulWidget {
  final String token;
  const PasswordResetConfirmScreen({super.key, required this.token});
  @override
  State<PasswordResetConfirmScreen> createState() =>
      _PasswordResetConfirmScreenState();
}

class _PasswordResetConfirmScreenState
    extends State<PasswordResetConfirmScreen> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final pw = _pw.text;
    if (pw.length < 8) {
      setState(() => _error = t.resetPasswordTooShort);
      return;
    }
    if (pw != _pw2.text) {
      setState(() => _error = t.resetPasswordMismatch);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context
          .read<AppState>()
          .api
          .confirmPasswordReset(widget.token, pw);
      setState(() => _done = true);
    } catch (_) {
      // Single collapsed failure message (used/expired/invalid all look alike).
      setState(() => _error = t.resetLinkInvalid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.resetSetNewTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_done) ...[
            Card(
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Icon(Icons.check_circle_outline,
                      color: scheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(t.resetDoneMessage,
                        style:
                            TextStyle(color: scheme.onSecondaryContainer)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
                child: Text(t.resetBackToLogin),
              ),
            ),
          ] else ...[
            Text(t.resetSetNewIntro, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 16),
            TextField(
              controller: _pw,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: t.resetNewPassword,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pw2,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: t.resetConfirmPassword,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 8),
            Text(t.resetPasswordHint,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.lock_reset_outlined),
                label: Text(t.resetSetNewTitle),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
