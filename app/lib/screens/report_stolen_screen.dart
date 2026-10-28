import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'registry_imei.dart';
import 'used_phone_check_screen.dart' show openOnlineGd;
import 'package:assisto/widgets/app_sheet.dart';

/// Report-my-phone-stolen + mark-recovered, backed by the COMMUNITY registry.
///
/// HONESTY: filing a report here does NOT block the phone on the mobile network
/// (that is NEIR, not available yet). It warns the Assisto community: anyone who
/// later checks this IMEI (Used-phone check) sees a 'reported_stolen' verdict.
/// The user is told to file an Online police GD first — the GD number is
/// required — and to keep working with the police; we never advise confronting
/// whoever has the phone.
///
/// Reachable from the Sell screen AND the Used-phone check screen; it is NOT a
/// separate top-level sidebar entry (keeps the net new entries to two).
class ReportStolenScreen extends StatefulWidget {
  const ReportStolenScreen({super.key});

  @override
  State<ReportStolenScreen> createState() => _ReportStolenScreenState();
}

class _ReportStolenScreenState extends State<ReportStolenScreen> {
  final _imei = TextEditingController();
  final _gd = TextEditingController();
  final _model = TextEditingController();
  final _area = TextEditingController();

  bool _busy = false;
  bool _hasVaultImei = false;

  @override
  void initState() {
    super.initState();
    _probeVault();
  }

  @override
  void dispose() {
    _imei.dispose();
    _gd.dispose();
    _model.dispose();
    _area.dispose();
    super.dispose();
  }

  Future<void> _probeVault() async {
    final imei = await RegistryImei.fromVault(context);
    if (mounted && imei != null && imei.isNotEmpty) {
      setState(() {
        _hasVaultImei = true;
        if (_imei.text.trim().isEmpty) _imei.text = imei;
      });
    }
  }

  Future<void> _prefill() async {
    final imei = await RegistryImei.fromVault(context);
    if (imei != null && imei.isNotEmpty) setState(() => _imei.text = imei);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _report() async {
    final t = AppLocalizations.of(context);
    final imei = _imei.text.trim();
    final gd = _gd.text.trim();
    if (imei.isEmpty || gd.isEmpty) {
      _snack(t.upReportNeedFields);
      return;
    }
    setState(() => _busy = true);
    final api = context.read<AppState>().api;
    try {
      await api.registryReportStolen(
        imei: imei,
        gdNumber: gd,
        model: _model.text.trim(),
        area: _area.text.trim(),
      );
      if (mounted) _snack(t.upReportDone);
    } on ApiException {
      if (mounted) _snack(t.upReportError);
    } catch (_) {
      if (mounted) _snack(t.upReportError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recover() async {
    final t = AppLocalizations.of(context);
    final imei = _imei.text.trim();
    if (imei.isEmpty) {
      _snack(t.upImeiEmpty);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.upRecoverConfirmTitle),
        content: Text(t.upRecoverConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.upRecoverButton)),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final api = context.read<AppState>().api;
    try {
      await api.registryRecover(imei);
      if (mounted) _snack(t.upRecoverDone);
    } on ApiException {
      if (mounted) _snack(t.upRecoverError);
    } catch (_) {
      if (mounted) _snack(t.upRecoverError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.upReportTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Text(t.upReportIntro, style: const TextStyle(height: 1.35)),
          const SizedBox(height: Gap.md),
          // File-GD-first affordance.
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(t.upReportGdOpen),
              onPressed: openOnlineGd,
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _imei,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t.upImeiLabel,
              helperText: t.upImeiHint,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.smartphone_rounded),
            ),
          ),
          if (_hasVaultImei)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: Text(t.upPrefillFromVault),
                onPressed: _prefill,
              ),
            ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _gd,
            decoration: InputDecoration(
              labelText: t.upReportGdLabel,
              helperText: t.upReportGdHint,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.description_rounded),
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _model,
            decoration: InputDecoration(
              labelText: t.upFieldModel,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.phone_android_rounded),
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _area,
            decoration: InputDecoration(
              labelText: t.upReportAreaLabel,
              helperText: t.upReportAreaHint,
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.place_rounded),
            ),
          ),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: Brand.dangerButton(),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.report_rounded),
              label: Text(t.upReportButton),
              onPressed: _busy ? null : _report,
            ),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: Text(t.upRecoverButton),
              onPressed: _busy ? null : _recover,
            ),
          ),
          const SizedBox(height: Gap.lg),
          Text(t.upHonestFooter,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
