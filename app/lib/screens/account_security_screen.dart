import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../account_security_api.dart';
import '../l10n/app_localizations.dart';
import '../otp_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/password_field.dart';
import 'otp/email_verify_screen.dart';

/// recovery (owner order Part 8) — Settings → Account & security.
///
/// Phone (verified mark), email (or none) with Add / Change, an honest note
/// that Google sign-in does not exist in Assisto yet (no dead button),
/// change password (signs every other device out), the signed-in devices
/// with Sign out (one / all others), "someone asked to recover your
/// account — this was not me" and "your family member asks you to confirm".
class AccountSecurityScreen extends StatefulWidget {
  final AccountSecurityBackend? backend;
  final OtpBackend? otpBackend;

  /// Called with a fresh token when the server rotated this phone's session
  /// (password change / sign out others from an older-build token).
  final ValueChanged<String>? onToken;
  const AccountSecurityScreen({super.key, this.backend, this.otpBackend, this.onToken});

  @override
  State<AccountSecurityScreen> createState() => _AccountSecurityScreenState();
}

/// Bangla digits in a Bangla UI (phone numbers, codes, dates).
String recDigits(BuildContext context, String s) {
  if (Localizations.localeOf(context).languageCode != 'bn') return s;
  // U+09E6 = Bengali digit zero (no Bangla literals in Dart: lang gate)
  return s.replaceAllMapped(
      RegExp(r'[0-9]'), (m) => String.fromCharCode(0x09E6 + int.parse(m[0]!)));
}

String recWhen(BuildContext context, DateTime? d) {
  if (d == null) return '';
  final loc = Localizations.localeOf(context).languageCode;
  return recDigits(context, DateFormat('d MMM, h:mm a', loc).format(d.toLocal()));
}

class _AccountSecurityScreenState extends State<AccountSecurityScreen> {
  AccountSecurity? _s;
  bool _loading = true;
  bool _busy = false;

  AccountSecurityBackend get _b =>
      widget.backend ?? ApiAccountSecurityBackend(context.read<AppState>().api);
  OtpBackend get _otp =>
      widget.otpBackend ?? ApiOtpBackend(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = await _b.load();
    if (!mounted) return;
    setState(() {
      _s = s;
      _loading = false;
    });
  }

  void _token(String? t) {
    if (t == null || t.isEmpty) return;
    final f = widget.onToken;
    if (f != null) {
      f(t);
    } else {
      context.read<AppState>().replaceToken(t);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              key: const Key('rec-confirm-yes'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(yes, softWrap: true)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _signOut(SignedInDevice d) async {
    final t = AppLocalizations.of(context);
    if (!await _confirm(t.acsecSignOutTitle, t.acsecSignOutBody, t.acsecSignOut)) return;
    setState(() => _busy = true);
    final r = await _b.signOutDevice(d.id);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(r.ok ? t.acsecSignedOut : (r.message.isNotEmpty ? r.message : t.otpErrGeneric));
    await _load();
  }

  Future<void> _signOutOthers() async {
    final t = AppLocalizations.of(context);
    if (!await _confirm(t.acsecSignOutOthers, t.acsecSignOutOthersBody, t.acsecSignOut)) return;
    setState(() => _busy = true);
    final r = await _b.signOutOthers();
    if (!mounted) return;
    setState(() => _busy = false);
    _token(r.data['token'] as String?);
    _snack(r.ok ? t.acsecSignedOutOthers : (r.message.isNotEmpty ? r.message : t.otpErrGeneric));
    await _load();
  }

  Future<void> _email() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => EmailVerifyScreen(backend: _otp)));
    if (mounted) await _load();
  }

  Future<void> _password() async {
    final s = _s;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ChangePasswordScreen(
            backend: _b, hasPassword: s?.hasPassword ?? true, onToken: _token)));
    if (changed == true && mounted) await _load();
  }

  Future<void> _cancelRecovery(RecoveryAsk a) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    final r = await _b.cancelRecovery(a.id);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(r.ok ? t.acsecCancelled : (r.message.isNotEmpty ? r.message : t.otpErrGeneric));
    await _load();
  }

  Future<void> _family(RecoveryAsk a, bool yes) async {
    final t = AppLocalizations.of(context);
    if (!yes || await _confirm(t.acsecFamilyYesTitle, t.acsecFamilyYesBody, t.acsecFamilyYes)) {
      setState(() => _busy = true);
      final r = await _b.familyDecide(a.id, yes);
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(r.ok ? t.acsecFamilyThanks : (r.message.isNotEmpty ? r.message : t.otpErrGeneric));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _s;
    Widget body;
    if (_loading && s == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (s == null) {
      body = ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          const SizedBox(height: Gap.xl),
          Icon(Icons.cloud_off_rounded, size: 48, color: scheme.outline),
          const SizedBox(height: Gap.md),
          Text(t.acsecLoadFail, textAlign: TextAlign.center, style: AType.bodyLarge),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
              key: const Key('rec-retry'),
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.retry)),
        ],
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          key: const Key('rec-list'),
          padding: withNavBarInset(context, const EdgeInsets.symmetric(vertical: Gap.md)),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Text(t.acsecIntro,
                  style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
            ),
            for (final a in s.myRecoveryRequests) _ownerAlert(context, a),
            for (final a in s.familyRequests) _familyAsk(context, a),
            if (s.blockedReason.isNotEmpty)
              _note(context, Icons.lock_clock_rounded,
                  s.blockedReason == 'identity_locked' ? t.acsecLocked : t.acsecCooldown),
            _header(context, t.acsecSignInSection),
            ListTile(
              key: const Key('rec-phone'),
              leading: const Icon(Icons.phone_iphone_rounded),
              title: Text(s.phone.isEmpty ? t.acsecNoPhone : recDigits(context, s.phone)),
              subtitle: Text(s.phoneVerified ? t.acsecVerified : t.acsecNotVerified),
              trailing: s.phoneVerified
                  ? Icon(Icons.verified_rounded, color: scheme.primary,
                      semanticLabel: t.acsecVerified)
                  : null,
            ),
            ListTile(
              key: const Key('rec-email'),
              leading: const Icon(Icons.alternate_email_rounded),
              title: Text(s.email.isEmpty ? t.acsecNoEmail : s.email,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.email.isEmpty
                  ? t.acsecAddEmailWhy
                  : (s.emailVerified ? t.acsecVerified : t.acsecNotVerified)),
              trailing: s.emailVerified
                  ? Icon(Icons.verified_rounded, color: scheme.primary,
                      semanticLabel: t.acsecVerified)
                  : null,
              onTap: _email,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: const Key('rec-email-btn'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy ? null : _email,
                  icon: Icon(s.email.isEmpty ? Icons.add_rounded : Icons.edit_rounded),
                  label: Text(s.email.isEmpty || !s.emailVerified
                      ? t.acsecAddEmail
                      : t.acsecChangeEmail),
                ),
              ),
            ),
            // Honest: Assisto has no Google sign-in, so no Google button.
            if (!s.googleAvailable)
              ListTile(
                key: const Key('rec-google-note'),
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(t.acsecGoogleNote,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ListTile(
              key: const Key('rec-password'),
              leading: const Icon(Icons.password_rounded),
              title: Text(s.hasPassword ? t.acsecChangePassword : t.acsecSetPassword),
              subtitle: Text(t.acsecPasswordSub),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : _password,
            ),
            const Divider(),
            _header(context, t.acsecDevicesTitle(recDigits(context, '${s.devices.length}'))),
            if (s.devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                child: Text(t.acsecNoDevices),
              ),
            for (final d in s.devices) _device(context, d),
            if (s.devices.where((d) => !d.current).isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
                child: OutlinedButton.icon(
                  key: const Key('rec-signout-others'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48), foregroundColor: scheme.error),
                  onPressed: _busy ? null : _signOutOthers,
                  icon: const Icon(Icons.logout_rounded),
                  label: Text(t.acsecSignOutOthers, textAlign: TextAlign.center),
                ),
              ),
            const Divider(),
            _header(context, t.acsecLostTitle),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Text(t.acsecLostBody, style: AType.bodyMedium),
            ),
            const SizedBox(height: Gap.lg),
          ],
        ),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.acsecTitle)), body: body);
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Semantics(
          header: true,
          child: Text(text,
              style: AType.titleSmall.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary)),
        ),
      );

  Widget _note(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer))),
        ]),
      ),
    );
  }

  Widget _device(BuildContext context, SignedInDevice d) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = d.kind == 'legacy'
        ? t.acsecOlderApp
        : (d.name.isEmpty ? t.acsecAndroidPhone : d.name);
    final sub = d.current
        ? t.acsecThisPhone
        : (d.lastSeen != null
            ? t.acsecLastActive(recWhen(context, d.lastSeen))
            : t.acsecSince(recWhen(context, d.created)));
    return ListTile(
      key: Key('rec-device-${d.id}'),
      leading: Icon(d.current ? Icons.smartphone_rounded : Icons.phone_android_rounded,
          color: d.current ? scheme.primary : null),
      title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub),
      trailing: d.current
          ? null
          : TextButton(
              key: Key('rec-signout-${d.id}'),
              style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48), foregroundColor: scheme.error),
              onPressed: _busy ? null : () => _signOut(d),
              child: Text(t.acsecSignOut),
            ),
    );
  }

  Widget _ownerAlert(BuildContext context, RecoveryAsk a) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: Key('rec-owner-alert-${a.id}'),
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.acsecOwnerAlertTitle,
                    style: AType.titleMedium.copyWith(
                        color: scheme.onErrorContainer, fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.sm),
          Text(
              t.acsecOwnerAlertBody(recDigits(context, a.contactMasked),
                  recWhen(context, a.holdUntil)),
              style: TextStyle(color: scheme.onErrorContainer)),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: Key('rec-owner-cancel-${a.id}'),
            style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48),
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError),
            onPressed: _busy ? null : () => _cancelRecovery(a),
            icon: const Icon(Icons.block_rounded),
            label: Text(t.acsecNotMeCancel, textAlign: TextAlign.center),
          ),
        ]),
      ),
    );
  }

  Widget _familyAsk(BuildContext context, RecoveryAsk a) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: Key('rec-family-${a.id}'),
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.acsecFamilyTitle(a.name.isEmpty ? '—' : a.name),
              style: AType.titleMedium.copyWith(
                  color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(t.acsecFamilyBody, style: TextStyle(color: scheme.onTertiaryContainer)),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            FilledButton(
              key: Key('rec-family-yes-${a.id}'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : () => _family(a, true),
              child: Text(t.acsecFamilyYes),
            ),
            OutlinedButton(
              key: Key('rec-family-no-${a.id}'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : () => _family(a, false),
              child: Text(t.acsecFamilyNo),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Change (or first set) the password. Every other device is signed out.
class ChangePasswordScreen extends StatefulWidget {
  final AccountSecurityBackend backend;
  final bool hasPassword;
  final ValueChanged<String>? onToken;
  const ChangePasswordScreen(
      {super.key, required this.backend, this.hasPassword = true, this.onToken});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _cur = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _cur.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (_new.text.length < 8) {
      setState(() => _error = t.acsecPwShort);
      return;
    }
    if (_new.text != _again.text) {
      setState(() => _error = t.acsecPwMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.backend.changePassword(_cur.text, _new.text);
    if (!mounted) return;
    if (r.ok) {
      final tok = r.data['token'];
      if (tok is String && tok.isNotEmpty) widget.onToken?.call(tok);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.acsecPwDone)));
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = r.reason == 'network'
          ? t.otpErrNetwork
          : (r.message.isNotEmpty ? r.message : t.otpErrGeneric);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.hasPassword ? t.acsecChangePassword : t.acsecSetPassword)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Text(t.acsecPwIntro, style: AType.bodyMedium),
          const SizedBox(height: Gap.lg),
          if (widget.hasPassword) ...[
            ObscureTextField(
                key: const Key('rec-pw-current'),
                controller: _cur,
                labelText: t.acsecPwCurrent,
                autofillHints: const [AutofillHints.password]),
            const SizedBox(height: Gap.md),
          ],
          ObscureTextField(
              key: const Key('rec-pw-new'),
              controller: _new,
              labelText: t.acsecPwNew,
              autofillHints: const [AutofillHints.newPassword]),
          const SizedBox(height: Gap.md),
          ObscureTextField(
              key: const Key('rec-pw-again'),
              controller: _again,
              labelText: t.acsecPwAgain,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _save()),
          if (_error != null) ...[
            const SizedBox(height: Gap.md),
            Text(_error!, key: const Key('rec-pw-error'), style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: Gap.lg),
          FilledButton(
            key: const Key('rec-pw-save'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(
                    height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.acsecPwSave),
          ),
        ],
      ),
    );
  }
}

/// The gentle "add an email" card after a phone sign-up: shown at most twice
/// (the server decides: once, then once more after 5 days), "Later" always
/// there, never again once an email is verified. Checked once per app run.
class EmailNudge {
  static bool _checked = false;

  @visibleForTesting
  static void resetForTest() => _checked = false;

  static Future<void> maybeShow(BuildContext context,
      {required AccountSecurityBackend backend,
      required OtpBackend otpBackend}) async {
    if (_checked) return;
    _checked = true;
    try {
      final s = await backend.load();
      if (s == null || !s.nudge || !context.mounted) return;
      final t = AppLocalizations.of(context);
      final add = await showAppSheet<bool>(
        context: context,
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.mark_email_read_rounded,
                  size: 40, color: Theme.of(ctx).colorScheme.primary),
              const SizedBox(height: Gap.md),
              Text(t.acsecNudgeTitle,
                  textAlign: TextAlign.center,
                  style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.sm),
              Text(t.acsecNudgeBody, textAlign: TextAlign.center, style: AType.bodyMedium),
              const SizedBox(height: Gap.lg),
              FilledButton(
                key: const Key('rec-nudge-add'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.acsecAddEmail),
              ),
              const SizedBox(height: Gap.sm),
              TextButton(
                key: const Key('rec-nudge-later'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.acsecLater),
              ),
            ],
          ),
        ),
      );
      // "Later" (or swiping it away) counts; a verified email ends it for good
      // on the server.
      await backend.nudge('later');
      if (add == true && context.mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => EmailVerifyScreen(backend: otpBackend)));
      }
    } catch (_) {}
  }
}
