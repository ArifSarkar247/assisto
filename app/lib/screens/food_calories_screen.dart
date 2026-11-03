import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../api.dart';
import '../chat_vision/chat_photo.dart';
import '../chat_vision/cv_backend.dart';
import '../chat_vision/cv_controller.dart';
import '../l10n/app_localizations.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/bn_day_periods.dart' show appDateLocale;
import '../widgets/confirm_delete.dart';
import '../widgets/health_disclaimer_bar.dart';
import '../widgets/local_counter.dart';
import '../widgets/local_digits.dart';
import '../widgets/skeleton.dart';

/// FOOD PHOTO -> CALORIES (p2food, owner PART 2; flag `food_calories`).
///
/// Photo of the plate (existing /chat-vision rails, purpose 'food': the model
/// only names dish IDS) or a manual pick from the Bangla dish list -> portion
/// (plate / bowl / piece, grams editable) -> calories + macros from the CITED
/// table served by GET /food/table (FCT Bangladesh 2013 + USDA FNDDS). Dishes
/// without a cited value never get a number; the user may type their own.
/// Daily log + goal + 7-day chart in the user's own collections:
///   listItems('food/log')  -> [{id, date, dish, name_bn, name_en, portion,
///       grams, kcal, protein, fat, carb, fibre, src, code, self, via}]
///   listItems('food/goal') -> [{id, kcal}]
/// The math mirrors backend/core/logic/food_calories.py.
class FoodCaloriesScreen extends StatefulWidget {
  const FoodCaloriesScreen({super.key, this.cvBackend, this.now});

  /// Tests / gallery: the vision seam and the clock.
  final CvBackend? cvBackend;
  final DateTime Function()? now;

  @override
  State<FoodCaloriesScreen> createState() => _FoodCaloriesScreenState();
}

const String foodLogPath = 'food/log';
const String foodGoalPath = 'food/goal';

class FoodPortion {
  const FoodPortion(this.id, this.label, this.grams, this.approx);
  final String id;
  final String label;
  final double grams;
  final bool approx;
}

class FoodDish {
  const FoodDish({
    required this.id,
    required this.group,
    required this.name,
    required this.nameBn,
    required this.nameEn,
    required this.syn,
    required this.hasValue,
    required this.per100,
    required this.src,
    required this.code,
    required this.source,
    required this.note,
    required this.portions,
  });
  final String id, group, name, nameBn, nameEn, syn, src, code, source, note;
  final bool hasValue;
  final Map<String, double?> per100;
  final List<FoodPortion> portions;

  static double? _d(dynamic v) => v is num ? v.toDouble() : null;

  factory FoodDish.fromJson(Map<String, dynamic> j) {
    final p = j['per100'] is Map ? Map<String, dynamic>.from(j['per100'] as Map) : const {};
    return FoodDish(
      id: '${j['id'] ?? ''}',
      group: '${j['group'] ?? ''}',
      name: '${j['name'] ?? ''}',
      nameBn: '${j['name_bn'] ?? ''}',
      nameEn: '${j['name_en'] ?? ''}',
      syn: '${j['syn'] ?? ''}',
      hasValue: j['has_value'] == true,
      per100: {for (final k in FoodMath.nutrients) k: _d(p[k])},
      src: '${j['src'] ?? ''}',
      code: '${j['code'] ?? ''}',
      source: '${j['source'] ?? ''}',
      note: '${j['note'] ?? ''}',
      portions: [
        for (final x in (j['portions'] is List ? j['portions'] as List : const []))
          if (x is Map)
            FoodPortion('${x['id']}', '${x['label'] ?? ''}',
                _d(x['g']) ?? 0, x['approx'] == true),
      ],
    );
  }

  bool matches(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return true;
    return name.toLowerCase().contains(s) ||
        nameBn.contains(s) ||
        nameEn.toLowerCase().contains(s) ||
        syn.toLowerCase().contains(s);
  }
}

/// Pure math — mirrors backend/core/logic/food_calories.py.
class FoodMath {
  static const nutrients = ['kcal', 'protein', 'fat', 'carb', 'fibre'];
  static const maxGrams = 3000.0;
  static const maxSelfKcal = 5000;
  static const goalMin = 800, goalMax = 5000, goalDefault = 2000;

  static double _r1(double v) => (v * 10).roundToDouble() / 10;

  /// Cited nutrients for [grams] of [d]; null when the dish has no cited
  /// value or the grams are out of range (never invented).
  static Map<String, num?>? of(FoodDish d, double grams) {
    final k = d.per100['kcal'];
    if (!d.hasValue || k == null || grams <= 0 || grams > maxGrams) return null;
    return {
      'kcal': (k * grams / 100).round(),
      for (final n in nutrients.skip(1))
        n: d.per100[n] == null ? null : _r1(d.per100[n]! * grams / 100),
    };
  }

  static double? entryKcal(Map<String, dynamic> e) {
    final v = e['kcal'];
    if (v is! num || v < 0 || v > maxSelfKcal * 2) return null;
    return v.toDouble();
  }

  static Map<String, num> day(List<Map<String, dynamic>> rows, String date) {
    double kcal = 0, p = 0, f = 0, c = 0;
    var count = 0, unknown = 0;
    for (final e in rows) {
      if ('${e['date'] ?? ''}' != date) continue;
      count++;
      final k = entryKcal(e);
      if (k == null) {
        unknown++;
        continue;
      }
      kcal += k;
      double g(String n) => e[n] is num ? (e[n] as num).toDouble() : 0;
      p += g('protein');
      f += g('fat');
      c += g('carb');
    }
    return {
      'kcal': kcal.round(),
      'protein': _r1(p),
      'fat': _r1(f),
      'carb': _r1(c),
      'count': count,
      'unknown': unknown,
    };
  }

  static int? cleanGoal(String raw) {
    final v = int.tryParse(raw.trim());
    if (v == null || v < goalMin || v > goalMax) return null;
    return v;
  }
}

String foodDateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _PhotoTurn {
  _PhotoTurn(this.request, this.controller);
  final ChatPhotoRequest request;
  final CvController controller;
}

class _FoodCaloriesScreenState extends State<FoodCaloriesScreen> {
  bool _loading = true, _off = false;
  Object? _failCause;
  List<FoodDish> _dishes = [];
  Map<String, dynamic> _table = const {};
  bool _photoReady = false;
  List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic>? _goalRow;
  final List<_PhotoTurn> _photos = [];

  DateTime get _now => (widget.now ?? DateTime.now)();
  String get _today => foodDateKey(_now);
  bool get _bn => Localizations.localeOf(context).languageCode == 'bn';
  String _d(Object v) => toLocalDigits('$v', _bn);
  String _n(num v) => _d(v == v.roundToDouble() ? v.round() : v);

  int get _goal {
    final v = _goalRow?['kcal'];
    return v is num && v >= FoodMath.goalMin && v <= FoodMath.goalMax
        ? v.toInt()
        : FoodMath.goalDefault;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final p in _photos) {
      p.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failCause = null;
    });
    final api = context.read<AppState>().api;
    try {
      final t = await api.getJson('/food/table');
      final rows = await api.listItems(foodLogPath);
      final goals = await api.listItems(foodGoalPath);
      if (!mounted) return;
      setState(() {
        _table = t;
        _dishes = [
          for (final d in (t['dishes'] is List ? t['dishes'] as List : const []))
            if (d is Map) FoodDish.fromJson(Map<String, dynamic>.from(d)),
        ];
        _photoReady = t['photo_ready'] == true;
        _rows = rows;
        _goalRow = goals.isEmpty ? null : goals.first;
        _loading = false;
        _off = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _off = e.status == 403;
        _failCause = e.status == 403 ? null : e;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failCause = e;
      });
    }
  }

  FoodDish? _dish(String id) {
    for (final d in _dishes) {
      if (d.id == id) return d;
    }
    return null;
  }

  // ------------------------------------------------------------ actions
  Future<void> _pickFromList() async {
    final d = await showAppSheet<FoodDish>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DishPicker(dishes: _dishes),
    );
    if (d != null && mounted) await _portion(d, via: 'list');
  }

  Future<void> _portion(FoodDish d, {required String via}) async {
    final entry = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PortionSheet(dish: d),
    );
    if (entry == null || !mounted) return;
    final row = {...entry, 'date': _today, 'via': via};
    final t = AppLocalizations.of(context);
    try {
      final saved = await context.read<AppState>().api.createItem(foodLogPath, row);
      if (!mounted) return;
      setState(() => _rows = [..._rows, {...row, ...saved}]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.foodSaveFail)));
    }
  }

  Future<void> _photo() async {
    final bytes = await ChatPhotoAttachButton.pickPhoto(context);
    if (bytes == null || !mounted) return;
    _startPhoto(bytes);
  }

  void _startPhoto(Uint8List bytes) {
    final t = AppLocalizations.of(context);
    final req = ChatPhotoRequest(bytes, t.foodPhotoQuestion);
    final c = CvController(
      backend: widget.cvBackend ??
          ApiCvBackend(context.read<AppState>().api, purpose: 'food'),
      bytes: bytes,
      question: req.question,
    );
    c.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => _photos.insert(0, _PhotoTurn(req, c)));
    WidgetsBinding.instance.addPostFrameCallback((_) => c.start());
  }

  Future<void> _delete(Map<String, dynamic> e) async {
    final id = e['id'];
    if (id is! int) return;
    if (!await confirmDelete(context, what: _entryName(e))) return;
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    try {
      await context.read<AppState>().api.deleteItem(foodLogPath, id);
      if (!mounted) return;
      setState(() => _rows = _rows.where((r) => r['id'] != id).toList());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.foodSaveFail)));
    }
  }

  Future<void> _setGoal() async {
    final t = AppLocalizations.of(context);
    final v = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GoalSheet(initial: _goal),
    );
    if (v == null || !mounted) return;
    final api = context.read<AppState>().api;
    try {
      final g = _goalRow;
      if (g != null && g['id'] is int) {
        await api.updateItem(foodGoalPath, g['id'] as int, {'kcal': v});
        if (mounted) setState(() => _goalRow = {...g, 'kcal': v});
      } else {
        final saved = await api.createItem(foodGoalPath, {'kcal': v});
        if (mounted) setState(() => _goalRow = {'kcal': v, ...saved});
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.foodSaveFail)));
    }
  }

  String _entryName(Map<String, dynamic> e) {
    final n = '${e[_bn ? 'name_bn' : 'name_en'] ?? ''}';
    return n.isNotEmpty ? n : (_dish('${e['dish']}')?.name ?? '${e['dish'] ?? ''}');
  }

  // ------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.foodTitle)),
      body: Column(children: [
        const HealthDisclaimerBar(),
        Expanded(child: _body(t)),
      ]),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_off) return _message(t.foodOff, retry: false);
    if (_failCause != null) {
      return _message(honestFailText(t, _failCause), retry: true);
    }
    final todays = _rows.where((r) => '${r['date']}' == _today).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          if (_rows.isEmpty && _photos.isEmpty) _empty(t) else _todayCard(t),
          const SizedBox(height: Gap.md),
          _actions(t),
          for (final p in _photos) ..._photoTurn(t, p),
          if (todays.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            _header(t.foodTodayList),
            for (final e in todays.reversed) _entryTile(t, e),
          ],
          if (_rows.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            _header(t.foodWeek),
            _WeekChart(rows: _rows, today: _now, goal: _goal),
          ],
          const SizedBox(height: Gap.lg),
          _hints(t),
          const SizedBox(height: Gap.md),
          _sources(t),
        ],
      ),
    );
  }

  Widget _message(String text, {required bool retry}) {
    final t = AppLocalizations.of(context);
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
      children: [
        Icon(retry ? Icons.cloud_off_rounded : Icons.lock_clock_rounded, size: 48),
        const SizedBox(height: Gap.md),
        Text(text, textAlign: TextAlign.center),
        if (retry) ...[
          const SizedBox(height: Gap.md),
          Center(
            child: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.foodRetry),
            ),
          ),
        ],
      ],
    );
  }

  Widget _header(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Semantics(
          header: true,
          child: Text(s,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
      );

  Widget _empty(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('food-empty'),
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.restaurant_rounded, size: 40, color: scheme.onPrimaryContainer),
          const SizedBox(height: Gap.sm),
          Text(t.foodEmptyBenefit,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.foodEmptyHow,
              style: TextStyle(color: scheme.onPrimaryContainer, height: 1.4)),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('food-empty-cta'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _photoReady ? _photo : _pickFromList,
              icon: Icon(_photoReady
                  ? Icons.photo_camera_rounded
                  : Icons.list_alt_rounded),
              label: Text(t.foodEmptyCta),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _todayCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final d = FoodMath.day(_rows, _today);
    final eaten = d['kcal']!.toInt();
    final goal = _goal;
    final left = goal - eaten;
    final ratio = (eaten / goal).clamp(0.0, 1.0);
    return Card(
      key: const Key('food-today'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.foodToday, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(t.foodEatenOfGoal(_d(eaten), _d(goal)),
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          Semantics(
            label: t.foodEatenOfGoal(_d(eaten), _d(goal)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 10,
                color: left < 0 ? scheme.error : scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(left >= 0 ? t.foodLeft(_d(left)) : t.foodOver(_d(-left)),
              style: TextStyle(
                  color: left < 0 ? scheme.error : scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          Text(t.foodMacros(_n(d['protein']!), _n(d['fat']!), _n(d['carb']!)),
              style: TextStyle(color: scheme.onSurfaceVariant)),
          if (d['unknown']! > 0) ...[
            const SizedBox(height: Gap.xs),
            Text(t.foodUnknownCount(_d(d['unknown']!)),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('food-goal'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _setGoal,
              icon: const Icon(Icons.flag_rounded),
              label: Text(t.foodSetGoal),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _actions(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_photoReady)
        FilledButton.icon(
          key: const Key('food-photo'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _photo,
          icon: const Icon(Icons.photo_camera_rounded),
          label: Text(t.foodPhotoBtn),
        )
      else
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Text(t.foodPhotoNotReady,
              key: const Key('food-photo-not-ready'),
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      const SizedBox(height: Gap.sm),
      OutlinedButton.icon(
        key: const Key('food-pick'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
        onPressed: _pickFromList,
        icon: const Icon(Icons.list_alt_rounded),
        label: Text(t.foodPickBtn),
      ),
    ]);
  }

  List<Widget> _photoTurn(AppLocalizations t, _PhotoTurn p) {
    final c = p.controller;
    final job = c.job;
    final found = <FoodDish>[
      if (job != null && job.done)
        for (final id in job.dishes)
          if (_dish(id) != null) _dish(id)!,
    ];
    return [
      const SizedBox(height: Gap.md),
      ChatPhotoTurn(key: ObjectKey(p), request: p.request, controller: c),
      if (job != null && job.done) ...[
        const SizedBox(height: Gap.sm),
        Text(found.isEmpty ? t.foodRecognisedNone : t.foodRecognised,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final d in found)
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 18),
              label: Text(d.name),
              onPressed: () => _portion(d, via: 'photo'),
            ),
        ]),
      ],
    ];
  }

  Widget _entryTile(AppLocalizations t, Map<String, dynamic> e) {
    final scheme = Theme.of(context).colorScheme;
    final k = FoodMath.entryKcal(e);
    final g = e['grams'] is num ? (e['grams'] as num) : null;
    final src = _dish('${e['dish']}')?.source ?? '${e['source'] ?? ''}';
    final sub = <String>[
      k == null ? t.foodNoValueTag : t.foodKcalValue(_d(k.round())),
      if (g != null) t.foodGramsValue(_n(g)),
      if (e['self'] == true) t.foodSelfTag,
      if (src.isNotEmpty && e['self'] != true) t.foodSourceLine(_d(src)),
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        minVerticalPadding: Gap.sm,
        title: Text(_entryName(e)),
        subtitle: Text(sub.join(' · '), style: TextStyle(color: scheme.onSurfaceVariant)),
        trailing: IconButton(
          tooltip: t.delete,
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () => _delete(e),
        ),
      ),
    );
  }

  Widget _hints(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final hints = _table['hints'] is List ? _table['hints'] as List : const [];
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header(t.foodHintsTitle),
          for (final h in hints)
            if (h is Map)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Text(_d('• ${h['text'] ?? ''}\n   (${h['src'] ?? ''})'),
                    style: TextStyle(color: scheme.onSecondaryContainer, height: 1.4)),
              ),
          Text('${_table['disclaimer'] ?? ''}',
              style: TextStyle(
                  color: scheme.onSecondaryContainer, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _sources(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final src = _table['sources'] is Map ? _table['sources'] as Map : const {};
    return Card(
      key: const Key('food-sources'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header(t.foodSourcesTitle),
          Text(t.foodSourcesBody, style: const TextStyle(height: 1.4)),
          for (final s in src.values)
            if (s is Map)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: SelectableText(_d('${s['short']}: ${s['cite']}'),
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
              ),
        ]),
      ),
    );
  }
}

// ======================================================= dish picker
class _DishPicker extends StatefulWidget {
  const _DishPicker({required this.dishes});
  final List<FoodDish> dishes;
  @override
  State<_DishPicker> createState() => _DishPickerState();
}

class _DishPickerState extends State<_DishPicker> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  static String _groupLabel(AppLocalizations t, String g) => switch (g) {
        'rice' => t.foodGroupRice,
        'bread' => t.foodGroupBread,
        'dal' => t.foodGroupDal,
        'curry' => t.foodGroupCurry,
        'veg' => t.foodGroupVeg,
        'fish' => t.foodGroupFish,
        'meat' => t.foodGroupMeat,
        'egg' => t.foodGroupEgg,
        'snack' => t.foodGroupSnack,
        'sweet' => t.foodGroupSweet,
        'drink' => t.foodGroupDrink,
        'fruit' => t.foodGroupFruit,
        _ => t.foodGroupExtra,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final list = widget.dishes.where((d) => d.matches(_q.text)).toList();
    final kids = <Widget>[];
    String? last;
    for (final d in list) {
      if (d.group != last) {
        last = d.group;
        kids.add(Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
          child: Semantics(
            header: true,
            child: Text(_groupLabel(t, d.group),
                style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
          ),
        ));
      }
      kids.add(ListTile(
        minVerticalPadding: Gap.sm,
        title: Text(d.name),
        subtitle: Text(
            d.hasValue
                ? t.foodSourceLine(toLocalDigits(d.source, Localizations.localeOf(context).languageCode == 'bn'))
                : t.foodNoValueTag,
            style: TextStyle(color: scheme.onSurfaceVariant)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.pop(context, d),
      ));
    }
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: TextField(
            key: const Key('food-search'),
            controller: _q,
            maxLength: 40,
            buildCounter: localCounter,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: t.foodSearchHint,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Text(t.foodNoMatch, textAlign: TextAlign.center),
                )
              : ListView(
                  padding: withNavBarInset(context, EdgeInsets.zero),
                  children: kids,
                ),
        ),
      ]),
    );
  }
}

// ======================================================= portion sheet
class _PortionSheet extends StatefulWidget {
  const _PortionSheet({required this.dish});
  final FoodDish dish;
  @override
  State<_PortionSheet> createState() => _PortionSheetState();
}

class _PortionSheetState extends State<_PortionSheet> {
  late FoodPortion? _p =
      widget.dish.portions.isEmpty ? null : widget.dish.portions.first;
  double _qty = 1;
  final _grams = TextEditingController();
  final _self = TextEditingController();
  bool _gramsEdited = false;

  bool get _bn => Localizations.localeOf(context).languageCode == 'bn';
  String _d(Object v) => toLocalDigits('$v', _bn);
  String _n(num v) => _d(v == v.roundToDouble() ? v.round() : v);

  @override
  void dispose() {
    _grams.dispose();
    _self.dispose();
    super.dispose();
  }

  /// Bangla or ASCII digits typed -> a number.
  static double? _parse(String s) {
    final b = StringBuffer();
    for (final c in s.trim().codeUnits) {
      b.writeCharCode(c >= 0x09E6 && c <= 0x09EF ? 0x30 + (c - 0x09E6) : c);
    }
    return double.tryParse(b.toString());
  }

  double get _gramsValue {
    if (_gramsEdited) return _parse(_grams.text) ?? 0;
    return (_p?.grams ?? 0) * _qty;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final d = widget.dish;
    final g = _gramsValue;
    final n = FoodMath.of(d, g);
    final selfK = _parse(_self.text);
    final selfOk = selfK != null && selfK > 0 && selfK <= FoodMath.maxSelfKcal;
    final canAdd = d.hasValue ? n != null : (_self.text.trim().isEmpty || selfOk);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d.name,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          if (d.hasValue)
            Text(t.foodSourceLine(_d(d.source)),
                key: const Key('food-source-line'),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          if (d.note.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(d.note, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
          if (d.hasValue) ...[
            const SizedBox(height: Gap.md),
            Text(t.foodPortion, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (final p in d.portions)
                ChoiceChip(
                  label: Text(
                      '${p.label} · ${t.foodGramsValue(_n(p.grams))}${p.approx ? ' (${t.foodApprox})' : ''}'),
                  selected: !_gramsEdited && _p?.id == p.id,
                  onSelected: (_) => setState(() {
                    _p = p;
                    _gramsEdited = false;
                    _grams.clear();
                  }),
                ),
            ]),
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(
                  child: Text(t.foodQty,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
              IconButton(
                tooltip: t.foodQtyLess,
                onPressed: _qty > 0.5
                    ? () => setState(() {
                          _qty -= 0.5;
                          _gramsEdited = false;
                        })
                    : null,
                icon: const Icon(Icons.remove_circle_outline_rounded),
              ),
              Text(_n(_qty), style: Theme.of(context).textTheme.titleMedium),
              IconButton(
                tooltip: t.foodQtyMore,
                onPressed: _qty < 10
                    ? () => setState(() {
                          _qty += 0.5;
                          _gramsEdited = false;
                        })
                    : null,
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ]),
            TextField(
              key: const Key('food-grams'),
              controller: _grams,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              maxLength: 5,
              buildCounter: localCounter,
              decoration: InputDecoration(
                labelText: t.foodGrams,
                hintText: _n(g),
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _gramsEdited = v.trim().isNotEmpty),
            ),
            const SizedBox(height: Gap.sm),
            Semantics(
              liveRegion: true,
              child: Text(
                n == null ? '—' : t.foodKcalValue(_d(n['kcal']!)),
                key: const Key('food-kcal'),
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (n != null)
              Text(
                  t.foodMacros(_n(n['protein'] ?? 0), _n(n['fat'] ?? 0),
                      _n(n['carb'] ?? 0)),
                  style: TextStyle(color: scheme.onSurfaceVariant)),
          ] else ...[
            const SizedBox(height: Gap.md),
            TextField(
              key: const Key('food-self-kcal'),
              controller: _self,
              keyboardType: TextInputType.number,
              maxLength: 4,
              buildCounter: localCounter,
              decoration: InputDecoration(
                labelText: t.foodSelfKcal,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('food-add'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: canAdd
                  ? () {
                      final selfVal = selfOk ? selfK!.round() : null;
                      Navigator.pop(context, <String, dynamic>{
                        'dish': d.id,
                        'name_bn': d.nameBn,
                        'name_en': d.nameEn,
                        'portion': _gramsEdited ? 'grams' : (_p?.id ?? ''),
                        'qty': _gramsEdited ? null : _qty,
                        'grams': d.hasValue ? g : null,
                        if (n != null) ...n,
                        if (n == null) 'kcal': selfVal,
                        'self': n == null && selfVal != null,
                        'src': d.hasValue ? d.src : '',
                        'code': d.code,
                        'source': d.hasValue ? d.source : '',
                      });
                    }
                  : null,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.foodAdd),
            ),
          ),
        ]),
      ),
    );
  }
}

// ======================================================= goal sheet
class _GoalSheet extends StatefulWidget {
  const _GoalSheet({required this.initial});
  final int initial;
  @override
  State<_GoalSheet> createState() => _GoalSheetState();
}

class _GoalSheetState extends State<_GoalSheet> {
  late final _c = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    String d(Object v) => toLocalDigits('$v', bn);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.foodGoalTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(t.foodGoalHelp(d(FoodMath.goalMin), d(FoodMath.goalMax))),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('food-goal-field'),
            controller: _c,
            keyboardType: TextInputType.number,
            maxLength: 4,
            buildCounter: localCounter,
            decoration: InputDecoration(
              hintText: d(widget.initial),
              errorText: _err,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('food-goal-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () {
                final b = StringBuffer();
                for (final c in _c.text.trim().codeUnits) {
                  b.writeCharCode(
                      c >= 0x09E6 && c <= 0x09EF ? 0x30 + (c - 0x09E6) : c);
                }
                final v = FoodMath.cleanGoal(b.toString());
                if (v == null) {
                  setState(() => _err =
                      t.foodGoalInvalid(d(FoodMath.goalMin), d(FoodMath.goalMax)));
                  return;
                }
                Navigator.pop(context, v);
              },
              child: Text(t.foodSave),
            ),
          ),
        ]),
      ),
    );
  }
}

// ======================================================= week chart
class _WeekChart extends StatelessWidget {
  const _WeekChart({required this.rows, required this.today, required this.goal});
  final List<Map<String, dynamic>> rows;
  final DateTime today;
  final int goal;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final base = DateTime(today.year, today.month, today.day);
    final days = [for (var i = 6; i >= 0; i--) base.subtract(Duration(days: i))];
    final kcal = [for (final d in days) FoodMath.day(rows, foodDateKey(d))['kcal']!.toInt()];
    final top = [goal, ...kcal].reduce((a, b) => a > b ? a : b).toDouble();
    final fmt = DateFormat.E(appDateLocale(context));
    return Card(
      key: const Key('food-week'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: SizedBox(
          height: 160,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Semantics(
                  label: t.foodWeekA11y(fmt.format(days[i]), toLocalDigits('${kcal[i]}', bn)),
                  excludeSemantics: true,
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    FittedBox(
                      child: Text(toLocalDigits('${kcal[i]}', bn),
                          style: const TextStyle(fontSize: 11)),
                    ),
                    const SizedBox(height: Gap.xxs),
                    Container(
                      height: top <= 0 ? 0 : 100 * kcal[i] / top,
                      margin: const EdgeInsets.symmetric(horizontal: Gap.xs),
                      decoration: BoxDecoration(
                        color: kcal[i] > goal ? scheme.error : scheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: Gap.xxs),
                    FittedBox(child: Text(fmt.format(days[i]))),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
