import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/imei_tools.dart';
import 'report_stolen_screen.dart';
import 'registry_imei.dart';
import '../feature_gates.dart' show kNeirCheckWired, kTacSourceWired; // f6

/// Used-phone check (Daily Life). Enter a phone's IMEI and check Assisto's
/// COMMUNITY + server-side ownership registry before buying a second-hand phone.
///
/// HONESTY: this is NOT a mobile-network block (that is NEIR, not available —
/// the honest placeholder line is shown from [ApiClient.registryNeirStatus]).
/// A 'clean' result only means nobody reported this IMEI here. For a
/// 'reported_stolen' result we advise contacting the police and explicitly tell
/// the user NOT to confront the seller.
class UsedPhoneCheckScreen extends StatefulWidget {
  const UsedPhoneCheckScreen({super.key});

  @override
  State<UsedPhoneCheckScreen> createState() => _UsedPhoneCheckScreenState();
}

class _UsedPhoneCheckScreenState extends State<UsedPhoneCheckScreen> {
  // The dialer (*#06#) IMEI is the primary field and also what the registry /
  // TAC lookups use. The other three are optional cross-check sources.
  final _imei = TextEditingController(); // from the dialer *#06#
  final _imeiSettings = TextEditingController(); // Settings -> About
  final _imeiBox = TextEditingController(); // box / retail label
  final _imeiTray = TextEditingController(); // SIM-tray label

  bool _busy = false;
  String? _result; // 'clean' | 'reported_stolen' | 'verified_transfer'
  String? _adviceKey;
  String? _error; // friendly, already-localized error line
  bool _rateLimited = false;

  String? _neirMessage; // honest placeholder ("not available yet")
  bool _hasVaultImei = false;

  // ---- Tamper pre-check state (all client-side except the TAC lookup) ----
  bool _ranTamper = false;
  final List<String> _invalidImeis = []; // localized "which field" labels
  bool _imeiMismatch = false;
  // TAC lookup outcome: null = not run; false = honestly unavailable.
  bool? _tacAvailable;
  String? _tacBrand;
  String? _tacModel;
  // User's yes/no answer to "does this make/model match the actual phone?".
  // null = not answered yet.
  bool? _tacConfirmed;

  @override
  void initState() {
    super.initState();
    _loadNeir();
    _probeVaultImei();
  }

  @override
  void dispose() {
    _imei.dispose();
    _imeiSettings.dispose();
    _imeiBox.dispose();
    _imeiTray.dispose();
    super.dispose();
  }

  Future<void> _loadNeir() async {
    // Best-effort: show the honest NEIR placeholder. Never blocks the screen.
    try {
      final api = context.read<AppState>().api;
      final resp = await api.registryNeirStatus();
      if (!mounted) return;
      // The backend returns a message_key; we only need to know it's the
      // "not available" state, and we render our own localized sentence.
      final available = resp['available'] == true;
      if (!available) setState(() => _neirMessage = _neirLine());
    } catch (_) {
      // leave null — the honest footer still explains the registry's limits.
    }
  }

  String _neirLine() => AppLocalizations.of(context).upNeirNotAvailable;

  Future<void> _probeVaultImei() async {
    final imei = await RegistryImei.fromVault(context);
    if (mounted && imei != null && imei.isNotEmpty) {
      setState(() => _hasVaultImei = true);
    }
  }

  Future<void> _prefill() async {
    final imei = await RegistryImei.fromVault(context);
    if (imei != null && imei.isNotEmpty) {
      setState(() => _imei.text = imei);
    }
  }

  /// Any tamper red flag that should SHOUT over the registry verdict:
  /// an invalid IMEI, cross-source mismatch, or a user-confirmed TAC mismatch.
  bool get _hasTamperWarning =>
      _ranTamper &&
      (_invalidImeis.isNotEmpty || _imeiMismatch || _tacConfirmed == false);

  /// Deterministic, offline tamper pre-check: Luhn-validate each entered IMEI
  /// and compare all of them. Also kicks off the (honest, key-gated) TAC
  /// make/model lookup on the dialer IMEI. Never throws; TAC failure degrades
  /// to "not available yet".
  Future<void> _runTamperChecks(String dialer) async {
    final t = AppLocalizations.of(context);
    final entries = <(String, TextEditingController)>[
      (t.upImeiSrcDialer, _imei),
      (t.upImeiSrcSettings, _imeiSettings),
      (t.upImeiSrcBox, _imeiBox),
      (t.upImeiSrcTray, _imeiTray),
    ];
    final invalid = <String>[];
    final values = <String>[];
    for (final (srcLabel, ctrl) in entries) {
      final v = ctrl.text.trim();
      if (v.isEmpty) continue;
      values.add(v);
      if (!luhnValid(v)) invalid.add(srcLabel);
    }
    setState(() {
      _ranTamper = true;
      _invalidImeis
        ..clear()
        ..addAll(invalid);
      // Only meaningful to compare across >= 2 entered sources.
      _imeiMismatch = values.length >= 2 && !imeisMatch(values);
      // Reset the TAC confirmation each run; it is re-answered per lookup.
      _tacConfirmed = null;
      _tacAvailable = null;
      _tacBrand = null;
      _tacModel = null;
    });
    // TAC lookup only makes sense on a structurally valid dialer IMEI.
    if (luhnValid(dialer)) {
      final api = context.read<AppState>().api;
      final resp = await api.tacLookup(dialer);
      if (!mounted) return;
      final available = resp['available'] == true;
      setState(() {
        _tacAvailable = available;
        _tacBrand = available ? (resp['brand']?.toString()) : null;
        _tacModel = available ? (resp['model']?.toString()) : null;
      });
    } else {
      if (mounted) setState(() => _tacAvailable = false);
    }
  }

  Future<void> _check() async {
    final t = AppLocalizations.of(context);
    final imei = _imei.text.trim();
    if (imei.isEmpty) {
      setState(() => _error = t.upImeiEmpty);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _adviceKey = null;
      _rateLimited = false;
    });
    // Run the client-side tamper pre-check first (also fires the TAC lookup).
    await _runTamperChecks(imei);
    if (!mounted) return;
    final api = context.read<AppState>().api;
    try {
      final resp = await api.registryCheck(imei);
      if (!mounted) return;
      setState(() {
        _result = '${resp['result'] ?? ''}';
        _adviceKey = '${resp['advice_key'] ?? ''}';
        if (_result!.isEmpty) _error = t.upResultUnknown;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.status == 429) {
          _rateLimited = true;
          _error = t.upRateLimited;
        } else {
          _error = t.upCheckError;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = t.upCheckError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.upCheckTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text(t.upCheckIntro, style: const TextStyle(height: 1.35)),
          const SizedBox(height: Gap.lg),
          // --- Tamper check section: compare the IMEI across sources ---
          Text(t.upTamperTitle,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: Gap.xs),
          Text(t.upTamperIntro,
              style: TextStyle(
                  height: 1.35, color: scheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: Gap.md),
          _ImeiField(
            controller: _imei,
            label: t.upImeiSrcDialer,
            hint: t.upImeiSrcDialerHint,
            icon: Icons.dialpad,
          ),
          if (_hasVaultImei)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.auto_fix_high, size: 18),
                label: Text(t.upPrefillFromVault),
                onPressed: _prefill,
              ),
            ),
          const SizedBox(height: Gap.md),
          _ImeiField(
            controller: _imeiSettings,
            label: t.upImeiSrcSettings,
            hint: t.upImeiSrcSettingsHint,
            icon: Icons.settings_outlined,
          ),
          const SizedBox(height: Gap.md),
          _ImeiField(
            controller: _imeiBox,
            label: t.upImeiSrcBox,
            hint: t.upImeiSrcBoxHint,
            icon: Icons.inventory_2_outlined,
          ),
          const SizedBox(height: Gap.md),
          _ImeiField(
            controller: _imeiTray,
            label: t.upImeiSrcTray,
            hint: t.upImeiSrcTrayHint,
            icon: Icons.sim_card_outlined,
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search),
              label: Text(_busy ? t.upChecking : t.upCheckButton),
              onPressed: _busy ? null : _check,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Gap.md),
            _MessageCard(
              icon: _rateLimited ? Icons.hourglass_empty : Icons.error_outline,
              color: Brand.warning,
              text: _error!,
            ),
          ],
          // ---- Tamper verdict (the LOUDEST thing on the screen) ----
          if (_hasTamperWarning) ...[
            const SizedBox(height: Gap.lg),
            _TamperWarningCard(
              invalidImeis: _invalidImeis,
              mismatch: _imeiMismatch,
              tacMismatch: _tacConfirmed == false,
            ),
          ],
          // ---- TAC make/model cross-check (honest, key-gated) ----
          if (_ranTamper && _tacAvailable != null) ...[
            const SizedBox(height: Gap.md),
            _TacCard(
              available: _tacAvailable!,
              brand: _tacBrand,
              model: _tacModel,
              confirmed: _tacConfirmed,
              onAnswer: (yes) => setState(() => _tacConfirmed = yes),
            ),
          ],
          if (_result != null && _result!.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            _ResultCard(result: _result!, adviceKey: _adviceKey ?? ''),
          ],
          const SizedBox(height: Gap.lg),
          // Honest info: what changing an IMEI does (and doesn't) defeat.
          Card(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline,
                    size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.imeiHonestNote,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: scheme.onSurfaceVariant)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: Gap.md),
          // f6 (no showpieces): the "NEIR check not available yet" card is
          // hidden; the registry's limits stay explained in the footer. It
          // returns when the official NEIR check is really wired.
          if (kNeirCheckWired) ...[
            Card(
              color: scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Row(children: [
                  Icon(Icons.policy_outlined,
                      size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(_neirMessage ?? t.upNeirNotAvailable,
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.md),
          ],
          // Cross-link: if it's the user's OWN phone that's lost/stolen.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.report_gmailerrorred_outlined, size: 18),
              label: Text(t.upReportStolenLink),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ReportStolenScreen())),
            ),
          ),
          const SizedBox(height: Gap.lg),
          Text(t.upCheckFooter,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          Text(t.upHonestFooter,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// The big, colored verdict card. Colors + advice follow the backend contract:
///   clean             → green  / buy_ok
///   reported_stolen   → red    / contact_police_dont_confront
///   verified_transfer → blue   / verified_ok
class _ResultCard extends StatelessWidget {
  final String result;
  final String adviceKey;
  const _ResultCard({required this.result, required this.adviceKey});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final (Color color, IconData icon, String title, String body) =
        switch (result) {
      'reported_stolen' => (
          Brand.danger,
          Icons.gpp_bad_outlined,
          t.upResultStolenTitle,
          t.upResultStolenBody,
        ),
      'verified_transfer' => (
          Brand.blue,
          Icons.verified_outlined,
          t.upResultVerifiedTitle,
          t.upResultVerifiedBody,
        ),
      'clean' => (
          Brand.success,
          Icons.verified_user_outlined,
          t.upResultCleanTitle,
          t.upResultCleanBody,
        ),
      _ => (
          Brand.warning,
          Icons.help_outline,
          t.upResultUnknown,
          '',
        ),
    };
    return Card(
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color, size: 34),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w800,
                        fontSize: 18)),
              ),
            ]),
            if (body.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(body, style: const TextStyle(height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _MessageCard(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text)),
        ]),
      ),
    );
  }
}

/// One IMEI source input (dialer / settings / box / tray). Numeric keyboard,
/// its own hint explaining where the number is read from.
class _ImeiField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  const _ImeiField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
        prefixIcon: Icon(icon),
      ),
    );
  }
}

/// The loud red tamper warning. Lists any invalid IMEIs, the cross-source
/// mismatch, and a confirmed TAC make/model mismatch. Advises NOT to buy and to
/// inform police — never to confront the seller.
class _TamperWarningCard extends StatelessWidget {
  final List<String> invalidImeis;
  final bool mismatch;
  final bool tacMismatch;
  const _TamperWarningCard({
    required this.invalidImeis,
    required this.mismatch,
    required this.tacMismatch,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lines = <String>[
      if (mismatch) t.upTamperMismatch,
      if (tacMismatch) t.upTamperTacMismatch,
      for (final src in invalidImeis) t.upTamperInvalid(src),
    ];
    return Card(
      color: Brand.danger.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.gpp_bad_outlined, color: Brand.danger, size: 34),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.upTamperWarnTitle,
                    style: const TextStyle(
                        color: Brand.danger,
                        fontWeight: FontWeight.w800,
                        fontSize: 18)),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('•  '),
                  Expanded(child: Text(l, style: const TextStyle(height: 1.35))),
                ]),
              ),
            const SizedBox(height: Gap.xs),
            Text(t.upTamperAdvice,
                style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

/// The honest TAC make/model cross-check card. When the backend has a data
/// source it shows the brand/model and asks the user to confirm it matches the
/// ACTUAL phone (yes/no). When no source is wired up it says so plainly and
/// invents nothing.
class _TacCard extends StatelessWidget {
  final bool available;
  final String? brand;
  final String? model;
  final bool? confirmed;
  final ValueChanged<bool> onAnswer;
  const _TacCard({
    required this.available,
    required this.brand,
    required this.model,
    required this.confirmed,
    required this.onAnswer,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // f6 (no showpieces): with no TAC data source we show nothing rather
    // than a "not available yet" card — and we never guess a brand/model.
    if (!available && !kTacSourceWired) return const SizedBox.shrink();
    if (!available) {
      // HONEST: no TAC data source yet — never guess a brand/model.
      return Card(
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.help_outline, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.upTacUnavailable,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: scheme.onSurfaceVariant)),
            ),
          ]),
        ),
      );
    }
    final makeModel = [brand, model]
        .where((s) => s != null && s.trim().isNotEmpty)
        .join(' ');
    return Card(
      color: Brand.blue.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.phone_android, color: Brand.blue, size: 22),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.upTacHeading(makeModel),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, height: 1.35)),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            Text(t.upTacConfirmQuestion, style: const TextStyle(height: 1.35)),
            const SizedBox(height: Gap.sm),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onAnswer(true),
                  style: confirmed == true
                      ? OutlinedButton.styleFrom(
                          backgroundColor: Brand.success.withValues(alpha: 0.18))
                      : null,
                  child: Text(t.upTacYes),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onAnswer(false),
                  style: confirmed == false
                      ? OutlinedButton.styleFrom(
                          backgroundColor: Brand.danger.withValues(alpha: 0.18))
                      : null,
                  child: Text(t.upTacNo),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Opens the police Online GD portal (shared by the report flow). Kept here so
/// both screens can launch the same real URL without a plugin of their own.
Future<void> openOnlineGd() async {
  final uri = Uri.parse('https://gd.police.gov.bd/');
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Copy helper shared by the sell screen's token actions.
Future<void> copyToClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));
