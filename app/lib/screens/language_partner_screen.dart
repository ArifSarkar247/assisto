import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ads/ad_banner_slot.dart';
import '../l10n/app_localizations.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_digits.dart';
import '../widgets/skeleton.dart';
import 'lp2/lp_companion.dart';
import 'lp2/lp_data.dart';
import 'lp2/lp_engine.dart' show bandText;
import 'lp2/lp_life.dart';
import 'lp2/lp_mock.dart';
import 'lp2/lp_track.dart';
import 'lp2/lp_vocab.dart';

/// LANGUAGE PARTNER V2 — Start (owner-approved screen 1, 9 Nov).
///
/// Today goal + streak · IELTS card · Life English card · Going abroad chips ·
/// Other languages chips. Same drawer entry and class name as before; the old
/// flash-card decks are replaced by the vocabulary trainer (lp2/lp_vocab.dart).
/// Life English and vocabulary are bundled (offline); mocks come from
/// /lp/mocks (owner_actions/LANGUAGE_PARTNER_API.md).
class LanguagePartnerScreen extends StatefulWidget {
  const LanguagePartnerScreen({super.key});
  @override
  State<LanguagePartnerScreen> createState() => _LanguagePartnerScreenState();
}

class _LanguagePartnerScreenState extends State<LanguagePartnerScreen> {
  LpProgress _p = LpProgress.empty;
  bool _loading = true;
  Object? _fail;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(LpContent.refresh(context.read<AppState>().api));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    try {
      _p = await LpProgress.load(context.read<AppState>().api);
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(appBar: AppBar(title: Text(tr.lpTitle)), body: const SkeletonList());
    }
    return Scaffold(
      // owner 10 Nov PART B: Free users only, allowlisted, no space without a fill
      bottomNavigationBar: const AdBannerSlot(screen: 'lp_home'),
      appBar: AppBar(title: Text(tr.lpTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
          children: [
            if (_fail != null)
              Card(
                child: ListTile(
                  leading: Icon(Icons.cloud_off_rounded, color: scheme.error),
                  title: Text(honestFailText(tr, _fail, otherwise: tr.lp2ProgressOffline)),
                  trailing: TextButton(onPressed: _load, child: Text(tr.retry)),
                ),
              ),
            _GoalCard(p: _p, onVocab: () => _open(const LpVocabScreen())),
            const SizedBox(height: Gap.md),
            _BigCard(
              key: const Key('lp2-ielts'),
              icon: Icons.school_rounded,
              colour: Brand.blue,
              title: tr.lp2IeltsTitle,
              body: tr.lp2IeltsBody,
              extra: _p.lastMock == null
                  ? null
                  : tr.lp2LastMock(ld(context, bandText(((_p.lastMock!['overall'] as num?) ?? 0).toDouble()))),
              actions: [
                (tr.lp2MockTests, Icons.timer_rounded, () => _open(const LpIeltsHub())),
                (tr.lp2BookCompanion, Icons.menu_book_rounded, () => _open(const LpCompanionScreen())),
              ],
            ),
            const SizedBox(height: Gap.md),
            _BigCard(
              key: const Key('lp2-life'),
              icon: Icons.record_voice_over_rounded,
              colour: Brand.green,
              title: tr.lp2LifeTitle,
              body: tr.lp2LifeBody,
              extra: () {
                final done = _p.days.where((d) => '${d['kind']}'.startsWith('life:')).map((d) => d['kind']).toSet().length;
                return done == 0 ? null : tr.lp2LifeDone(ld(context, done));
              }(),
              actions: [
                (tr.lp2LifeStart, Icons.play_arrow_rounded, () => _open(const LpLifeListScreen())),
              ],
            ),
            const SizedBox(height: Gap.lg),
            _ChipGroup(
              key: const Key('lp2-abroad'),
              title: tr.lp2AbroadTitle,
              chips: [
                (kLpAbroadChips[0], tr.lp2AbroadJapan),
                (kLpAbroadChips[1], tr.lp2AbroadKorea),
                (kLpAbroadChips[2], tr.lp2AbroadGermany),
                (kLpAbroadChips[3], tr.lp2AbroadGulf),
              ],
            ),
            const SizedBox(height: Gap.md),
            _ChipGroup(
              key: const Key('lp2-other'),
              title: tr.lp2OtherLangTitle,
              chips: [
                (kLpOtherChips[0], tr.lp2LangChineseHsk),
                (kLpOtherChips[1], tr.lp2LangFrenchA1),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  final LpProgress p;
  final VoidCallback onVocab;
  const _GoalCard({required this.p, required this.onVocab});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final done = p.minutesToday;
    final s = p.streak;
    final reached = done >= kLpDailyGoalMin;
    return Card(
      key: const Key('lp2-goal'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.flag_rounded, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(tr.lp2GoalTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            Icon(Icons.local_fire_department_rounded,
                color: s.current > 0 ? Brand.warning : scheme.ds.muted),
            const SizedBox(width: Gap.xs),
            Text(tr.lp2Streak(ld(context, s.current)), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: Gap.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (done / kLpDailyGoalMin).clamp(0.0, 1.0),
              minHeight: 10,
              color: reached ? Brand.success : scheme.primary,
              backgroundColor: scheme.ds.cardHighest,
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(
              reached
                  ? tr.lp2GoalDone
                  : tr.lp2GoalMin(ld(context, done), ld(context, kLpDailyGoalMin)),
              style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
          if (s.best > 0)
            Text(tr.lp2StreakBest(ld(context, s.best)), style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              key: const Key('lp2-vocab'),
              style: FilledButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
              onPressed: onVocab,
              icon: const Icon(Icons.style_rounded),
              label: Text(tr.lp2VocabOpen),
            ),
          ),
        ]),
      ),
    );
  }
}

class _BigCard extends StatelessWidget {
  final IconData icon;
  final Color colour;
  final String title, body;
  final String? extra;
  final List<(String, IconData, VoidCallback)> actions;
  const _BigCard(
      {super.key,
      required this.icon,
      required this.colour,
      required this.title,
      required this.body,
      this.extra,
      required this.actions});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: actions.first.$3,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: colour.withValues(alpha: 0.15),
                child: Icon(icon, color: Brand.onTint(context, colour)),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            Text(body, style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.4)),
            if (extra != null) ...[
              const SizedBox(height: Gap.sm),
              Text(extra!, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: Brand.onTint(context, colour))),
            ],
            const SizedBox(height: Gap.md),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (final (i, a) in actions.indexed)
                i == 0
                    ? FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
                        onPressed: a.$3,
                        icon: Icon(a.$2),
                        label: Text(a.$1))
                    : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
                        onPressed: a.$3,
                        icon: Icon(a.$2),
                        label: Text(a.$1)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Going-abroad / other-language chips (lpfinish): each opens that language's
/// REAL course — syllabus, weekly lessons taught from Bangla and practice tests
/// in the public exam format (lp2/lp_track.dart). One course = one chip.
class _ChipGroup extends StatelessWidget {
  final String title;
  final List<(LpTrackChip, String)> chips;
  const _ChipGroup({super.key, required this.title, required this.chips});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final (chip, label) in chips)
            ActionChip(
              key: ValueKey('lp2-chip-${chip.id}'),
              avatar: Icon(chip.icon, size: 18),
              label: Text(label),
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => LpTrackScreen(title: label, tracks: chip.tracks))),
            ),
        ]),
      ]);
}
