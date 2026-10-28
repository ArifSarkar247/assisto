import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../api.dart';
import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/offline_banner.dart';
import 'agent_core_widgets.dart';
import 'life_graph_source.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// agentmem (WP-MEMORY, flag `agent_core`): the agent's life-graph memory,
/// opened from the "AI knows" page. Browse by type, edit, delete, delete all
/// (confirm), export (JSON via the share sheet — the user decides where it
/// goes; nothing is e-mailed), pending suggestions (Keep / Don't keep),
/// "still right?" checks, pause weekly learning and choose retention.
/// Honest states: loading, flag off, error/offline, empty. 48 dp targets,
/// TalkBack labels, dark theme from the app theme. No Bangla literals here.
class LifeGraphScreen extends StatefulWidget {
  final LifeGraphSource? source;

  /// Test seam: receives the exported bytes instead of the temp file + the
  /// platform share sheet.
  final Future<void> Function(List<int> bytes)? onExportBytes;
  const LifeGraphScreen({super.key, this.source, this.onExportBytes});

  @override
  State<LifeGraphScreen> createState() => _LifeGraphScreenState();
}

String lgTypeLabel(AppLocalizations t, String type) => switch (type) {
      'person' => t.lgTypePerson,
      'place' => t.lgTypePlace,
      'routine' => t.lgTypeRoutine,
      'preference' => t.lgTypePreference,
      'date' => t.lgTypeDate,
      'business' => t.lgTypeBusiness,
      _ => type,
    };

IconData lgTypeIcon(String type) => switch (type) {
      'person' => Icons.people_alt_rounded,
      'place' => Icons.place_rounded,
      'routine' => Icons.repeat_rounded,
      'preference' => Icons.favorite_border_rounded,
      'date' => Icons.event_rounded,
      'business' => Icons.storefront_rounded,
      _ => Icons.label_outline_rounded,
    };

String lgOriginLabel(AppLocalizations t, String origin) => switch (origin) {
      'run' => t.lgOriginRun,
      'learn' => t.lgOriginLearn,
      _ => t.lgOriginUser,
    };

class _LifeGraphScreenState extends State<LifeGraphScreen> {
  late final LifeGraphSource _src = widget.source ??
      ApiLifeGraphSource(Provider.of<AppState>(context, listen: false).api);
  LgListing? _data;
  List<LgFact> _suggestions = const [];
  String _type = '';
  String? _error; // null = no error; '' = generic
  bool _featureOff = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await _src.list(type: _type);
      final d = LgListing.fromJson(j);
      var sugg = const <LgFact>[];
      if (d.suggestions > 0) {
        final s = LgListing.fromJson(await _src.list(status: 'suggested'));
        sugg = s.facts;
      }
      if (!mounted) return;
      setState(() {
        _data = d;
        _suggestions = sugg;
        _error = null;
        _featureOff = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _featureOff = e is ApiException && e.status == 403;
        _error = e is ApiException ? e.message : '';
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _act(Future<void> Function() fn, String done) async {
    final t = AppLocalizations.of(context);
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
      _snack(done);
    } catch (e) {
      _snack(e is ApiException && e.message.isNotEmpty ? e.message : t.lgActionFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  // ---------------------------------------------------------------- actions
  Future<void> _export() async {
    final t = AppLocalizations.of(context);
    try {
      final bytes = await _src.exportBytes();
      if (widget.onExportBytes != null) {
        await widget.onExportBytes!(bytes);
      } else {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/assisto-life-graph.json');
        await f.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles([XFile(f.path, mimeType: 'application/json')],
            subject: t.lgTitle);
      }
      _snack(t.lgExportDone);
    } catch (_) {
      _snack(t.lgExportFailed);
    }
  }

  Future<void> _deleteAll() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        icon: const Icon(Icons.delete_forever_rounded),
        title: Text(t.lgDeleteAllTitle),
        content: Text(t.lgDeleteAllBody),
        actions: [
          TextButton(
              key: const ValueKey('lg_delete_all_cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.lgCancel)),
          FilledButton(
              key: const ValueKey('lg_delete_all_confirm'),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError,
                  minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.lgDeleteAllConfirm)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    var n = 0;
    await _act(() async => n = await _src.deleteAll(), '');
    _snack(t.lgDeleteAllDone(acNum(context, n)));
  }

  Future<void> _edit({LgFact? fact}) async {
    final res = await showAppSheet<_EditResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FactEditor(fact: fact, initialType: _type.isEmpty ? 'person' : _type),
    );
    if (res == null || !mounted) return;
    final t = AppLocalizations.of(context);
    if (res.delete && fact != null) {
      await _act(() => _src.delete(fact.id), t.lgDeleted);
    } else if (fact == null) {
      await _act(() => _src.create(res.fields), t.lgSaved);
    } else {
      await _act(() => _src.update(fact.id, res.fields), t.lgSaved);
    }
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final d = _data;
    final canAct = d != null && !_featureOff;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.lgTitle),
        actions: [
          if (canAct)
            IconButton(
                key: const ValueKey('lg_export'),
                tooltip: t.lgExport,
                onPressed: _export,
                icon: const Icon(Icons.ios_share_rounded)),
          if (canAct)
            PopupMenuButton<String>(
              key: const ValueKey('lg_menu'),
              tooltip: t.lgMenu,
              onSelected: (v) {
                if (v == 'delete_all') _deleteAll();
                if (v == 'export') _export();
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'export', child: Text(t.lgExport)),
                PopupMenuItem(
                    key: const ValueKey('lg_delete_all'),
                    value: 'delete_all',
                    child: Text(t.lgDeleteAll,
                        style: TextStyle(color: Theme.of(context).colorScheme.error))),
              ],
            ),
        ],
      ),
      floatingActionButton: canAct
          ? FloatingActionButton.extended(
              key: const ValueKey('lg_add'),
              onPressed: () => _edit(),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.lgAdd))
          : null,
      body: SafeArea(child: _body(t, d)),
    );
  }

  Widget _body(AppLocalizations t, LgListing? d) {
    if (d == null && _error == null) {
      return Center(
          child: Semantics(
              label: t.lgLoading, child: const CircularProgressIndicator()));
    }
    if (d == null) {
      return ListView(children: [
        const OfflineBanner(),
        AcMessage(
            icon: _featureOff ? Icons.lock_clock_rounded : Icons.cloud_off_rounded,
            body: _featureOff
                ? t.lgFeatureOff
                : ((_error ?? '').isNotEmpty ? _error! : t.lgErrorLoad),
            action: _featureOff ? null : t.lgRetry,
            onAction: _featureOff
                ? null
                : () {
                    setState(() => _error = null);
                    _load();
                  }),
      ]);
    }
    final s = Theme.of(context).colorScheme;
    final empty = d.total == 0 && _suggestions.isEmpty;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 96),
        children: [
          const OfflineBanner(),
          _PrivacyNote(text: t.lgPrivacyNote),
          const SizedBox(height: Gap.md),
          if (_suggestions.isNotEmpty) ...[
            Semantics(
              header: true,
              child: Text(t.lgSuggestionsTitle(acNum(context, _suggestions.length)),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: Gap.xs),
            Text(t.lgSuggestionsHint, style: TextStyle(color: s.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            for (final f in _suggestions)
              _SuggestionCard(
                fact: f,
                onKeep: () => _act(() => _src.approve(f.id), t.lgKept),
                onReject: () => _act(() => _src.reject(f.id), t.lgRejected),
              ),
            const SizedBox(height: Gap.md),
          ],
          if (empty)
            AcMessage(
                key: const ValueKey('lg_empty'),
                icon: Icons.psychology_alt_rounded,
                title: t.lgEmptyTitle,
                body: t.lgEmptyBody,
                action: t.lgAdd,
                onAction: () => _edit())
          else ...[
            _TypeChips(
              selected: _type,
              counts: d.counts,
              total: d.total,
              onSelect: (v) {
                setState(() => _type = v);
                _load();
              },
            ),
            const SizedBox(height: Gap.sm),
            if (d.facts.isEmpty && d.total > 0)
              AcMessage(icon: Icons.filter_alt_off_rounded, body: t.lgFilterEmpty),
            for (final f in d.facts)
              _FactTile(
                fact: f,
                onTap: () => _edit(fact: f),
                onConfirm: () => _act(() => _src.confirm(f.id), t.lgSaved),
              ),
          ],
          const SizedBox(height: Gap.lg),
          _LearningCard(
            prefs: d.prefs,
            onPause: (v) => _act(() => _src.setPrefs({'learning_paused': v}), t.lgSaved),
            onRetention: (m) => _act(() => _src.setPrefs({'retention_months': m}), t.lgSaved),
          ),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
            key: const ValueKey('lg_delete_all_button'),
            style: OutlinedButton.styleFrom(
                foregroundColor: s.error, minimumSize: const Size(48, 48)),
            onPressed: _deleteAll,
            icon: const Icon(Icons.delete_forever_rounded),
            label: Text(t.lgDeleteAll),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ pieces
class _PrivacyNote extends StatelessWidget {
  final String text;
  const _PrivacyNote({required this.text});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: s.secondaryContainer, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_rounded, size: 20, color: s.onSecondaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text, style: TextStyle(color: s.onSecondaryContainer, height: 1.4))),
      ]),
    );
  }
}

class _TypeChips extends StatelessWidget {
  final String selected;
  final Map<String, int> counts;
  final int total;
  final ValueChanged<String> onSelect;
  const _TypeChips(
      {required this.selected, required this.counts, required this.total, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget chip(String key, String label, int n) => Padding(
          padding: const EdgeInsets.only(right: Gap.sm, bottom: Gap.sm),
          child: ChoiceChip(
            key: ValueKey('lg_chip_${key.isEmpty ? 'all' : key}'),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            label: Text('$label · ${acNum(context, n)}'),
            avatar: key.isEmpty ? null : Icon(lgTypeIcon(key), size: 18),
            selected: selected == key,
            onSelected: (_) => onSelect(key),
          ),
        );
    return Wrap(children: [
      chip('', t.lgAll, total),
      for (final k in kLgTypes) chip(k, lgTypeLabel(t, k), counts[k] ?? 0),
    ]);
  }
}

class _FactTile extends StatelessWidget {
  final LgFact fact;
  final VoidCallback onTap;
  final VoidCallback onConfirm;
  const _FactTile({required this.fact, required this.onTap, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final f = fact;
    final title = f.relation.isEmpty ? f.label : '${f.label} (${f.relation})';
    final sub = [
      if (f.value.isNotEmpty) f.value,
      if (f.when.isNotEmpty) f.when,
    ].join(' · ');
    final meta = [
      lgTypeLabel(t, f.type),
      lgOriginLabel(t, f.origin),
      if (f.updatedAt != null) t.lgUpdated(acTime(context, f.updatedAt)),
    ].join(' · ');
    return Card(
      key: ValueKey('lg_fact_${f.id}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(lgTypeIcon(f.type), color: s.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: Gap.xxs),
                      Text(sub),
                    ],
                    const SizedBox(height: Gap.xs),
                    Text(meta, style: TextStyle(color: s.onSurfaceVariant, fontSize: 12.5)),
                  ]),
                ),
                Semantics(
                  button: true,
                  label: t.lgEdit,
                  child: const SizedBox(
                      width: 48, height: 48, child: Icon(Icons.edit_outlined)),
                ),
              ]),
              if (f.sensitive || !f.useInAi)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    if (f.sensitive)
                      _Badge(
                          icon: Icons.shield_outlined,
                          text: t.lgSensitive,
                          bg: s.tertiaryContainer,
                          fg: s.onTertiaryContainer),
                    if (!f.sensitive && !f.useInAi)
                      _Badge(
                          icon: Icons.block_rounded,
                          text: t.lgNotForAi,
                          bg: s.surfaceContainerHighest,
                          fg: s.onSurfaceVariant),
                  ]),
                ),
              if (f.stillRight) ...[
                const SizedBox(height: Gap.sm),
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: Gap.xs, children: [
                  Icon(Icons.help_outline_rounded, size: 18, color: s.tertiary),
                  Text(t.lgStillRight),
                  TextButton(
                      key: ValueKey('lg_confirm_${f.id}'),
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: onConfirm,
                      child: Text(t.lgStillRightYes)),
                ]),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// A small wrapping badge (text never clips at 200% font).
class _Badge extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color bg, fg;
  const _Badge({required this.icon, required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: Gap.xs),
          Flexible(child: Text(text, style: TextStyle(color: fg, fontSize: 12.5))),
        ]),
      );
}

class _SuggestionCard extends StatelessWidget {
  final LgFact fact;
  final VoidCallback onKeep;
  final VoidCallback onReject;
  const _SuggestionCard({required this.fact, required this.onKeep, required this.onReject});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final f = fact;
    final title = f.relation.isEmpty ? f.label : '${f.label} (${f.relation})';
    return Card(
      key: ValueKey('lg_sugg_${f.id}'),
      color: s.surfaceContainerHigh,
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(lgTypeIcon(f.type), color: s.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
          ]),
          if (f.value.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(f.replaces != null ? t.lgChangeTo(f.value) : f.value),
          ],
          const SizedBox(height: Gap.xs),
          Text('${lgTypeLabel(t, f.type)} · ${lgOriginLabel(t, f.origin)}',
              style: TextStyle(color: s.onSurfaceVariant, fontSize: 12.5)),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            FilledButton(
                key: ValueKey('lg_keep_${f.id}'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onKeep,
                child: Text(t.lgKeep)),
            OutlinedButton(
                key: ValueKey('lg_reject_${f.id}'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onReject,
                child: Text(t.lgReject)),
          ]),
        ]),
      ),
    );
  }
}

class _LearningCard extends StatelessWidget {
  final LgPrefs prefs;
  final ValueChanged<bool> onPause;
  final ValueChanged<int> onRetention;
  const _LearningCard({required this.prefs, required this.onPause, required this.onRetention});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            key: const ValueKey('lg_pause'),
            title: Text(t.lgPauseLearning),
            subtitle: Text(prefs.learningPaused ? t.lgLearningPaused : t.lgLearningOn),
            value: prefs.learningPaused,
            onChanged: onPause,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
            child: Text(t.lgRetentionTitle, style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
            child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final m in prefs.retentionChoices)
                ChoiceChip(
                  key: ValueKey('lg_ret_$m'),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text(t.lgRetentionMonths(acNum(context, m))),
                  selected: prefs.retentionMonths == m,
                  onSelected: (_) => onRetention(m),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Text(t.lgRetentionHint, style: TextStyle(color: s.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

class _EditResult {
  final Map<String, dynamic> fields;
  final bool delete;
  const _EditResult(this.fields, {this.delete = false});
}

class _FactEditor extends StatefulWidget {
  final LgFact? fact;
  final String initialType;
  const _FactEditor({this.fact, required this.initialType});

  @override
  State<_FactEditor> createState() => _FactEditorState();
}

class _FactEditorState extends State<_FactEditor> {
  late String _type = widget.fact?.type ?? widget.initialType;
  late final _label = TextEditingController(text: widget.fact?.label ?? '');
  late final _relation = TextEditingController(text: widget.fact?.relation ?? '');
  late final _value = TextEditingController(text: widget.fact?.value ?? '');
  late final _when = TextEditingController(text: widget.fact?.when ?? '');
  late bool _sensitive = widget.fact?.sensitive ?? false;
  late bool _useInAi = widget.fact?.useInAi ?? true;
  bool _tried = false;

  @override
  void dispose() {
    for (final c in [_label, _relation, _value, _when]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_label.text.trim().isEmpty && _value.text.trim().isEmpty) {
      setState(() => _tried = true);
      return;
    }
    Navigator.pop(
        context,
        _EditResult({
          'type': _type,
          'label': _label.text.trim(),
          'relation': _relation.text.trim(),
          'value': _value.text.trim(),
          'when': _when.text.trim(),
          'sensitive': _sensitive,
          'use_in_ai': _useInAi,
        }));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final f = widget.fact;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, bottom + Gap.lg),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(f == null ? t.lgAddTitle : t.lgEditTitle,
              style: Theme.of(context).textTheme.titleLarge),
          if (f != null) ...[
            const SizedBox(height: Gap.xs),
            Text(
                [
                  lgOriginLabel(t, f.origin),
                  if (f.createdAt != null) acTime(context, f.createdAt),
                ].join(' · '),
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<String>(
            key: const ValueKey('lg_field_type'),
            initialValue: _type,
            decoration: InputDecoration(labelText: t.lgFieldType),
            items: [
              for (final k in kLgTypes)
                DropdownMenuItem(value: k, child: Text(lgTypeLabel(t, k))),
            ],
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
              key: const ValueKey('lg_field_label'),
              controller: _label,
              maxLength: 80,
              decoration: InputDecoration(labelText: t.lgFieldLabel)),
          TextField(
              key: const ValueKey('lg_field_relation'),
              controller: _relation,
              maxLength: 40,
              decoration: InputDecoration(labelText: t.lgFieldRelation)),
          TextField(
              key: const ValueKey('lg_field_value'),
              controller: _value,
              maxLength: 300,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                  labelText: t.lgFieldValue,
                  errorText: _tried ? t.lgNeedText : null)),
          TextField(
              key: const ValueKey('lg_field_when'),
              controller: _when,
              maxLength: 60,
              decoration: InputDecoration(labelText: t.lgFieldWhen)),
          SwitchListTile(
            key: const ValueKey('lg_field_sensitive'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.lgFieldSensitive),
            value: _sensitive,
            onChanged: (v) => setState(() => _sensitive = v),
          ),
          SwitchListTile(
            key: const ValueKey('lg_field_ai'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.lgFieldUseInAi),
            value: _useInAi && !_sensitive,
            onChanged: _sensitive ? null : (v) => setState(() => _useInAi = v),
          ),
          const SizedBox(height: Gap.sm),
          FilledButton(
              key: const ValueKey('lg_save'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _save,
              child: Text(t.lgSave)),
          if (f != null) ...[
            const SizedBox(height: Gap.sm),
            TextButton.icon(
                key: const ValueKey('lg_delete_one'),
                style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    minimumSize: const Size(48, 48)),
                onPressed: () =>
                    Navigator.pop(context, const _EditResult({}, delete: true)),
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(t.lgDelete)),
          ],
        ]),
      ),
    );
  }
}

/// The entry on the "AI knows" page (flag `agent_core` only): opens the
/// agent's life-graph memory.
class LifeGraphEntryCard extends StatelessWidget {
  const LifeGraphEntryCard({super.key});

  static bool get visible => FeatureFlags.instance.isOn('agent_core');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('lg_entry'),
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
      child: ListTile(
        minVerticalPadding: Gap.md,
        leading: Icon(Icons.hub_rounded, color: s.primary),
        title: Text(t.lgEntryTitle),
        subtitle: Text(t.lgEntryBody),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const LifeGraphScreen())),
      ),
    );
  }
}
