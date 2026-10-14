import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../admin_flags_api.dart';
import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/admin_notes.dart';
import '../../widgets/skeleton.dart';

/// COST KILL-SWITCH & FEATURE FLAGS (owner/superuser) — SPEC v2.1 §21 #178,
/// ADVANCED.
///
/// One console for every operational flag: the cost-sensitive "kill switches"
/// (anything that spends money — AI calls, SMS/push fan-out, cloud media,
/// maps) and plain feature toggles. Flipping anything that affects cost, or
/// disables a user-facing feature, runs a CONFIRM GATE that demands a typed
/// reason; every flip writes an append-only AUDIT row (who / what / old→new /
/// when / why) rendered as a reviewer-grade timeline.
///
/// The backend (`core.logic.admin_flags`) is the authority and re-validates
/// every flip; the on-device [FlagCatalog] only predicts the confirm gate for
/// snappy UX. Owner-only: the entry point is pre-gated and the backend returns
/// 403 (shown as the owner-only state). All copy via [AppLocalizations] — zero
/// Bangla in source.
class CostFlagsScreen extends StatefulWidget {
  const CostFlagsScreen({super.key});

  @override
  State<CostFlagsScreen> createState() => _CostFlagsScreenState();
}

enum _Status { loading, ok, error, ownerOnly }

class _CostFlagsScreenState extends State<CostFlagsScreen> {
  _Status _status = _Status.loading;
  String _error = '';
  List<Map<String, dynamic>> _flags = const [];
  List<Map<String, dynamic>> _audit = const [];
  Map<String, dynamic> _summary = const {};
  String? _busyFlag; // flag currently being flipped (disables its switch)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = _Status.loading);
    try {
      final r = await context.read<AppState>().api.adminFlags();
      if (!mounted) return;
      setState(() {
        _flags = (r['flags'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _audit = (r['audit'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _summary = (r['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
        _status = _Status.ok;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.status == 403) {
          _status = _Status.ownerOnly;
        } else {
          _error = e.message;
          _status = _Status.error;
        }
      });
    } catch (_) {
      // Network / unexpected error — show the friendly localized body (line 297
      // falls back to t.flagLoadErrorBody when _error is empty), never a raw
      // exception string.
      if (!mounted) return;
      setState(() {
        _error = '';
        _status = _Status.error;
      });
    }
  }

  // Localized human label for a stable flag id (no Bangla in source).
  String _flagLabel(AppLocalizations t, String id) {
    switch (id) {
      case 'ai_drafting':
        return t.flagAiDrafting;
      case 'ai_inbox_summary':
        return t.flagAiInboxSummary;
      case 'ai_scam_check':
        return t.flagAiScamCheck;
      case 'sms_fanout':
        return t.flagSmsFanout;
      case 'push_fanout':
        return t.flagPushFanout;
      case 'cloud_photo_enhance':
        return t.flagCloudPhotoEnhance;
      case 'maps_geocoding':
        return t.flagMapsGeocoding;
      case 'messenger_public':
        return t.flagMessengerPublic;
      case 'business_crm':
        return t.flagBusinessCrm;
      case 'family_sharing':
        return t.flagFamilySharing;
      case 'new_signups':
        return t.flagNewSignups;
      default:
        return id;
    }
  }

  String _groupLabel(AppLocalizations t, String g) {
    switch (g) {
      case 'ai':
        return t.flagGroupAi;
      case 'messaging':
        return t.flagGroupMessaging;
      case 'media':
        return t.flagGroupMedia;
      case 'location':
        return t.flagGroupLocation;
      case 'features':
        return t.flagGroupFeatures;
      case 'ops':
        return t.flagGroupOps;
      default:
        return g;
    }
  }

  String _confirmBody(AppLocalizations t, String code, String label) {
    switch (code) {
      case 'enable_cost':
        return t.flagConfirmEnableCost(label);
      case 'disable_cost':
        return t.flagConfirmDisableCost(label);
      case 'disable_feature':
        return t.flagConfirmDisableFeature(label);
      default:
        return t.flagConfirmGeneric(label);
    }
  }

  Future<void> _onToggle(Map<String, dynamic> flag, bool newValue) async {
    final t = AppLocalizations.of(context);
    final id = flag['id'] as String;
    final kind = (flag['kind'] as String?) ?? FlagCatalog.kindFeature;
    final label = _flagLabel(t, id);
    final code = FlagCatalog.confirmCode(kind, newValue);
    final needsConfirm = FlagCatalog.needsConfirm(kind, newValue);

    String reason = '';
    if (needsConfirm) {
      final confirmed = await _confirmWithReason(
        title: newValue ? t.flagEnableTitle(label) : t.flagDisableTitle(label),
        body: _confirmBody(t, code, label),
        danger: kind == FlagCatalog.kindCost || newValue == false,
        onReason: (r) => reason = r,
        isCost: kind == FlagCatalog.kindCost,
      );
      if (confirmed != true) return;
    }

    setState(() => _busyFlag = id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r =
          await context.read<AppState>().api.adminFlipFlag(id, newValue, reason);
      if (!mounted) return;
      setState(() {
        _flags = (r['flags'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _audit = (r['audit'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _summary = (r['summary'] as Map?)?.cast<String, dynamic>() ?? _summary;
        _busyFlag = null;
      });
      messenger.showSnackBar(SnackBar(
          content: Text(
              newValue ? t.flagEnabledToast(label) : t.flagDisabledToast(label))));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busyFlag = null);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyFlag = null);
      messenger.showSnackBar(SnackBar(content: Text(t.flagFlipFailed(e))));
    }
  }

  Future<bool?> _confirmWithReason({
    required String title,
    required String body,
    required bool danger,
    required bool isCost,
    required void Function(String) onReason,
  }) {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final scheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final hasReason = ctrl.text.trim().isNotEmpty;
          return AlertDialog(
            title: Row(children: [
              Icon(isCost ? Icons.payments_outlined : Icons.flag_outlined,
                  color: danger ? Brand.danger : scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(title)),
            ]),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(body, style: const TextStyle(height: 1.4)),
                const SizedBox(height: Gap.md),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (_) => setD(() {}),
                  decoration: InputDecoration(
                    labelText: t.flagReasonLabel,
                    hintText: t.flagReasonHint,
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: Gap.sm),
                Text(t.flagAuditedNote,
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.cancel)),
              FilledButton(
                style: danger
                    ? FilledButton.styleFrom(backgroundColor: Brand.danger)
                    : null,
                onPressed: hasReason
                    ? () {
                        onReason(ctrl.text.trim());
                        Navigator.pop(ctx, true);
                      }
                    : null,
                child: Text(t.flagConfirmFlip),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.costFlagsTitle),
        actions: [
          if (_status == _Status.ok)
            IconButton(
              tooltip: t.refresh,
              icon: const Icon(Icons.refresh),
              onPressed: _load,
            ),
        ],
      ),
      body: switch (_status) {
        _Status.loading => const SkeletonList(),
        _Status.ownerOnly => StateMessage(
            icon: Icons.admin_panel_settings_outlined,
            title: t.flagOwnerOnlyTitle,
            message: t.flagOwnerOnlyBody,
            tint: Brand.warning,
          ),
        _Status.error => StateMessage(
            icon: Icons.cloud_off_outlined,
            title: t.flagLoadErrorTitle,
            message: _error.isEmpty ? t.flagLoadErrorBody : _error,
            tint: Brand.danger,
            action: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry),
            ),
          ),
        _Status.ok => _buildBody(t),
      },
    );
  }

  Widget _buildBody(AppLocalizations t) {
    if (_flags.isEmpty) {
      return StateMessage(
        icon: Icons.toggle_off_outlined,
        title: t.flagEmptyTitle,
        message: t.flagEmptyBody,
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text(t.refresh),
        ),
      );
    }
    // Group flags by their group, preserving server order.
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final f in _flags) {
      (groups[(f['group'] as String?) ?? 'features'] ??= []).add(f);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
        children: [
          _summaryCard(t),
          const SizedBox(height: Gap.md),
          AdminPrivacyNote(text: t.flagKillSwitchNote),
          const SizedBox(height: Gap.lg),
          for (final entry in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(2, Gap.sm, 0, Gap.xs),
              child: Text(_groupLabel(t, entry.key),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary)),
            ),
            for (final f in entry.value) _flagTile(t, f),
            const SizedBox(height: Gap.sm),
          ],
          const SizedBox(height: Gap.md),
          _auditSection(t),
        ],
      ),
    );
  }

  Widget _summaryCard(AppLocalizations t) {
    final costOn = _summary['cost_on'] ?? 0;
    final costTotal = _summary['cost_total'] ?? 0;
    final featOff = _summary['features_off'] ?? 0;
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.flagSummaryCostLine('$costOn', '$costTotal'),
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 4),
        Text(
            featOff == 0
                ? t.flagSummaryAllFeaturesOn
                : t.flagSummaryFeaturesOff('$featOff'),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.92))),
      ]),
    );
  }

  Widget _flagTile(AppLocalizations t, Map<String, dynamic> f) {
    final scheme = Theme.of(context).colorScheme;
    final id = f['id'] as String;
    final kind = (f['kind'] as String?) ?? FlagCatalog.kindFeature;
    final value = f['value'] == true;
    final isCost = kind == FlagCatalog.kindCost;
    final busy = _busyFlag == id;
    // Honest state pill: a cost switch that is ON is "spending"; a feature
    // that is OFF is "disabled for everyone".
    final pillColor = isCost
        ? (value ? Brand.warning : scheme.onSurfaceVariant)
        : (value ? Brand.success : Brand.danger);
    final pillText = isCost
        ? (value ? t.flagPillSpending : t.flagPillOff)
        : (value ? t.flagPillOn : t.flagPillDisabled);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(
          color: isCost
              ? Brand.warning.withValues(alpha: 0.35)
              : scheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
        child: Row(children: [
          Icon(isCost ? Icons.payments_outlined : Icons.flag_outlined,
              size: 20, color: isCost ? Brand.warning : scheme.primary),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_flagLabel(t, id),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Gap.sm, vertical: 2),
                    decoration: BoxDecoration(
                      color: pillColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Text(pillText,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: pillColor)),
                  ),
                  if (isCost) ...[
                    const SizedBox(width: Gap.sm),
                    Text(t.flagCostTag,
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                  ],
                ]),
              ],
            ),
          ),
          busy
              ? const SizedBox(
                  width: 40,
                  height: 24,
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))))
              : Switch(
                  value: value,
                  onChanged:
                      _busyFlag != null ? null : (v) => _onToggle(f, v),
                ),
        ]),
      ),
    );
  }

  Widget _auditSection(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('d MMM, h:mm a');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.history, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Text(t.flagAuditTitle,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 4),
      Text(t.flagAuditAppendOnly,
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      if (_audit.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.lg),
          child: Text(t.flagAuditEmpty,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        )
      else
        for (int i = 0; i < _audit.length; i++)
          _auditRow(t, _audit[i], fmt, i == 0, i == _audit.length - 1),
    ]);
  }

  Widget _auditRow(AppLocalizations t, Map<String, dynamic> a,
      DateFormat fmt, bool first, bool last) {
    final id = (a['flag'] as String?) ?? '';
    final label = _flagLabel(t, id);
    final newVal = a['new'] == true;
    final color = newVal ? Brand.success : Brand.danger;
    final icon = newVal ? Icons.toggle_on_outlined : Icons.toggle_off_outlined;
    String whenMeta;
    final at = a['at'];
    DateTime? dt;
    if (at is String) dt = DateTime.tryParse(at);
    final actor = (a['actor'] ?? '').toString();
    whenMeta = dt != null
        ? t.flagAuditMeta(actor, fmt.format(dt.toLocal()))
        : t.flagAuditMeta(actor, at?.toString() ?? '');
    return AdminTimelineEntry(
      icon: icon,
      color: color,
      title: newVal ? t.flagAuditEnabled(label) : t.flagAuditDisabled(label),
      reason: (a['reason'] ?? '').toString(),
      meta: whenMeta,
      isFirst: first,
      isLast: last,
    );
  }
}
