import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../api.dart';
import '../wrapped_api.dart';
import '../widgets/skeleton.dart';
import '../widgets/wrapped_cards.dart';
import '../widgets/wrapped_share.dart';
import 'money_common.dart';
import '../services/error_kind.dart' show honestFailText; // qa2
import '../widgets/bn_day_periods.dart' show appDateLocale;
import '../widgets/subs_common.dart' show fmtInt;

/// Monthly Money Wrapped (feature #63, SPEC v2.1 §21) — a Spotify-Wrapped-style
/// recap of ONE month, built from the user's REAL transactions (read-only).
///
/// Swipeable story cards (PageView) in the brand gradient, each a festival-card
/// surface that can be captured and shared as an image. The recap comes from
/// the backend [WrappedApi.moneyWrapped] endpoint, which computes every figure
/// from real rows and NEVER invents numbers; for users with too little history
/// it returns `enough_data: false` and this screen shows an honest
/// "not enough data yet" state instead of fabricating a recap.
///
/// No literal Bangla text lives here: all copy is from ARB (`t.*`); only the
/// Taka symbol (via [tkFmt]) and real numbers render. The personality slug from
/// the backend is mapped to a localised title/blurb + an emoji below.
class MoneyWrappedScreen extends StatefulWidget {
  /// Optional 'YYYY-MM' to recap; null lets the server pick the latest month.
  final String? month;
  const MoneyWrappedScreen({super.key, this.month});

  @override
  State<MoneyWrappedScreen> createState() => _MoneyWrappedScreenState();
}

class _MoneyWrappedScreenState extends State<MoneyWrappedScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  int _page = 0;
  final _pageController = PageController();
  // One capture key per card so we can share exactly the visible slide.
  final Map<int, GlobalKey> _cardKeys = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final d = await app.api.moneyWrapped(month: widget.month);
      if (mounted) setState(() => _data = d);
    } on ApiException catch (e) {
      if (mounted) setState(() {
        _failed = true;
        _failCause = e;
      });
    } catch (e) {
      if (mounted) setState(() {
        _failed = true;
        _failCause = e;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  GlobalKey _keyFor(int i) => _cardKeys.putIfAbsent(i, () => GlobalKey());

  // -- personality slug -> (emoji, localised title, localised blurb) ----------
  (String, String, String) _persona(AppLocalizations t, String slug) {
    switch (slug) {
      case 'super_saver':
        return ('\u{1F4B0}', t.wrappedPersonaSuperSaver,
            t.wrappedPersonaSuperSaverBlurb);
      case 'big_spender':
        return ('\u{1F680}', t.wrappedPersonaBigSpender,
            t.wrappedPersonaBigSpenderBlurb);
      case 'mindful_minimalist':
        return ('\u{1F9D8}', t.wrappedPersonaMinimalist,
            t.wrappedPersonaMinimalistBlurb);
      case 'foodie':
        return ('\u{1F371}', t.wrappedPersonaFoodie,
            t.wrappedPersonaFoodieBlurb);
      case 'treat_yourself':
        return ('\u{1F6CD}', t.wrappedPersonaTreatYourself,
            t.wrappedPersonaTreatYourselfBlurb);
      case 'always_on_the_move':
        return ('\u{1F6F5}', t.wrappedPersonaOnTheMove,
            t.wrappedPersonaOnTheMoveBlurb);
      case 'steady_balancer':
        return ('⚖️', t.wrappedPersonaBalancer,
            t.wrappedPersonaBalancerBlurb);
      case 'quiet_month':
        return ('\u{1F31F}', t.wrappedPersonaQuiet,
            t.wrappedPersonaQuietBlurb);
      default: // everyday_spender
        return ('\u{1F4B3}', t.wrappedPersonaEveryday,
            t.wrappedPersonaEverydayBlurb);
    }
  }

  /// Human month label from 'YYYY-MM' using the active locale.
  String _monthLabel(String? ym) {
    if (ym == null || ym.length < 7) return '';
    final d = DateTime.tryParse('$ym-01');
    if (d == null) return ym;
    return DateFormat.yMMMM(Localizations.localeOf(context).toString())
        .format(d);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.wrappedTitle)),
      body: _loading
          ? const SkeletonList(count: 4)
          : _failed
              ? _errorState(t)
              : (_data?['enough_data'] == true)
                  ? _deck(t)
                  : _emptyState(t),
    );
  }

  Widget _errorState(AppLocalizations t) => StateMessage(
        icon: Icons.cloud_off_outlined,
        title: t.wrappedErrorTitle,
        message: honestFailText(t, _failCause, otherwise: t.wrappedErrorHint),
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text(t.retry),
        ),
      );

  Widget _emptyState(AppLocalizations t) {
    final need = (_data?['min_txns'] as num?)?.toInt() ?? 5;
    final have = (_data?['txn_count'] as num?)?.toInt() ?? 0;
    return StateMessage(
      icon: Icons.auto_awesome_outlined,
      title: t.wrappedEmptyTitle,
      // qa1: locale digits (the count had Latin digits in the Bangla UI)
      message: t.wrappedEmptyHint(fmtInt(context, need), fmtInt(context, have)),
    );
  }

  Widget _deck(AppLocalizations t) {
    final cards = _buildCards(t);
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: cards.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => RepaintBoundary(
              key: _keyFor(i),
              child: cards[i],
            ),
          ),
        ),
        // Page dots.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.md),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < cards.length; i++)
                AnimatedContainer(
                  duration: Motion.fast,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _page
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
            ],
          ),
        ),
        // Share the currently-visible card as a festival-style image.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _share(t),
              icon: const Icon(Icons.ios_share),
              label: Text(t.wrappedShare),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _share(AppLocalizations t) async {
    final key = _keyFor(_page);
    final caption = t.wrappedShareCaption(_monthLabel(_data?['month']));
    final messenger = ScaffoldMessenger.of(context);
    final ok = await WrappedShare.shareAsImage(key, caption);
    if (!ok) {
      await WrappedShare.shareAsText(caption);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(t.wrappedShareTextOnly)));
      }
    }
  }

  // -- card deck, built ONLY from stats the backend actually returned ---------
  List<Widget> _buildCards(AppLocalizations t) {
    final d = _data!;
    final monthLbl = _monthLabel(d['month'] as String?);
    final cards = <Widget>[];
    var idx = 0;

    // 1) Intro.
    cards.add(WrappedCardFrame(
      index: idx++,
      eyebrow: t.wrappedTitle,
      footer: monthLbl,
      child: WrappedBigStat(
        value: monthLbl,
        caption: t.wrappedIntroCaption,
        icon: Icons.auto_awesome,
      ),
    ));

    // 2) Total spent.
    cards.add(WrappedCardFrame(
      index: idx++,
      eyebrow: t.wrappedSpentEyebrow,
      footer: monthLbl,
      child: WrappedBigStat(
        value: tkFmt(d['total_spent']),
        caption: t.wrappedSpentCaption,
        icon: Icons.north_east,
      ),
    ));

    // 3) Earned + saved (only if any income was recorded).
    final earned = dbl(d['total_earned']);
    if (earned > 0) {
      cards.add(WrappedCardFrame(
        index: idx++,
        eyebrow: t.wrappedEarnedEyebrow,
        footer: monthLbl,
        child: WrappedLineStat(
          icon: Icons.south_west,
          title: t.wrappedEarnedTitle,
          value: tkFmt(d['total_earned']),
          note: t.wrappedSavedNote(tkFmt(d['total_saved'])),
        ),
      ));

      // 4) Savings-rate ring.
      cards.add(WrappedCardFrame(
        index: idx++,
        eyebrow: t.wrappedSavingsEyebrow,
        footer: monthLbl,
        child: WrappedSavingsRing(
          ratePct: (d['savings_rate'] as num?)?.toInt() ?? 0,
          title: t.wrappedSavingsTitle,
          caption: t.wrappedSavingsCaption,
        ),
      ));
    }

    // 5) Top category (only if we actually have one).
    final topCat = d['top_category'];
    if (topCat != null && (d['top_category_amount'] != null)) {
      cards.add(WrappedCardFrame(
        index: idx++,
        eyebrow: t.wrappedTopCategoryEyebrow,
        footer: monthLbl,
        child: WrappedLineStat(
          icon: Icons.local_fire_department_outlined,
          title: topCat.toString(),
          value: tkFmt(d['top_category_amount']),
          note: t.wrappedTopCategoryNote,
        ),
      ));
    }

    // 6) Biggest single expense (only if one exists).
    final biggest = d['biggest_expense'] as Map?;
    if (biggest != null) {
      cards.add(WrappedCardFrame(
        index: idx++,
        eyebrow: t.wrappedBiggestEyebrow,
        footer: monthLbl,
        child: WrappedLineStat(
          icon: Icons.bolt_outlined,
          title: (biggest['category']?.toString().isNotEmpty == true)
              ? biggest['category'].toString()
              : t.wrappedBiggestTitle,
          value: tkFmt(biggest['amount']),
          note: t.wrappedBiggestNote(_dateLabel(biggest['date'])),
        ),
      ));
    }

    // 7) Spend trend vs last month — ONLY when a real prior month exists.
    final trend = d['spend_trend'] as Map?;
    if (trend != null && trend['has_previous'] == true) {
      final up = trend['up'] == true;
      cards.add(WrappedCardFrame(
        index: idx++,
        eyebrow: t.wrappedTrendEyebrow,
        footer: monthLbl,
        child: WrappedTrend(
          up: up,
          pct: (trend['pct'] as num?)?.toInt() ?? 0,
          deltaValue: tkSigned(dbl(trend['delta'])),
          title: t.wrappedTrendTitle,
          caption:
              up ? t.wrappedTrendUp : t.wrappedTrendDown,
        ),
      ));
    }

    // 8) No-spend days.
    final noSpend = (d['no_spend_days'] as num?)?.toInt() ?? 0;
    cards.add(WrappedCardFrame(
      index: idx++,
      eyebrow: t.wrappedNoSpendEyebrow,
      footer: monthLbl,
      child: WrappedLineStat(
        icon: Icons.self_improvement_outlined,
        title: t.wrappedNoSpendTitle,
        value: '$noSpend',
        note: t.wrappedNoSpendNote(
            (d['days_in_scope'] as num?)?.toInt() ?? 0),
      ),
    ));

    // 9) Fun facts chip card (category count, txn count, busiest day).
    final facts = <String>[
      t.wrappedFactCategories((d['category_count'] as num?)?.toInt() ?? 0),
      t.wrappedFactTxns((d['txn_count'] as num?)?.toInt() ?? 0),
    ];
    final busiest = d['busiest_day'] as Map?;
    if (busiest != null) {
      facts.add(t.wrappedFactBusiest(
          _dateLabel(busiest['date']), tkFmt(busiest['amount'])));
    }
    cards.add(WrappedCardFrame(
      index: idx++,
      eyebrow: t.wrappedFactsEyebrow,
      footer: monthLbl,
      child: WrappedFactChips(facts: facts),
    ));

    // 10) Persona finale.
    final (emoji, pTitle, pBlurb) =
        _persona(t, (d['personality'] ?? 'everyday_spender').toString());
    cards.add(WrappedCardFrame(
      index: idx++,
      eyebrow: t.wrappedPersonaEyebrow,
      footer: monthLbl,
      child: WrappedPersona(
        emoji: emoji,
        title: pTitle,
        blurb: pBlurb,
        eyebrow: t.wrappedPersonaLead,
      ),
    ));

    return cards;
  }

  String _dateLabel(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    if (d == null) return '';
    return DateFormat('d MMM', appDateLocale(context)).format(d);
  }
}
