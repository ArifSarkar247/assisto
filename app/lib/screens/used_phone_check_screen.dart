import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'report_stolen_screen.dart';
import 'registry_imei.dart';

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
  final _imei = TextEditingController();

  bool _busy = false;
  String? _result; // 'clean' | 'reported_stolen' | 'verified_transfer'
  String? _adviceKey;
  String? _error; // friendly, already-localized error line
  bool _rateLimited = false;

  String? _neirMessage; // honest placeholder ("not available yet")
  bool _hasVaultImei = false;

  @override
  void initState() {
    super.initState();
    _loadNeir();
    _probeVaultImei();
  }

  @override
  void dispose() {
    _imei.dispose();
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
          TextField(
            controller: _imei,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t.upImeiLabel,
              helperText: t.upImeiHint,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.smartphone_outlined),
            ),
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
          if (_result != null && _result!.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            _ResultCard(result: _result!, adviceKey: _adviceKey ?? ''),
          ],
          const SizedBox(height: Gap.lg),
          // Honest NEIR placeholder.
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
