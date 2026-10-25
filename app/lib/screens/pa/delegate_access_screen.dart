import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/pa_delegate_engine.dart';

/// PA SECRETARY MODE — privacy / role-based DELEGATE ACCESS (#111, §14, ADVANCED).
///
/// The owner configures WHAT their PA (the delegate) may see or do on their
/// behalf: granular, role-based toggles that start at a conservative
/// LEAST-PRIVILEGE default (schedule / briefs / tasks — read only). Turning on a
/// SENSITIVE scope (approve-visitors, send-followups, view-contacts, and the
/// private money / health / documents categories) raises a CONFIRM GATE that
/// states, honestly, exactly what that scope exposes. An AUDIT tab shows what
/// the delegate actually accessed (including denied attempts).
///
/// HONEST ENFORCEMENT: this screen configures the owner's DRAFT; the grant is
/// authoritative only once the server stores it, and every delegate action is
/// re-checked server-side via `can_access` against the DB-stored scopes. A
/// scope merely toggled here grants the delegate nothing until it is persisted
/// and enforced on the server (see up_pa3_integration.md).
class DelegateAccessScreen extends StatefulWidget {
  const DelegateAccessScreen({super.key});
  @override
  State<DelegateAccessScreen> createState() => _DelegateAccessScreenState();
}

class _DelegateAccessScreenState extends State<DelegateAccessScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  Set<String>? _scopes; // null while loading / never configured
  bool _configured = false; // false ⇒ first-use welcome state
  List<PaAuditEntry> _audit = [];
  bool _loading = true;
  String? _error;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stored = await PaDelegateStore.loadScopes();
      final audit = await PaDelegateStore.loadAudit();
      if (!mounted) return;
      setState(() {
        _configured = stored != null;
        _scopes = stored ?? defaultScopes();
        _audit = audit;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _persist() async {
    await PaDelegateStore.saveScopes(_scopes ?? defaultScopes());
  }

  /// Begin delegation from the least-privilege default (first-use action).
  Future<void> _startLeastPrivilege() async {
    setState(() {
      _scopes = defaultScopes();
      _configured = true;
    });
    await _persist();
  }

  Future<void> _toggle(PaScope scope, bool on) async {
    final current = _scopes ?? defaultScopes();
    // Revoking is always immediate and safe.
    if (!on) {
      setState(() => _scopes = setScope(current, scope.id, false));
      await _persist();
      await PaDelegateStore.appendAudit(buildAuditEntry(
          scope: scope.id, action: 'revoked', at: DateTime.now()));
      await _reloadAudit();
      return;
    }
    // Granting a sensitive scope must pass the confirm gate.
    if (grantRequiresConfirm(scope.id)) {
      final ok = await _confirmSensitiveGrant(scope);
      if (ok != true) return; // held — NOT granted
    }
    setState(() => _scopes = setScope(current, scope.id, true));
    await _persist();
    await PaDelegateStore.appendAudit(buildAuditEntry(
        scope: scope.id, action: 'granted', at: DateTime.now()));
    await _reloadAudit();
  }

  Future<void> _reloadAudit() async {
    final audit = await PaDelegateStore.loadAudit();
    if (!mounted) return;
    setState(() => _audit = audit);
  }

  Future<bool?> _confirmSensitiveGrant(PaScope scope) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.lock_outline_rounded, color: Brand.warning),
        title: Text(t.paGrantConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.paGrantConfirmBody(_scopeLabel(scope.id))),
            const SizedBox(height: Gap.md),
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: Brand.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(_exposesLabel(scope.exposesKey),
                  style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.paGrantConfirmYes)),
        ],
      ),
    );
  }

  // --------------------------------------------------------- scope labels

  String _scopeLabel(String id) {
    switch (id) {
      case scopeSeeSchedule:
        return t.paScopeSchedule;
      case scopeViewBriefs:
        return t.paScopeBriefs;
      case scopeSeeTasks:
        return t.paScopeTasks;
      case scopeApproveVisitors:
        return t.paScopeVisitors;
      case scopeSendFollowups:
        return t.paScopeFollowups;
      case scopeManageTasks:
        return t.paScopeManageTasks;
      case scopeViewContacts:
        return t.paScopeContacts;
      case scopeSeeMoney:
        return t.paScopeMoney;
      case scopeSeeHealth:
        return t.paScopeHealth;
      case scopeSeeDocuments:
        return t.paScopeDocuments;
    }
    return id;
  }

  String _exposesLabel(String key) {
    switch (key) {
      case 'paScopeExposesSchedule':
        return t.paScopeExposesSchedule;
      case 'paScopeExposesBriefs':
        return t.paScopeExposesBriefs;
      case 'paScopeExposesTasks':
        return t.paScopeExposesTasks;
      case 'paScopeExposesVisitors':
        return t.paScopeExposesVisitors;
      case 'paScopeExposesFollowups':
        return t.paScopeExposesFollowups;
      case 'paScopeExposesManageTasks':
        return t.paScopeExposesManageTasks;
      case 'paScopeExposesContacts':
        return t.paScopeExposesContacts;
      case 'paScopeExposesMoney':
        return t.paScopeExposesMoney;
      case 'paScopeExposesHealth':
        return t.paScopeExposesHealth;
      case 'paScopeExposesDocuments':
        return t.paScopeExposesDocuments;
    }
    return '';
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'granted':
        return t.paAuditGranted;
      case 'revoked':
        return t.paAuditRevoked;
      case 'acted':
        return t.paAuditActed;
      case 'denied':
        return t.paAuditDenied;
      default:
        return t.paAuditViewed;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.paDelegateTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(
                child: Text(t.paDelegateTabScopes,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
            Tab(
                child: Text(t.paDelegateTabAudit,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_scopesTab(), _auditTab()],
      ),
    );
  }

  // --------------------------------------------------------------- scopes tab

  Widget _scopesTab() {
    if (_loading) return const SkeletonList(count: 6);
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: Brand.danger,
        title: t.paDelegateLoadError,
        action: FilledButton.tonal(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (!_configured) {
      // First-use welcome state — nothing is delegated yet.
      return StateMessage(
        icon: Icons.verified_user_rounded,
        tint: Brand.blue,
        title: t.paDelegateWelcomeTitle,
        message: t.paDelegateWelcomeBody,
        action: FilledButton.icon(
          onPressed: _startLeastPrivilege,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: Text(t.paDelegateStart),
        ),
      );
    }

    final scopes = _scopes ?? defaultScopes();
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
      children: [
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(children: [
            const Icon(Icons.shield_rounded, size: 20),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.paDelegateLeastPrivilegeNote,
                    style: const TextStyle(fontSize: 12.5))),
          ]),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.paDelegateScopesHeader,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        for (final s in kScopeCatalog)
          _ScopeTile(
            label: _scopeLabel(s.id),
            exposes: _exposesLabel(s.exposesKey),
            sensitive: s.sensitive,
            value: scopes.contains(s.id),
            sensitiveBadge: t.paScopeSensitiveBadge,
            onChanged: (v) => _toggle(s, v),
          ),
        const SizedBox(height: Gap.lg),
        Text(t.paDelegateServerNote,
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
    );
  }

  // ----------------------------------------------------------------- audit tab

  Widget _auditTab() {
    if (_loading) return const SkeletonList(count: 4);
    if (_audit.isEmpty) {
      return StateMessage(
        icon: Icons.history_rounded,
        title: t.paAuditEmptyTitle,
        message: t.paAuditEmptyBody,
      );
    }
    final summary = summarizeAudit(_audit);
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.all(Gap.lg),
      itemCount: _audit.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
      itemBuilder: (_, i) {
        if (i == 0) {
          return Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Text(
              t.paAuditSummary(/* (denied, sensitive, total) */
                  summary.denied, summary.sensitive, summary.total),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          );
        }
        final e = _audit[i - 1];
        return ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 2),
          leading: Icon(
            e.allowed ? Icons.check_circle_outline_rounded : Icons.block_rounded,
            color: e.allowed
                ? (e.sensitive ? Brand.warning : Brand.success)
                : Brand.danger,
            size: 20,
          ),
          title: Text('${_actionLabel(e.action)} · ${_scopeLabel(e.scope)}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.at,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: e.sensitive
              ? Chip(
                  label: Text(t.paScopeSensitiveBadge,
                      style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Brand.warning.withValues(alpha: 0.15),
                  side: BorderSide.none,
                )
              : null,
        );
      },
    );
  }
}

class _ScopeTile extends StatelessWidget {
  final String label;
  final String exposes;
  final bool sensitive;
  final bool value;
  final String sensitiveBadge;
  final ValueChanged<bool> onChanged;
  const _ScopeTile({
    required this.label,
    required this.exposes,
    required this.sensitive,
    required this.value,
    required this.sensitiveBadge,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        title: Row(children: [
          Flexible(
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
          if (sensitive) ...[
            const SizedBox(width: Gap.sm),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Brand.warning.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(sensitiveBadge,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Brand.warning)),
            ),
          ],
        ]),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(exposes,
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}
