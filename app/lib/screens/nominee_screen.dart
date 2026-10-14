import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/nominee_scope_picker.dart';
import '../widgets/nominee_release_sheet.dart';
import '../widgets/nominee_card.dart';
import '../widgets/nominee_consent_banner.dart';

/// Nominee / family access (feature 36) — ADVANCED.
///
/// A trusted-person "digital inheritance / emergency access" surface: the owner
/// defines who (name, relationship, phone) may reach which *categories* of their
/// information (emergency card, document vault pointers, money overview, final
/// wishes / instructions) IF something happens to them, in a chosen priority
/// order.
///
/// SAFETY MODEL (see nominee_release_sheet.dart for the full flow):
///   Access is NEVER granted silently or automatically. A nominee only gains
///   access after a *verified release trigger* that the owner configured, and
///   the owner can cancel at any point during the grace window. We store only
///   pointers / instructions here — raw vault secrets stay E2E-encrypted and are
///   never surfaced through this screen.
class NomineeScreen extends StatefulWidget {
  const NomineeScreen({super.key});
  @override
  State<NomineeScreen> createState() => _NomineeScreenState();
}

class _NomineeScreenState extends State<NomineeScreen> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true, _error = false, _saving = false;

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
      _list = await context.read<AppState>().api.listItems('nominees');
      _list.sort((a, b) => ((a['priority'] ?? 99) as num)
          .compareTo((b['priority'] ?? 99) as num));
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Add / edit a nominee. Captures name, relationship, phone, the categories
  /// they may access, the priority order and the release trigger. On save we
  /// persist via the generic item API (new fields are additive — see
  /// .phaseB/up_nominee_integration.md).
  Future<void> _edit(AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final name = TextEditingController(text: existing?['name'] ?? '');
    final phone = TextEditingController(text: existing?['contact'] ?? '');
    String relationship = existing?['relationship'] ?? 'family';
    // Categories the nominee may access — defaults to the least-sensitive one.
    final scopes = <String>{
      ...((existing?['scopes'] as List?)?.cast<String>() ??
          [existing?['scope'] ?? 'emergency'])
    };
    int priority = (existing?['priority'] ?? _list.length + 1) as int;
    String trigger = existing?['trigger'] ?? 'owner_grant';
    int inactivityDays = (existing?['inactivity_days'] ?? 30) as int;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: Gap.lg,
            right: Gap.lg,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg),
        child: StatefulBuilder(
          builder: (ctx, setD) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: Gap.sm),
                Text(existing == null ? tr.addNominee : tr.nomineeEdit,
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: Gap.lg),
                TextField(
                    controller: name,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(labelText: tr.name)),
                const SizedBox(height: Gap.md),
                TextField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(labelText: tr.phoneEmail)),
                const SizedBox(height: Gap.md),
                DropdownButtonFormField<String>(
                  value: relationship,
                  decoration: InputDecoration(labelText: tr.nomineeRelationship),
                  items: [
                    DropdownMenuItem(
                        value: 'spouse', child: Text(tr.nomineeRelSpouse)),
                    DropdownMenuItem(
                        value: 'child', child: Text(tr.nomineeRelChild)),
                    DropdownMenuItem(
                        value: 'parent', child: Text(tr.nomineeRelParent)),
                    DropdownMenuItem(
                        value: 'sibling', child: Text(tr.nomineeRelSibling)),
                    DropdownMenuItem(
                        value: 'family', child: Text(tr.nomineeRelFamily)),
                    DropdownMenuItem(
                        value: 'lawyer', child: Text(tr.nomineeRelLawyer)),
                    DropdownMenuItem(
                        value: 'friend', child: Text(tr.nomineeRelFriend)),
                  ],
                  onChanged: (v) => setD(() => relationship = v ?? 'family'),
                ),
                const SizedBox(height: Gap.lg),
                Text(tr.nomineeWhatTheyCanAccess,
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                Text(tr.nomineeScopeHint,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                const SizedBox(height: Gap.sm),
                NomineeScopePicker(
                  selected: scopes,
                  onChanged: (s) => setD(() {}),
                ),
                const SizedBox(height: Gap.lg),
                Text(tr.nomineeReleaseTrigger,
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                Text(tr.nomineeTriggerHint,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                const SizedBox(height: Gap.sm),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'owner_grant',
                  groupValue: trigger,
                  onChanged: (v) => setD(() => trigger = v!),
                  title: Text(tr.nomineeTriggerOwnerGrant),
                  subtitle: Text(tr.nomineeTriggerOwnerGrantDesc),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'inactivity',
                  groupValue: trigger,
                  onChanged: (v) => setD(() => trigger = v!),
                  title: Text(tr.nomineeTriggerInactivity),
                  subtitle: Text(tr.nomineeTriggerInactivityDesc),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'multi_verify',
                  groupValue: trigger,
                  onChanged: (v) => setD(() => trigger = v!),
                  title: Text(tr.nomineeTriggerMultiVerify),
                  subtitle: Text(tr.nomineeTriggerMultiVerifyDesc),
                ),
                if (trigger == 'inactivity') ...[
                  const SizedBox(height: Gap.sm),
                  Row(children: [
                    Expanded(child: Text(tr.nomineeInactivityDays)),
                    _StepperField(
                      value: inactivityDays,
                      min: 7,
                      max: 180,
                      step: 7,
                      onChanged: (v) => setD(() => inactivityDays = v),
                    ),
                  ]),
                ],
                const SizedBox(height: Gap.md),
                Row(children: [
                  Expanded(child: Text(tr.nomineePriorityOrder)),
                  _StepperField(
                    value: priority,
                    min: 1,
                    max: 20,
                    step: 1,
                    onChanged: (v) => setD(() => priority = v),
                  ),
                ]),
                const SizedBox(height: Gap.lg),
                // Consent + warning before any nominee is saved.
                NomineeConsentBanner(relationship: relationship),
                const SizedBox(height: Gap.lg),
                Row(children: [
                  Expanded(
                    child: TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(tr.cancel)),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: FilledButton(
                        onPressed: scopes.isEmpty || name.text.trim().isEmpty
                            ? null
                            : () => Navigator.pop(ctx, true),
                        child: Text(tr.nomineeSaveTrustedPerson)),
                  ),
                ]),
                const SizedBox(height: Gap.sm),
              ],
            ),
          ),
        ),
      ),
    );

    if (ok == true && name.text.trim().isNotEmpty && scopes.isNotEmpty) {
      setState(() => _saving = true);
      final payload = <String, dynamic>{
        'name': name.text.trim(),
        'contact': phone.text.trim(),
        'relationship': relationship,
        // keep legacy single `scope` populated for back-compat with the current
        // serializer; `scopes` is the advanced multi-category list.
        'scope': scopes.contains('all') ? 'all' : scopes.first,
        'scopes': scopes.toList(),
        'priority': priority,
        'trigger': trigger,
        'inactivity_days': inactivityDays,
      };
      try {
        if (existing != null) {
          await context.read<AppState>().api.updateItem(
              'nominees', existing['id'], payload);
        } else {
          await context.read<AppState>().api.createItem('nominees', payload);
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr.nomineeSaveFailed)));
        }
      }
      if (mounted) setState(() => _saving = false);
      await _load();
    }
  }

  /// Open the release-management sheet for one nominee. This is the ONLY place
  /// access can actually be opened/closed, and it is wrapped in confirmation +
  /// grace-window safeguards.
  Future<void> _manageRelease(Map<String, dynamic> n) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => NomineeReleaseSheet(nominee: n),
    );
    if (changed == true) await _load();
  }

  Future<void> _delete(AppLocalizations tr, Map<String, dynamic> n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.nomineeRemoveTitle),
        content: Text(tr.nomineeRemoveBody(n['name'] ?? '')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.delete)),
        ],
      ),
    );
    if (ok == true) {
      try {
        await context.read<AppState>().api.deleteItem('nominees', n['id']);
      } catch (_) {}
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.nomineeFamilyAccess)),
      floatingActionButton: _loading || _error
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : () => _edit(tr),
              icon: const Icon(Icons.person_add_alt),
              label: Text(tr.nominee2)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: tr.checkInternetRetry,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)))
              : _list.isEmpty
                  ? _EmptyState(onAdd: () => _edit(tr))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                            Gap.lg, Gap.lg, Gap.lg, 96),
                        children: [
                          // Standing explanation of the safety guarantee.
                          _SafetyHeader(),
                          const SizedBox(height: Gap.lg),
                          for (var i = 0; i < _list.length; i++) ...[
                            NomineeCard(
                              nominee: _list[i],
                              onManageRelease: () => _manageRelease(_list[i]),
                              onEdit: () => _edit(tr, existing: _list[i]),
                              onDelete: () => _delete(tr, _list[i]),
                            ),
                            if (i != _list.length - 1)
                              const SizedBox(height: Gap.md),
                          ],
                        ],
                      ),
                    ),
    );
  }
}

/// Crafted empty state with the value proposition and a warm, respectful tone.
class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return StateMessage(
      icon: Icons.family_restroom,
      title: tr.noNomineesYet,
      message: tr.addATrustedPersonWho,
      action: FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.person_add_alt),
          label: Text(tr.addNominee)),
    );
  }
}

/// Persistent safety banner shown above the list — the one-line promise that
/// access never opens silently.
class _SafetyHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(Icons.verified_user_outlined,
            color: scheme.onSecondaryContainer, size: 22),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Text(tr.nomineeAccessNeverSilent,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: scheme.onSecondaryContainer)),
        ),
      ]),
    );
  }
}

/// Compact +/- numeric stepper (priority order, inactivity days). Locale-aware
/// digits are rendered inside the display helper — no numeric literal leaks to
/// the UI as a raw Latin string in bn locale.
class _StepperField extends StatelessWidget {
  final int value, min, max, step;
  final ValueChanged<int> onChanged;
  const _StepperField({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });

  /// Render an int in the active locale's digits without any Bangla literal in
  /// source (Bangla-Bengali digits are the contiguous block U+09E6..U+09EF).
  static String localeDigits(int n, String localeName) {
    final latin = n.toString();
    if (!localeName.startsWith('bn')) return latin;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final ch in latin.runes) {
      b.writeCharCode(ch >= 0x30 && ch <= 0x39 ? bnZero + (ch - 0x30) : ch);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: value > min ? () => onChanged(value - step) : null,
        ),
        SizedBox(
          width: 36,
          child: Text(localeDigits(value, locale),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: value < max ? () => onChanged(value + step) : null,
        ),
      ]),
    );
  }
}
