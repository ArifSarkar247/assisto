import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// QURBANI & EID PLANNER — ADVANCED (#190, SPEC v2.1 §20).
///
/// A Qurbani is one sacrificial animal. A large animal (cow/buffalo/camel) can
/// be shared by up to SEVEN people; a goat/sheep is ONE person's full Qurbani.
/// This screen tracks the animal + its shares, each participant and the shares
/// they hold, the EXACT cost-per-share split (no drift), the traditional
/// three-part meat-distribution plan (family/relatives/poor — the customary
/// split, shown neutrally and editable), and a planning checklist.
///
/// All MONEY is INTEGER POISHA; the on-screen math (`_QMath`) mirrors
/// backend/core/logic/qurbani.py VERBATIM (largest-remainder distribution) so
/// every number is deterministic and identical offline. The app HOLDS NO MONEY
/// and keeps NO animal — it only helps people plan and split the cost fairly.
///
/// Honest states: welcome (first use) · loading · error · empty-participants.
/// ZERO Bangla literals — every string is an AppLocalizations getter; the ৳
/// sign is a currency glyph (gate-exempt).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('qurbani/plans')        → [{id, animal, total_shares, cost,
///                                          meat_kg, dist_family, dist_relatives,
///                                          dist_poor, done}]
///   listItems('qurbani/participants')  → [{id, plan, name, shares}]
/// create/update/deleteItem on the same paths. Each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection (PaCollectionItem
/// precedent).
class QurbaniScreen extends StatefulWidget {
  const QurbaniScreen({super.key});
  @override
  State<QurbaniScreen> createState() => _QurbaniScreenState();
}

const String _plansPath = 'qurbani/plans';
const String _participantsPath = 'qurbani/participants';

// Animal kinds -> max shares (mirror qurbani.py ANIMAL_SHARES).
const Map<String, int> _animalShares = {
  'cow': 7,
  'buffalo': 7,
  'camel': 7,
  'goat': 1,
  'sheep': 1,
};
const List<String> _checklistSteps = [
  'animal_chosen',
  'shares_filled',
  'cost_collected',
  'butcher_booked',
  'storage_ready',
  'distribution',
];

class _QurbaniScreenState extends State<QurbaniScreen> {
  List<Map<String, dynamic>> _plans = [];
  List<Map<String, dynamic>> _participants = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  int? _planId; // currently selected plan

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
    final api = context.read<AppState>().api;
    try {
      final res = await Future.wait([
        api.listItems(_plansPath),
        api.listItems(_participantsPath),
      ]);
      _plans = res[0];
      _participants = res[1];
      _planId ??= _plans.isNotEmpty ? _plans.first['id'] as int? : null;
      if (_planId != null && !_plans.any((p) => p['id'] == _planId)) {
        _planId = _plans.isNotEmpty ? _plans.first['id'] as int? : null;
      }
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic>? get _plan {
    for (final p in _plans) {
      if (p['id'] == _planId) return p;
    }
    return null;
  }

  List<Map<String, dynamic>> get _planParticipants =>
      _participants.where((p) => p['plan'] == _planId).toList();

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.qurbaniTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.qurbaniTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.qurbaniLoadError),
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
          ),
        ),
      );
    }
    if (_plans.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.qurbaniTitle)),
        body: StateMessage(
          icon: Icons.volunteer_activism_outlined,
          title: tr.qurbaniWelcomeTitle,
          message: tr.qurbaniWelcomeBody,
          action: FilledButton.icon(
            onPressed: _addPlan,
            icon: const Icon(Icons.add),
            label: Text(tr.qurbaniNewPlan),
          ),
        ),
      );
    }
    final plan = _plan!;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.qurbaniTitle),
          actions: [
            if (_plans.length > 1)
              PopupMenuButton<int>(
                icon: const Icon(Icons.swap_horiz),
                tooltip: tr.qurbaniSwitchPlan,
                onSelected: (id) => setState(() => _planId = id),
                itemBuilder: (ctx) => [
                  for (final p in _plans)
                    PopupMenuItem<int>(
                      value: p['id'] as int,
                      child: Text(_animalLabel(tr, p['animal']?.toString())),
                    ),
                ],
              ),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: tr.qurbaniNewPlan,
              onPressed: _addPlan,
            ),
          ],
          bottom: TabBar(tabs: [
            Tab(text: tr.qurbaniTabAnimal),
            Tab(text: tr.qurbaniTabMeat),
            Tab(text: tr.qurbaniTabChecklist),
          ]),
        ),
        body: TabBarView(children: [
          _AnimalTab(
            plan: plan,
            participants: _planParticipants,
            onChanged: _load,
            onEditPlan: () => _editPlan(plan),
            onAddParticipant: () => _addParticipant(plan),
            onEditParticipant: _editParticipant,
            onDeleteParticipant: _deleteParticipant,
          ),
          _MeatTab(plan: plan, onEdit: () => _editMeat(plan)),
          _ChecklistTab(plan: plan, onToggle: _toggleStep),
        ]),
      ),
    );
  }

  // ---- plan CRUD ------------------------------------------------------------
  Future<void> _addPlan() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _planSheet(context, null);
    if (res == null) return;
    try {
      final row = await api.createItem(_plansPath, res);
      await _load();
      if (mounted) {
        setState(() => _planId = row['id'] as int?);
        _toast(tr.saved);
      }
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _editPlan(Map<String, dynamic> plan) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _planSheet(context, plan);
    if (res == null) return;
    try {
      await api.updateItem(_plansPath, plan['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _editMeat(Map<String, dynamic> plan) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _meatSheet(context, plan);
    if (res == null) return;
    try {
      await api.updateItem(_plansPath, plan['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _toggleStep(String step) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final plan = _plan!;
    final done = _QMath.doneList(plan['done']);
    if (done.contains(step)) {
      done.remove(step);
    } else {
      done.add(step);
    }
    try {
      await api.updateItem(_plansPath, plan['id'] as int, {'done': done});
      await _load();
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  // ---- participant CRUD -----------------------------------------------------
  Future<void> _addParticipant(Map<String, dynamic> plan) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final free = _QMath.sharesFree(plan, _planParticipants);
    if (free <= 0) {
      _toast(tr.qurbaniAllSharesTaken);
      return;
    }
    final res = await _participantSheet(context, null, free);
    if (res == null) return;
    res['plan'] = plan['id'];
    try {
      await api.createItem(_participantsPath, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _editParticipant(Map<String, dynamic> p) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final plan = _plan!;
    final free = _QMath.sharesFree(plan, _planParticipants) +
        (int.tryParse('${p['shares'] ?? 0}') ?? 0);
    final res = await _participantSheet(context, p, free);
    if (res == null) return;
    try {
      await api.updateItem(_participantsPath, p['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _deleteParticipant(Map<String, dynamic> p) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok = await _confirm(context, tr.qurbaniRemoveParticipantTitle,
        tr.qurbaniRemoveParticipantBody((p['name'] ?? '').toString()));
    if (ok != true) return;
    try {
      await api.deleteItem(_participantsPath, p['id'] as int);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

String _animalLabel(AppLocalizations tr, String? kind) {
  switch (kind) {
    case 'cow':
      return tr.qurbaniAnimalCow;
    case 'buffalo':
      return tr.qurbaniAnimalBuffalo;
    case 'camel':
      return tr.qurbaniAnimalCamel;
    case 'goat':
      return tr.qurbaniAnimalGoat;
    case 'sheep':
      return tr.qurbaniAnimalSheep;
    default:
      return tr.qurbaniAnimalCow;
  }
}

String _stepLabel(AppLocalizations tr, String step) {
  switch (step) {
    case 'animal_chosen':
      return tr.qurbaniStepAnimalChosen;
    case 'shares_filled':
      return tr.qurbaniStepSharesFilled;
    case 'cost_collected':
      return tr.qurbaniStepCostCollected;
    case 'butcher_booked':
      return tr.qurbaniStepButcherBooked;
    case 'storage_ready':
      return tr.qurbaniStepStorageReady;
    case 'distribution':
      return tr.qurbaniStepDistribution;
    default:
      return step;
  }
}

// ======================= ANIMAL + SHARES TAB =======================
class _AnimalTab extends StatelessWidget {
  final Map<String, dynamic> plan;
  final List<Map<String, dynamic>> participants;
  final Future<void> Function() onChanged;
  final VoidCallback onEditPlan;
  final VoidCallback onAddParticipant;
  final Future<void> Function(Map<String, dynamic>) onEditParticipant;
  final Future<void> Function(Map<String, dynamic>) onDeleteParticipant;
  const _AnimalTab({
    required this.plan,
    required this.participants,
    required this.onChanged,
    required this.onEditPlan,
    required this.onAddParticipant,
    required this.onEditParticipant,
    required this.onDeleteParticipant,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final summary = _QMath.planSummary(plan, participants);
    final total = summary.totalShares;
    final taken = summary.sharesTaken;
    final free = summary.sharesFree;
    return Scaffold(
      floatingActionButton: free > 0
          ? FloatingActionButton.extended(
              onPressed: onAddParticipant,
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(tr.qurbaniAddParticipant),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
        children: [
          // animal + cost card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.pets, color: scheme.primary),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                        _animalLabel(tr, plan['animal']?.toString()),
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: tr.edit,
                        onPressed: onEditPlan),
                  ]),
                  const SizedBox(height: Gap.sm),
                  _kv(context, tr.qurbaniTotalCost, summary.costDisplay),
                  _kv(context, tr.qurbaniCostPerShare,
                      summary.costPerShareDisplay),
                  _kv(context, tr.qurbaniCollected, summary.collectedDisplay),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.md),
          // shares progress
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.qurbaniSharesTakenOfTotal('$taken', '$total'),
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : taken / total,
                      minHeight: 10,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  Text(
                    free > 0
                        ? tr.qurbaniSharesFree('$free')
                        : tr.qurbaniAllSharesTaken,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.md),
          Text(tr.qurbaniParticipants,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          if (participants.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xl),
              child: StateMessage(
                icon: Icons.group_outlined,
                title: tr.qurbaniNoParticipantsTitle,
                message: tr.qurbaniNoParticipantsBody,
                action: FilledButton.icon(
                  onPressed: onAddParticipant,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: Text(tr.qurbaniAddParticipant),
                ),
              ),
            )
          else
            ...summary.participants.map((p) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text('${p.shares}',
                          style: TextStyle(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700)),
                    ),
                    title: Text(p.name),
                    subtitle: Text(tr.qurbaniSharesCount('${p.shares}')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(p.costDisplay,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          final raw = participants
                              .firstWhere((e) => e['id'] == p.id);
                          if (v == 'edit') onEditParticipant(raw);
                          if (v == 'delete') onDeleteParticipant(raw);
                        },
                        itemBuilder: (ctx) => [
                          PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                          PopupMenuItem(
                              value: 'delete', child: Text(tr.delete)),
                        ],
                      ),
                    ]),
                  ),
                )),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
              child: Text(k, style: TextStyle(color: scheme.onSurfaceVariant))),
          const SizedBox(width: Gap.sm),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ======================= MEAT DISTRIBUTION TAB =======================
class _MeatTab extends StatelessWidget {
  final Map<String, dynamic> plan;
  final VoidCallback onEdit;
  const _MeatTab({required this.plan, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final summary = _QMath.planSummary(plan, const []);
    final meat = summary.meatPlan;
    final totalG = summary.meatTotalG;
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(children: [
              Icon(Icons.info_outline, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(tr.qurbaniMeatNeutralNote)),
            ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        Card(
          child: ListTile(
            title: Text(tr.qurbaniMeatTotal),
            trailing: Text(
              totalG > 0 ? summary.meatTotalKgDisplay : tr.qurbaniMeatNotSet,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            onTap: onEdit,
          ),
        ),
        const SizedBox(height: Gap.md),
        if (totalG <= 0)
          StateMessage(
            icon: Icons.scale_outlined,
            title: tr.qurbaniMeatWelcomeTitle,
            message: tr.qurbaniMeatWelcomeBody,
            action: FilledButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
              label: Text(tr.qurbaniSetMeatWeight),
            ),
          )
        else
          ...meat.map((m) => Card(
                child: ListTile(
                  leading: Icon(_meatIcon(m.part), color: scheme.primary),
                  title: Text(_meatPartLabel(tr, m.part)),
                  trailing: Text(m.kgDisplay,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              )),
      ],
    );
  }

  IconData _meatIcon(String part) {
    switch (part) {
      case 'family':
        return Icons.home_outlined;
      case 'relatives':
        return Icons.diversity_3_outlined;
      default:
        return Icons.volunteer_activism_outlined;
    }
  }

  String _meatPartLabel(AppLocalizations tr, String part) {
    switch (part) {
      case 'family':
        return tr.qurbaniPartFamily;
      case 'relatives':
        return tr.qurbaniPartRelatives;
      default:
        return tr.qurbaniPartPoor;
    }
  }
}

// ======================= CHECKLIST TAB =======================
class _ChecklistTab extends StatelessWidget {
  final Map<String, dynamic> plan;
  final Future<void> Function(String) onToggle;
  const _ChecklistTab({required this.plan, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final done = _QMath.doneList(plan['done']);
    final pct = _checklistSteps.isEmpty
        ? 0
        : (100 * done.where(_checklistSteps.contains).length ~/
            _checklistSteps.length);
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr.qurbaniChecklistProgress('$pct'),
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 10,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        ..._checklistSteps.map((step) {
          final checked = done.contains(step);
          return Card(
            child: CheckboxListTile(
              value: checked,
              onChanged: (_) => onToggle(step),
              title: Text(_stepLabel(tr, step)),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          );
        }),
      ],
    );
  }
}

// ===========================================================================
// _QMath — VERBATIM mirror of backend/core/logic/qurbani.py (integer poisha,
// integer grams, largest-remainder split). Deterministic + offline-identical.
// ===========================================================================
class _QParticipant {
  final dynamic id;
  final String name;
  final int shares;
  final int cost;
  final String costDisplay;
  _QParticipant(this.id, this.name, this.shares, this.cost, this.costDisplay);
}

class _QMeat {
  final String part;
  final int grams;
  final String kgDisplay;
  _QMeat(this.part, this.grams, this.kgDisplay);
}

class _QSummary {
  final int totalShares;
  final int maxShares;
  final String costDisplay;
  final String costPerShareDisplay;
  final int sharesTaken;
  final int sharesFree;
  final String collectedDisplay;
  final List<_QParticipant> participants;
  final int meatTotalG;
  final String meatTotalKgDisplay;
  final List<_QMeat> meatPlan;
  _QSummary({
    required this.totalShares,
    required this.maxShares,
    required this.costDisplay,
    required this.costPerShareDisplay,
    required this.sharesTaken,
    required this.sharesFree,
    required this.collectedDisplay,
    required this.participants,
    required this.meatTotalG,
    required this.meatTotalKgDisplay,
    required this.meatPlan,
  });
}

class _QMath {
  static int toPoisha(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) return (v * 100).round();
    var s = v.toString().trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final parts = s.split('.');
      whole = parts[0];
      frac = parts.length > 1 ? parts[1] : '';
    } else {
      whole = s;
      frac = '';
    }
    whole = whole.isEmpty ? '0' : whole;
    frac = (frac + '00').substring(0, 3);
    final taka = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (taka == null || milli == null) return 0;
    var poisha = taka * 100 + milli ~/ 10;
    if (milli % 10 >= 5) poisha += 1;
    return neg ? -poisha : poisha;
  }

  static String _group(int n) {
    var s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  static String fmtPoisha(int p) {
    final neg = p < 0;
    p = p.abs();
    final taka = p ~/ 100;
    final paisa = p % 100;
    return '${neg ? '-' : ''}৳${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
  }

  static String kg(int grams) {
    final kg = grams ~/ 1000;
    final g = grams % 1000;
    return '${_group(kg)}.${(g ~/ 10).toString().padLeft(2, '0')} kg';
  }

  // largest-remainder split of `total` by `weights`; sums EXACTLY to total.
  static List<int> largestRemainder(int total, List<int> weights) {
    weights = weights.map((w) => w < 0 ? 0 : w).toList();
    var W = weights.fold<int>(0, (a, b) => a + b);
    if (weights.isEmpty) return [];
    if (W == 0) {
      weights = List.filled(weights.length, 1);
      W = weights.length;
    }
    final sign = total < 0 ? -1 : 1;
    final t = total.abs();
    final floors = <int>[];
    final rems = <int>[];
    for (final w in weights) {
      final num = t * w;
      floors.add(num ~/ W);
      rems.add(num % W);
    }
    var leftover = t - floors.fold<int>(0, (a, b) => a + b);
    final order = List<int>.generate(weights.length, (i) => i)
      ..sort((a, b) {
        final c = rems[b].compareTo(rems[a]);
        return c != 0 ? c : a.compareTo(b);
      });
    for (var k = 0; k < leftover; k++) {
      floors[order[k]] += 1;
    }
    return floors.map((f) => sign * f).toList();
  }

  static int maxShares(String? kind) =>
      _animalShares[(kind ?? '').toLowerCase()] ?? 7;

  static List<String> doneList(dynamic raw) {
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return <String>[];
  }

  static int sharesTaken(List<Map<String, dynamic>> participants) =>
      participants.fold<int>(
          0, (a, p) => a + (int.tryParse('${p['shares'] ?? 0}') ?? 0));

  static int sharesFree(
      Map<String, dynamic> plan, List<Map<String, dynamic>> participants) {
    final cap = maxShares(plan['animal']?.toString());
    var total = int.tryParse('${plan['total_shares'] ?? cap}') ?? cap;
    total = total.clamp(1, cap);
    final taken = sharesTaken(participants);
    final free = total - taken;
    return free < 0 ? 0 : free;
  }

  static _QSummary planSummary(
      Map<String, dynamic> plan, List<Map<String, dynamic>> participants) {
    final cap = maxShares(plan['animal']?.toString());
    var totalShares = int.tryParse('${plan['total_shares'] ?? cap}') ?? cap;
    totalShares = totalShares.clamp(1, cap);
    final cost = toPoisha(plan['cost']);

    final taken = sharesTaken(participants);
    final free = (totalShares - taken) < 0 ? 0 : (totalShares - taken);

    // cost per share (display rounding, half up)
    int cps = 0;
    if (totalShares > 0) {
      final base = cost.abs() ~/ totalShares;
      final rem = cost.abs() % totalShares;
      cps = base + (rem * 2 >= totalShares ? 1 : 0);
      if (cost < 0) cps = -cps;
    }

    // taken portion of the cost (no drift)
    int takenCost;
    if (taken <= 0) {
      takenCost = 0;
    } else if (taken >= totalShares) {
      takenCost = cost;
    } else {
      takenCost = largestRemainder(cost, [taken, totalShares - taken])[0];
    }
    final weights =
        participants.map((p) => int.tryParse('${p['shares'] ?? 0}') ?? 0).toList();
    final amounts =
        taken > 0 ? largestRemainder(takenCost, weights) : List.filled(weights.length, 0);
    final rows = <_QParticipant>[];
    var collected = 0;
    for (var i = 0; i < participants.length; i++) {
      final p = participants[i];
      final amt = i < amounts.length ? amounts[i] : 0;
      collected += amt;
      rows.add(_QParticipant(
        p['id'],
        (p['name'] ?? '').toString(),
        weights[i],
        amt,
        fmtPoisha(amt),
      ));
    }

    // meat
    final meatKg = double.tryParse('${plan['meat_kg'] ?? 0}') ?? 0;
    final meatG = (meatKg * 1000).round();
    final dw = [
      int.tryParse('${plan['dist_family'] ?? 1}') ?? 1,
      int.tryParse('${plan['dist_relatives'] ?? 1}') ?? 1,
      int.tryParse('${plan['dist_poor'] ?? 1}') ?? 1,
    ];
    final meatParts = largestRemainder(meatG, dw);
    const names = ['family', 'relatives', 'poor'];
    final meatPlan = <_QMeat>[];
    for (var i = 0; i < 3; i++) {
      meatPlan.add(_QMeat(names[i], meatParts[i], kg(meatParts[i])));
    }

    return _QSummary(
      totalShares: totalShares,
      maxShares: cap,
      costDisplay: fmtPoisha(cost),
      costPerShareDisplay: fmtPoisha(cps),
      sharesTaken: taken,
      sharesFree: free,
      collectedDisplay: fmtPoisha(collected),
      participants: rows,
      meatTotalG: meatG,
      meatTotalKgDisplay: kg(meatG),
      meatPlan: meatPlan,
    );
  }
}

// ======================= INPUT SHEETS =======================
Future<Map<String, dynamic>?> _planSheet(
    BuildContext context, Map<String, dynamic>? existing) async {
  final tr = AppLocalizations.of(context);
  String animal = (existing?['animal'] ?? 'cow').toString();
  final costC = TextEditingController(
      text: existing == null
          ? ''
          : (_QMath.toPoisha(existing['cost']) / 100).toStringAsFixed(2));
  int totalShares = int.tryParse('${existing?['total_shares'] ?? ''}') ??
      _QMath.maxShares(animal);
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        final cap = _QMath.maxShares(animal);
        if (totalShares > cap) totalShares = cap;
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(existing == null ? tr.qurbaniNewPlan : tr.qurbaniEditPlan,
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              DropdownButtonFormField<String>(
                initialValue: animal,
                decoration: InputDecoration(
                    labelText: tr.qurbaniAnimal,
                    border: const OutlineInputBorder()),
                items: [
                  for (final k in _animalShares.keys)
                    DropdownMenuItem(value: k, child: Text(_animalLabel(tr, k))),
                ],
                onChanged: (v) => setSheet(() {
                  animal = v ?? 'cow';
                  totalShares = _QMath.maxShares(animal);
                }),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: costC,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.qurbaniTotalCost,
                    prefixText: '৳ ',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              if (cap > 1)
                Row(children: [
                  Expanded(child: Text(tr.qurbaniTotalSharesLabel)),
                  DropdownButton<int>(
                    value: totalShares,
                    items: [
                      for (var i = 1; i <= cap; i++)
                        DropdownMenuItem(value: i, child: Text('$i')),
                    ],
                    onChanged: (v) =>
                        setSheet(() => totalShares = v ?? totalShares),
                  ),
                ])
              else
                Text(tr.qurbaniSingleShareNote,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (_QMath.toPoisha(costC.text) <= 0) {
                      ScaffoldMessenger.of(ctx)
                        ..clearSnackBars()
                        ..showSnackBar(
                            SnackBar(content: Text(tr.qurbaniCostRequired)));
                      return;
                    }
                    Navigator.pop(ctx, {
                      'animal': animal,
                      'total_shares': cap == 1 ? 1 : totalShares,
                      'cost': costC.text.trim(),
                    });
                  },
                  child: Text(tr.save),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

Future<Map<String, dynamic>?> _participantSheet(
    BuildContext context, Map<String, dynamic>? existing, int free) async {
  final tr = AppLocalizations.of(context);
  final nameC =
      TextEditingController(text: (existing?['name'] ?? '').toString());
  int shares = int.tryParse('${existing?['shares'] ?? 1}') ?? 1;
  if (shares > free) shares = free;
  if (shares < 1) shares = 1;
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                existing == null
                    ? tr.qurbaniAddParticipant
                    : tr.qurbaniEditParticipant,
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: nameC,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: tr.qurbaniParticipantName,
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(child: Text(tr.qurbaniShares)),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed:
                    shares > 1 ? () => setSheet(() => shares--) : null,
              ),
              Text('$shares',
                  style: Theme.of(ctx).textTheme.titleLarge),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed:
                    shares < free ? () => setSheet(() => shares++) : null,
              ),
            ]),
            Text(tr.qurbaniSharesFree('$free'),
                style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final name = nameC.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(ctx)
                      ..clearSnackBars()
                      ..showSnackBar(
                          SnackBar(content: Text(tr.qurbaniNameRequired)));
                    return;
                  }
                  Navigator.pop(ctx, {'name': name, 'shares': shares});
                },
                child: Text(tr.save),
              ),
            ),
          ]),
        );
      });
    },
  );
}

Future<Map<String, dynamic>?> _meatSheet(
    BuildContext context, Map<String, dynamic> plan) async {
  final tr = AppLocalizations.of(context);
  final kgC = TextEditingController(
      text: (double.tryParse('${plan['meat_kg'] ?? 0}') ?? 0) == 0
          ? ''
          : '${plan['meat_kg']}');
  int f = int.tryParse('${plan['dist_family'] ?? 1}') ?? 1;
  int r = int.tryParse('${plan['dist_relatives'] ?? 1}') ?? 1;
  int p = int.tryParse('${plan['dist_poor'] ?? 1}') ?? 1;
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        Widget stepper(String label, int val, void Function(int) set) => Row(
              children: [
                Expanded(child: Text(label)),
                IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: val > 0 ? () => set(val - 1) : null),
                Text('$val', style: Theme.of(ctx).textTheme.titleMedium),
                IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => set(val + 1)),
              ],
            );
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(tr.qurbaniMeatTitle,
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.sm),
              Text(tr.qurbaniMeatNeutralNote,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: kgC,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.qurbaniMeatTotal,
                    suffixText: 'kg',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Text(tr.qurbaniDistributionWeights,
                  style: Theme.of(ctx).textTheme.titleSmall),
              stepper(tr.qurbaniPartFamily, f, (v) => setSheet(() => f = v)),
              stepper(
                  tr.qurbaniPartRelatives, r, (v) => setSheet(() => r = v)),
              stepper(tr.qurbaniPartPoor, p, (v) => setSheet(() => p = v)),
              const SizedBox(height: Gap.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, {
                    'meat_kg': kgC.text.trim().isEmpty ? 0 : kgC.text.trim(),
                    'dist_family': f,
                    'dist_relatives': r,
                    'dist_poor': p,
                  }),
                  child: Text(tr.save),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

Future<bool?> _confirm(BuildContext context, String title, String body) {
  final tr = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(tr.delete)),
      ],
    ),
  );
}
