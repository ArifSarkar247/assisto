import 'package:flutter/material.dart';

import '../../config.dart';
import '../../l10n/app_localizations.dart';
import '../../services/server_config.dart';
import '../../theme.dart';
import '../../widgets/admin_notes.dart';

/// SERVER-ADDRESS SWAP (owner/admin) — SPEC v2.1 §21 #179, ADVANCED.
///
/// Lets the owner point the app at a different backend base URL — for a staging
/// server, a self-hosted instance, or a migration — WITHOUT a rebuild. The flow
/// is deliberately safe:
///   1. type a base URL (validated: scheme + host, no path),
///   2. PROBE its reachability (`/api/v1/health`) on an independent client,
///      with an honest state indicator (checking / reachable / unreachable /
///      error + round-trip latency),
///   3. a CONFIRM GATE before saving (it changes where every request goes),
///   4. SAFE REVERT back to the shipped default, one tap away.
///
/// HONEST ABOUT APPLY: [AppConfig.apiBase] is compile-time, and this change may
/// not edit api.dart's request helpers, so the saved override is read by
/// api.dart only after the integrator wires it (one line) and/or the app
/// relaunches — the screen says so plainly and never claims a live swap it
/// can't prove. All copy via [AppLocalizations]; zero Bangla in source.
class ServerAddressScreen extends StatefulWidget {
  const ServerAddressScreen({super.key});

  @override
  State<ServerAddressScreen> createState() => _ServerAddressScreenState();
}

class _ServerAddressScreenState extends State<ServerAddressScreen> {
  final _ctrl = TextEditingController();
  String? _override; // currently-saved override (null == default)
  bool _loaded = false;
  ProbeResult? _probe; // last probe result for the typed value
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final o = await ServerConfig.readOverride();
    if (!mounted) return;
    setState(() {
      _override = o;
      _ctrl.text = o ?? '';
      _loaded = true;
    });
  }

  String _validationMsg(AppLocalizations t, String code) {
    switch (code) {
      case 'empty':
        return t.srvErrEmpty;
      case 'bad_scheme':
        return t.srvErrScheme;
      case 'no_host':
        return t.srvErrHost;
      case 'has_path':
        return t.srvErrPath;
      default:
        return t.srvErrParse;
    }
  }

  Future<void> _runProbe() async {
    final t = AppLocalizations.of(context);
    final problem = ServerConfig.validateProblem(_ctrl.text);
    if (problem.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_validationMsg(t, problem))));
      return;
    }
    setState(() {
      _probing = true;
      _probe = null;
    });
    final res = await ServerConfig.probe(_ctrl.text);
    if (!mounted) return;
    setState(() {
      _probe = res;
      _probing = false;
    });
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final problem = ServerConfig.validateProblem(_ctrl.text);
    if (problem.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_validationMsg(t, problem))));
      return;
    }
    final norm = ServerConfig.normalize(_ctrl.text)!;
    // Confirm gate — unreachable gets a sterner warning.
    final reachable = _probe?.state == ServerConfig.probeReachable;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.swap_horiz, color: Theme.of(ctx).colorScheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(t.srvConfirmTitle)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.srvConfirmBody(norm), style: const TextStyle(height: 1.4)),
            if (!reachable) ...[
              const SizedBox(height: Gap.sm),
              Text(t.srvConfirmUnverified,
                  style: TextStyle(
                      color: Brand.warning, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: Gap.sm),
            Text(t.srvApplyNote,
                style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.srvSaveConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ServerConfig.saveOverride(norm);
    if (!mounted) return;
    setState(() => _override = norm == AppConfig.apiBase ? null : norm);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.srvSavedToast)));
  }

  Future<void> _revert() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.srvRevertTitle),
        content: Text(t.srvRevertBody(AppConfig.apiBase)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.srvRevertConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ServerConfig.saveOverride(null);
    if (!mounted) return;
    setState(() {
      _override = null;
      _ctrl.text = '';
      _probe = null;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.srvRevertedToast)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: Text(t.srvTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.srvTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
        children: [
          _currentCard(t),
          const SizedBox(height: Gap.lg),
          Text(t.srvNewLabel,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) => setState(() => _probe = null),
            decoration: InputDecoration(
              hintText: t.srvHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: Gap.md),
          _probeIndicator(t),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _probing ? null : _runProbe,
                icon: _probing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check),
                label: Text(t.srvTestButton),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton.icon(
                onPressed: _probing ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(t.srvSaveButton),
              ),
            ),
          ]),
          const SizedBox(height: Gap.lg),
          AdminPrivacyNote(text: t.srvApplyNote),
          const SizedBox(height: Gap.md),
          if (_override != null)
            OutlinedButton.icon(
              onPressed: _revert,
              style: OutlinedButton.styleFrom(foregroundColor: Brand.danger),
              icon: const Icon(Icons.settings_backup_restore),
              label: Text(t.srvRevertButton),
            ),
        ],
      ),
    );
  }

  Widget _currentCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final isDefault = _override == null;
    final current = _override ?? AppConfig.apiBase;
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(isDefault ? Icons.verified_outlined : Icons.swap_horiz,
              size: 18,
              color: isDefault ? Brand.success : Brand.warning),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(isDefault ? t.srvCurrentDefault : t.srvCurrentCustom,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        SelectableText(current,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
      ]),
    );
  }

  Widget _probeIndicator(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    if (_probing) {
      return _probeRow(Icons.sync, scheme.primary, t.srvProbeChecking, null);
    }
    final p = _probe;
    if (p == null) {
      return _probeRow(
          Icons.help_outline, scheme.onSurfaceVariant, t.srvProbeIdle, null);
    }
    switch (p.state) {
      case ServerConfig.probeReachable:
        return _probeRow(Icons.check_circle_outline, Brand.success,
            t.srvProbeReachable, t.srvProbeLatency('${p.latencyMs}'));
      case ServerConfig.probeUnreachable:
        return _probeRow(Icons.error_outline, Brand.warning,
            t.srvProbeUnreachable('${p.status}'), null);
      default:
        return _probeRow(
            Icons.cloud_off_outlined, Brand.danger, t.srvProbeError, null);
    }
  }

  Widget _probeRow(IconData icon, Color color, String title, String? sub) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(fontWeight: FontWeight.w600, color: color)),
            if (sub != null)
              Text(sub,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}
