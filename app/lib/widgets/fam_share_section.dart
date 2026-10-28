import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;
import '../l10n/app_localizations.dart';
import 'fam_sharing_strings.dart';

/// #67 SELECTIVE SHARING (SPEC v2.1 §21) — ADVANCED upgrade of the FAMILY
/// good-bit. A fully self-contained, clearly-bounded section embedded as ONE
/// tab in FamilyScreen. Nothing here touches the famacct section (D5).
///
/// What it does (benchmarked against circle_privacy's visibility contract — the
/// finer-grained, per-item cousin):
///   • per-family-member, per-item consent toggles for which of MY info each
///     member may see: location / medicine / money-summary / documents /
///     safe-journey (consent screen).
///   • an audit log of what was shared/revoked and when.
///   • a revoke flow (per item, per member, or everything).
///
/// SERVER-ENFORCED INTENT: the toggles POST to the sharing endpoints (see
/// family_sharing.py ENDPOINT NEEDS and up_fambundle_arb.json integration note);
/// the server runs can_share_item() before serializing any shared field, so a
/// client cannot see an ungranted item. This widget is default-deny and keeps
/// an on-screen audit so the owner always knows exactly what is shared.
///
/// Items mirror backend family_sharing.SHAREABLE_ITEMS, 1:1.
const List<String> kFamShareItems = [
  'location',
  'medicine',
  'money_summary',
  'documents',
  'safe_journey',
];

String _itemKey(String item) => const {
      'location': 'famItemLocation',
      'medicine': 'famItemMedicine',
      'money_summary': 'famItemMoney',
      'documents': 'famItemDocuments',
      'safe_journey': 'famItemJourney',
    }[item]!;

IconData _itemIcon(String item) => const {
      'location': Icons.location_on_rounded,
      'medicine': Icons.medication_rounded,
      'money_summary': Icons.savings_rounded,
      'documents': Icons.folder_rounded,
      'safe_journey': Icons.directions_walk_rounded,
    }[item]!;

class FamShareSection extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  const FamShareSection({super.key, required this.members});

  @override
  State<FamShareSection> createState() => _FamShareSectionState();
}

class _FamShareSectionState extends State<FamShareSection> {
  // Local mirror of {member_id: set(items)}. Default-deny: starts empty.
  // The server is the source of truth; this reflects the owner's choices and is
  // what each toggle POSTs. Default is SHARE NOTHING.
  final Map<int, Set<String>> _grants = {};
  // On-screen audit log (newest first). The server persists the authoritative
  // log; this is the immediate, honest echo of this session's changes.
  final List<Map<String, dynamic>> _audit = [];

  // q1-seams: the grid used to start EMPTY on every open (never read from the
  // server), so it could say "nothing shared" while the server still shared,
  // and a failed toggle/revoke was swallowed. Now the server's consent model
  // is loaded, every write re-applies the server's answer, and a failure says
  // so and reloads the truth.
  bool _serverLoadFailed = false;

  @override
  void initState() {
    super.initState();
    _loadServer();
  }

  /// Apply GET/POST family/sharing/* consent payload {rows:[{member_id, items}]}.
  void _applyServer(Map<String, dynamic> r) {
    final rows = r['rows'];
    if (rows is! List) return;
    _grants.clear();
    for (final row in rows) {
      if (row is! Map) continue;
      final mid = (row['member_id'] as num?)?.toInt();
      final items = row['items'];
      if (mid == null || items is! Map) continue;
      final on = <String>{
        for (final e in items.entries)
          if (e.value == true) '${e.key}',
      };
      if (on.isNotEmpty) _grants[mid] = on;
    }
  }

  Future<void> _loadServer() async {
    try {
      final r = await context
          .read<AppState>()
          .api
          .getJson('/family/sharing/consent');
      if (!mounted) return;
      setState(() {
        _serverLoadFailed = false;
        _applyServer(r);
      });
    } catch (_) {
      if (mounted) setState(() => _serverLoadFailed = true);
    }
  }

  bool _granted(int mid, String item) => _grants[mid]?.contains(item) ?? false;

  void _toggle(int mid, String name, String item, bool on) {
    setState(() {
      final s = _grants.putIfAbsent(mid, () => <String>{});
      if (on) {
        s.add(item);
      } else {
        s.remove(item);
        if (s.isEmpty) _grants.remove(mid);
      }
      _audit.insert(0, {
        'action': on ? 'grant' : 'revoke',
        'name': name,
        'item': item,
        'at': DateTime.now(),
      });
    });
    // SERVER-ENFORCED: POST /family/sharing/grant {member_id, item, on}
    // (wired by the integrator; see family_sharing.py). Best-effort, non-fatal.
    _post('grant', body: {'member_id': mid, 'item': item, 'on': on});
  }

  void _revokeMember(int mid, String name) {
    setState(() {
      _grants.remove(mid);
      _audit.insert(0, {
        'action': 'revoke_member',
        'name': name,
        'item': null,
        'at': DateTime.now(),
      });
    });
    _post('revoke-member', body: {'member_id': mid});
  }

  void _revokeAll() {
    setState(() {
      _grants.clear();
      _audit.insert(0, {
        'action': 'revoke_all',
        'name': '',
        'item': null,
        'at': DateTime.now(),
      });
    });
    _post('revoke-all');
  }

  Future<void> _post(String op, {Map<String, dynamic>? body}) async {
    // The endpoint is the authoritative enforcement point: re-apply its answer;
    // on failure say so and reload the server's real state (q1-seams).
    try {
      final r = await context
          .read<AppState>()
          .api
          .createItem('family/sharing/$op', body ?? const {});
      if (mounted) setState(() => _applyServer(r));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).grpActionFailed)));
      await _loadServer();
    }
  }

  int get _totalShared =>
      _grants.values.fold(0, (a, s) => a + s.length);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.members.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_person_rounded,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(famLabel(context, 'famShareEmpty'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
          ]),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 88),
      children: [
        _header(scheme),
        const SizedBox(height: Gap.md),
        if (_serverLoadFailed)
          Card(
            key: const ValueKey('q1-famshare-load-failed'),
            color: scheme.errorContainer,
            child: ListTile(
              leading: Icon(Icons.cloud_off_rounded,
                  color: scheme.onErrorContainer),
              title: Text(AppLocalizations.of(context).q1FamShareLoadFailed,
                  style: TextStyle(color: scheme.onErrorContainer)),
              trailing: IconButton(
                tooltip: AppLocalizations.of(context).retry,
                icon: Icon(Icons.refresh_rounded, color: scheme.onErrorContainer),
                onPressed: _loadServer,
              ),
            ),
          ),
        // consent screen: per-member, per-item grid
        for (final m in widget.members) _memberCard(m, scheme),
        const SizedBox(height: Gap.sm),
        _serverNote(scheme),
        const SizedBox(height: Gap.md),
        _auditCard(scheme),
        const SizedBox(height: Gap.md),
        OutlinedButton.icon(
          onPressed: _totalShared == 0 ? null : _confirmRevokeAll,
          icon: const Icon(Icons.layers_clear_rounded),
          style: OutlinedButton.styleFrom(foregroundColor: Brand.danger),
          label: Text(famLabel(context, 'famShareRevokeAll')),
        ),
      ],
    );
  }

  Widget _header(ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.verified_user_rounded, color: Colors.white),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(famLabel(context, 'famShareTitle'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(famLabel(context, 'famShareIntro'),
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: Gap.sm),
          Text(
              _totalShared == 0
                  ? famLabel(context, 'famShareNothing')
                  : AppLocalizations.of(context).famShareSharedCount(famNum(context, _totalShared)),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _memberCard(Map<String, dynamic> m, ColorScheme scheme) {
    final mid = m['id'] as int?;
    if (mid == null) return const SizedBox.shrink();
    final name = (m['name'] ?? '').toString();
    final count = _grants[mid]?.length ?? 0;
    return Card(
      child: ExpansionTile(
        leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
        title: Text(name),
        subtitle: Text([
          (m['relation'] ?? '').toString(),
          count == 0
              ? famLabel(context, 'famShareNothing')
              : AppLocalizations.of(context).famShareSharedCount(famNum(context, count)),
        ].where((e) => e.isNotEmpty).join(' · ')),
        childrenPadding:
            const EdgeInsets.only(left: Gap.md, right: Gap.md, bottom: Gap.sm),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(famLabel(context, 'famShareConsentTitle'),
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              Text(famLabel(context, 'famShareConsentBody'),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
          ),
          // play-nomed: no "share my medicine" switch in the Play flavour.
          for (final item in kFamShareItems)
            if (item != 'medicine' || kMedicalFeaturesAllowed)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              secondary: Icon(_itemIcon(item)),
              value: _granted(mid, item),
              title: Text(famLabel(context, _itemKey(item))),
              onChanged: (v) => _toggle(mid, name, item, v),
            ),
          if (count > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _confirmRevokeMember(mid, name),
                icon: const Icon(Icons.person_off_rounded, size: 18),
                style: TextButton.styleFrom(foregroundColor: Brand.danger),
                label: Text(famLabel(context, 'famShareRevokeMember')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _serverNote(ColorScheme scheme) => Row(children: [
        Icon(Icons.shield_rounded, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(famLabel(context, 'famShareServerNote'),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
      ]);

  Widget _auditCard(ColorScheme scheme) {
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.history_rounded, size: 18),
            const SizedBox(width: Gap.sm),
            Text(famLabel(context, 'famShareAuditTitle'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: Gap.sm),
          if (_audit.isEmpty)
            Text(famLabel(context, 'famShareAuditEmpty'),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))
          else
            for (final e in _audit.take(20)) _auditRow(e, scheme),
        ]),
      ),
    );
  }

  Widget _auditRow(Map<String, dynamic> e, ColorScheme scheme) {
    final action = e['action'] as String;
    final isGrant = action == 'grant';
    final isRevoke =
        action == 'revoke' || action == 'revoke_member' || action == 'revoke_all';
    final at = e['at'] as DateTime;
    final time =
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final item = e['item'] as String?;
    final label = isGrant
        ? famLabel(context, 'famShareAuditGrant')
        : famLabel(context, 'famShareAuditRevoke');
    final who = (e['name'] ?? '').toString();
    final what = item != null ? famLabel(context, _itemKey(item)) : '';
    final line = [who, what].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(isGrant ? Icons.add_circle_outline_rounded : Icons.remove_circle_outline_rounded,
            size: 16, color: isRevoke ? Brand.danger : Brand.success),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text('$label${line.isEmpty ? '' : ' — $line'}',
              style: const TextStyle(fontSize: 13)),
        ),
        Text(time,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  Future<void> _confirmRevokeMember(int mid, String name) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              scrollable: true, // insets: 200% text / keyboard
              title: Text(famLabel(context, 'famShareRevokeMember')),
              content: Text(famLabel(context, 'famShareRevokeQ')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.cancel)),
                FilledButton(
                    style:
                        Brand.dangerButton(),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(famLabel(context, 'famShareRevokeMember'))),
              ],
            ));
    if (ok == true) {
      _revokeMember(mid, name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(famLabel(context, 'famShareRevoked'))));
      }
    }
  }

  Future<void> _confirmRevokeAll() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              scrollable: true, // insets: 200% text / keyboard
              title: Text(famLabel(context, 'famShareRevokeAll')),
              content: Text(famLabel(context, 'famShareRevokeAllQ')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.cancel)),
                FilledButton(
                    style:
                        Brand.dangerButton(),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(famLabel(context, 'famShareRevokeAll'))),
              ],
            ));
    if (ok == true) {
      _revokeAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(famLabel(context, 'famShareRevoked'))));
      }
    }
  }
}
