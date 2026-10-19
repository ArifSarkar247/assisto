import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/password_field.dart';
import '../services/security_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'journey_start_screen.dart';

/// Section 8 — Stolen-While-Unlocked Protection hub.
///
/// HONESTY CONTRACT: Assisto cannot stop a thief who already knows your
/// Security PIN, and it never enforces OS settings. What the SERVER does add:
///   - a DELAY before a sensitive action (sell/transfer, disarm, remove admin,
///     change contacts, turn off lost mode, change PIN, export data) takes
///     effect — cancellable until then;
///   - an ALERT to you (other devices / email) and your trusted contacts;
///   - a server-held OWNERSHIP record so a snatched phone can't instantly be
///     sold or wiped-of-ownership.
///
/// The Assisto Security PIN is SEPARATE from the phone screen lock. Disarm and
/// other destructive actions route through [SecurityGuard.run] so they respect
/// the delay / freeze / approval rules.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});
  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  static const _guard = SecurityGuard();

  bool _loading = true;
  bool _error = false;
  bool _busy = false;
  Map<String, dynamic> _state = const {};
  List<Map<String, dynamic>> _members = const [];

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final s = await _api.securityState();
      List<Map<String, dynamic>> members = const [];
      try {
        final m = await _api.getJson('/circle/members');
        members = ((m['results'] ?? m['members'] ?? []) as List)
            .cast<Map<String, dynamic>>()
            .where((e) => '${e['state'] ?? 'accepted'}' == 'accepted')
            .toList();
      } catch (_) {/* approver picker is best-effort */}
      if (!mounted) return;
      setState(() {
        _state = s;
        _members = members;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  bool get _hasPin => _state['has_pin'] == true;
  bool get _armed => _state['armed'] == true;
  DateTime? get _frozenUntil {
    final v = _state['frozen_until'];
    return v == null ? null : DateTime.tryParse('$v')?.toLocal();
  }

  bool get _isFrozen =>
      _frozenUntil != null && _frozenUntil!.isAfter(DateTime.now());

  String get _status => '${_state['status'] ?? 'owned'}';
  int get _trustedPlaces => (_state['trusted_place_count'] as num?)?.toInt() ?? 0;
  int get _wrongPin => (_state['wrong_pin_count'] as num?)?.toInt() ?? 0;

  List<Map<String, dynamic>> get _pending =>
      ((_state['pending'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmtDate(DateTime d) {
    final locale = Localizations.localeOf(context).languageCode;
    return DateFormat('EEE d MMM, h:mm a', locale).format(d);
  }

  // ---- PIN set / change ---------------------------------------------------

  Future<void> _setPin() async {
    final tr = AppLocalizations.of(context);
    final res = await _askSetPin(tr, requireCurrent: _hasPin);
    if (res == null) return;
    setState(() => _busy = true);
    try {
      final r = await _api.securityPinSet(res.$2, currentPin: res.$1);
      if (r['ok'] == true) {
        _snack(tr.securityPinSaved);
        await _load();
      } else {
        _snack(tr.securityPinSetFailed);
      }
    } catch (_) {
      _snack(tr.securityActionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Returns (currentPin?, newPin) or null if cancelled.
  Future<(String?, String)?> _askSetPin(AppLocalizations tr,
      {required bool requireCurrent}) async {
    final cur = TextEditingController();
    final a = TextEditingController();
    final b = TextEditingController();
    String? error;
    return showDialog<(String?, String)?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(requireCurrent
              ? tr.securityChangePinTitle
              : tr.securitySetPinTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr.securityPinSeparateNote,
                    style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: Gap.sm),
                if (requireCurrent)
                  ObscureTextField(
                    controller: cur,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    decoration:
                        InputDecoration(labelText: tr.securityCurrentPinLabel),
                  ),
                ObscureTextField(
                  controller: a,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration:
                      InputDecoration(labelText: tr.securityNewPinLabel),
                ),
                ObscureTextField(
                  controller: b,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration:
                      InputDecoration(labelText: tr.securityConfirmPinLabel),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text(error!,
                        style:
                            TextStyle(color: Theme.of(ctx).colorScheme.error)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr.cancel),
            ),
            FilledButton(
              onPressed: () {
                final na = a.text.trim();
                if (na.length < 4) {
                  setD(() => error = tr.securityPinTooShort);
                  return;
                }
                if (na != b.text.trim()) {
                  setD(() => error = tr.securityPinMismatch);
                  return;
                }
                if (requireCurrent && cur.text.trim().isEmpty) {
                  setD(() => error = tr.securityCurrentPinRequired);
                  return;
                }
                Navigator.pop(
                    ctx, (requireCurrent ? cur.text.trim() : null, na));
              },
              child: Text(tr.save),
            ),
          ],
        ),
      ),
    );
  }

  // ---- arm / disarm -------------------------------------------------------

  Future<void> _arm() async {
    final tr = AppLocalizations.of(context);
    if (!_hasPin) {
      _snack(tr.securityNeedPinFirst);
      return;
    }
    // Arming raises protection (not destructive) but still needs the Security
    // PIN so a thief with an unlocked phone can't quietly change the setup.
    final pin = await _guard.askPin(context, tr);
    if (pin == null || pin.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await _api.securityArm(pin);
      if (r['ok'] == true) {
        _snack(tr.securityArmed);
      } else if (r['locked'] == true) {
        _snack(tr.securityLockedOut);
      } else {
        _snack(tr.securityBadPin);
      }
      await _load();
    } catch (_) {
      _snack(tr.securityActionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disarm() async {
    final tr = AppLocalizations.of(context);
    if (!_hasPin) {
      _snack(tr.securityNeedPinFirst);
      return;
    }
    // Disarm is destructive → full gate (biometric + PIN + delay/freeze).
    final r = await _guard.run(context, 'disarm');
    if (!mounted) return;
    if (r.state == SecActionState.applied || r.state == SecActionState.pending) {
      await _load();
    }
  }

  Future<void> _cancelPending(Map<String, dynamic> item) async {
    final tr = AppLocalizations.of(context);
    final id = (item['id'] as num?)?.toInt();
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.securityCancelConfirmTitle),
        content: Text(tr.securityCancelConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.close),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.securityWasntMe),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _api.securityCancel(id);
      _snack(tr.securityCancelled);
      await _load();
    } catch (_) {
      _snack(tr.securityActionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.securityTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? _errorState(tr)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(Gap.md),
                    children: [
                      if (_isFrozen) ...[
                        _frozenBanner(tr),
                        const SizedBox(height: Gap.md),
                      ],
                      _statusCard(tr),
                      const SizedBox(height: Gap.md),
                      _pinCard(tr),
                      const SizedBox(height: Gap.md),
                      _armCard(tr),
                      const SizedBox(height: Gap.md),
                      if (_pending.isNotEmpty) ...[
                        _pendingCard(tr),
                        const SizedBox(height: Gap.md),
                      ],
                      _approverCard(tr),
                      const SizedBox(height: Gap.md),
                      _honestCard(tr),
                      const SizedBox(height: Gap.xl),
                    ],
                  ),
                ),
    );
  }

  Widget _errorState(AppLocalizations tr) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: Gap.md),
              Text(tr.securityLoadFailed, textAlign: TextAlign.center),
              const SizedBox(height: Gap.md),
              FilledButton(
                  onPressed: _load, child: Text(tr.securityRetry)),
            ],
          ),
        ),
      );

  Widget _frozenBanner(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: Brand.danger.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(
          children: [
            const Icon(Icons.ac_unit, color: Brand.danger, size: 28),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.securityFrozenTitle,
                      style: TextStyle(
                          color: Brand.danger,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                    tr.securityFrozenUntil(_fmtDate(_frozenUntil!)),
                    style: TextStyle(
                        color: scheme.onSurface, fontSize: 13, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    final armed = _armed;
    final fg = armed ? Brand.success : Brand.warning;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(armed ? Icons.verified_user : Icons.gpp_maybe,
                    color: fg, size: 32),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        armed
                            ? tr.securityStateArmed
                            : tr.securityStateDisarmed,
                        style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w700,
                            fontSize: 16),
                      ),
                      Text(_statusLabel(tr),
                          style: TextStyle(
                              color: scheme.onSurfaceVariant, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: Gap.lg),
            // Trusted places link → Safe Journey places.
            InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const JourneyStartScreen())),
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: Row(
                  children: [
                    const Icon(Icons.place_outlined, size: 20),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(tr.securityTrustedPlaces(
                          fmtInt(context, _trustedPlaces))),
                    ),
                    const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
              ),
            ),
            if (_wrongPin > 0)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(
                  tr.securityWrongPinCount(fmtInt(context, _wrongPin)),
                  style: TextStyle(color: Brand.warning, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(AppLocalizations tr) {
    switch (_status) {
      case 'reported_stolen':
        return tr.securityStatusReportedStolen;
      case 'transfer_pending':
        return tr.securityStatusTransferPending;
      case 'transferred':
        return tr.securityStatusTransferred;
      default:
        return tr.securityStatusOwned;
    }
  }

  Widget _pinCard(AppLocalizations tr) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.pin_outlined),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(tr.securityPinCardTitle,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
                TextButton(
                  onPressed: _busy ? null : _setPin,
                  child: Text(
                      _hasPin ? tr.securityChangePin : tr.securitySetPin),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              _hasPin ? tr.securityPinIsSet : tr.securityPinNotSet,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.xs),
            Text(tr.securityPinSeparateNote,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _armCard(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.securityArmCardTitle,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: Gap.xs),
            Text(tr.securityArmCardBody,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: Gap.sm),
            SizedBox(
              width: double.infinity,
              child: _armed
                  ? OutlinedButton.icon(
                      icon: const Icon(Icons.lock_open_outlined),
                      label: Text(tr.securityDisarm),
                      onPressed: _busy ? null : _disarm,
                    )
                  : FilledButton.icon(
                      icon: const Icon(Icons.shield_outlined),
                      label: Text(tr.securityArm),
                      onPressed: _busy ? null : _arm,
                    ),
            ),
            if (_armed)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(tr.securityDisarmNote,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _pendingCard(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: Brand.warning.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.securityPendingCardTitle,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: Gap.xs),
            Text(tr.securityPendingCardBody,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 12)),
            const SizedBox(height: Gap.sm),
            for (final p in _pending) _pendingRow(tr, p),
          ],
        ),
      ),
    );
  }

  Widget _pendingRow(AppLocalizations tr, Map<String, dynamic> p) {
    final eff = p['effective_at'] == null
        ? null
        : DateTime.tryParse('${p['effective_at']}')?.toLocal();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_actionLabel(tr, '${p['action'] ?? ''}'),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (eff != null)
                  Text(tr.securityEffectiveAt(_fmtDate(eff)),
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: Gap.sm),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.block, size: 18),
            label: Text(tr.securityWasntMe),
            onPressed: _busy ? null : () => _cancelPending(p),
          ),
        ],
      ),
    );
  }

  String _actionLabel(AppLocalizations tr, String action) {
    switch (action) {
      case 'sell_transfer':
        return tr.securityActionSellTransfer;
      case 'disarm':
        return tr.securityActionDisarm;
      case 'remove_admin':
        return tr.securityActionRemoveAdmin;
      case 'change_contacts':
        return tr.securityActionChangeContacts;
      case 'turn_off_lost':
        return tr.securityActionTurnOffLost;
      case 'change_pin':
        return tr.securityActionChangePin;
      case 'export_data':
        return tr.securityActionExportData;
      default:
        return action;
    }
  }

  Future<void> _setApprover(int? id) async {
    final tr = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await _api.securitySetApprover(id);
      await _load();
    } catch (_) {
      _snack(tr.securityActionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _approverCard(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    // Backend persists the choice via POST security/approver; sell/disarm then
    // need this accepted circle member's OK (awaiting_approval) before applying.
    final cands = (_state['approver_candidates'] as List?) ?? const [];
    final current = _state['family_approver'] as Map?;
    final currentId = current?['id'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.diversity_1_outlined),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(tr.securityApproverTitle,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(tr.securityApproverBody,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: Gap.sm),
            if (cands.isEmpty)
              Text(tr.securityApproverNone,
                  style: Theme.of(context).textTheme.bodySmall)
            else ...[
              Text(tr.securityApproverCandidates,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  for (final m in cands)
                    ChoiceChip(
                      avatar: const Icon(Icons.person_outline, size: 18),
                      label: Text('${m['name'] ?? ''}'),
                      selected: m['id'] == currentId,
                      onSelected: _busy
                          ? null
                          : (sel) => _setApprover(sel ? m['id'] as int : null),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _honestCard(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline,
                    color: scheme.onSecondaryContainer, size: 20),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(tr.securityHonestTitle,
                      style: TextStyle(
                          color: scheme.onSecondaryContainer,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            Text(tr.securityHonestBody,
                style: TextStyle(
                    color: scheme.onSecondaryContainer,
                    fontSize: 13,
                    height: 1.35)),
          ],
        ),
      ),
    );
  }
}
