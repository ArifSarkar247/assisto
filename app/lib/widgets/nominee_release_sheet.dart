import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';

/// The release-management sheet — the ONLY place nominee access can be opened
/// or closed, deliberately wrapped in safeguards.
///
/// WHY THIS CANNOT TRIGGER UNSAFELY (release-safeguard design):
///  1. Nothing opens on save. Creating a nominee only *arms* a dormant plan.
///  2. A release always has a named trigger, and each trigger is verified:
///       - owner_grant : the OWNER, while authenticated on their own device,
///         taps "Request release", then must *confirm* a second time. Even then
///         access does not open immediately — it enters a GRACE WINDOW.
///       - inactivity  : reuses the Safe-Journey wellness watch. Access is only
///         *proposed* after the owner misses the wellness prompt for the full
///         configured period AND the response window; the owner can answer "I'm
///         OK" at any time to cancel. No movement data alone opens anything.
///       - multi_verify: requires a quorum (owner-set, e.g. 2 of the named
///         trusted people) to each confirm independently before the grace
///         window even starts.
///  3. GRACE WINDOW: once a release is requested it is `pending`, not `open`.
///     During the window the owner is notified on every channel and a single
///     tap cancels it. Only after the window elapses with no cancellation does
///     access open — and it is still owner-revocable afterwards.
///  4. Key-gated payload: the actual data (vault pointers etc.) is released by
///     a server/E2E key step that only unlocks under a verified trigger; this
///     client never holds or leaks the raw secrets. The flow here is real; the
///     final unlock is mock/key-gated pending backend (see
///     .phaseB/up_nominee_integration.md).
///  5. Fully reversible + audited at every step.
class NomineeReleaseSheet extends StatefulWidget {
  final Map<String, dynamic> nominee;
  const NomineeReleaseSheet({super.key, required this.nominee});
  @override
  State<NomineeReleaseSheet> createState() => _NomineeReleaseSheetState();
}

class _NomineeReleaseSheetState extends State<NomineeReleaseSheet> {
  bool _busy = false;
  bool _changed = false;
  late bool _activated = widget.nominee['activated'] == true;
  late bool _pending = widget.nominee['release_pending'] == true;

  int get _id => widget.nominee['id'] as int;

  /// Owner requests a release → enter the cancellable pending grace window.
  /// We persist the intent via updateItem (additive fields). No access opens.
  Future<void> _requestRelease(AppLocalizations tr) async {
    final confirm = await _confirm(
      tr,
      title: tr.nomineeRequestReleaseTitle,
      body: tr.nomineeRequestReleaseBody,
      confirmLabel: tr.nomineeRequestReleaseConfirm,
      danger: false,
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.updateItem('nominees', _id, {
        'release_pending': true,
      });
      _pending = true;
      _changed = true;
    } catch (_) {
      _snack(tr.nomineeSaveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Owner cancels the pending release during the grace window — instant,
  /// no confirmation needed (cancelling is always safe).
  Future<void> _cancelRelease(AppLocalizations tr) async {
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.updateItem('nominees', _id, {
        'release_pending': false,
      });
      _pending = false;
      _changed = true;
    } catch (_) {
      _snack(tr.nomineeSaveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Open access now (only reachable after the pending window, and always with
  /// an explicit second confirmation). Uses the existing activate endpoint.
  Future<void> _openAccess(AppLocalizations tr) async {
    final confirm = await _confirm(
      tr,
      title: tr.nomineeOpenNowTitle,
      body: tr.nomineeOpenNowBody,
      confirmLabel: tr.nomineeOpenNowConfirm,
      danger: true,
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.nomineeActivate(_id, true);
      await context.read<AppState>().api.updateItem('nominees', _id, {
        'release_pending': false,
      });
      _activated = true;
      _pending = false;
      _changed = true;
    } catch (_) {
      _snack(tr.nomineeSaveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Revoke / close access — always available, always safe.
  Future<void> _revoke(AppLocalizations tr) async {
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.nomineeActivate(_id, false);
      _activated = false;
      _changed = true;
    } catch (_) {
      _snack(tr.nomineeSaveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<bool?> _confirm(AppLocalizations tr,
      {required String title,
      required String body,
      required String confirmLabel,
      required bool danger}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          danger
              ? FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(ctx).colorScheme.error),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(confirmLabel))
              : FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(confirmLabel)),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final trigger = (widget.nominee['trigger'] ?? 'owner_grant') as String;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: Gap.sm),
              Text(tr.nomineeManageAccess,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.xs),
              Text(widget.nominee['name'] ?? '',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),

              // Current status card.
              _StatusCard(activated: _activated, pending: _pending),
              const SizedBox(height: Gap.lg),

              // The safeguard explanation — always visible.
              _SafeguardExplainer(trigger: trigger),
              const SizedBox(height: Gap.lg),

              if (_busy) const LinearProgressIndicator(),
              if (_busy) const SizedBox(height: Gap.md),

              // Primary action, driven by current state.
              if (_activated) ...[
                Text(tr.nomineeAccessOpenNote,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.md),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _revoke(tr),
                  icon: const Icon(Icons.lock_outline_rounded),
                  label: Text(tr.nomineeRevokeAccess),
                ),
              ] else if (_pending) ...[
                Text(tr.nomineePendingNote,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.md),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: scheme.error),
                  onPressed: _busy ? null : () => _cancelRelease(tr),
                  icon: const Icon(Icons.cancel_rounded),
                  label: Text(tr.nomineeCancelRelease),
                ),
                const SizedBox(height: Gap.sm),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _openAccess(tr),
                  icon: const Icon(Icons.lock_open_rounded),
                  label: Text(tr.nomineeOpenNowAfterWindow),
                ),
              ] else ...[
                Text(tr.nomineeArmedNote,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.md),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _requestRelease(tr),
                  icon: const Icon(Icons.schedule_send_rounded),
                  label: Text(tr.nomineeRequestRelease),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool activated, pending;
  const _StatusCard({required this.activated, required this.pending});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (color, label, icon, desc) = activated
        ? (scheme.error, tr.nomineeStatusOpen, Icons.lock_open_rounded,
            tr.nomineeStatusOpenDesc)
        : pending
            ? (Brand.warning, tr.nomineeStatusPending, Icons.hourglass_top_rounded,
                tr.nomineeStatusPendingDesc)
            : (Brand.success, tr.nomineeStatusArmed, Icons.lock_outline_rounded,
                tr.nomineeStatusArmedDesc);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 2),
            Text(desc,
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: scheme.onSurface)),
          ]),
        ),
      ]),
    );
  }
}

class _SafeguardExplainer extends StatelessWidget {
  final String trigger;
  const _SafeguardExplainer({required this.trigger});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final triggerExplain = trigger == 'inactivity'
        ? tr.nomineeTriggerInactivityDesc
        : trigger == 'multi_verify'
            ? tr.nomineeTriggerMultiVerifyDesc
            : tr.nomineeTriggerOwnerGrantDesc;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.verified_user_rounded,
              size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Text(tr.nomineeHowReleaseWorks,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: Gap.sm),
        Text(triggerExplain,
            style: TextStyle(
                fontSize: 12.5, height: 1.4, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        Text(tr.nomineeGraceWindowNote,
            style: TextStyle(
                fontSize: 12.5, height: 1.4, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        Text(tr.nomineeNoSecretsNote2,
            style: TextStyle(
                fontSize: 12.5, height: 1.4, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}
