import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../feedback/feedback_sheet.dart';
import '../l10n/app_localizations.dart';
import '../services/security_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart';
import '../widgets/password_field.dart';
import '../otp_api.dart';
import 'otp/otp_verify_screen.dart';
import 'settings_screen.dart' show SupportScreen;

/// Secure, Play-compliant "Delete my profile & all data".
///
/// HONESTY (the copy the user sees reflects this):
///   * Deletion is PERMANENT only after a 7-day grace period; until then the
///     account is fully recoverable — the owner (or a trusted contact with the
///     "this wasn't me" token) can cancel it from anywhere.
///   * A thief who just snatched an unlocked phone CANNOT wipe the account: a
///     recent theft signal blocks the request (HTTP 423), and even a successful
///     request is delayed + alerted + cancellable.
///
/// This screen REPLACES the old one-tap delete. It never calls the instant
/// `AppState.deleteAccount()` wipe; it schedules the deletion server-side and
/// leaves the user logged in so they can still cancel during the grace period.
class DeleteAccountScreen extends StatefulWidget {
  /// o1-otp: injectable for widget tests; defaults to the real API.
  final OtpBackend? otpBackend;
  const DeleteAccountScreen({super.key, this.otpBackend});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

enum _Phase { loading, preview, verify, pending, blocked }

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  _Phase _phase = _Phase.loading;

  // Preview.
  Map<String, int> _counts = const {};
  bool _exportDownloaded = false;

  // Pending.
  DateTime? _effectiveAt;
  // dl1: the deletion was ALREADY scheduled (opened again, or a second
  // request) — say so plainly with the same date + the Cancel button.
  bool _alreadyPending = false;
  String? _blockedReason; // 'theft_signal' | 'frozen'

  // Verify inputs.
  final _password = TextEditingController();
  bool _hasPin = false; // user HAS a Security PIN -> biometric + PIN required.
  String? _securityPin; // captured via askPin after biometric.
  // o1-otp: single-use SMS proof (purpose delete_account). Asked for only when
  // the server says otp_required (i.e. an SMS gateway is connected).
  String? _otpProof;

  bool _busy = false;
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  AppState get _app => context.read<AppState>();

  // --- bootstrap: pending banner first, else preview -----------------------
  Future<void> _bootstrap() async {
    // 1) Is there already a pending request? Show it (banner-first) if so.
    try {
      final st = await _app.api.accountDeleteStatus();
      if (!mounted) return;
      if ('${st['state']}' == 'pending') {
        setState(() {
          _effectiveAt = _parseDate(st['effective_at']);
          _alreadyPending = true;
          _phase = _Phase.pending;
        });
        return;
      }
    } catch (_) {
      // Non-fatal — fall through to preview.
    }

    // 2) Does the user have a Security PIN? (biometric + PIN only if so).
    try {
      final sec = await _app.api.securityState();
      _hasPin = sec['has_pin'] == true;
    } catch (_) {
      _hasPin = false;
    }

    // 3) Preview — what will be deleted.
    await _loadPreview();
  }

  bool _previewFailed = false;

  /// User-safe error text: the server's own (localized) message when there is
  /// one, otherwise a plain "check your connection" line.
  String _friendly(Object e, {bool load = false}) {
    final t = AppLocalizations.of(context);
    if (e is ApiException && e.message.trim().isNotEmpty && (e.status ?? 0) < 500) {
      return e.message;
    }
    return load ? t.qaLoadFailedRetry : t.qaActionFailed;
  }

  Future<void> _loadPreview() async {
    setState(() {
      _busy = true;
      _inlineError = null;
    });
    try {
      final p = await _app.api.accountDeletePreview();
      final raw = (p['counts'] as Map?) ?? const {};
      final counts = <String, int>{};
      raw.forEach((k, v) {
        final n = v is int ? v : int.tryParse('$v') ?? 0;
        if (n > 0) counts['$k'] = n;
      });
      if (!mounted) return;
      setState(() {
        _counts = counts;
        _exportDownloaded = p['export_downloaded'] == true;
        _phase = _Phase.preview;
        _busy = false;
        _previewFailed = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // QA a6: never show raw exception text (it leaked
        // "ClientException ... uri=https://..." to users).
        _inlineError = _friendly(e, load: true);
        _previewFailed = true;
        _phase = _Phase.preview;
        _busy = false;
      });
    }
  }

  // --- export (reuses the existing "Download my data" JSON export) ---------
  Future<void> _downloadMyData() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final raw = await _app.api.exportRaw();
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/assisto-export.json');
      await f.writeAsString(raw);
      if (!mounted) return;
      setState(() {
        _exportDownloaded = true; // optimistic — nudge stops showing.
        _busy = false;
      });
      messenger.showSnackBar(SnackBar(content: Text(t.savedToPath(f.path))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(_friendly(e))));
    }
  }

  // --- verify PIN (biometric then askPin) ----------------------------------
  Future<void> _capturePin() async {
    final t = AppLocalizations.of(context);
    const guard = SecurityGuard();
    final bio = await guard.ensureBiometric(context);
    if (!mounted) return;
    if (!bio) {
      setState(() => _inlineError = t.delAcctBiometricFailed);
      return;
    }
    final pin = await guard.askPin(context, t);
    if (!mounted) return;
    if (pin == null || pin.isEmpty) return; // cancelled — no error.
    setState(() {
      _securityPin = pin;
      _inlineError = null;
    });
  }

  // --- submit the deletion request -----------------------------------------
  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _inlineError = null;
    });

    final pos = await _bestEffortPosition();

    Map<String, dynamic> resp;
    try {
      resp = await _app.api.accountDeleteRequest(
        password: _password.text,
        otpProof: _otpProof,
        securityPin: _hasPin ? _securityPin : null,
        lat: pos?.latitude,
        lng: pos?.longitude,
      );
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _inlineError = t.delAcctRequestError;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _inlineError = t.delAcctRequestError;
      });
      return;
    }
    if (!mounted) return;

    final status = resp['_status'] as int?;
    final state = '${resp['state'] ?? ''}';
    final reason = '${resp['reason'] ?? ''}';

    // 423 — safety block (theft signal / freeze). Do NOT delete.
    if (status == 423 || state == 'blocked') {
      setState(() {
        _busy = false;
        _blockedReason = reason.isEmpty ? 'theft_signal' : reason;
        _phase = _Phase.blocked;
      });
      return;
    }

    // o1-otp: SMS confirmation needed (gateway connected) -> code step, then
    // resubmit once with the proof. An expired/used proof asks again.
    if (reason == 'otp_required' ||
        (reason == 'bad_otp' && _otpProof != null)) {
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
      return _submit();
    }

    // 400/403 — bad credential. Inline error, let them retry.
    if (status == 400 || status == 403 || resp['ok'] == false) {
      String msg;
      switch (reason) {
        case 'bad_password':
          msg = t.delAcctBadPassword;
          break;
        case 'bad_otp':
          msg = t.delAcctBadOtp;
          break;
        case 'bad_pin':
          msg = t.delAcctBadPin;
          break;
        case 'locked':
          msg = t.delAcctPinLocked;
          break;
        default:
          msg = t.delAcctRequestError;
      }
      setState(() {
        _busy = false;
        _inlineError = msg;
      });
      return;
    }

    // pending — scheduled. Stay logged in so the user can still cancel.
    if (state == 'pending') {
      setState(() {
        _busy = false;
        _effectiveAt = _parseDate(resp['effective_at']);
        _alreadyPending = resp['already_pending'] == true;
        _phase = _Phase.pending;
      });
      return;
    }

    setState(() {
      _busy = false;
      _inlineError = t.delAcctRequestError;
    });
  }

  // --- cancel a pending deletion -------------------------------------------
  Future<void> _cancel() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final r = await _app.api.accountDeleteCancel();
      if (!mounted) return;
      if (r['ok'] == true || '${r['state']}' == 'cancelled') {
        messenger.showSnackBar(SnackBar(content: Text(t.delAcctCancelled)));
        // Back to normal — reload the preview so the screen is reusable.
        _effectiveAt = null;
        _alreadyPending = false;
        await _loadPreview();
        return;
      }
      setState(() {
        _busy = false;
        _inlineError = t.delAcctRequestError;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _inlineError = t.delAcctRequestError;
      });
    }
  }

  Future<Position?> _bestEffortPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // UI
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.delAcctTitle)),
      body: SafeArea(
        child: _phase == _Phase.loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(Gap.lg),
                child: _body(t),
              ),
      ),
    );
  }

  Widget _body(AppLocalizations t) {
    switch (_phase) {
      case _Phase.pending:
        return _pendingBody(t);
      case _Phase.blocked:
        return _blockedBody(t);
      case _Phase.verify:
        return _verifyBody(t);
      case _Phase.preview:
      default:
        return _previewBody(t);
    }
  }

  // --- Step 0: preview ------------------------------------------------------
  Widget _previewBody(AppLocalizations t) {
    final entries = _groupedCounts(t);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _warnCard(
          icon: Icons.warning_amber_rounded,
          color: Brand.danger,
          title: t.delAcctPreviewTitle,
          body: t.delAcctPreviewBody,
        ),
        const SizedBox(height: Gap.lg),
        // QA a6: when the preview failed we don't KNOW what will be deleted —
        // never claim "nothing stored".
        if (!_previewFailed) ...[
        Text(t.delAcctWhatDeleted,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        ],
        if (_previewFailed)
          const SizedBox.shrink()
        else if (entries.isEmpty)
          Text(t.delAcctNothingToDelete)
        else
          Card(
            child: Column(
              children: [
                for (final e in entries)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.delete_outline, size: 20),
                    title: Text(e.key),
                    trailing: Text(fmtInt(context, e.value),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Gap.lg),
        // Prominent "Download my data first" — always offered; nudge if not done.
        OutlinedButton.icon(
          onPressed: _busy ? null : _downloadMyData,
          icon: const Icon(Icons.download_outlined),
          label: Text(t.delAcctDownloadFirst),
        ),
        if (!_exportDownloaded) ...[
          const SizedBox(height: Gap.xs),
          Text(t.delAcctExportNudge,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Brand.warnInk(context))),
        ] else ...[
          const SizedBox(height: Gap.xs),
          Row(children: [
            const Icon(Icons.check_circle, color: Brand.success, size: 16),
            const SizedBox(width: 6),
            Text(t.delAcctExportDone,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ],
        const SizedBox(height: Gap.xl),
        _problemGuidance(t),
        const SizedBox(height: Gap.xl),
        if (_inlineError != null) ...[
          _inlineErr(_inlineError!),
          const SizedBox(height: Gap.sm),
        ],
        if (_inlineError != null)
          // Preview failed to load — offer a retry instead of continuing.
          OutlinedButton.icon(
            onPressed: _busy ? null : _loadPreview,
            icon: const Icon(Icons.refresh),
            label: Text(t.delAcctTryAgain),
          )
        else
          FilledButton(
            style: Brand.dangerButton(),
            onPressed: _busy
                ? null
                : () => setState(() {
                      _inlineError = null;
                      _phase = _Phase.verify;
                    }),
            child: Text(t.delAcctContinue),
          ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: Text(t.delAcctKeepAccount),
        ),
      ],
    );
  }

  // --- Step 1: verify (multi-factor) ---------------------------------------
  Widget _verifyBody(AppLocalizations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _warnCard(
          icon: Icons.lock_outline,
          color: Brand.blue,
          title: t.delAcctVerifyTitle,
          body: t.delAcctVerifyBody,
        ),
        const SizedBox(height: Gap.lg),

        // Password.
        ObscureTextField(
          controller: _password,
          autofillHints: const [AutofillHints.password],
          // Re-evaluate _canSubmit() as the user types (the submit button
          // otherwise stayed disabled until some unrelated rebuild).
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: t.delAcctPasswordLabel,
            prefixIcon: const Icon(Icons.key_outlined),
          ),
        ),
        const SizedBox(height: Gap.lg),

        // OTP (o1-otp): asked on submit, only when SMS is connected.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.sms_outlined,
                size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.otpDelSmsNote,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),

        // Security PIN (only when the user HAS one): biometric + PIN.
        if (_hasPin) ...[
          const SizedBox(height: Gap.lg),
          Card(
            child: ListTile(
              leading: Icon(
                _securityPin != null
                    ? Icons.verified_user
                    : Icons.fingerprint,
                color: _securityPin != null ? Brand.success : null,
              ),
              title: Text(t.delAcctPinTitle),
              subtitle: Text(_securityPin != null
                  ? t.delAcctPinCaptured
                  : t.delAcctPinSubtitle),
              trailing: TextButton(
                onPressed: _busy ? null : _capturePin,
                child: Text(_securityPin != null
                    ? t.delAcctPinRedo
                    : t.delAcctPinVerify),
              ),
            ),
          ),
        ],

        const SizedBox(height: Gap.xl),
        if (_inlineError != null) ...[
          _inlineErr(_inlineError!),
          const SizedBox(height: Gap.sm),
        ],
        FilledButton(
          style: Brand.dangerButton(),
          onPressed: _busy || !_canSubmit() ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.delAcctScheduleDeletion),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed:
              _busy ? null : () => setState(() => _phase = _Phase.preview),
          child: Text(t.delAcctBack),
        ),
      ],
    );
  }

  bool _canSubmit() {
    if (_password.text.isEmpty) return false;
    if (_hasPin && _securityPin == null) return false;
    return true;
  }

  // --- pending state --------------------------------------------------------
  Widget _pendingBody(AppLocalizations t) {
    final when = _fmtWhen(_effectiveAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Banner at the TOP: scheduled + "this wasn't me" cancel.
        Card(
          color: Brand.warning.withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.schedule, color: Brand.warning),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(t.delAcctScheduledTitle,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ]),
                const SizedBox(height: Gap.sm),
                Text(
                    _alreadyPending
                        ? t.delAcctAlreadyPending(when)
                        : t.delAcctScheduledBody(when),
                    key: const Key('del-acct-pending-body')),
                const SizedBox(height: Gap.sm),
                Text(t.delAcctAlertedContacts,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.xl),
        if (_inlineError != null) ...[
          _inlineErr(_inlineError!),
          const SizedBox(height: Gap.sm),
        ],
        FilledButton.icon(
          key: const Key('del-acct-cancel'),
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.undo),
          label: Text(t.delAcctCancelDeletion),
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: Text(t.delAcctClose),
        ),
      ],
    );
  }

  // --- blocked (423) state --------------------------------------------------
  Widget _blockedBody(AppLocalizations t) {
    final frozen = _blockedReason == 'frozen';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _warnCard(
          icon: Icons.shield_outlined,
          color: Brand.blue,
          title: t.delAcctBlockedTitle,
          body: frozen ? t.delAcctBlockedFrozen : t.delAcctBlockedTheft,
        ),
        const SizedBox(height: Gap.xl),
        FilledButton(
          onPressed: () => setState(() {
            _blockedReason = null;
            _phase = _Phase.verify;
          }),
          child: Text(t.delAcctTryAgain),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: Text(t.delAcctClose),
        ),
      ],
    );
  }

  // --- dl1: honest guidance before anyone deletes to "fix" a problem --------
  Widget _problemGuidance(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('del-acct-guidance'),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.support_agent_outlined,
                    color: scheme.onSecondaryContainer),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.delAcctGuidanceTitle,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: scheme.onSecondaryContainer)),
                      const SizedBox(height: Gap.xs),
                      Text(t.delAcctGuidanceBody,
                          style: TextStyle(color: scheme.onSecondaryContainer)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                OutlinedButton.icon(
                  key: const Key('del-acct-feedback'),
                  onPressed: () =>
                      FeedbackSheet.open(context, route: 'account_delete'),
                  icon: const Icon(Icons.feedback_outlined),
                  label: Text(t.delAcctSendFeedback),
                ),
                OutlinedButton.icon(
                  key: const Key('del-acct-support'),
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const SupportScreen())),
                  icon: const Icon(Icons.help_outline),
                  label: Text(t.delAcctContactSupport),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- small helpers --------------------------------------------------------
  Widget _warnCard({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) {
    return Card(
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: Gap.xs),
                  Text(body),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inlineErr(String msg) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: Brand.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          const Icon(Icons.error_outline, color: Brand.danger, size: 18),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(msg, style: const TextStyle(color: Brand.danger))),
        ]),
      );

  String _fmtWhen(DateTime? dt) {
    if (dt == null) return '';
    final locale = Localizations.localeOf(context).toLanguageTag();
    // Localized long date + time; Bangla locale renders Bangla digits/month.
    return DateFormat.yMMMMd(locale).add_jm().format(dt);
  }

  /// The server counts every reverse relation of the user by its Django
  /// accessor name ("reminders", "txns", "auth_token", …). Show people what
  /// they recognise, in their language: known kinds under a localized label
  /// (several accessors can share one), the rest summed into "Other records".
  /// QA qa1: the old "Reminder set"-style English names showed in Bangla UI.
  List<MapEntry<String, int>> _groupedCounts(AppLocalizations t) {
    final groups = <String, List<String>>{
      t.delAcctKindMemories: ['memories'],
      t.delAcctKindReminders: ['reminders'],
      t.delAcctKindNotes: ['notes'],
      t.delAcctKindTodos: ['todos'],
      t.delAcctKindDocuments: ['documents'],
      t.delAcctKindMoney: ['txns', 'accounts', 'budgets', 'loans', 'goals',
          'autopay_rules', 'bill_templates', 'fam_expenses', 'fam_pools'],
      t.delAcctKindContacts: ['contacts'],
      t.delAcctKindCircle: ['circle_members', 'circle_groups', 'circle_invites'],
      t.delAcctKindMessages: ['circle_sent', 'scheduled_messages', 'channel_posts'],
      t.delAcctKindAiChats: ['chat_sessions', 'chat_threads'],
      t.delAcctKindHealth: ['medicines', 'prescriptions', 'doctors', 'appointments'],
      t.delAcctKindEvents: ['birthdays', 'meetings'],
      t.delAcctKindFamily: ['family', 'nominees', 'emergency'],
      t.delAcctKindBusiness: ['products', 'sales', 'orders', 'sale_customers',
          'business_expenses', 'business', 'shop_sites', 'product_categories'],
      t.delAcctKindProtection: ['vehicle_trackers', 'protected_phones', 'stolen_reports'],
      t.delAcctKindSafety: ['journeys', 'saved_places', 'checkins'],
      t.delAcctKindPa: ['pa_items', 'school_items'],
      t.delAcctKindPhotos: ['photo_jobs', 'photo_exports'],
      t.delAcctKindCrm: ['crm_orgs', 'crm_memberships'],
    };
    final known = <String>{for (final g in groups.values) ...g};
    final out = <MapEntry<String, int>>[];
    groups.forEach((label, keys) {
      final n = keys.fold<int>(0, (a, k) => a + (_counts[k] ?? 0));
      if (n > 0) out.add(MapEntry(label, n));
    });
    final other = _counts.entries
        .where((e) => !known.contains(e.key))
        .fold<int>(0, (a, e) => a + e.value);
    if (other > 0) out.add(MapEntry(t.delAcctKindOther, other));
    return out;
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    return DateTime.tryParse('$v')?.toLocal();
  }
}
