import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../account_security_api.dart';
import '../l10n/app_localizations.dart';
import '../models.dart' show AppUser;
import '../otp_api.dart';
import '../security/secret_store.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_counter.dart';
import '../widgets/password_field.dart';
import 'account_security_screen.dart' show recDigits, recWhen;
import 'otp/otp_verify_screen.dart';
import 'password_reset_screen.dart';

/// recovery (owner order Part 8) — forgot password: the person types their
/// number and CHOOSES where the code goes: SMS, or their verified email
/// (masked). No verified email -> SMS only. "Lost your phone and have no
/// email?" opens the support recovery request.
class ForgotPasswordScreen extends StatefulWidget {
  final AccountSecurityBackend? backend;
  final OtpBackend? otpBackend;
  const ForgotPasswordScreen({super.key, this.backend, this.otpBackend});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

enum _Via { sms, email }

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _phone = TextEditingController();
  final _pw = TextEditingController();
  RecoveryOptions? _opts;
  _Via _via = _Via.sms;
  String? _proof;
  String? _error;
  bool _busy = false;
  bool _done = false;

  AccountSecurityBackend get _b =>
      widget.backend ?? ApiAccountSecurityBackend(context.read<AppState>().api);
  OtpBackend get _otp =>
      widget.otpBackend ?? ApiOtpBackend(context.read<AppState>().api);

  @override
  void dispose() {
    _phone.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final t = AppLocalizations.of(context);
    if (!looksLikeBdMobile(_phone.text)) {
      setState(() => _error = t.otpPhoneInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final o = await _b.options(_phone.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _opts = o;
      if (o == null) {
        _error = t.otpErrNetwork;
      } else {
        _via = o.email ? _Via.email : _Via.sms;
      }
    });
  }

  Future<void> _sendCode() async {
    final t = AppLocalizations.of(context);
    final proof = await OtpVerifyScreen.run(context,
        backend: _otp,
        purpose: 'password_reset',
        phone: _phone.text.trim(),
        title: t.acsecForgotTitle,
        emailFirst: _via == _Via.email);
    if (!mounted || proof == null) return;
    setState(() => _proof = proof);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (_pw.text.length < 8) {
      setState(() => _error = t.acsecPwShort);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await _otp.resetPassword(_phone.text.trim(), _proof!, _pw.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _done = true;
      } else if (r.reason == 'weak_password') {
        _error = r.message.isNotEmpty ? r.message : t.acsecPwShort;
      } else {
        _proof = null;
        _error = r.reason == 'network' ? t.otpErrNetwork : t.otpErrNoActive;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final o = _opts;
    return Scaffold(
      appBar: AppBar(title: Text(t.acsecForgotTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          if (_done) ...[
            Icon(Icons.check_circle_rounded, size: 48, color: scheme.primary),
            const SizedBox(height: Gap.md),
            Text(t.acsecForgotDone, key: const Key('fp-done'),
                textAlign: TextAlign.center, style: AType.titleMedium),
            const SizedBox(height: Gap.lg),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.acsecBackToSignIn),
            ),
          ] else ...[
            Text(t.acsecForgotIntro, style: AType.bodyMedium),
            const SizedBox(height: Gap.lg),
            TextField(
              key: const Key('fp-phone'),
              controller: _phone,
              enabled: !_busy && _proof == null,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              onChanged: (_) => setState(() {
                _opts = null;
                _error = null;
              }),
              decoration: InputDecoration(
                labelText: t.otpPhoneLabel,
                prefixIcon: const Icon(Icons.phone_iphone_rounded),
              ),
            ),
            const SizedBox(height: Gap.md),
            if (o == null)
              FilledButton(
                key: const Key('fp-continue'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : _check,
                child: Text(t.acsecContinue),
              )
            else if (_proof == null) ...[
              Semantics(
                  header: true,
                  child: Text(t.acsecWhereCode,
                      style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700))),
              const SizedBox(height: Gap.sm),
              if (o.sms)
                _choice(context, _Via.sms, Icons.sms_rounded, t.acsecViaSms,
                    t.acsecViaSmsSub),
              if (o.email)
                _choice(context, _Via.email, Icons.alternate_email_rounded,
                    t.acsecViaEmail, t.acsecViaEmailSub(o.emailMasked)),
              if (!o.email)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: Text(t.acsecSmsOnlyNote,
                      key: const Key('fp-sms-only'),
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                ),
              const SizedBox(height: Gap.md),
              if (o.sms || o.email)
                FilledButton.icon(
                  key: const Key('fp-send'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy ? null : _sendCode,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(t.acsecSendCode),
                )
              else
                Text(t.acsecNoChannel, key: const Key('fp-no-channel')),
            ] else ...[
              Text(t.acsecCodeOk, style: AType.titleSmall),
              const SizedBox(height: Gap.md),
              ObscureTextField(
                  key: const Key('fp-new-pw'),
                  controller: _pw,
                  labelText: t.acsecPwNew,
                  autofillHints: const [AutofillHints.newPassword]),
              const SizedBox(height: Gap.md),
              FilledButton(
                key: const Key('fp-save'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : _save,
                child: Text(t.acsecPwSave),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Gap.md),
              Text(_error!, key: const Key('fp-error'), style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: Gap.xl),
            const Divider(),
            // an email-only account (no phone): the email-link reset
            ListTile(
              key: const Key('fp-use-email'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.email_rounded),
              title: Text(t.acsecUseEmailInstead),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PasswordResetScreen(otpBackend: widget.otpBackend))),
            ),
            ListTile(
              key: const Key('fp-lost-phone'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.support_agent_rounded),
              title: Text(t.acsecLostNoEmail),
              subtitle: Text(t.acsecLostNoEmailSub),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SupportRecoveryScreen(
                      backend: widget.backend, otpBackend: widget.otpBackend))),
            ),
          ],
        ],
      ),
    );
  }

  Widget _choice(BuildContext context, _Via v, IconData icon, String title, String sub) {
    final scheme = Theme.of(context).colorScheme;
    final on = _via == v;
    return Card(
      key: Key('fp-via-${v.name}'),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: on ? scheme.primary : scheme.outlineVariant, width: on ? 2 : 1)),
      child: ListTile(
        leading: Icon(icon, color: on ? scheme.primary : null),
        title: Text(title),
        subtitle: Text(recDigits(context, sub)),
        trailing: Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            color: on ? scheme.primary : scheme.outline),
        selected: on,
        onTap: () => setState(() => _via = v),
      ),
    );
  }
}

/// Where the open request's reference lives on this phone (injectable).
abstract class RecoveryRefStore {
  Future<Map<String, String>?> read();
  Future<void> write(Map<String, String> v);
  Future<void> clear();
}

class SecretRecoveryRefStore implements RecoveryRefStore {
  const SecretRecoveryRefStore();
  static const _k = 'acct_recovery_ref';
  @override
  Future<Map<String, String>?> read() async {
    final v = await SecretStore.instance.read(_k);
    if (v == null || v.isEmpty) return null;
    final p = v.split('|');
    if (p.length < 3) return null;
    return {'ref': p[0], 'secret': p[1], 'contact': p[2]};
  }

  @override
  Future<void> write(Map<String, String> v) =>
      SecretStore.instance.write(_k, '${v['ref']}|${v['secret']}|${v['contact']}');

  @override
  Future<void> clear() => SecretStore.instance.delete(_k);
}

/// Lost phone + no verified email: a support recovery request. Proof = the
/// NEW number proven by SMS, past account details, and (optional) a My
/// Circle family member who confirms in their own app. A 48-hour security
/// hold and a human review — never instant. The account's signed-in phones
/// can cancel it. Reviewers see match results, never chats or files.
class SupportRecoveryScreen extends StatefulWidget {
  final AccountSecurityBackend? backend;
  final OtpBackend? otpBackend;
  final RecoveryRefStore store;

  /// Signed in at the end (default: AppState.adoptSession).
  final Future<void> Function(String token, AppUser user)? onSignedIn;
  const SupportRecoveryScreen(
      {super.key,
      this.backend,
      this.otpBackend,
      this.store = const SecretRecoveryRefStore(),
      this.onSignedIn});

  @override
  State<SupportRecoveryScreen> createState() => _SupportRecoveryScreenState();
}

class _SupportRecoveryScreenState extends State<SupportRecoveryScreen> {
  final _lost = TextEditingController();
  final _newNo = TextEditingController();
  final _name = TextEditingController();
  final _c1 = TextEditingController();
  final _c2 = TextEditingController();
  final _c3 = TextEditingController();
  final _oldPw = TextEditingController();
  final _family = TextEditingController();
  final _pw = TextEditingController();
  int? _year;
  int? _month;
  String? _contactProof;
  Map<String, String>? _ref;
  Map<String, dynamic>? _status;
  String? _error;
  bool _busy = false;
  bool _loaded = false;

  AccountSecurityBackend get _b =>
      widget.backend ?? ApiAccountSecurityBackend(context.read<AppState>().api);
  OtpBackend get _otp =>
      widget.otpBackend ?? ApiOtpBackend(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void dispose() {
    for (final c in [_lost, _newNo, _name, _c1, _c2, _c3, _oldPw, _family, _pw]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    Map<String, String>? r;
    try {
      r = await widget.store.read();
    } catch (_) {
      // best-effort: no saved request -> the form (never a dead end)
    }
    if (!mounted) return;
    setState(() {
      _ref = r;
      _loaded = true;
    });
    if (r != null) await _refresh();
  }

  Future<void> _refresh({bool manual = false}) async {
    final r = _ref;
    if (r == null) return;
    setState(() => _busy = true);
    final s = await _b.supportStatus(r['ref']!, r['secret']!);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = s.ok ? s.data : null;
      if (!s.ok) _error = s.reason == 'network' ? AppLocalizations.of(context).otpErrNetwork : null;
    });
    if (!s.ok && s.status == 404) {
      await widget.store.clear();
      if (mounted) setState(() => _ref = null);
    } else if (manual && s.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).acsecChecked)));
    }
  }

  Future<void> _verifyNew() async {
    final t = AppLocalizations.of(context);
    if (!looksLikeBdMobile(_newNo.text)) {
      setState(() => _error = t.otpPhoneInvalid);
      return;
    }
    setState(() => _error = null);
    final p = await OtpVerifyScreen.run(context,
        backend: _otp,
        purpose: 'account_recovery',
        phone: _newNo.text.trim(),
        title: t.acsecSupportTitle);
    if (!mounted || p == null) return;
    setState(() => _contactProof = p);
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    if (!looksLikeBdMobile(_lost.text)) {
      setState(() => _error = t.otpPhoneInvalid);
      return;
    }
    if (_contactProof == null) {
      setState(() => _error = t.acsecVerifyNewFirst);
      return;
    }
    if (_name.text.trim().isEmpty) {
      setState(() => _error = t.acsecNameNeeded);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await _b.supportStart({
      'account_phone': _lost.text.trim(),
      'contact_phone': _newNo.text.trim(),
      'contact_otp_proof': _contactProof,
      'name': _name.text.trim(),
      if (_year != null) 'signup_year': _year,
      if (_month != null) 'signup_month': _month,
      'circle_names': [_c1.text, _c2.text, _c3.text]
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      if (_oldPw.text.isNotEmpty) 'old_password': _oldPw.text,
      if (_family.text.trim().isNotEmpty) 'family_phone': _family.text.trim(),
    });
    if (!mounted) return;
    if (r.ok) {
      final v = {
        'ref': '${r.data['ref']}',
        'secret': '${r.data['secret']}',
        'contact': _newNo.text.trim()
      };
      try {
        await widget.store.write(v);
      } catch (_) {
        // best-effort: the request is already on the server; the ref stays in
        // memory for this session and is shown on screen to note down.
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _ref = v;
      });
      await _refresh();
      return;
    }
    setState(() {
      _busy = false;
      if (r.reason == 'bad_otp') _contactProof = null;
      _error = r.reason == 'network'
          ? t.otpErrNetwork
          : (r.message.isNotEmpty ? r.message : t.otpErrGeneric);
    });
  }

  Future<void> _finish() async {
    final t = AppLocalizations.of(context);
    final r = _ref!;
    if (_pw.text.length < 8) {
      setState(() => _error = t.acsecPwShort);
      return;
    }
    final proof = await OtpVerifyScreen.run(context,
        backend: _otp,
        purpose: 'account_recovery',
        phone: r['contact'],
        title: t.acsecSupportTitle);
    if (!mounted || proof == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await _b.supportComplete(r['ref']!, r['secret']!, proof, _pw.text);
    if (!mounted) return;
    if (res.ok && res.data['token'] is String && res.data['user'] is Map) {
      await widget.store.clear();
      final user = AppUser.fromJson(Map<String, dynamic>.from(res.data['user'] as Map));
      final f = widget.onSignedIn;
      if (f != null) {
        await f(res.data['token'] as String, user);
      } else if (mounted) {
        await context.read<AppState>().adoptSession(res.data['token'] as String, user);
      }
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      _busy = false;
      _error = res.message.isNotEmpty ? res.message : t.otpErrGeneric;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.acsecSupportTitle)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: _ref == null ? _form(context) : _statusView(context),
            ),
    );
  }

  Widget _infoCard(BuildContext context, String text, {IconData icon = Icons.shield_rounded}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer))),
        ]),
      ),
    );
  }

  InputDecoration _dec(String label, {String? helper, IconData? icon}) => InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 3,
      prefixIcon: icon == null ? null : Icon(icon));

  List<Widget> _form(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now().year;
    return [
      _infoCard(context, t.acsecSupportIntro),
      const SizedBox(height: Gap.lg),
      TextField(
          key: const Key('sr-lost'),
          controller: _lost,
          keyboardType: TextInputType.phone,
          decoration: _dec(t.acsecLostNumber, icon: Icons.phonelink_erase_rounded)),
      const SizedBox(height: Gap.md),
      TextField(
          key: const Key('sr-new'),
          controller: _newNo,
          enabled: _contactProof == null,
          keyboardType: TextInputType.phone,
          decoration: _dec(t.acsecNewNumber,
              helper: t.acsecNewNumberHelp, icon: Icons.phone_iphone_rounded)),
      const SizedBox(height: Gap.sm),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: _contactProof == null
            ? OutlinedButton.icon(
                key: const Key('sr-verify-new'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : _verifyNew,
                icon: const Icon(Icons.sms_rounded),
                label: Text(t.acsecVerifyNew))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.verified_rounded, color: scheme.primary),
                const SizedBox(width: Gap.xs),
                Flexible(child: Text(t.acsecNewVerified, key: const Key('sr-new-ok'))),
              ]),
      ),
      const SizedBox(height: Gap.lg),
      Semantics(
          header: true,
          child: Text(t.acsecProofTitle,
              style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700))),
      const SizedBox(height: Gap.sm),
      TextField(
          key: const Key('sr-name'),
          controller: _name,
          maxLength: 120,
          buildCounter: localCounter,
          textCapitalization: TextCapitalization.words,
          decoration: _dec(t.acsecAccountName, icon: Icons.badge_rounded)),
      const SizedBox(height: Gap.sm),
      DropdownButtonFormField<int>(
        key: const Key('sr-year'),
        initialValue: _year,
        isExpanded: true,
        decoration: _dec(t.acsecSignupYear, icon: Icons.event_rounded),
        items: [
          for (var y = now; y >= now - 5; y--)
            DropdownMenuItem(value: y, child: Text(recDigits(context, '$y'))),
        ],
        onChanged: (v) => setState(() => _year = v),
      ),
      const SizedBox(height: Gap.sm),
      DropdownButtonFormField<int>(
        key: const Key('sr-month'),
        initialValue: _month,
        isExpanded: true,
        decoration: _dec(t.acsecSignupMonth, icon: Icons.calendar_month_rounded),
        items: [
          for (var m = 1; m <= 12; m++)
            DropdownMenuItem(
                value: m,
                child: Text(DateFormat('MMMM', Localizations.localeOf(context).languageCode)
                    .format(DateTime(2000, m)), overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => setState(() => _month = v),
      ),
      const SizedBox(height: Gap.md),
      Text(t.acsecCircleNames, style: AType.bodyMedium),
      const SizedBox(height: Gap.xs),
      for (final c in [_c1, _c2, _c3]) ...[
        TextField(controller: c, decoration: _dec(t.acsecCircleNameHint, icon: Icons.person_rounded)),
        const SizedBox(height: Gap.sm),
      ],
      ObscureTextField(
          key: const Key('sr-old-pw'),
          controller: _oldPw,
          labelText: t.acsecOldPassword),
      const SizedBox(height: Gap.lg),
      Semantics(
          header: true,
          child: Text(t.acsecFamilyConfirmTitle,
              style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700))),
      const SizedBox(height: Gap.sm),
      TextField(
          key: const Key('sr-family'),
          controller: _family,
          keyboardType: TextInputType.phone,
          decoration: _dec(t.acsecFamilyPhone,
              helper: t.acsecFamilyPhoneHelp, icon: Icons.family_restroom_rounded)),
      if (_error != null) ...[
        const SizedBox(height: Gap.md),
        Text(_error!, key: const Key('sr-error'), style: TextStyle(color: scheme.error)),
      ],
      const SizedBox(height: Gap.lg),
      FilledButton.icon(
        key: const Key('sr-submit'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy ? null : _submit,
        icon: const Icon(Icons.send_rounded),
        label: Text(t.acsecSendRequest),
      ),
      const SizedBox(height: Gap.sm),
      Text(t.acsecPrivacyNote,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
    ];
  }

  List<Widget> _statusView(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _status;
    final st = '${s?['state'] ?? ''}';
    final hold = DateTime.tryParse('${s?['hold_until'] ?? ''}');
    final fam = '${s?['family_state'] ?? 'none'}';
    String line;
    switch (st) {
      case 'pending':
        line = t.acsecStPending(recWhen(context, hold));
        break;
      case 'approved_waiting':
        line = t.acsecStApprovedWait(recWhen(context, hold));
        break;
      case 'ready':
        line = t.acsecStReady;
        break;
      case 'rejected':
        line = t.acsecStRejected;
        break;
      case 'cancelled':
        line = t.acsecStCancelled;
        break;
      case 'completed':
        line = t.acsecStCompleted;
        break;
      case 'expired':
        line = t.acsecStExpired;
        break;
      default:
        line = t.acsecStUnknown;
    }
    final ended = const {'rejected', 'cancelled', 'completed', 'expired'}.contains(st);
    return [
      _infoCard(context, t.acsecRefLine(recDigits(context, _ref!['ref']!)),
          icon: Icons.confirmation_number_rounded),
      const SizedBox(height: Gap.lg),
      Text(line, key: const Key('sr-state'), style: AType.titleMedium),
      if (fam != 'none') ...[
        const SizedBox(height: Gap.sm),
        Text(fam == 'confirmed'
            ? t.acsecFamConfirmed
            : (fam == 'denied' ? t.acsecFamDenied : t.acsecFamPending)),
      ],
      const SizedBox(height: Gap.lg),
      if (st == 'ready') ...[
        ObscureTextField(
            key: const Key('sr-final-pw'),
            controller: _pw,
            labelText: t.acsecPwNew,
            autofillHints: const [AutofillHints.newPassword]),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          key: const Key('sr-finish'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _finish,
          icon: const Icon(Icons.lock_open_rounded),
          label: Text(t.acsecFinish),
        ),
      ] else if (!ended)
        OutlinedButton.icon(
          key: const Key('sr-refresh'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : () => _refresh(manual: true),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.acsecCheckAgain),
        )
      else
        OutlinedButton(
          key: const Key('sr-new-request'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () async {
            await widget.store.clear();
            if (mounted) setState(() => _ref = null);
          },
          child: Text(t.acsecStartOver),
        ),
      if (_error != null) ...[
        const SizedBox(height: Gap.md),
        Text(_error!, style: TextStyle(color: scheme.error)),
      ],
    ];
  }
}
