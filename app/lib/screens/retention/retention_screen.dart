import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../business/business_plans_screen.dart';
import 'retention_people.dart';
import 'retention_results.dart';
import 'retention_source.dart';
import 'retention_widgets.dart';
import 'retention_wizard.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// retention1 — RETENTION AUTOMATION (big-week H) for a Business-plan shop
/// owner: simple automations to the shop's OWN customers (thank-you + review
/// ask, we-miss-you, polite khata due reminder, back-in-stock, birthday).
/// Behind the server flag `retention_auto`; the server answers 403
/// feature_off while hidden and this screen says so honestly. No ads here.
class RetentionScreen extends StatefulWidget {
  final RetentionSource? source;

  /// Tests / gallery: force the first-run guide on (true) or off (false).
  final bool? guide;
  const RetentionScreen({super.key, this.source, this.guide});

  @override
  State<RetentionScreen> createState() => _RetentionScreenState();
}

const _kGuideSeen = 'rt_guide_seen_v1';

class _RetentionScreenState extends State<RetentionScreen> {
  late final RetentionSource _src = widget.source ?? ApiRetentionSource(context.read<AppState>().api);
  bool _loading = true;
  String? _error;
  bool _featureOff = false;
  Map<String, dynamic> _data = const {};
  bool _showGuide = false;

  @override
  void initState() {
    super.initState();
    _initGuide();
    _load();
  }

  Future<void> _initGuide() async {
    if (widget.guide != null) {
      _showGuide = widget.guide!;
      return;
    }
    try {
      final p = await SharedPreferences.getInstance();
      if (mounted) setState(() => _showGuide = !(p.getBool(_kGuideSeen) ?? false));
    } catch (_) {}
  }

  Future<void> _closeGuide() async {
    setState(() => _showGuide = false);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kGuideSeen, true);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _data = await _src.overview();
      _featureOff = false;
    } catch (e) {
      if (rtStatus(e) == 403) {
        _featureOff = true;
      } else {
        _error = rtError(e) ?? '';
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openWizard([Map<String, dynamic>? initial]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => RetentionWizardScreen(source: _src, overview: _data, initial: initial)));
    if (saved == true) await _load();
  }

  Future<void> _toggle(Map<String, dynamic> a, bool on) async {
    final t = AppLocalizations.of(context);
    try {
      await _src.update(rtInt(a['id']), {'enabled': on});
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.rtDeleteTitle),
        content: Text(t.rtDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.rtCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.rtDelete)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _src.delete(rtInt(a['id']));
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    await _load();
  }

  Future<void> _openLimits() async {
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RetentionLimitsSheet(source: _src, overview: _data),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ready = !_loading && !_featureOff && _error == null && _data['plan_ok'] == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.rtTitle),
        actions: [
          IconButton(
            tooltip: t.rtHowItWorks,
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => setState(() => _showGuide = !_showGuide),
          ),
          if (ready)
            IconButton(
              tooltip: t.rtLimitsEdit,
              icon: const Icon(Icons.tune_rounded),
              onPressed: _openLimits,
            ),
        ],
      ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_featureOff) {
      return RtMessage(icon: Icons.lock_clock_outlined, title: t.rtFeatureOffTitle, body: t.rtFeatureOffBody);
    }
    if (_error != null) {
      return RtMessage(
        icon: Icons.cloud_off_rounded,
        title: t.rtLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.rtLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.rtRetry)),
      );
    }
    if (_data['plan_ok'] != true) {
      return ListView(children: [
        if (_showGuide) RetentionGuideCard(onClose: _closeGuide),
        SizedBox(
          height: 420,
          child: RtMessage(
            icon: Icons.workspace_premium_outlined,
            title: t.rtPlanTitle,
            body: t.rtPlanBody,
            action: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BusinessPlansScreen())),
              child: Text(t.rtSeePlans),
            ),
          ),
        ),
      ]);
    }
    final lang = rtLang(context);
    final autos = rtList(_data['automations']);
    final caps = rtMap(_data['caps']);
    final max = rtInt(_data['max_automations'], 10);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (_showGuide || autos.isEmpty) RetentionGuideCard(onClose: autos.isEmpty ? null : _closeGuide),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.shield_outlined, size: 20)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    t.rtLimitsLine(
                        rtDigits(lang, rtInt(caps['per_customer_day'], 1)),
                        rtDigits(lang, rtInt(caps['per_customer_week'], 2)),
                        rtDigits(lang, rtInt(caps['business_daily'], 100))),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ]),
          ),
          if (autos.isEmpty) _Welcome(onStart: () => _openWizard()),
          for (final a in autos)
            _AutomationCard(
              auto: a,
              onToggle: (v) => _toggle(a, v),
              onEdit: () => _openWizard(a),
              onDelete: () => _delete(a),
              onResults: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RetentionResultsScreen(source: _src, automationId: rtInt(a['id'])))),
            ),
          if (autos.isNotEmpty && autos.length < max)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                icon: const Icon(Icons.add_rounded),
                label: Text(t.rtNew),
                onPressed: () => _openWizard(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.cake_outlined),
                label: Text(t.rtManageBirthdays),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => RetentionBirthdaysScreen(source: _src))),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.inventory_2_outlined),
                label: Text(t.rtManageAsks),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => RetentionStockAsksScreen(source: _src))),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  final VoidCallback onStart;
  const _Welcome({required this.onStart});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.rtWelcomeTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(t.rtWelcomeBody),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.add_rounded),
          label: Text(t.rtCreateFirst),
          onPressed: onStart,
        ),
      ]),
    );
  }
}

class _AutomationCard extends StatelessWidget {
  final Map<String, dynamic> auto;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit, onDelete, onResults;
  const _AutomationCard({
    required this.auto,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onResults,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = rtLang(context);
    final kind = (auto['kind'] ?? '').toString();
    final name = (auto['name'] ?? '').toString();
    final ch = (auto['channel'] ?? 'in_app').toString();
    final sum = rtMap(auto['summary']);
    final on = auto['enabled'] == true;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onResults,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 4), child: Icon(rtKindIcon(kind))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name.isNotEmpty ? name : rtKindTitle(t, kind),
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(rtKindWhen(t, lang, kind, rtMap(auto['params']))),
                  const SizedBox(height: 2),
                  Row(children: [
                    Icon(rtChannelIcon(ch), size: 16),
                    const SizedBox(width: 4),
                    Flexible(child: Text(rtChannelName(t, ch), style: Theme.of(context).textTheme.bodySmall)),
                  ]),
                ]),
              ),
              Semantics(
                label: t.rtSwitchLabel,
                child: Switch(value: on, onChanged: onToggle),
              ),
              PopupMenuButton<String>(
                tooltip: t.rtMenu,
                onSelected: (v) => switch (v) {
                  'edit' => onEdit(),
                  'results' => onResults(),
                  _ => onDelete(),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'results', child: Text(t.rtResults)),
                  PopupMenuItem(value: 'edit', child: Text(t.rtEdit)),
                  PopupMenuItem(value: 'delete', child: Text(t.rtDelete)),
                ],
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              RtStat(label: t.rtSent, value: rtDigits(lang, rtInt(sum['sent'])), icon: Icons.send_rounded),
              RtStat(
                  label: t.rtReplied,
                  value: rtDigits(lang, rtInt(sum['replied'])),
                  icon: Icons.reply_rounded),
              RtStat(
                  label: t.rtPurchases,
                  value: rtDigits(lang, rtInt(sum['purchases'])),
                  icon: Icons.shopping_bag_outlined),
              RtStat(
                  label: t.rtStopped,
                  value: rtDigits(lang, rtInt(sum['opted_out'])),
                  icon: Icons.block_rounded),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Owner caps (lower only) + record a customer's stop request by phone.
class RetentionLimitsSheet extends StatefulWidget {
  final RetentionSource source;
  final Map<String, dynamic> overview;
  const RetentionLimitsSheet({super.key, required this.source, required this.overview});

  @override
  State<RetentionLimitsSheet> createState() => _RetentionLimitsSheetState();
}

class _RetentionLimitsSheetState extends State<RetentionLimitsSheet> {
  late final Map<String, int> _caps = {
    for (final e in rtMap(widget.overview['caps']).entries) e.key: rtInt(e.value, 1)
  };
  late final Map<String, int> _max = {
    for (final e in rtMap(widget.overview['server_max']).entries) e.key: rtInt(e.value, 1)
  };
  final _phone = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await widget.source.saveCaps(Map<String, dynamic>.from(_caps));
      if (mounted) rtSnack(context, t.rtCapsSaved);
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _optOut() async {
    final t = AppLocalizations.of(context);
    final p = _phone.text.trim();
    if (p.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.source.addOptOut(p);
      _phone.clear();
      if (mounted) rtSnack(context, t.rtOptOutDone);
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _stepper(String label, String key) {
    final t = AppLocalizations.of(context);
    final lang = rtLang(context);
    final v = _caps[key] ?? 1;
    final mx = _max[key] ?? v;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(label)),
        IconButton(
          tooltip: t.rtLess,
          icon: const Icon(Icons.remove_circle_outline_rounded),
          onPressed: v > 1 ? () => setState(() => _caps[key] = v - 1) : null,
        ),
        Text(rtDigits(lang, v), style: Theme.of(context).textTheme.titleMedium),
        IconButton(
          tooltip: t.rtMore,
          icon: const Icon(Icons.add_circle_outline_rounded),
          onPressed: v < mx ? () => setState(() => _caps[key] = v + 1) : null,
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(t.rtCapsTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(t.rtCapsBody),
          const SizedBox(height: 8),
          _stepper(t.rtCapDay, 'per_customer_day'),
          _stepper(t.rtCapWeek, 'per_customer_week'),
          _stepper(t.rtCapDaily, 'business_daily'),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy ? null : _save,
            child: Text(t.rtSave),
          ),
          const Divider(height: 32),
          Text(t.rtOptOutTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _phone,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: t.rtOptOutHint, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.block_rounded),
            label: Text(t.rtOptOutAdd),
            // enabled only once a full phone number is typed
            onPressed: (_busy || _phone.text.replaceAll(RegExp(r'\D'), '').length < 10) ? null : _optOut,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.rtDone),
            ),
          ),
        ]),
      ),
    );
  }
}
