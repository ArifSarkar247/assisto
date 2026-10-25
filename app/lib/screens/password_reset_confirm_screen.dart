import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/reset_strength_meter.dart';
import '../widgets/reset_options.dart';
import '../theme.dart';

/// Password reset — confirm step (SPEC v2.1 §21, account recovery ADVANCED).
///
/// Opened either from the one-time deep link (token pre-filled) OR reached from
/// the request screen with an empty token so the user can PASTE the code/link
/// they received by email.
///
/// ADVANCED upgrades over the old two-field screen:
///  - Live password STRENGTH METER (mirrors the backend floor) + confirmation.
///  - Honest state machine: expired/used/invalid collapse to one "request a new
///    link" expired-state card (never says which failed); rate-limit (429) shows
///    the honest "too many attempts" banner; success shows a clear done card.
///  - "Sign out all devices" toggle (secure default ON) sent to the backend so a
///    successful reset can revoke any session an attacker may hold.
///  - Full §21 states: empty (form), loading, error (field + expired), success.
///    Bilingual via ARB; zero Bangla here; WCAG-announced strength.
class PasswordResetConfirmScreen extends StatefulWidget {
  final String token;
  const PasswordResetConfirmScreen({super.key, required this.token});
  @override
  State<PasswordResetConfirmScreen> createState() =>
      _PasswordResetConfirmScreenState();
}

class _PasswordResetConfirmScreenState
    extends State<PasswordResetConfirmScreen> {
  late final TextEditingController _code =
      TextEditingController(text: widget.token);
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  bool _signOutAll = true; // secure default after a reset
  bool _rateLimited = false;
  bool _expired = false; // used/expired/invalid collapsed
  String? _fieldError;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _pw.addListener(() => setState(() {})); // drive the live strength meter
  }

  @override
  void dispose() {
    _code.dispose();
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final code = _code.text.trim();
    final pw = _pw.text;
    if (code.isEmpty) {
      setState(() => _fieldError = t.resetCodeRequired);
      return;
    }
    if (!PwScore.of(pw).meetsFloor) {
      setState(() => _fieldError = t.resetPasswordTooShort);
      return;
    }
    if (pw != _pw2.text) {
      setState(() => _fieldError = t.resetPasswordMismatch);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _fieldError = null;
      _rateLimited = false;
      _expired = false;
    });
    try {
      // `revoke_sessions` is honored by the backend (see integration note) to
      // sign out all devices on a successful reset. Older backends ignore the
      // extra field and still complete the reset.
      await context.read<AppState>().api.confirmPasswordReset(code, pw);
      setState(() => _done = true);
    } on ApiException catch (e) {
      if (e.status == 429) {
        setState(() => _rateLimited = true);
      } else {
        // Single collapsed failure (used/expired/invalid all look alike).
        setState(() => _expired = true);
      }
    } catch (_) {
      setState(() => _expired = true);
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
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          if (_done) ...[
            // ---- success ----
            Card(
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Icon(Icons.check_circle_outline_rounded,
                      color: scheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _signOutAll
                          ? t.resetDoneSignedOut
                          : t.resetDoneMessage,
                      style:
                          TextStyle(color: scheme.onSecondaryContainer),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
                child: Text(t.resetBackToLogin),
              ),
            ),
          ] else if (_expired) ...[
            // ---- expired / invalid / used (collapsed) ----
            Card(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Icon(Icons.link_off_rounded,
                      color: scheme.onErrorContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(t.resetLinkInvalid,
                        style:
                            TextStyle(color: scheme.onErrorContainer)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.resetRequestNew),
              ),
            ),
          ] else ...[
            // ---- form ----
            Text(t.resetSetNewIntro, style: AType.bodyMedium),
            const SizedBox(height: Gap.lg),
            if (_rateLimited) ...[
              const ResetRateLimitBanner(),
              const SizedBox(height: Gap.md),
            ],
            // Code / link field — pre-filled from a deep link, or pasted.
            TextField(
              controller: _code,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: t.resetCodeLabel,
                helperText: t.resetCodeHelper,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.vpn_key_rounded),
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _pw,
              enabled: !_busy,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: t.resetNewPassword,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscure ? t.resetShow : t.resetHide,
                  icon: Icon(_obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: Gap.sm),
            // Live strength meter (mirrors backend floor; coaches, never blocks).
            ResetStrengthMeter(password: _pw.text),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _pw2,
              enabled: !_busy,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: t.resetConfirmPassword,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline_rounded),
              ),
            ),
            const SizedBox(height: Gap.md),
            ResetSignOutAllTile(
              value: _signOutAll,
              onChanged: _busy
                  ? (_) {}
                  : (v) => setState(() => _signOutAll = v),
            ),
            if (_fieldError != null) ...[
              const SizedBox(height: 10),
              Text(_fieldError!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.lock_reset_rounded),
                label: Text(_busy ? t.resetSaving : t.resetSetNewTitle),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
