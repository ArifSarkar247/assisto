import 'package:flutter/material.dart';
import '../ds/ds.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../mess_v2_api.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_counter.dart';
import '../widgets/skeleton.dart';
import 'mess/mess_ad.dart';
import 'mess/mess_detail_screen.dart';
import 'mess/mess_store.dart';
import 'plans_screen.dart';

/// MESS AND BACHELOR V2 — entry screen (All Services tile "Mess and
/// bachelor"; owner order 10 Nov 01:20, Part 2 A–L).
///
/// V1 kept a per-user, name-only ledger on one phone. V2 is a SHARED mess on
/// the server: members are real people from My Circle, each enters own meals
/// from own phone, a My Circle group with the mess name is created
/// automatically, and month-end is computed and locked for everyone. Free for
/// everyone (one small banner for Free users); Premium extras: several
/// messes and full old-month reports.
///
/// This screen lists my messes, creates a new one (name required), and
/// offers to bring V1 records in (the V1 rows are kept as a backup).
class MessAccountingScreen extends StatefulWidget {
  const MessAccountingScreen({super.key});
  @override
  State<MessAccountingScreen> createState() => _MessAccountingScreenState();
}

class _MessAccountingScreenState extends State<MessAccountingScreen> {
  Map<String, dynamic>? _data;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final api = context.read<AppState>().api;
    try {
      await MessOutbox.flush(api);
      final r = await api.messList();
      if (mounted) setState(() => _data = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<Map<String, dynamic>> get _messes =>
      ((_data?['messes'] as List?) ?? const []).whereType<Map>()
          .map((m) => m.cast<String, dynamic>()).toList();

  Future<void> _open(int id) async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MessDetailScreen(messId: id)));
    _load();
  }

  Future<void> _create() async {
    final t = AppLocalizations.of(context);
    if (_data?['can_create'] == false) {
      final go = await showAppSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => AppSheetBody(
          primary: FilledButton(
              key: const ValueKey('mess-premium-go'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.mv2SeePremium)),
          child: Text(t.mv2PremiumSeveral, style: Theme.of(ctx).textTheme.bodyLarge),
        ),
      );
      if (go == true && mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlansScreen()));
      }
      return;
    }
    final res = await showMessSettingsSheet(context);
    if (res == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final m = await context.read<AppState>().api.messCreate(res);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.mv2Created)));
      await _open((m['id'] as num).toInt());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e is ApiException && e.message.isNotEmpty
                ? e.message
                : honestFailText(t, e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importLegacy() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.messImportLegacy();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.mv2ImportDone)));
      await _open((r['mess_id'] as num).toInt());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e is ApiException && e.message.isNotEmpty
                ? e.message
                : honestFailText(t, e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    if (_error != null && _data == null) {
      body = ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        DsEmptyState(
          icon: Icons.cloud_off_rounded,
          title: t.mv2Title,
          benefit: honestFailText(t, _error),
          actionLabel: t.retry,
          onAction: _load,
        ),
      ]);
    } else if (_data == null) {
      body = const SkeletonList();
    } else {
      final messes = _messes;
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
          children: [
            // design2: DS empty state — drawn illustration, benefit line,
            // one big Create button, then the how-to steps
            if (messes.isEmpty)
              DsEmptyState(
                icon: Icons.groups_rounded,
                title: t.mv2EmptyTitle,
                benefit: t.mv2EmptyBody,
                actionLabel: t.mv2CreateMess,
                actionKey: const ValueKey('mess-create'),
                onAction: _busy ? null : _create,
                howTo: [t.mv2How1, t.mv2How2, t.mv2How3, t.mv2How4],
              )
            else ...[
              for (final m in messes) _messTile(m, t, scheme),
              const SizedBox(height: Gap.md),
              DsButton(
                buttonKey: const ValueKey('mess-create'),
                expand: true,
                onPressed: _busy ? null : _create,
                icon: Icons.add_home_work_rounded,
                label: t.mv2CreateMess,
              ),
            ],
            if (_data?['legacy_available'] == true) ...[
              const SizedBox(height: Gap.md),
              DsCard(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(t.mv2ImportTitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: Gap.xs),
                    Text(t.mv2ImportBody),
                    const SizedBox(height: Gap.sm),
                    OutlinedButton.icon(
                      key: const ValueKey('mess-import'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: _busy ? null : _importLegacy,
                      icon: const Icon(Icons.move_down_rounded),
                      label: Text(t.mv2ImportButton),
                    ),
                  ]),
              ),
            ],
            const SizedBox(height: Gap.md),
            Text(t.mv2FreeLine, textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.ds.muted)),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.mv2Title)),
      body: body,
      bottomNavigationBar: const MessAdBanner(),
    );
  }

  Widget _messTile(Map<String, dynamic> m, AppLocalizations t, ColorScheme scheme) {
    final closed = m['status'] == 'closed';
    final role = m['is_admin'] == true
        ? t.mv2RoleAdmin
        : (m['i_am_manager'] == true ? t.mv2RoleManager : t.mv2RoleMember);
    return Card(
      child: ListTile(
        key: ValueKey('mess-${m['id']}'),
        minTileHeight: 64,
        leading: CircleAvatar(child: Icon(closed ? Icons.lock_rounded : Icons.home_work_rounded)),
        title: Text('${m['name'] ?? ''}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
        subtitle: Text(closed ? t.mv2MessClosed : role),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _open((m['id'] as num).toInt()),
      ),
    );
  }
}

/// Create / edit mess sheet (owner order A): name REQUIRED (e.g. Rampura
/// Mess), optional address, month start day, breakfast 0.5 or 1, cut-off.
Future<Map<String, dynamic>?> showMessSettingsSheet(BuildContext context,
    {Map<String, dynamic>? current}) {
  return showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _MessSettingsSheet(current: current),
  );
}

class _MessSettingsSheet extends StatefulWidget {
  const _MessSettingsSheet({this.current});
  final Map<String, dynamic>? current;
  @override
  State<_MessSettingsSheet> createState() => _MessSettingsSheetState();
}

class _MessSettingsSheetState extends State<_MessSettingsSheet> {
  late final _name = TextEditingController(text: '${widget.current?['name'] ?? ''}');
  late final _addr = TextEditingController(text: '${widget.current?['address'] ?? ''}');
  late int _startDay = (widget.current?['month_start_day'] as num?)?.toInt() ?? 1;
  late int _breakfast = (widget.current?['breakfast_milli'] as num?)?.toInt() ?? 500;
  late int _cutoff = (widget.current?['cutoff_hour'] as num?)?.toInt() ?? 22;
  String? _nameErr;

  @override
  void dispose() {
    _name.dispose();
    _addr.dispose();
    super.dispose();
  }

  void _save() {
    final t = AppLocalizations.of(context);
    final n = _name.text.trim();
    if (n.isEmpty) {
      setState(() => _nameErr = t.mv2NameRequired);
      return;
    }
    Navigator.pop(context, {
      'name': n,
      'address': _addr.text.trim(),
      'month_start_day': _startDay,
      'breakfast_milli': _breakfast,
      'cutoff_hour': _cutoff,
      if (widget.current == null) 'client_id': MessOutbox.newClientId(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
          key: const ValueKey('mess-settings-save'),
          onPressed: _save,
          child: Text(widget.current == null ? t.mv2CreateMess : t.mv2Save),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.current == null ? t.mv2CreateMess : t.mv2EditMess,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.md),
        TextField(
          key: const ValueKey('mess-name'),
          controller: _name,
          maxLength: 80,
          buildCounter: localCounter,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
              labelText: t.mv2NameLabel, hintText: t.mv2NameHint, errorText: _nameErr),
          onChanged: (_) {
            if (_nameErr != null) setState(() => _nameErr = null);
          },
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          key: const ValueKey('mess-address'),
          controller: _addr,
          maxLength: 200,
          buildCounter: localCounter,
          decoration: InputDecoration(labelText: t.mv2AddressLabel),
        ),
        const SizedBox(height: Gap.sm),
        DropdownButtonFormField<int>(
          key: const ValueKey('mess-start-day'),
          initialValue: _startDay,
          isExpanded: true,
          decoration: InputDecoration(labelText: t.mv2StartDayLabel),
          items: [
            for (var d = 1; d <= 28; d++)
              DropdownMenuItem(value: d, child: Text(t.mv2StartDayItem(messDigits(context, d)))),
          ],
          onChanged: (v) => setState(() => _startDay = v ?? 1),
        ),
        const SizedBox(height: Gap.md),
        Text(t.mv2BreakfastLabel, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: Gap.xs),
        SegmentedButton<int>(
          segments: [
            ButtonSegment(value: 500, label: Text(messDigits(context, '0.5'))),
            ButtonSegment(value: 1000, label: Text(messDigits(context, '1'))),
          ],
          selected: {_breakfast},
          onSelectionChanged: (s) => setState(() => _breakfast = s.first),
        ),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<int>(
          key: const ValueKey('mess-cutoff'),
          initialValue: _cutoff,
          isExpanded: true,
          decoration: InputDecoration(labelText: t.mv2CutoffLabel),
          items: [
            for (var h = 12; h <= 23; h++)
              DropdownMenuItem(
                  value: h,
                  child: Text(t.mv2CutoffItem(messDigits(context, '${h.toString().padLeft(2, '0')}:00')))),
          ],
          onChanged: (v) => setState(() => _cutoff = v ?? 22),
        ),
      ]),
    );
  }
}
