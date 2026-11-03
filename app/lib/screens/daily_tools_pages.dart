import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/bangla_calendar.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/daily_tools_engine.dart';
import '../widgets/finance_calc.dart' show EmiResult;
import '../widgets/local_digits.dart';
import '../world/world_api.dart';
import 'daily_tools_screen.dart' show dailyToolTitle;

/// One Daily tool, full screen (see daily_tools_screen.dart). Every tool
/// recalculates live as the user types — no "calculate" button to miss.
class DailyToolPage extends StatefulWidget {
  const DailyToolPage(
      {super.key,
      required this.tool,
      this.isFav = false,
      this.onToggleFav,
      this.worldApi,
      this.debugNow});
  final String tool;
  final bool isFav;
  final Future<void> Function()? onToggleFav;

  /// Tests: the source of "today's indicative rate / BAJUS price".
  final WorldApi? worldApi;

  /// Tests / gallery: a fixed "today".
  final DateTime? debugNow;

  @override
  State<DailyToolPage> createState() => _DailyToolPageState();
}

class _DailyToolPageState extends State<DailyToolPage> {
  late bool _fav = widget.isFav;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final now = widget.debugNow ?? DateTime.now();
    Widget body;
    switch (widget.tool) {
      case 'land':
        body = const UnitTool(cat: 'land', lockCat: true);
      case 'weight':
        body = const UnitTool(cat: 'weight', lockCat: true);
      case 'unit':
        body = const UnitTool(cat: 'length');
      case 'currency':
        body = CurrencyTool(worldApi: widget.worldApi, now: now);
      case 'emi':
        body = const EmiTool();
      case 'zakat':
        body = ZakatTool(worldApi: widget.worldApi);
      case 'percent':
        body = const PercentTool();
      case 'split':
        body = const SplitTool();
      case 'age':
        body = AgeTool(now: now);
      case 'date':
        body = DateTool(now: now);
      case 'bmi':
        body = const BmiTool();
      case 'timer':
        body = const TimerTool();
      case 'qr':
        body = const QrTool();
      case 'words':
        body = const WordsTool();
      default:
        body = const FunTool();
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(dailyToolTitle(t, widget.tool)),
        actions: [
          if (widget.onToggleFav != null)
            IconButton(
              tooltip: _fav ? t.dtUnfav : t.dtFav,
              icon: Icon(_fav ? Icons.star_rounded : Icons.star_border_rounded),
              onPressed: () async {
                setState(() => _fav = !_fav);
                await widget.onToggleFav!();
              },
            ),
        ],
      ),
      body: ListView(
        padding: withNavBarInset(
            context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [body],
      ),
    );
  }
}

// ------------------------------------------------------------------ shared bits

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// A number in the UI's digits with lakh grouping.
String _n(BuildContext c, double v, {int dp = 2}) =>
    toLocalDigits(fmtNum(v, dp: dp), _bn(c));

/// [v] as typed-in text in the UI's digits (prefills, chip taps).
String _ln(BuildContext c, Object v) => toLocalDigits('$v', _bn(c));

/// Prefilled fields show Bangla digits on a Bangla screen (once, after the
/// locale is known). parseNum reads both.
void localizePrefill(BuildContext c, Iterable<TextEditingController> cs) {
  if (!_bn(c)) return;
  for (final x in cs) {
    final v = toLocalDigits(x.text, true);
    if (v != x.text) x.text = v;
  }
}

String _money(BuildContext c, double v) => '৳ ${_n(c, v)}';

String _date(BuildContext c, DateTime d) {
  final loc = AppLocalizations.of(c).localeName;
  return toLocalDigits(
      '${d.day} ${DateFormat('MMMM', loc).format(d)} ${d.year}', _bn(c));
}

String _weekday(BuildContext c, DateTime d) =>
    DateFormat('EEEE', AppLocalizations.of(c).localeName).format(d);

class NumField extends StatelessWidget {
  const NumField(
      {super.key,
      required this.controller,
      required this.label,
      this.suffix,
      this.hint,
      this.onChanged,
      this.allowNegative = false});
  final TextEditingController controller;
  final String label;
  final String? suffix;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final bool allowNegative;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: TextField(
          controller: controller,
          keyboardType: TextInputType.numberWithOptions(
              decimal: true, signed: allowNegative),
          inputFormatters: [LengthLimitingTextInputFormatter(16)],
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixText: suffix,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}

/// Label/value result rows with a copy button for the whole result.
class ResultCard extends StatelessWidget {
  const ResultCard(
      {super.key, required this.rows, this.headline, this.copyText});
  final String? headline;
  final List<(String, String)> rows;
  final String? copyText;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (headline != null)
              Text(headline!,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: cs.onSecondaryContainer)),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Wrap(
                  spacing: Gap.sm,
                  children: [
                    Text(r.$1,
                        style: TextStyle(color: cs.onSecondaryContainer)),
                    Text(r.$2,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: cs.onSecondaryContainer)),
                  ],
                ),
              ),
            if (copyText != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: cs.onSecondaryContainer),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: copyText!));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text(t.dtCopied)));
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(t.dtCopy),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class NoteLine extends StatelessWidget {
  const NoteLine(this.text, {super.key, this.icon = Icons.info_outline_rounded});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );
}

/// Shown instead of a result until the needed numbers are typed — says
/// what to type (never a blank area).
class EnterHint extends StatelessWidget {
  const EnterHint(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      NoteLine(text, icon: Icons.edit_note_rounded);
}

Widget _chips<T>(BuildContext context, List<T> values, T selected,
        String Function(T) label, ValueChanged<T> onSel) =>
    Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final v in values)
          ChoiceChip(
            label: Text(label(v)),
            selected: v == selected,
            onSelected: (_) => onSel(v),
          ),
      ]),
    );

String unitName(AppLocalizations t, String id) => t.dtUnitName(id);

// ------------------------------------------------------------------ unit / land / weight

class UnitTool extends StatefulWidget {
  const UnitTool({super.key, required this.cat, this.lockCat = false});
  final String cat;
  final bool lockCat;
  @override
  State<UnitTool> createState() => _UnitToolState();
}

class _UnitToolState extends State<UnitTool> {
  late String _cat = widget.cat;
  late String _from = _defaultFrom(widget.cat);
  final _v = TextEditingController(text: '1');
  bool _loc = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loc) localizePrefill(context, [_v]);
    _loc = true;
  }

  static String _defaultFrom(String cat) {
    switch (cat) {
      case 'land':
        return 'bigha';
      case 'weight':
        return 'bhori';
      case 'temp':
        return 'c';
      case 'volume':
        return 'litre';
      default:
        return 'foot';
    }
  }

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final v = parseNum(_v.text);
    final all = v == null ? null : convertAll(_cat, _from, v);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!widget.lockCat)
        _chips<String>(
            context,
            const ['length', 'land', 'weight', 'volume', 'temp'],
            _cat,
            t.dtCatName,
            (c) => setState(() {
                  _cat = c;
                  _from = _defaultFrom(c);
                })),
      NumField(
          controller: _v,
          label: t.dtValue,
          allowNegative: _cat == 'temp',
          onChanged: (_) => setState(() {})),
      Text(t.dtFromUnit, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.sm),
      _chips<String>(context, [for (final u in kUnitCats[_cat]!) u.id], _from,
          (u) => unitName(t, u), (u) => setState(() => _from = u)),
      if (all == null)
        EnterHint(t.dtEnterValue)
      else
        Card(
          child: Column(children: [
            for (final e in all.entries)
              if (e.key != _from)
                InkWell(
                  // tap a row = copy that value (with a visible confirmation)
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(
                        text: toLocalDigits(fmtUnit(e.value), _bn(context))));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text(t.dtCopied)));
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Gap.lg, vertical: Gap.sm),
                      child: Row(children: [
                        Expanded(child: Text(unitName(t, e.key))),
                        const SizedBox(width: Gap.sm),
                        Flexible(
                          child: Text(
                              toLocalDigits(fmtUnit(e.value), _bn(context)),
                              textAlign: TextAlign.end,
                              style: const TextStyle(fontWeight: FontWeight.w800)),
                        ),
                      ]),
                    ),
                  ),
                ),
          ]),
        ),
      if (_cat == 'land') ...[
        NoteLine(t.dtLandNote),
        NoteLine(t.dtLandRegional),
      ],
      if (_cat == 'weight') NoteLine(t.dtWeightNote),
      if (_cat == 'length') NoteLine(t.dtLengthNote),
    ]);
  }
}

// ------------------------------------------------------------------ currency

class CurrencyTool extends StatefulWidget {
  const CurrencyTool({super.key, this.worldApi, required this.now});
  final WorldApi? worldApi;
  final DateTime now;
  @override
  State<CurrencyTool> createState() => _CurrencyToolState();
}

class _CurrencyToolState extends State<CurrencyTool> {
  String _code = 'USD';
  bool _toBdt = true;
  final _amount = TextEditingController(text: '100');
  final _rate = TextEditingController();
  bool _loc = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loc) localizePrefill(context, [_amount]);
    _loc = true;
  }

  DateTime? _rateDate;
  String _rateSource = 'user'; // 'user' | 'indicative'
  bool _loading = false;
  Map<String, dynamic> _saved = {};

  @override
  void initState() {
    super.initState();
    DailyToolsStore.load().then((d) {
      if (!mounted) return;
      final fx = d['fx'];
      _saved = fx is Map<String, dynamic> ? fx : {};
      _code = (d['fxCode'] ?? 'USD').toString();
      if (!kFxCodes.contains(_code)) _code = 'USD';
      _applySaved();
    });
  }

  void _applySaved() {
    final s = _saved[_code];
    setState(() {
      if (s is Map) {
        final r = (s['rate'] as num?)?.toDouble();
        _rate.text = r == null ? '' : _ln(context, fmtNum(r, dp: 4).replaceAll(',', ''));
        _rateDate = DateTime.tryParse('${s['date'] ?? ''}');
        _rateSource = '${s['src'] ?? 'user'}';
      } else {
        _rate.clear();
        _rateDate = null;
        _rateSource = 'user';
      }
    });
  }

  Future<void> _persist() async {
    final r = parseNum(_rate.text);
    if (r == null || r <= 0) return;
    _saved[_code] = {
      'rate': r,
      'date': (_rateDate ?? widget.now).toIso8601String().substring(0, 10),
      'src': _rateSource,
    };
    await DailyToolsStore.patch({'fx': _saved, 'fxCode': _code});
  }

  Future<void> _fillIndicative() async {
    final t = AppLocalizations.of(context);
    setState(() => _loading = true);
    Map<String, dynamic> j = {};
    try {
      final api = widget.worldApi ?? ApiWorldApi(context.read<AppState>().api);
      j = await api.today();
    } catch (_) {
      j = {};
    }
    if (!mounted) return;
    double? rate;
    String updated = '';
    final cards = j['cards'];
    final cur = cards is Map ? cards['currency'] : null;
    if (cur is Map && cur['rows'] is List) {
      for (final r in cur['rows'] as List) {
        if (r is Map && r['code'] == _code) {
          rate = (r['bdt'] as num?)?.toDouble();
        }
      }
      updated = '${cur['updated'] ?? ''}';
    }
    setState(() => _loading = false);
    if (rate == null || rate <= 0) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.dtFxNoFeed)));
      return;
    }
    setState(() {
      _rate.text = _ln(context, fmtNum(rate!, dp: 4).replaceAll(',', ''));
      _rateDate = DateTime.tryParse(updated) ?? widget.now;
      _rateSource = 'indicative';
    });
    _persist();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _rateDate ?? widget.now,
      firstDate: DateTime(2000),
      lastDate: widget.now,
    );
    if (d == null) return;
    setState(() => _rateDate = d);
    _persist();
  }

  @override
  void dispose() {
    _amount.dispose();
    _rate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final amount = parseNum(_amount.text);
    final rate = parseNum(_rate.text);
    final ok = amount != null && rate != null && rate > 0;
    final amt = amount ?? 0, rt = rate ?? 0;
    final fxName = t.dtFxName(_code);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.dtFxCurrency, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.sm),
      _chips<String>(context, kFxCodes, _code, t.dtFxName, (c) {
        _code = c;
        _applySaved();
        DailyToolsStore.patch({'fxCode': c});
      }),
      NumField(
        controller: _rate,
        label: t.dtFxRateLabel(fxName),
        suffix: '৳',
        onChanged: (_) {
          setState(() {
            _rateSource = 'user';
            _rateDate ??= widget.now;
          });
          _persist();
        },
      ),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _pickDate,
          icon: const Icon(Icons.event_rounded),
          label: Text(_rateDate == null
              ? t.dtFxRateDateNone
              : t.dtFxRateDate(_date(context, _rateDate!))),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _loading ? null : _fillIndicative,
          icon: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download_rounded),
          label: Text(t.dtFxUseIndicative),
        ),
      ]),
      if (_rateSource == 'indicative') NoteLine(t.dtFxIndicativeNote),
      const SizedBox(height: Gap.md),
      _chips<bool>(context, const [true, false], _toBdt,
          (v) => v ? t.dtFxToBdt(fxName) : t.dtFxFromBdt(fxName),
          (v) => setState(() => _toBdt = v)),
      NumField(
          controller: _amount,
          label: _toBdt ? t.dtFxAmountForeign(fxName) : t.dtFxAmountBdt,
          onChanged: (_) => setState(() {})),
      if (!ok)
        EnterHint(t.dtFxEnterRate)
      else
        ResultCard(
          headline: _toBdt
              ? _money(context, fxConvert(amt, rt))
              : '${_n(context, fxConvert(amt, rt, toBdt: false))} $_code',
          rows: [
            (t.dtFxRateUsed, '${_n(context, rt, dp: 4)} ৳'),
            if (_rateDate != null) (t.dtFxRateOn, _date(context, _rateDate!)),
          ],
          copyText: _toBdt
              ? toLocalDigits(fmtNum(fxConvert(amt, rt)), _bn(context))
              : toLocalDigits(
                  fmtNum(fxConvert(amt, rt, toBdt: false)), _bn(context)),
        ),
      NoteLine(t.dtFxHonest),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => launchUrl(
              Uri.parse('https://www.bb.org.bd/en/index.php/econdata/exchangerate'),
              mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(t.dtFxBbLink),
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ EMI

class EmiTool extends StatefulWidget {
  const EmiTool({super.key});
  @override
  State<EmiTool> createState() => _EmiToolState();
}

class _EmiToolState extends State<EmiTool> {
  final _p = TextEditingController();
  final _r = TextEditingController();
  final _m = TextEditingController(text: '12');
  bool _loc = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loc) localizePrefill(context, [_m]);
    _loc = true;
  }

  @override
  void dispose() {
    _p.dispose();
    _r.dispose();
    _m.dispose();
    super.dispose();
  }

  Widget _col(BuildContext context, String title, EmiResult r, bool highlight) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: highlight ? cs.secondaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          Text(t.dtEmiMonthly),
          Text(_money(context, r.emi),
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          Text('${t.dtEmiInterest} ${_money(context, r.interest)}'),
          Text('${t.dtEmiTotal} ${_money(context, r.total)}'),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = parseNum(_p.text);
    final r = parseNum(_r.text);
    final m = parseNum(_m.text)?.round();
    final ok = p != null && p > 0 && r != null && r >= 0 && m != null && m > 0 && m <= 600;
    final c = ok ? emiCompare(p!, r!, m!) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NumField(controller: _p, label: t.dtEmiPrincipal, suffix: '৳', onChanged: (_) => setState(() {})),
      NumField(controller: _r, label: t.dtEmiRate, suffix: '%', onChanged: (_) => setState(() {})),
      NumField(controller: _m, label: t.dtEmiMonths, onChanged: (_) => setState(() {})),
      _chips<int>(context, const [6, 12, 24, 36, 60], m ?? 0,
          (v) => t.dtMonthsN(_ln(context, v)), (v) => setState(() => _m.text = _ln(context, v))),
      if (c == null)
        EnterHint(t.dtEmiEnter)
      else ...[
        LayoutBuilder(builder: (context, box) {
          final a = _col(context, t.dtEmiReducing, c.reducing, true);
          final b = _col(context, t.dtEmiFlat, c.flat, false);
          if (box.maxWidth < 520 || MediaQuery.textScalerOf(context).scale(1) > 1.3) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, b]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: a),
            Expanded(child: b),
          ]);
        }),
        if (c.flatExtra > 0)
          ResultCard(rows: [
            (t.dtEmiFlatExtra, _money(context, c.flatExtra)),
            if (c.flatEffectiveRate > 0)
              (t.dtEmiFlatReally(_n(context, r ?? 0)), '${_n(context, c.flatEffectiveRate)}%'),
          ]),
      ],
      NoteLine(t.dtEmiExplain),
      NoteLine(t.dtEmiAsk),
    ]);
  }
}

// ------------------------------------------------------------------ zakat

class ZakatTool extends StatefulWidget {
  const ZakatTool({super.key, this.worldApi});
  final WorldApi? worldApi;
  @override
  State<ZakatTool> createState() => _ZakatToolState();
}

class _ZakatToolState extends State<ZakatTool> {
  String _basis = 'silver';
  final _goldP = TextEditingController();
  final _silverP = TextEditingController();
  final _cash = TextEditingController();
  final _gold = TextEditingController();
  final _silver = TextEditingController();
  final _biz = TextEditingController();
  final _debt = TextEditingController();
  String _priceSrc = 'user';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    DailyToolsStore.load().then((d) {
      if (!mounted) return;
      setState(() {
        final g = (d['goldPrice'] as num?)?.toDouble();
        final s = (d['silverPrice'] as num?)?.toDouble();
        if (g != null) _goldP.text = _ln(context, fmtNum(g).replaceAll(',', ''));
        if (s != null) _silverP.text = _ln(context, fmtNum(s).replaceAll(',', ''));
        _priceSrc = '${d['priceSrc'] ?? 'user'}';
      });
    });
  }

  @override
  void dispose() {
    for (final c in [_goldP, _silverP, _cash, _gold, _silver, _biz, _debt]) {
      c.dispose();
    }
    super.dispose();
  }

  void _savePrices() => DailyToolsStore.patch({
        'goldPrice': parseNum(_goldP.text),
        'silverPrice': parseNum(_silverP.text),
        'priceSrc': _priceSrc,
      });

  Future<void> _fillBajus() async {
    final t = AppLocalizations.of(context);
    setState(() => _loading = true);
    Map<String, dynamic> j = {};
    try {
      final api = widget.worldApi ?? ApiWorldApi(context.read<AppState>().api);
      j = await api.today();
    } catch (_) {
      j = {};
    }
    if (!mounted) return;
    double? g, s;
    final cards = j['cards'];
    final gold = cards is Map ? cards['gold'] : null;
    if (gold is Map && gold['rows'] is List) {
      for (final r in gold['rows'] as List) {
        if (r is! Map) continue;
        if (r['key'] == 'gold_22k') g = (r['bdt'] as num?)?.toDouble();
        if (r['key'] == 'silver_22k') s = (r['bdt'] as num?)?.toDouble();
      }
    }
    setState(() => _loading = false);
    if (g == null && s == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.dtZakatNoFeed)));
      return;
    }
    setState(() {
      if (g != null) _goldP.text = _ln(context, fmtNum(g).replaceAll(',', ''));
      if (s != null) _silverP.text = _ln(context, fmtNum(s).replaceAll(',', ''));
      _priceSrc = 'bajus';
    });
    _savePrices();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    double v(TextEditingController c) => parseNum(c.text) ?? 0;
    final z = zakatCalc(
      basis: _basis,
      goldPricePerBhori: v(_goldP),
      silverPricePerBhori: v(_silverP),
      cash: v(_cash),
      goldBhori: v(_gold),
      silverBhori: v(_silver),
      businessAndLent: v(_biz),
      debts: v(_debt),
    );
    void changed(String _) => setState(() {});
    void priceChanged(String _) {
      setState(() => _priceSrc = 'user');
      _savePrices();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.dtZakatBasis, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.sm),
      _chips<String>(context, const ['silver', 'gold'], _basis,
          (v) => v == 'gold' ? t.dtZakatGoldBasis : t.dtZakatSilverBasis,
          (v) => setState(() => _basis = v)),
      NoteLine(t.dtZakatBasisNote),
      NumField(controller: _goldP, label: t.dtZakatGoldPrice, suffix: '৳', onChanged: priceChanged),
      NumField(controller: _silverP, label: t.dtZakatSilverPrice, suffix: '৳', onChanged: priceChanged),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _loading ? null : _fillBajus,
          icon: const Icon(Icons.download_rounded),
          label: Text(t.dtZakatFillBajus),
        ),
      ),
      NoteLine(_priceSrc == 'bajus' ? t.dtZakatSrcBajus : t.dtZakatSrcUser),
      const SizedBox(height: Gap.sm),
      NumField(controller: _cash, label: t.dtZakatCash, suffix: '৳', onChanged: changed),
      NumField(controller: _gold, label: t.dtZakatGoldQty, suffix: t.dtUnitName('bhori'), onChanged: changed),
      NumField(controller: _silver, label: t.dtZakatSilverQty, suffix: t.dtUnitName('bhori'), onChanged: changed),
      NumField(controller: _biz, label: t.dtZakatBiz, suffix: '৳', onChanged: changed),
      NumField(controller: _debt, label: t.dtZakatDebt, suffix: '৳', onChanged: changed),
      if (z.priceMissing)
        EnterHint(_basis == 'gold' ? t.dtZakatNeedGold : t.dtZakatNeedSilver)
      else if (z.wealth <= 0)
        EnterHint(t.dtZakatEnterWealth)
      else
        ResultCard(
          headline: z.aboveNisab ? _money(context, z.due) : t.dtZakatBelow,
          rows: [
            (t.dtZakatNisab, _money(context, z.nisabValue)),
            (t.dtZakatWealth, _money(context, z.wealth)),
            if (z.aboveNisab) (t.dtZakatRate, t.dtZakatRateValue),
          ],
          copyText: z.aboveNisab ? toLocalDigits(fmtNum(z.due), _bn(context)) : null,
        ),
      NoteLine(t.dtZakatHonest),
    ]);
  }
}

// ------------------------------------------------------------------ percent / VAT / discount

class PercentTool extends StatefulWidget {
  const PercentTool({super.key});
  @override
  State<PercentTool> createState() => _PercentToolState();
}

class _PercentToolState extends State<PercentTool> {
  String _mode = 'vat_add';
  final _a = TextEditingController();
  final _b = TextEditingController(text: '15');
  bool _loc = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loc) localizePrefill(context, [_b]);
    _loc = true;
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  String _modeLabel(AppLocalizations t, String m) => t.dtPctMode(m);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final a = parseNum(_a.text);
    final b = parseNum(_b.text);
    final isRate = _mode != 'of' && _mode != 'change';
    String aLabel, bLabel;
    switch (_mode) {
      case 'vat_add':
        aLabel = t.dtPctPriceNoVat;
        bLabel = t.dtPctVatRate;
      case 'vat_out':
        aLabel = t.dtPctPriceWithVat;
        bLabel = t.dtPctVatRate;
      case 'discount':
        aLabel = t.dtPctPrice;
        bLabel = t.dtPctDiscount;
      case 'of':
        aLabel = t.dtPctPart;
        bLabel = t.dtPctWhole;
      default:
        aLabel = t.dtPctOld;
        bLabel = t.dtPctNew;
    }
    Widget result;
    if (a == null || b == null) {
      result = EnterHint(t.dtPctEnter);
    } else {
      switch (_mode) {
        case 'vat_add':
          final r = vatAdd(a, b);
          result = ResultCard(headline: _money(context, r.total), rows: [
            (t.dtPctVat, _money(context, r.vat)),
            (t.dtPctBase, _money(context, r.base)),
          ], copyText: toLocalDigits(fmtNum(r.total), _bn(context)));
        case 'vat_out':
          final r = vatExtract(a, b);
          result = ResultCard(headline: _money(context, r.base), rows: [
            (t.dtPctVatInside, _money(context, r.vat)),
            (t.dtPctTotal, _money(context, r.total)),
          ], copyText: toLocalDigits(fmtNum(r.base), _bn(context)));
        case 'discount':
          final (save, fin) = discount(a, b);
          result = ResultCard(headline: _money(context, fin), rows: [
            (t.dtPctYouSave, _money(context, save)),
          ], copyText: toLocalDigits(fmtNum(fin), _bn(context)));
        case 'of':
          final p = percentOf(a, b);
          result = p == null
              ? EnterHint(t.dtPctNotZero)
              : ResultCard(headline: '${_n(context, p)}%', rows: const []);
        default:
          final p = percentChange(a, b);
          result = p == null
              ? EnterHint(t.dtPctNotZero)
              : ResultCard(
                  headline: '${p >= 0 ? '+' : ''}${_n(context, p)}%',
                  rows: [(p >= 0 ? t.dtPctUp : t.dtPctDown, _n(context, (b - a).abs()))]);
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _chips<String>(context, const ['vat_add', 'vat_out', 'discount', 'of', 'change'],
          _mode, (m) => _modeLabel(t, m), (m) => setState(() {
                _mode = m;
                if (m == 'vat_add' || m == 'vat_out') _b.text = _ln(context, 15);
              })),
      NumField(controller: _a, label: aLabel, onChanged: (_) => setState(() {})),
      NumField(
          controller: _b,
          label: bLabel,
          suffix: isRate ? '%' : null,
          onChanged: (_) => setState(() {})),
      if (_mode == 'vat_add' || _mode == 'vat_out')
        _chips<double>(context, const [5, 7.5, 10, 15], b ?? -1,
            (v) => '${_n(context, v)}%', (v) => setState(() => _b.text = _ln(context, fmtNum(v)))),
      if (_mode == 'discount')
        _chips<double>(context, const [5, 10, 20, 25, 50], b ?? -1,
            (v) => '${_n(context, v)}%', (v) => setState(() => _b.text = _ln(context, fmtNum(v)))),
      result,
      if (_mode == 'vat_add' || _mode == 'vat_out') NoteLine(t.dtPctVatNote),
    ]);
  }
}

// ------------------------------------------------------------------ split bill

class SplitTool extends StatefulWidget {
  const SplitTool({super.key});
  @override
  State<SplitTool> createState() => _SplitToolState();
}

class _SplitToolState extends State<SplitTool> {
  final _bill = TextEditingController();
  int _people = 2;
  double _tip = 0;

  @override
  void dispose() {
    _bill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bill = parseNum(_bill.text);
    final r = bill == null ? null : splitBill(bill, _people, tipPct: _tip);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NumField(controller: _bill, label: t.dtSplitBill, suffix: '৳', onChanged: (_) => setState(() {})),
      Text(t.dtSplitPeople, style: const TextStyle(fontWeight: FontWeight.w800)),
      Row(children: [
        IconButton.filledTonal(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: t.dtLess,
          onPressed: _people > 1 ? () => setState(() => _people--) : null,
          icon: const Icon(Icons.remove_rounded),
        ),
        Expanded(
          child: Text(_n(context, _people.toDouble(), dp: 0),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall),
        ),
        IconButton.filledTonal(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: t.dtMore,
          onPressed: _people < 100 ? () => setState(() => _people++) : null,
          icon: const Icon(Icons.add_rounded),
        ),
      ]),
      const SizedBox(height: Gap.md),
      Text(t.dtSplitTip, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.sm),
      _chips<double>(context, const [0, 5, 10, 15], _tip,
          (v) => v == 0 ? t.dtSplitNoTip : '${_n(context, v)}%',
          (v) => setState(() => _tip = v)),
      if (r == null)
        EnterHint(t.dtSplitEnter)
      else
        ResultCard(
          headline: t.dtSplitEach(_money(context, r.perPerson)),
          rows: [
            if (r.tip > 0) (t.dtSplitTipAmt, _money(context, r.tip)),
            (t.dtSplitTotal, _money(context, r.total)),
            if (r.roundingExtra > 0)
              (t.dtSplitRounded(_money(context, r.perPersonRounded.toDouble())),
                  t.dtSplitExtra(_money(context, r.roundingExtra))),
          ],
          copyText: t.dtSplitShare(_money(context, r.total),
              _n(context, _people.toDouble(), dp: 0), _money(context, r.perPerson)),
        ),
    ]);
  }
}

// ------------------------------------------------------------------ age

class AgeTool extends StatefulWidget {
  const AgeTool({super.key, required this.now});
  final DateTime now;
  @override
  State<AgeTool> createState() => _AgeToolState();
}

class _AgeToolState extends State<AgeTool> {
  DateTime? _birth;
  late DateTime _on = widget.now;

  Future<void> _pick(bool birth) async {
    final d = await showDatePicker(
      context: context,
      initialDate: birth ? (_birth ?? DateTime(widget.now.year - 25)) : _on,
      firstDate: DateTime(1900),
      lastDate: DateTime(widget.now.year + 50),
    );
    if (d == null) return;
    setState(() {
      if (birth) {
        _birth = d;
      } else {
        _on = d;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final a = _birth == null ? null : ageOn(_birth!, _on);
    String n(int v) => _n(context, v.toDouble(), dp: 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 56)),
        onPressed: () => _pick(true),
        icon: const Icon(Icons.cake_rounded),
        label: Text(_birth == null ? t.dtAgePickBirth : t.dtAgeBorn(_date(context, _birth!))),
      ),
      const SizedBox(height: Gap.sm),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 56)),
        onPressed: () => _pick(false),
        icon: const Icon(Icons.event_rounded),
        label: Text(t.dtAgeOn(_date(context, _on))),
      ),
      const SizedBox(height: Gap.md),
      if (_birth == null)
        EnterHint(t.dtAgeEnter)
      else if (a == null)
        EnterHint(t.dtAgeFuture)
      else
        ResultCard(
          headline: t.dtAgeYmd(n(a.years), n(a.months), n(a.days)),
          rows: [
            (t.dtAgeTotalMonths, n(a.totalMonths)),
            (t.dtAgeTotalWeeks, n(a.totalWeeks)),
            (t.dtAgeTotalDays, n(a.totalDays)),
            (t.dtAgeNextBday, a.nextBirthdayIn == 0 ? t.dtAgeToday : t.dtDaysN(n(a.nextBirthdayIn))),
            (t.dtAgeBornWeekday, _weekday(context, _birth!)),
            (t.dtAgeBornBangla, BanglaDate.of(_birth!).format(bn: _bn(context))),
          ],
          copyText: t.dtAgeYmd(n(a.years), n(a.months), n(a.days)),
        ),
      NoteLine(t.dtAgeNote),
    ]);
  }
}

// ------------------------------------------------------------------ date converter

class DateTool extends StatefulWidget {
  const DateTool({super.key, required this.now});
  final DateTime now;
  @override
  State<DateTool> createState() => _DateToolState();
}

class _DateToolState extends State<DateTool> {
  String _from = 'en'; // en | bn | hijri
  late DateTime _g = DateTime.utc(widget.now.year, widget.now.month, widget.now.day);
  late final BanglaDate _b0 = BanglaDate.of(_g);
  late final HijriDate _h0 = HijriDate.of(_g);
  late final _bDay = TextEditingController(text: '${_b0.day}');
  late final _bYear = TextEditingController(text: '${_b0.year}');
  late int _bMonth = _b0.month;
  late final _hDay = TextEditingController(text: '${_h0.day}');
  late final _hYear = TextEditingController(text: '${_h0.year}');
  late int _hMonth = _h0.month;
  bool _loc = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loc) localizePrefill(context, [_bDay, _bYear, _hDay, _hYear]);
    _loc = true;
  }

  @override
  void dispose() {
    for (final c in [_bDay, _bYear, _hDay, _hYear]) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime? _resolve() {
    if (_from == 'en') return _g;
    if (_from == 'bn') {
      final d = parseNum(_bDay.text)?.round();
      final y = parseNum(_bYear.text)?.round();
      if (d == null || y == null || y < 1300 || y > 1600) return null;
      return bangabdaToGregorian(y, _bMonth, d);
    }
    final d = parseNum(_hDay.text)?.round();
    final y = parseNum(_hYear.text)?.round();
    if (d == null || y == null || y < 1300 || y > 1600 || d < 1) return null;
    if (d > HijriDate.monthLength(y, _hMonth)) return null;
    return HijriDate(y, _hMonth, d).toGregorian();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = _bn(context);
    final hMonths = t.dtHijriMonths.split(',');
    final g = _resolve();
    Widget dayYear(TextEditingController d, TextEditingController y) => Row(children: [
          Expanded(child: NumField(controller: d, label: t.dtDay, onChanged: (_) => setState(() {}))),
          const SizedBox(width: Gap.sm),
          Expanded(child: NumField(controller: y, label: t.dtYear, onChanged: (_) => setState(() {}))),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.dtDateFrom, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.sm),
      _chips<String>(context, const ['en', 'bn', 'hijri'], _from, t.dtCalName,
          (v) => setState(() {
                // carry the date being shown into the new calendar's fields
                final cur = _resolve();
                _from = v;
                if (cur == null) return;
                _g = cur;
                final b = BanglaDate.of(cur);
                final h = HijriDate.of(cur);
                _bDay.text = _ln(context, b.day);
                _bYear.text = _ln(context, b.year);
                _bMonth = b.month;
                _hDay.text = _ln(context, h.day);
                _hYear.text = _ln(context, h.year);
                _hMonth = h.month;
              })),
      if (_from == 'en')
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 56)),
          onPressed: () async {
            final d = await showDatePicker(
                context: context,
                initialDate: _g,
                firstDate: DateTime(1900),
                lastDate: DateTime(2100));
            if (d != null) setState(() => _g = DateTime.utc(d.year, d.month, d.day));
          },
          icon: const Icon(Icons.event_rounded),
          label: Text(_date(context, _g)),
        ),
      if (_from == 'bn') ...[
        DropdownButtonFormField<int>(
          value: _bMonth,
          isExpanded: true,
          decoration: InputDecoration(labelText: t.dtMonth, border: const OutlineInputBorder()),
          items: [
            for (var i = 1; i <= 12; i++)
              DropdownMenuItem(
                  value: i,
                  child: Text((bn ? BanglaDate.monthsBn : BanglaDate.monthsEn)[i - 1])),
          ],
          onChanged: (v) => setState(() => _bMonth = v ?? _bMonth),
        ),
        const SizedBox(height: Gap.md),
        dayYear(_bDay, _bYear),
      ],
      if (_from == 'hijri') ...[
        DropdownButtonFormField<int>(
          value: _hMonth,
          isExpanded: true,
          decoration: InputDecoration(labelText: t.dtMonth, border: const OutlineInputBorder()),
          items: [
            for (var i = 1; i <= 12; i++)
              DropdownMenuItem(value: i, child: Text(hMonths[(i - 1) % hMonths.length])),
          ],
          onChanged: (v) => setState(() => _hMonth = v ?? _hMonth),
        ),
        const SizedBox(height: Gap.md),
        dayYear(_hDay, _hYear),
      ],
      const SizedBox(height: Gap.md),
      if (g == null)
        EnterHint(t.dtDateInvalid)
      else
        Builder(builder: (context) {
          final b = BanglaDate.of(g);
          final h = HijriDate.of(g);
          final hs = toLocalDigits(
              '${h.day} ${hMonths[(h.month - 1) % hMonths.length]} ${h.year}', bn);
          return ResultCard(
            headline: _weekday(context, g),
            rows: [
              (t.dtCalName('en'), _date(context, g)),
              (t.dtCalName('bn'), b.format(bn: bn)),
              (t.dtHijriApprox, hs),
            ],
            copyText: '${_date(context, g)} | ${b.format(bn: bn)} | $hs',
          );
        }),
      NoteLine(t.dtBanglaCalNote),
      NoteLine(t.dtHijriNote),
    ]);
  }
}

// ------------------------------------------------------------------ BMI

class BmiTool extends StatefulWidget {
  const BmiTool({super.key});
  @override
  State<BmiTool> createState() => _BmiToolState();
}

class _BmiToolState extends State<BmiTool> {
  bool _feet = true;
  final _w = TextEditingController();
  final _cm = TextEditingController();
  final _ft = TextEditingController();
  final _in = TextEditingController();

  @override
  void dispose() {
    for (final c in [_w, _cm, _ft, _in]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final w = parseNum(_w.text);
    final h = _feet
        ? (parseNum(_ft.text) == null
            ? null
            : feetInchToCm(parseNum(_ft.text)!, parseNum(_in.text) ?? 0))
        : parseNum(_cm.text);
    final r = (w == null || h == null) ? null : bmiCalc(w, h);
    void ch(String _) => setState(() {});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NumField(controller: _w, label: t.dtBmiWeight, suffix: t.dtUnitName('kg'), onChanged: ch),
      _chips<bool>(context, const [true, false], _feet,
          (v) => v ? t.dtBmiFeet : t.dtBmiCm, (v) => setState(() => _feet = v)),
      if (_feet)
        Row(children: [
          Expanded(child: NumField(controller: _ft, label: t.dtUnitName('foot'), onChanged: ch)),
          const SizedBox(width: Gap.sm),
          Expanded(child: NumField(controller: _in, label: t.dtUnitName('inch'), onChanged: ch)),
        ])
      else
        NumField(controller: _cm, label: t.dtBmiHeightCm, suffix: t.dtUnitName('cm'), onChanged: ch),
      if (r == null)
        EnterHint(t.dtBmiEnter)
      else
        ResultCard(
          headline: '${t.dtToolBmi} ${_n(context, r.bmi, dp: 1)}',
          rows: [
            (t.dtBmiBandLabel, t.dtBmiBand(r.band)),
            (t.dtBmiHealthy,
                t.dtBmiRange(_n(context, r.healthyMinKg, dp: 1), _n(context, r.healthyMaxKg, dp: 1))),
          ],
        ),
      NoteLine(t.dtBmiNote),
    ]);
  }
}

// ------------------------------------------------------------------ stopwatch / timer

class TimerTool extends StatefulWidget {
  const TimerTool({super.key});
  @override
  State<TimerTool> createState() => _TimerToolState();
}

class _TimerToolState extends State<TimerTool> {
  bool _stopwatchMode = true;
  final Stopwatch _sw = Stopwatch();
  final List<Duration> _laps = [];
  Timer? _tick;
  Duration _countTotal = const Duration(minutes: 5);
  Duration _left = const Duration(minutes: 5);
  bool _counting = false;
  bool _done = false;
  final _mins = TextEditingController(text: '5');
  bool _loc = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loc) localizePrefill(context, [_mins]);
    _loc = true;
  }

  @override
  void dispose() {
    _tick?.cancel();
    _mins.dispose();
    super.dispose();
  }

  void _ensureTick() {
    _tick ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      if (_counting) {
        final left = _left - const Duration(milliseconds: 200);
        if (left <= Duration.zero) {
          _counting = false;
          _left = Duration.zero;
          _done = true;
          HapticFeedback.heavyImpact();
          Future.delayed(const Duration(milliseconds: 400), HapticFeedback.heavyImpact);
        } else {
          _left = left;
        }
      }
      if (!_sw.isRunning && !_counting) {
        _tick?.cancel();
        _tick = null;
      }
      setState(() {});
    });
  }

  String _fmt(Duration d, {bool tenths = true}) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ds = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    final core = h > 0 ? '$h:$m:$s' : '$m:$s';
    return toLocalDigits(tenths ? '$core.$ds' : core, _bn(context));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final big = Theme.of(context).textTheme.displaySmall?.copyWith(
        fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()]);
    final btn = FilledButton.styleFrom(minimumSize: const Size(120, 56));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _chips<bool>(context, const [true, false], _stopwatchMode,
          (v) => v ? t.dtStopwatch : t.dtCountdown,
          (v) => setState(() => _stopwatchMode = v)),
      const SizedBox(height: Gap.md),
      if (_stopwatchMode) ...[
        Semantics(
          liveRegion: false,
          label: t.dtStopwatch,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(_fmt(_sw.elapsed), style: big, textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Wrap(alignment: WrapAlignment.center, spacing: Gap.md, runSpacing: Gap.md, children: [
          FilledButton.icon(
            style: btn,
            onPressed: () => setState(() {
              if (_sw.isRunning) {
                _sw.stop();
              } else {
                _sw.start();
                _ensureTick();
              }
            }),
            icon: Icon(_sw.isRunning ? Icons.pause_rounded : Icons.play_arrow_rounded),
            label: Text(_sw.isRunning ? t.dtPause : t.dtStart),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(120, 56)),
            onPressed: _sw.isRunning
                ? () => setState(() => _laps.insert(0, _sw.elapsed))
                : (_sw.elapsed > Duration.zero
                    ? () => setState(() {
                          _sw.reset();
                          _laps.clear();
                        })
                    : null),
            icon: Icon(_sw.isRunning ? Icons.flag_rounded : Icons.restart_alt_rounded),
            label: Text(_sw.isRunning ? t.dtLap : t.dtReset),
          ),
        ]),
        for (var i = 0; i < _laps.length; i++)
          ListTile(
            title: Text(t.dtLapN(_n(context, (_laps.length - i).toDouble(), dp: 0))),
            trailing: Text(_fmt(_laps[i])),
          ),
      ] else ...[
        if (!_counting && !_done) ...[
          NumField(
              controller: _mins,
              label: t.dtMinutes,
              onChanged: (v) => setState(() {
                    final m = parseNum(v);
                    if (m != null && m > 0 && m <= 24 * 60) {
                      _countTotal = Duration(seconds: (m * 60).round());
                      _left = _countTotal;
                    }
                  })),
          _chips<int>(context, const [1, 3, 5, 10, 15, 30], _countTotal.inSeconds % 60 == 0 ? _countTotal.inMinutes : -1,
              (v) => t.dtMinutesN(_ln(context, v)), (v) => setState(() {
                    _mins.text = _ln(context, v);
                    _countTotal = Duration(minutes: v);
                    _left = _countTotal;
                  })),
        ],
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(_fmt(_left, tenths: false), style: big, textAlign: TextAlign.center),
        ),
        if (_done)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Text(t.dtTimeUp,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800)),
          ),
        const SizedBox(height: Gap.lg),
        Wrap(alignment: WrapAlignment.center, spacing: Gap.md, runSpacing: Gap.md, children: [
          FilledButton.icon(
            style: btn,
            onPressed: () => setState(() {
              if (_done) {
                _done = false;
                _left = _countTotal;
                return;
              }
              _counting = !_counting;
              if (_counting) _ensureTick();
            }),
            icon: Icon(_counting ? Icons.pause_rounded : Icons.play_arrow_rounded),
            label: Text(_done ? t.dtReset : (_counting ? t.dtPause : t.dtStart)),
          ),
          if (!_done)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(120, 56)),
              onPressed: _left != _countTotal
                  ? () => setState(() {
                        _counting = false;
                        _left = _countTotal;
                      })
                  : null,
              icon: const Icon(Icons.restart_alt_rounded),
              label: Text(t.dtReset),
            ),
        ]),
        NoteLine(t.dtTimerNote),
      ],
    ]);
  }
}

// ------------------------------------------------------------------ QR maker

class QrTool extends StatefulWidget {
  const QrTool({super.key});
  @override
  State<QrTool> createState() => _QrToolState();
}

class _QrToolState extends State<QrTool> {
  String _kind = 'text'; // text | wifi | phone
  final _text = TextEditingController();
  final _ssid = TextEditingController();
  final _pass = TextEditingController();

  @override
  void dispose() {
    for (final c in [_text, _ssid, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _payload() {
    String esc(String s) => s.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
    switch (_kind) {
      case 'wifi':
        final s = _ssid.text.trim();
        if (s.isEmpty) return null;
        final p = _pass.text;
        return p.isEmpty
            ? 'WIFI:T:nopass;S:${esc(s)};;'
            : 'WIFI:T:WPA;S:${esc(s)};P:${esc(p)};;';
      case 'phone':
        final n = asciiDigits(_text.text).replaceAll(RegExp(r'[^0-9+]'), '');
        return n.length < 3 ? null : 'tel:$n';
      default:
        final s = _text.text.trim();
        return s.isEmpty ? null : s;
    }
  }

  Future<void> _share(String data) async {
    final t = AppLocalizations.of(context);
    try {
      final img = await QrPainter(
        data: data,
        version: QrVersions.auto,
        gapless: true,
        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
        dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square, color: Colors.black),
      ).toImageData(720);
      if (img == null) throw StateError('no image');
      await Share.shareXFiles([
        XFile.fromData(img.buffer.asUint8List(), mimeType: 'image/png', name: 'qr.png'),
      ]);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.dtQrShareFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final data = _payload();
    void ch(String _) => setState(() {});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _chips<String>(context, const ['text', 'wifi', 'phone'], _kind, t.dtQrKind,
          (v) => setState(() => _kind = v)),
      if (_kind == 'wifi') ...[
        _plainField(_ssid, t.dtQrSsid, ch),
        _plainField(_pass, t.dtQrPass, ch),
      ] else
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: TextField(
            controller: _text,
            onChanged: ch,
            minLines: 1,
            maxLines: 4,
            keyboardType: _kind == 'phone' ? TextInputType.phone : TextInputType.multiline,
            inputFormatters: [LengthLimitingTextInputFormatter(800)],
            decoration: InputDecoration(
                labelText: _kind == 'phone' ? t.dtQrPhone : t.dtQrText,
                border: const OutlineInputBorder()),
          ),
        ),
      if (data == null)
        EnterHint(t.dtQrEnter)
      else ...[
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(Gap.md),
            child: Semantics(
              label: t.dtToolQr,
              child: QrImageView(
                  data: data, size: 220, backgroundColor: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: () => _share(data),
          icon: const Icon(Icons.share_rounded),
          label: Text(t.dtQrShare),
        ),
      ],
      NoteLine(t.dtQrNoScanner),
    ]);
  }

  Widget _plainField(TextEditingController c, String label, ValueChanged<String> ch) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: TextField(
          controller: c,
          onChanged: ch,
          inputFormatters: [LengthLimitingTextInputFormatter(64)],
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );
}

// ------------------------------------------------------------------ words

class WordsTool extends StatefulWidget {
  const WordsTool({super.key});
  @override
  State<WordsTool> createState() => _WordsToolState();
}

class _WordsToolState extends State<WordsTool> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = wordStats(_c.text);
    String n(int v) => _n(context, v.toDouble(), dp: 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _c,
        onChanged: (_) => setState(() {}),
        minLines: 5,
        maxLines: 12,
        inputFormatters: [LengthLimitingTextInputFormatter(50000)],
        decoration: InputDecoration(
            labelText: t.dtWordsInput,
            hintText: t.dtWordsHint,
            border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.md),
      if (s.words == 0)
        EnterHint(t.dtWordsEnter)
      else
        ResultCard(
          headline: t.dtWordsN(n(s.words)),
          rows: [
            (t.dtWordsBangla, n(s.banglaWords)),
            (t.dtWordsEnglish, n(s.englishWords)),
            (t.dtWordsChars, n(s.chars)),
            (t.dtWordsCharsNoSpace, n(s.charsNoSpace)),
            (t.dtWordsSentences, n(s.sentences)),
            (t.dtWordsParagraphs, n(s.paragraphs)),
            (t.dtWordsRead, t.dtMinutesApprox(n((s.readSeconds / 60).ceil()))),
          ],
        ),
    ]);
  }
}

// ------------------------------------------------------------------ dice / coin / lottery

class FunTool extends StatefulWidget {
  const FunTool({super.key, this.rng});
  final math.Random? rng;
  @override
  State<FunTool> createState() => _FunToolState();
}

class _FunToolState extends State<FunTool> {
  late final math.Random _rng = widget.rng ?? math.Random();
  int _diceCount = 1;
  List<int> _dice = const [];
  bool? _coin;
  final _lo = TextEditingController(text: '1');
  final _hi = TextEditingController(text: '100');
  final _count = TextEditingController(text: '1');
  List<int>? _picked;
  bool _loc = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loc) localizePrefill(context, [_lo, _hi, _count]);
    _loc = true;
  }
  bool _pickError = false;

  static const _faces = [
    Icons.looks_one_rounded, Icons.looks_two_rounded, Icons.looks_3_rounded,
    Icons.looks_4_rounded, Icons.looks_5_rounded, Icons.looks_6_rounded,
  ];

  @override
  void dispose() {
    for (final c in [_lo, _hi, _count]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final sum = _dice.fold<int>(0, (a, b) => a + b);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.dtDice, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.sm),
      _chips<int>(context, const [1, 2, 3], _diceCount, (v) => t.dtDiceN(_ln(context, v)),
          (v) => setState(() {
                _diceCount = v;
                _dice = const [];
              })),
      if (_dice.isNotEmpty)
        Semantics(
          liveRegion: true,
          label: t.dtDiceResult(_n(context, sum.toDouble(), dp: 0)),
          child: Wrap(alignment: WrapAlignment.center, spacing: Gap.md, children: [
            for (final d in _dice) Icon(_faces[d - 1], size: 72, color: cs.primary),
          ]),
        ),
      if (_dice.length > 1)
        Text(t.dtDiceResult(_n(context, sum.toDouble(), dp: 0)), textAlign: TextAlign.center),
      const SizedBox(height: Gap.sm),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
        onPressed: () {
          HapticFeedback.selectionClick();
          setState(() => _dice = rollDice(_diceCount, _rng));
        },
        icon: const Icon(Icons.casino_rounded),
        label: Text(t.dtRoll),
      ),
      const Divider(height: Gap.xxl),
      Text(t.dtCoin, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.sm),
      if (_coin != null)
        Semantics(
          liveRegion: true,
          child: Text(_coin! ? t.dtHeads : t.dtTails,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
        ),
      FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
        onPressed: () => setState(() => _coin = flipCoin(_rng)),
        icon: const Icon(Icons.toll_rounded),
        label: Text(t.dtFlip),
      ),
      const Divider(height: Gap.xxl),
      Text(t.dtPick, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.sm),
      Row(children: [
        Expanded(child: NumField(controller: _lo, label: t.dtFrom)),
        const SizedBox(width: Gap.sm),
        Expanded(child: NumField(controller: _hi, label: t.dtTo)),
      ]),
      NumField(controller: _count, label: t.dtHowMany),
      if (_pickError) EnterHint(t.dtPickInvalid),
      if (_picked != null)
        Semantics(
          liveRegion: true,
          child: Text(toLocalDigits(_picked!.join(', '), _bn(context)),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        ),
      const SizedBox(height: Gap.sm),
      FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
        onPressed: () {
          final lo = parseNum(_lo.text)?.round();
          final hi = parseNum(_hi.text)?.round();
          final c = parseNum(_count.text)?.round();
          final r = (lo == null || hi == null || c == null || c > 100)
              ? null
              : pickNumbers(lo, hi, c, _rng);
          setState(() {
            _picked = r;
            _pickError = r == null;
          });
        },
        icon: const Icon(Icons.shuffle_rounded),
        label: Text(t.dtPickGo),
      ),
    ]);
  }
}
