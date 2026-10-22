import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models.dart';
import '../otp_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/password_field.dart';
import 'otp/otp_verify_screen.dart';

/// dl1: shown right after a sign-in when the account has a PENDING deletion
/// (inside the 7-day grace period). Two honest choices:
///
///   * "Restore account" — cancels the deletion (POST account/delete/cancel)
///     and continues into the app with everything intact.
///   * "Delete now and start fresh" — a second, explicit step: password, an
///     SMS code when SMS is connected (said plainly when it is not), and the
///     typed word DELETE. The server purges the old account immediately (the
///     same purge the hourly clean-up uses) and returns a new, empty account
///     for the same number, which the app adopts.
///
/// A quiet third option signs out and leaves the deletion scheduled.
class DeletionGraceScreen extends StatefulWidget {
  /// Injectable for widget tests; defaults to the real OTP API.
  final OtpBackend? otpBackend;

  /// Open directly on the "Delete now and start fresh" confirmation step
  /// (used by the review gallery; the app always starts on the two choices).
  final bool startOnFreshStep;
  const DeletionGraceScreen(
      {super.key, this.otpBackend, this.startOnFreshStep = false});

  @override
  State<DeletionGraceScreen> createState() => _DeletionGraceScreenState();
}

class _DeletionGraceScreenState extends State<DeletionGraceScreen> {
  late bool _confirming = widget.startOnFreshStep; // true = start-fresh step
  bool _busy = false;
  String? _error;
  String? _otpProof;
  final _password = TextEditingController();
  final _typed = TextEditingController();

  /// The word to type. The server accepts "DELETE" (and the Bangla word), so
  /// it works on any keyboard.
  static const confirmWord = 'DELETE';

  @override
  void dispose() {
    _password.dispose();
    _typed.dispose();
    super.dispose();
  }

  AppState get _app => context.read<AppState>();

  String _when(DateTime? dt) {
    if (dt == null) return '';
    final locale = Localizations.localeOf(context).toLanguageTag();
    return DateFormat.yMMMMd(locale).format(dt);
  }

  Future<void> _restore() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _app.api.accountDeleteCancel();
      if (!mounted) return;
      if (r['ok'] == true || '${r['state']}' == 'cancelled') {
        messenger?.showSnackBar(SnackBar(content: Text(t.dlGraceRestored)));
        _app.clearDeletionGrace();
        return;
      }
      setState(() {
        _busy = false;
        _error = t.delAcctRequestError;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.delAcctRequestError;
      });
    }
  }

  bool get _canDelete =>
      _password.text.isNotEmpty &&
      _typed.text.trim().toUpperCase() == confirmWord;

  Future<void> _startFresh() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    Map<String, dynamic> r;
    try {
      r = await _app.api.accountStartFresh(
          password: _password.text,
          confirmText: _typed.text.trim(),
          otpProof: _otpProof);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.delAcctRequestError;
      });
      return;
    }
    if (!mounted) return;
    final reason = '${r['reason'] ?? ''}';
    final status = r['_status'] as int?;

    if (reason == 'otp_required' || (reason == 'bad_otp' && _otpProof != null)) {
      _otpProof = null;
      final proof = await OtpVerifyScreen.run(context,
          backend: widget.otpBackend ?? ApiOtpBackend(_app.api),
          purpose: 'delete_account',
          title: t.otpDeleteTitle,
          intro: t.otpDeleteIntro);
      if (!mounted) return;
      if (proof == null) {
        setState(() => _busy = false);
        return;
      }
      _otpProof = proof;
      return _startFresh();
    }

    if (status == null && r['token'] is String && r['user'] is Map) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      final fresh =
          AppUser.fromJson((r['user'] as Map).cast<String, dynamic>());
      await _app.adoptFreshAccount(r['token'] as String, fresh);
      messenger?.showSnackBar(SnackBar(content: Text(t.dlGraceFreshDone)));
      return;
    }

    String msg;
    if (status == 423 || '${r['state']}' == 'blocked') {
      msg = t.delAcctBlockedTheft;
    } else if (reason == 'bad_password') {
      msg = t.delAcctBadPassword;
    } else if (reason == 'bad_otp') {
      msg = t.delAcctBadOtp;
    } else if (reason == 'no_pending') {
      // Already cancelled elsewhere — nothing to delete; continue normally.
      _app.clearDeletionGrace();
      return;
    } else {
      msg = t.delAcctRequestError;
    }
    setState(() {
      _busy = false;
      _error = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: _confirming ? _freshStep(t) : _choices(t),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(IconData icon, Color tint, String title, String body) {
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 36, color: tint),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(title,
            textAlign: TextAlign.center,
            style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(body, textAlign: TextAlign.center, style: tt.bodyLarge),
      ],
    );
  }

  Widget _errorBox(String msg) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 18),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(msg, style: TextStyle(color: scheme.onErrorContainer))),
      ]),
    );
  }

  Widget _choices(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      key: const Key('dl-grace-choices'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(Icons.event_busy_outlined, Brand.warnInk(context),
            t.dlGraceTitle, t.dlGraceBody(_when(_app.deletionGraceAt))),
        const SizedBox(height: Gap.xl),
        // Choice 1 — Restore (the safe, primary choice).
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.dlGraceRestoreHint, style: tt.bodyMedium),
                const SizedBox(height: Gap.md),
                FilledButton.icon(
                  key: const Key('dl-grace-restore'),
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.restore),
                  label: Text(t.dlGraceRestore),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        // Choice 2 — Delete now and start fresh (explicit second step).
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.dlGraceFreshHint, style: tt.bodyMedium),
                const SizedBox(height: Gap.md),
                OutlinedButton.icon(
                  key: const Key('dl-grace-fresh'),
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _error = null;
                            _confirming = true;
                          }),
                  icon: Icon(Icons.delete_forever_outlined, color: scheme.error),
                  label: Text(t.dlGraceFresh,
                      style: TextStyle(color: scheme.error)),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      side: BorderSide(color: scheme.error)),
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: Gap.md),
          _errorBox(_error!),
        ],
        const SizedBox(height: Gap.lg),
        TextButton(
          onPressed: _busy ? null : () => _app.logout(),
          child: Text(t.dlGraceSignOut, textAlign: TextAlign.center),
        ),
      ],
    );
  }

  Widget _freshStep(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      key: const Key('dl-grace-confirm'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(Icons.delete_forever_outlined, scheme.error, t.dlGraceFreshTitle,
            t.dlGraceFreshBody),
        const SizedBox(height: Gap.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.sms_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                  _app.deletionGraceOtp ? t.dlGraceOtpOn : t.dlGraceOtpOff,
                  key: const Key('dl-grace-otp-note'),
                  style: tt.bodySmall),
            ),
          ],
        ),
        const SizedBox(height: Gap.lg),
        ObscureTextField(
          key: const Key('dl-grace-password'),
          controller: _password,
          autofillHints: const [AutofillHints.password],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: t.dlGracePasswordLabel,
            prefixIcon: const Icon(Icons.key_outlined),
          ),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          key: const Key('dl-grace-typed'),
          controller: _typed,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: t.dlGraceTypeToConfirm(confirmWord),
            prefixIcon: const Icon(Icons.keyboard_outlined),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: Gap.md),
          _errorBox(_error!),
        ],
        const SizedBox(height: Gap.xl),
        FilledButton(
          key: const Key('dl-grace-fresh-go'),
          style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              minimumSize: const Size.fromHeight(52)),
          onPressed: _busy || !_canDelete ? null : _startFresh,
          child: _busy
              ? SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: scheme.onError))
              : Text(t.dlGraceFreshButton, textAlign: TextAlign.center),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _error = null;
                    _confirming = false;
                  }),
          child: Text(t.delAcctBack),
        ),
      ],
    );
  }
}
