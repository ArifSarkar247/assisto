import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/bangla_calendar.dart' show asciiDigits;
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/daily_tools_engine.dart';
import 'daily_tools_pages.dart';

/// DAILY TOOLS (p2tools, flag `daily_tools`, default OFF): the offline
/// toolbox for Bangladeshi daily life — land / weight / unit converter
/// (bigha, katha, decimal, maund, seer, bhori...), currency (user rate +
/// date, or Assisto's indicative rate with its source), age, EMI flat vs
/// reducing, zakat, VAT / discount / percent, tip + split bill, BMI, date
/// converter (English / Bangabda / Hijri — approximate), stopwatch + timer,
/// QR maker, dice / lottery for kids, Bangla word counter.
///
/// Search (bn + en names and keywords, Bangla digits ok), favourites (star,
/// kept on the phone) and recents. No ads on this screen (kids use the dice).
class DailyToolsScreen extends StatefulWidget {
  const DailyToolsScreen({super.key, this.debugFavs});

  /// Gallery/tests: start with these favourites instead of the stored ones.
  final List<String>? debugFavs;

  @override
  State<DailyToolsScreen> createState() => _DailyToolsScreenState();
}

/// Tool ids in display order.
const List<String> kDailyTools = [
  'land', 'weight', 'unit', 'currency', 'emi', 'zakat', 'percent', 'split',
  'age', 'date', 'bmi', 'timer', 'qr', 'words', 'fun',
];

/// English search words (the Bangla ones come from the ARB, `dtKw_<id>`).
const Map<String, String> _enKeywords = {
  'land': 'land bigha katha decimal shotangsho shotok acre jomi area plot',
  'weight': 'weight gold bhori tola ana rati maund mon seer kg gram',
  'unit': 'unit convert length foot metre hath inch volume litre temperature',
  'currency': 'currency dollar riyal ringgit exchange rate taka bdt remittance',
  'emi': 'emi loan installment kisti interest flat reducing bank',
  'zakat': 'zakat nisab gold silver ramadan',
  'percent': 'percent vat discount sale tax percentage',
  'split': 'split bill tip share friends restaurant',
  'age': 'age birthday born years',
  'date': 'date calendar bangla bangabda hijri arabic convert',
  'bmi': 'bmi weight height health body',
  'timer': 'timer stopwatch countdown clock lap',
  'qr': 'qr code wifi link share',
  'words': 'word count counter characters letters essay',
  'fun': 'dice coin toss lottery random number kids game',
};

IconData dailyToolIcon(String id) {
  switch (id) {
    case 'land':
      return Icons.landscape_rounded;
    case 'weight':
      return Icons.scale_rounded;
    case 'unit':
      return Icons.straighten_rounded;
    case 'currency':
      return Icons.currency_exchange_rounded;
    case 'emi':
      return Icons.account_balance_rounded;
    case 'zakat':
      return Icons.volunteer_activism_rounded;
    case 'percent':
      return Icons.percent_rounded;
    case 'split':
      return Icons.groups_rounded;
    case 'age':
      return Icons.cake_rounded;
    case 'date':
      return Icons.calendar_month_rounded;
    case 'bmi':
      return Icons.monitor_weight_rounded;
    case 'timer':
      return Icons.timer_rounded;
    case 'qr':
      return Icons.qr_code_2_rounded;
    case 'words':
      return Icons.text_fields_rounded;
    default:
      return Icons.casino_rounded;
  }
}

String dailyToolTitle(AppLocalizations t, String id) {
  switch (id) {
    case 'land':
      return t.dtToolLand;
    case 'weight':
      return t.dtToolWeight;
    case 'unit':
      return t.dtToolUnit;
    case 'currency':
      return t.dtToolCurrency;
    case 'emi':
      return t.dtToolEmi;
    case 'zakat':
      return t.dtToolZakat;
    case 'percent':
      return t.dtToolPercent;
    case 'split':
      return t.dtToolSplit;
    case 'age':
      return t.dtToolAge;
    case 'date':
      return t.dtToolDate;
    case 'bmi':
      return t.dtToolBmi;
    case 'timer':
      return t.dtToolTimer;
    case 'qr':
      return t.dtToolQr;
    case 'words':
      return t.dtToolWords;
    default:
      return t.dtToolFun;
  }
}

String dailyToolSub(AppLocalizations t, String id) {
  switch (id) {
    case 'land':
      return t.dtSubLand;
    case 'weight':
      return t.dtSubWeight;
    case 'unit':
      return t.dtSubUnit;
    case 'currency':
      return t.dtSubCurrency;
    case 'emi':
      return t.dtSubEmi;
    case 'zakat':
      return t.dtSubZakat;
    case 'percent':
      return t.dtSubPercent;
    case 'split':
      return t.dtSubSplit;
    case 'age':
      return t.dtSubAge;
    case 'date':
      return t.dtSubDate;
    case 'bmi':
      return t.dtSubBmi;
    case 'timer':
      return t.dtSubTimer;
    case 'qr':
      return t.dtSubQr;
    case 'words':
      return t.dtSubWords;
    default:
      return t.dtSubFun;
  }
}

/// True when [query] matches tool [id] (title, subtitle, bn keywords from the
/// ARB, English keywords). Case-insensitive; Bangla digits = ASCII digits.
bool dailyToolMatches(AppLocalizations t, String id, String query) {
  final q = asciiDigits(query.trim().toLowerCase());
  if (q.isEmpty) return true;
  final hay = [
    dailyToolTitle(t, id),
    dailyToolSub(t, id),
    t.dtKeywords(id),
    _enKeywords[id] ?? '',
    id,
  ].join(' ').toLowerCase();
  return q.split(RegExp(r'\s+')).every(hay.contains);
}

class _DailyToolsScreenState extends State<DailyToolsScreen> {
  final _search = TextEditingController();
  List<String> _favs = [];
  List<String> _recent = [];

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    if (widget.debugFavs != null) {
      _favs = [...widget.debugFavs!];
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final d = await DailyToolsStore.load();
    if (!mounted) return;
    setState(() {
      _favs = DailyToolsStore.strings(d, 'fav')
          .where(kDailyTools.contains)
          .toList();
      _recent = DailyToolsStore.strings(d, 'recent')
          .where(kDailyTools.contains)
          .toList();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _toggleFav(String id) async {
    final on = _favs.contains(id);
    setState(() => on ? _favs.remove(id) : _favs.add(id));
    await DailyToolsStore.patch({'fav': _favs});
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(on ? t.dtFavRemoved : t.dtFavAdded)));
  }

  Future<void> _open(String id) async {
    setState(() => _recent = DailyToolsStore.pushRecent(_recent, id));
    DailyToolsStore.patch({'recent': _recent});
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => DailyToolPage(
            tool: id,
            isFav: _favs.contains(id),
            onToggleFav: () => _toggleFav(id))));
  }

  Widget _tile(String id) {
    final fav = _favs.contains(id);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        minVerticalPadding: Gap.md,
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
          child: Icon(dailyToolIcon(id)),
        ),
        title: Text(dailyToolTitle(t, id),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(dailyToolSub(t, id)),
        trailing: IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: fav ? t.dtUnfav : t.dtFav,
          icon: Icon(fav ? Icons.star_rounded : Icons.star_border_rounded,
              color: fav ? Colors.amber.shade700 : null),
          onPressed: () => _toggleFav(id),
        ),
        onTap: () => _open(id),
      ),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.sm),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
      );

  @override
  Widget build(BuildContext context) {
    final q = _search.text;
    final hits = kDailyTools.where((id) => dailyToolMatches(t, id, q)).toList();
    final searching = q.trim().isNotEmpty;
    final recent = _recent.where((r) => !_favs.contains(r)).take(3).toList();
    return Scaffold(
      appBar: AppBar(title: Text(t.dtTitle)),
      body: ListView(
        padding: withNavBarInset(
            context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(t.dtIntro),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _search,
            inputFormatters: [LengthLimitingTextInputFormatter(60)],
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              labelText: t.dtSearchLabel,
              hintText: t.dtSearchHint,
              border: const OutlineInputBorder(),
              suffixIcon: searching
                  ? IconButton(
                      tooltip: t.dtClearSearch,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(_search.clear),
                    )
                  : null,
            ),
          ),
          if (searching) ...[
            _header(t.dtResults),
            if (hits.isEmpty) ...[
              Text(t.dtNoMatch),
              const SizedBox(height: Gap.sm),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => setState(_search.clear),
                icon: const Icon(Icons.apps_rounded),
                label: Text(t.dtShowAll),
              ),
            ] else
              for (final id in hits) _tile(id),
          ] else ...[
            _header(t.dtFavourites),
            if (_favs.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Row(children: [
                  const Icon(Icons.star_border_rounded),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text(t.dtFavEmpty)),
                ]),
              )
            else
              for (final id in _favs) _tile(id),
            if (recent.isNotEmpty) ...[
              _header(t.dtRecent),
              for (final id in recent) _tile(id),
            ],
            _header(t.dtAllTools),
            for (final id in kDailyTools)
              if (!_favs.contains(id) && !recent.contains(id)) _tile(id),
            const SizedBox(height: Gap.md),
            Text(t.dtOfflineNote,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
