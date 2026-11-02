import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'guardian_journey_screen.dart';

/// circlea — many-to-many guardianship in one place (Google Family Link
/// benchmark: several parents per child, one parent many children, and the
/// child always sees every parent).
///
///   "Who can see me"        GET  /guardians/mine  — every guardian by name,
///                           what they see (kids watch / school mode / trip),
///                           and Remove where the child decides (consent
///                           rules: school mode + trips yes; a kids watch is
///                           set up by its parent — the screen says who).
///   "Children I look after" GET  /guardians/children — each child with the
///                           OTHER guardians ("also: Dad").
/// Never flag-gated: transparency + removal must always work. Free.

/// Tests / gallery: replace the API ({mine:{guardians}, children:{children}}).
Future<Map<String, dynamic>> Function(String path)? guardiansLoaderOverride;
Future<Map<String, dynamic>> Function(int uid)? guardianRemoveOverride;

class CircleGuardiansScreen extends StatefulWidget {
  const CircleGuardiansScreen({super.key});
  @override
  State<CircleGuardiansScreen> createState() => _CircleGuardiansScreenState();
}

class _CircleGuardiansScreenState extends State<CircleGuardiansScreen> {
  List<Map<String, dynamic>> _mine = const [];
  List<Map<String, dynamic>> _kids = const [];
  bool _loading = true;
  bool _failed = false;
  int? _busy;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<Map<String, dynamic>> _get(String path) =>
      guardiansLoaderOverride != null ? guardiansLoaderOverride!(path) : _api.getJson(path);

  List<Map<String, dynamic>> _rows(Map<String, dynamic> j, String k) => [
        for (final x in (j[k] as List? ?? const []))
          if (x is Map) x.cast<String, dynamic>()
      ];

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await Future.wait([_get('/guardians/mine'), _get('/guardians/children')]);
      if (!mounted) return;
      setState(() {
        _mine = _rows(r[0], 'guardians');
        _kids = _rows(r[1], 'children');
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  String _src(AppLocalizations t, String kind) => switch (kind) {
        'kids_watch' => t.cgaSrcWatch,
        'school_mode' => t.cgaSrcSchool,
        _ => t.cgaSrcJourney,
      };

  Future<void> _remove(Map<String, dynamic> g) async {
    final t = AppLocalizations.of(context);
    final name = '${g['name'] ?? ''}';
    final ok = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.cgaRemoveTitle(name),
              style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(t.cgaRemoveBody(name), style: AType.bodyMedium),
          const SizedBox(height: Gap.lg),
          FilledButton(
            key: const Key('cga-remove-confirm'),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.cgaRemoveYes),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.cancel),
          ),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    final uid = (g['id'] as num).toInt();
    setState(() => _busy = uid);
    try {
      final r = guardianRemoveOverride != null
          ? await guardianRemoveOverride!(uid)
          : await _api.postJson('/guardians/mine/$uid/remove');
      if (!mounted) return;
      final kept = _rows(r, 'kept');
      setState(() {
        _mine = _rows(r, 'guardians');
        _busy = null;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(kept.isEmpty
              ? t.cgaRemoved(name)
              : t.cgaRemovedButWatch(name, '${kept.first['set_up_by'] ?? ''}'))));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = null);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.cgaRemoveFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.cgaTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? ListView(padding: const EdgeInsets.all(Gap.xl), children: [
                  Text(t.cgaLoadFailed, textAlign: TextAlign.center),
                  const SizedBox(height: Gap.md),
                  Center(
                    child: FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(t.retry)),
                  ),
                ])
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    key: const Key('cga-list'),
                    padding: withNavBarInset(
                        context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl)),
                    children: [
                      _header(t.cgaWhoSeesMe, Icons.visibility_rounded),
                      if (_mine.isEmpty) _emptyMine(t) else for (final g in _mine) _guardian(t, g),
                      const SizedBox(height: Gap.lg),
                      _header(t.cgaMyChildren, Icons.family_restroom_rounded),
                      if (_kids.isEmpty) _emptyKids(t) else for (final k in _kids) _child(t, k),
                      const SizedBox(height: Gap.md),
                      Text(t.cgaFree,
                          style: AType.bodySmall
                              .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
    );
  }

  Widget _header(String s, IconData icon) => Semantics(
        header: true,
        child: Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700))),
          ]),
        ),
      );

  Widget _emptyMine(AppLocalizations t) => Card(
        key: const Key('cga-mine-empty'),
        margin: const EdgeInsets.only(bottom: Gap.sm),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Icon(Icons.visibility_off_rounded, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.cgaNobodySeesMe, style: AType.bodyMedium)),
          ]),
        ),
      );

  Widget _emptyKids(AppLocalizations t) => Card(
        key: const Key('cga-kids-empty'),
        margin: const EdgeInsets.only(bottom: Gap.sm),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.cgaKidsEmptyBenefit, style: AType.bodyLarge),
            const SizedBox(height: Gap.xs),
            Text(t.cgaKidsEmptyHow,
                style: AType.bodyMedium
                    .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              key: const Key('cga-kids-start'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () async {
                await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GuardianJourneyScreen()));
                if (mounted) _load();
              },
              icon: const Icon(Icons.route_rounded),
              label: Text(t.cgaKidsStart),
            ),
          ]),
        ),
      );

  Widget _chips(AppLocalizations t, List sources) => Wrap(
        spacing: Gap.xs,
        runSpacing: Gap.xs,
        children: [
          for (final k in {for (final s in sources) if (s is Map) '${s['kind']}'})
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                  k == 'kids_watch'
                      ? Icons.watch_rounded
                      : (k == 'school_mode' ? Icons.school_rounded : Icons.route_rounded),
                  size: 16),
              label: Text(_src(t, k)),
            ),
        ],
      );

  Widget _guardian(AppLocalizations t, Map<String, dynamic> g) {
    final scheme = Theme.of(context).colorScheme;
    final name = '${g['name'] ?? ''}';
    final sources = (g['sources'] as List?) ?? const [];
    final watchOwners = {
      for (final s in sources)
        if (s is Map && s['kind'] == 'kids_watch' && s['removable'] != true)
          '${s['set_up_by'] ?? ''}'
    }..removeWhere((x) => x.isEmpty);
    final uid = (g['id'] as num?)?.toInt();
    return Card(
      key: ValueKey('cga-guardian-$uid'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CircleAvatar(
                child: Text(name.trim().isEmpty ? '?' : name.trim().characters.first)),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(name, style: AType.titleMedium)),
          ]),
          const SizedBox(height: Gap.xs),
          _chips(t, sources),
          if (watchOwners.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.cgaWatchOnlyOwner(watchOwners.join(', ')),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
          if (g['removable'] == true) ...[
            const SizedBox(height: Gap.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: ValueKey('cga-remove-$uid'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48), foregroundColor: scheme.error),
                onPressed: _busy != null || uid == null ? null : () => _remove(g),
                icon: _busy == uid
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.person_remove_rounded),
                label: Text(t.cgaRemove),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _child(AppLocalizations t, Map<String, dynamic> k) {
    final scheme = Theme.of(context).colorScheme;
    final co = [
      for (final g in (k['co_guardians'] as List? ?? const []))
        if (g is Map) '${g['name'] ?? ''}'
    ]..removeWhere((x) => x.isEmpty);
    return Card(
      key: ValueKey('cga-child-${k['key']}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.child_care_rounded),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text('${k['name'] ?? ''}', style: AType.titleMedium)),
          ]),
          const SizedBox(height: Gap.xs),
          _chips(t, (k['sources'] as List?) ?? const []),
          const SizedBox(height: Gap.xs),
          Text(co.isEmpty ? t.cgaOnlyYou : t.cgaAlsoWatching(co.join(', ')),
              key: ValueKey('cga-co-${k['key']}'),
              style: AType.bodyMedium.copyWith(
                  color: co.isEmpty ? scheme.onSurfaceVariant : scheme.onSurface)),
          if (co.isEmpty)
            Text(t.cgaAddCoGuardianHow,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
