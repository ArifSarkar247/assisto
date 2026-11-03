import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart' show openForUser;
import '../../state.dart';
import '../../theme.dart';
import '../../voice/reply_speaker.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/farmer_crop_data.dart';
import '../../world/world_api.dart';
import '../disaster_alerts_screen.dart';
import '../farmer_mode_screen.dart' show farmerCropLabel;
import '../world/world_guide_hub_screen.dart';

/// p3farm — Farmer mode HELP tab, per-crop calendar and the disease check.
///
/// Low-literacy design: one big full-width button per job (icon + 2 short
/// lines), a "Listen" speaker on every button (phone TTS via the existing
/// lazy [ReplySpeaker] — no new native code), and the Krishi Call Centre
/// 16123 one tap away everywhere. Every button does real work:
///   * disease check  -> [FarmDiseaseScreen] (AI photo through the existing
///     Farmers hub ONLY when a vision key is connected, else the offline
///     symptom picker with official links + 16123);
///   * disaster alerts -> the existing [DisasterAlertsScreen] (BMD/FFWC/DDM);
///   * farm weather   -> BAMIS (official agro-met portal) in the browser;
///   * market price   -> an HONEST sheet: DAM has no open feed, so no price is
///     shown — the official DAM site opens instead;
///   * 16123          -> the dialer;
///   * khata / calendar -> the existing Ledger / Calendar tabs.

const _title = AType.headlineSmall;
const _body = AType.titleLarge;

String farmSourceLabel(AppLocalizations t, String code) => switch (code) {
      'brri' => t.farmSrcBrri,
      'bjri' => t.farmSrcBjri,
      'bari' => t.farmSrcBari,
      'bwmri' => t.farmSrcBwmri,
      _ => code,
    };

String farmCropPlanLabel(AppLocalizations t, String crop) => switch (crop) {
      'winter_veg' => t.farmCropWinterVeg,
      'summer_veg' => t.farmCropSummerVeg,
      _ => farmerCropLabel(t, crop),
    };

String farmJobLabel(AppLocalizations t, String job) => switch (job) {
      'sow' => t.farmJobSow,
      'transplant' => t.farmJobTransplant,
      _ => t.farmJobHarvest,
    };

Future<void> callKrishiCentre(BuildContext context) => openForUser(
    context, Uri.parse('tel:$kKrishiCallCentre'),
    where: 'farm.call16123');

Future<void> openFarmSource(BuildContext context, String code) {
  final url = kFarmSourceUrls[code];
  if (url == null) return Future.value();
  return openForUser(context, Uri.parse(url),
      where: 'farm.source', mode: LaunchMode.externalApplication);
}

// =========================================================================== //
// HELP TAB
// =========================================================================== //

class FarmerHelpTab extends StatefulWidget {
  const FarmerHelpTab(
      {super.key, required this.onOpenTab, this.worldApi, this.speaker});

  /// Switches Farmer mode to another tab (1 = ledger, 2 = calendar).
  final void Function(int) onOpenTab;
  final WorldApi? worldApi;
  final ReplySpeaker? speaker;

  @override
  State<FarmerHelpTab> createState() => _FarmerHelpTabState();
}

class _FarmerHelpTabState extends State<FarmerHelpTab> {
  late final ReplySpeaker _speaker = widget.speaker ?? ReplySpeaker();

  @override
  void initState() {
    super.initState();
    _speaker.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _speaker.removeListener(_changed);
    if (widget.speaker == null) {
      _speaker.stop();
      _speaker.dispose();
    }
    super.dispose();
  }

  void _push(Widget w) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tiles = <_TileSpec>[
      _TileSpec('disease', Icons.eco_rounded, t.farmTileDisease, t.farmTileDiseaseHint,
          () => _push(FarmDiseaseScreen(worldApi: widget.worldApi, speaker: _speaker))),
      _TileSpec('disaster', Icons.storm_rounded, t.farmTileDisaster, t.farmTileDisasterHint,
          () => _push(const DisasterAlertsScreen())),
      _TileSpec('weather', Icons.wb_cloudy_rounded, t.farmTileWeather, t.farmTileWeatherHint,
          () => openFarmSource(context, 'bamis')),
      _TileSpec('market', Icons.storefront_rounded, t.farmTileMarket, t.farmTileMarketHint,
          () => showFarmMarketSheet(context, onKhata: () => widget.onOpenTab(1))),
      _TileSpec('call', Icons.call_rounded, t.farmTileCall, t.farmTileCallHint,
          () => callKrishiCentre(context)),
      _TileSpec('khata', Icons.menu_book_rounded, t.farmTileKhata, t.farmTileKhataHint,
          () => widget.onOpenTab(1)),
      _TileSpec('calendar', Icons.calendar_month_rounded, t.farmTileCalendar,
          t.farmTileCalendarHint, () => widget.onOpenTab(2)),
    ];
    return ListView(
      padding: withNavBarInset(
          context, const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xl)),
      children: [
        Text(t.farmHelpIntro, style: AType.bodyLarge.copyWith(height: 1.35)),
        const SizedBox(height: Gap.md),
        for (final s in tiles) ...[
          _FarmBigTile(spec: s, speaker: _speaker),
          const SizedBox(height: Gap.md),
        ],
      ],
    );
  }
}

class _TileSpec {
  final String id;
  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;
  const _TileSpec(this.id, this.icon, this.title, this.hint, this.onTap);
}

/// One big full-width button + its own "Listen" speaker (48dp+).
class _FarmBigTile extends StatelessWidget {
  const _FarmBigTile({required this.spec, required this.speaker});
  final _TileSpec spec;
  final ReplySpeaker speaker;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final k = AssistoTokens.of(context);
    final key = 'farm_tile_${spec.id}';
    final speaking = speaker.isSpeaking(key);
    return Card(
      key: ValueKey(key),
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: spec.onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 84),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.xs, Gap.md),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: k.successContainer,
                  child: Icon(spec.icon, size: 32, color: k.onSuccessContainer),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(spec.title,
                          style: _body.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(spec.hint,
                          style: AType.bodyLarge
                              .copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  iconSize: 30,
                  constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
                  tooltip: speaking ? t.aivStopReading : t.aivListen,
                  icon: Icon(speaking
                      ? Icons.stop_circle_rounded
                      : Icons.volume_up_rounded),
                  onPressed: () async {
                    if (speaking) {
                      await speaker.stop();
                      return;
                    }
                    final r = await speaker.speak(
                        key, '${spec.title}. ${spec.hint}',
                        lang: t.localeName.startsWith('bn') ? 'bn' : 'en');
                    if (context.mounted) ReplySpeaker.explain(context, r);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =========================================================================== //
// MARKET PRICE — honest sheet (DAM has no open feed)
// =========================================================================== //

Future<void> showFarmMarketSheet(BuildContext context,
    {required VoidCallback onKhata}) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.farmMarketTitle,
                style: _title.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.md),
            Text(t.farmMarketBody, style: AType.bodyLarge.copyWith(height: 1.4)),
            const SizedBox(height: Gap.lg),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: FilledButton.icon(
                key: const ValueKey('farm_market_dam'),
                onPressed: () => openFarmSource(ctx, 'dam'),
                icon: const Icon(Icons.open_in_new_rounded, size: 24),
                label: Text(t.farmMarketOpen, style: _body),
              ),
            ),
            const SizedBox(height: Gap.md),
            Text(t.farmMarketKhataHint, style: AType.bodyLarge),
            const SizedBox(height: Gap.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  onKhata();
                },
                icon: const Icon(Icons.menu_book_rounded, size: 24),
                label: Text(t.farmTileKhata, style: _body),
              ),
            ),
          ],
        ),
      );
    },
  );
}

// =========================================================================== //
// PER-CROP CALENDAR (shown at the top of the Calendar tab)
// =========================================================================== //

class FarmCropCalendarSection extends StatelessWidget {
  const FarmCropCalendarSection(
      {super.key, required this.month, required this.monthName});
  final int month;
  final String Function(int) monthName;

  String _months(List<int> ms) =>
      ms.isEmpty ? '' : (ms.length == 1 ? monthName(ms.first)
          : '${monthName(ms.first)} – ${monthName(ms.last)}');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final k = AssistoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final active = cropsActiveIn(month);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // THIS MONTH strip
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: k.successContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${t.farmThisMonth} — ${monthName(month)}',
                  style: _body.copyWith(
                      fontWeight: FontWeight.w700, color: k.onSuccessContainer)),
              const SizedBox(height: Gap.sm),
              for (final c in active)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                      '• ${farmCropPlanLabel(t, c.crop)}: ${c.jobsIn(month).map((j) => farmJobLabel(t, j)).join(', ')}',
                      style: AType.bodyLarge.copyWith(color: k.onSuccessContainer)),
                ),
            ],
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.farmCropCalTitle, style: _title.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: Gap.sm),
        Text(t.farmCropCalNote, style: AType.bodyLarge.copyWith(height: 1.35)),
        const SizedBox(height: Gap.md),
        for (final c in kCropCalendar) ...[
          Card(
            key: ValueKey('farm_crop_${c.crop}'),
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: c.jobsIn(month).isNotEmpty
                  ? BorderSide(color: k.success, width: 2)
                  : BorderSide.none,
            ),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(farmCropPlanLabel(t, c.crop),
                      style: _body.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  _row(context, Icons.grass_rounded, t.farmJobSow, _months(c.sow)),
                  if (c.transplant.isNotEmpty)
                    _row(context, Icons.spa_rounded, t.farmJobTransplant,
                        _months(c.transplant)),
                  _row(context, Icons.agriculture_rounded, t.farmJobHarvest,
                      _months(c.harvest)),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => openFarmSource(context, c.source),
                      icon: const Icon(Icons.verified_rounded, size: 20),
                      label: Text('${t.farmSourceWord}: ${farmSourceLabel(t, c.source)}',
                          style: AType.bodyMedium),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.md),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) =>
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text('$label: $value', style: AType.bodyLarge)),
          ],
        ),
      );
}

// =========================================================================== //
// DISEASE CHECK — AI photo when connected, else guided symptom picker
// =========================================================================== //

class FarmDiseaseScreen extends StatefulWidget {
  const FarmDiseaseScreen(
      {super.key, this.worldApi, this.speaker, this.initialGroup, this.initialProblem});
  final WorldApi? worldApi;
  final ReplySpeaker? speaker;

  /// Tests / gallery: open with a crop group / problem already picked.
  final String? initialGroup;
  final String? initialProblem;

  @override
  State<FarmDiseaseScreen> createState() => _FarmDiseaseScreenState();
}

class _FarmDiseaseScreenState extends State<FarmDiseaseScreen> {
  late final WorldApi _api =
      widget.worldApi ?? ApiWorldApi(context.read<AppState>().api);
  late final ReplySpeaker _speaker = widget.speaker ?? ReplySpeaker();
  bool? _photoReady; // null = still checking (offline -> false)
  String? _group;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _group = widget.initialGroup;
    _problem = widget.initialProblem;
    _speaker.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _speaker.removeListener(_changed);
    if (widget.speaker == null) {
      _speaker.stop();
      _speaker.dispose();
    }
    super.dispose();
  }

  Future<void> _check() async {
    bool ready = false;
    try {
      final d = await _api.hub('farmers');
      ready = d['photo_ready'] == true;
    } catch (_) {
      ready = false; // offline / server down: the picker still works
    }
    if (mounted) setState(() => _photoReady = ready);
  }

  String _groupLabel(AppLocalizations t, String g) => switch (g) {
        'rice' => t.farmDzGroupRice,
        'potato' => farmerCropLabel(t, 'potato'),
        'jute' => farmerCropLabel(t, 'jute'),
        _ => t.farmDzGroupVeg,
      };

  IconData _groupIcon(String g) => switch (g) {
        'rice' => Icons.grass_rounded,
        'potato' => Icons.circle_rounded,
        'jute' => Icons.forest_rounded,
        _ => Icons.local_florist_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final k = AssistoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final problems = _group == null ? const <FarmProblem>[] : kFarmProblems[_group]!;
    final picked = _problem == null
        ? null
        : problems.where((p) => p.id == _problem).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(t.farmDzTitle,
              maxLines: 1, style: _title.copyWith(fontWeight: FontWeight.bold)),
        ),
      ),
      body: ListView(
        padding: withNavBarInset(
            context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
        children: [
          // ---- AI photo (only when a vision key is connected) -------------
          if (_photoReady == true)
            Card(
              key: const ValueKey('farm_dz_photo'),
              margin: EdgeInsets.zero,
              color: k.infoContainer,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(t.farmDzPhotoTitle,
                        style: _body.copyWith(
                            fontWeight: FontWeight.w700, color: k.onInfoContainer)),
                    const SizedBox(height: 4),
                    Text(t.farmDzPhotoHint,
                        style: AType.bodyLarge.copyWith(color: k.onInfoContainer)),
                    const SizedBox(height: Gap.sm),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 56),
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) =>
                                WorldGuideHubScreen(hubId: 'farmers', api: _api))),
                        icon: const Icon(Icons.photo_camera_rounded, size: 26),
                        label: Text(t.farmDzPhotoOpen, style: _body),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (_photoReady == false)
            Text(t.farmDzPhotoOff,
                key: const ValueKey('farm_dz_photo_off'),
                style: AType.bodyLarge.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          // ---- 1. crop ----------------------------------------------------
          Text(t.farmDzPickCrop, style: _title.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final g in kFarmProblemGroups)
                ChoiceChip(
                  key: ValueKey('farm_dz_group_$g'),
                  avatar: Icon(_groupIcon(g), size: 22),
                  label: Text(_groupLabel(t, g), style: _body),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.sm),
                  selected: _group == g,
                  onSelected: (_) => setState(() {
                    _group = g;
                    _problem = null;
                  }),
                ),
            ],
          ),
          if (_group != null) ...[
            const SizedBox(height: Gap.lg),
            Text(t.farmDzPickSign, style: _title.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.sm),
            for (final p in problems) ...[
              Card(
                key: ValueKey('farm_dz_sign_${p.id}'),
                margin: EdgeInsets.zero,
                color: _problem == p.id ? k.successContainer : scheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: _problem == p.id
                      ? BorderSide(color: k.success, width: 2)
                      : BorderSide.none,
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => setState(() => _problem = p.id),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.md),
                      child: Row(
                        children: [
                          Icon(
                              _problem == p.id
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 26),
                          const SizedBox(width: Gap.sm),
                          Expanded(
                              child: Text(farmProblemSign(t, p.id),
                                  style: AType.bodyLarge)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Gap.sm),
            ],
          ],
          if (picked != null) ...[
            const SizedBox(height: Gap.md),
            _ProblemCard(problem: picked, speaker: _speaker),
          ],
          const SizedBox(height: Gap.lg),
          const _ConsultCard(),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => openFarmSource(context, 'janala'),
              icon: const Icon(Icons.photo_library_rounded, size: 22),
              label: Text(t.farmDzJanala, style: AType.bodyLarge),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  const _ProblemCard({required this.problem, required this.speaker});
  final FarmProblem problem;
  final ReplySpeaker speaker;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = farmProblemName(t, problem.id);
    final sign = farmProblemSign(t, problem.id);
    final care = farmProblemCare(t, problem.id);
    final key = 'farm_pb_${problem.id}';
    final speaking = speaker.isSpeaking(key);
    return Card(
      key: ValueKey('farm_dz_result_${problem.id}'),
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${t.farmDzMayBe}: $name',
                      style: _title.copyWith(fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  iconSize: 30,
                  constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
                  tooltip: speaking ? t.aivStopReading : t.aivListen,
                  icon: Icon(speaking ? Icons.stop_circle_rounded : Icons.volume_up_rounded),
                  onPressed: () async {
                    if (speaking) {
                      await speaker.stop();
                      return;
                    }
                    final r = await speaker.speak(
                        key, '$name. $sign. ${t.farmDzCare}: $care. ${t.farmConsult}',
                        lang: t.localeName.startsWith('bn') ? 'bn' : 'en');
                    if (context.mounted) ReplySpeaker.explain(context, r);
                  },
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(sign, style: AType.bodyLarge),
            const SizedBox(height: Gap.md),
            Text(t.farmDzCare, style: _body.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(care, style: AType.bodyLarge.copyWith(height: 1.35)),
            const SizedBox(height: Gap.md),
            Text(t.farmDzNotDiagnosis,
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => openFarmSource(context, problem.source),
                icon: const Icon(Icons.verified_rounded, size: 20),
                label: Text('${t.farmDzOfficial}: ${farmSourceLabel(t, problem.source)}',
                    style: AType.bodyMedium),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Always-visible "consult your officer / call 16123" card.
class _ConsultCard extends StatelessWidget {
  const _ConsultCard();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final k = AssistoTokens.of(context);
    return Container(
      key: const ValueKey('farm_consult'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: k.successContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.farmConsult,
              style: AType.bodyLarge.copyWith(color: k.onSuccessContainer, height: 1.35)),
          const SizedBox(height: Gap.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              key: const ValueKey('farm_call_16123'),
              style: FilledButton.styleFrom(
                  backgroundColor: k.success, foregroundColor: k.onSuccess),
              onPressed: () => callKrishiCentre(context),
              icon: const Icon(Icons.call_rounded, size: 26),
              label: Text(t.farmTileCall, style: _body),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- problem labels (ARB getters; zero literals) -------------------------- //

String farmProblemName(AppLocalizations t, String id) => switch (id) {
      'rice_blast' => t.farmPbRiceBlastName,
      'rice_blight' => t.farmPbRiceBlightName,
      'rice_bph' => t.farmPbRiceBphName,
      'rice_borer' => t.farmPbRiceBorerName,
      'potato_late_blight' => t.farmPbPotatoLateBlightName,
      'potato_wilt' => t.farmPbPotatoWiltName,
      'jute_stem_rot' => t.farmPbJuteStemRotName,
      'brinjal_borer' => t.farmPbBrinjalBorerName,
      'gourd_fruit_fly' => t.farmPbGourdFruitFlyName,
      _ => id,
    };

String farmProblemSign(AppLocalizations t, String id) => switch (id) {
      'rice_blast' => t.farmPbRiceBlastSign,
      'rice_blight' => t.farmPbRiceBlightSign,
      'rice_bph' => t.farmPbRiceBphSign,
      'rice_borer' => t.farmPbRiceBorerSign,
      'potato_late_blight' => t.farmPbPotatoLateBlightSign,
      'potato_wilt' => t.farmPbPotatoWiltSign,
      'jute_stem_rot' => t.farmPbJuteStemRotSign,
      'brinjal_borer' => t.farmPbBrinjalBorerSign,
      'gourd_fruit_fly' => t.farmPbGourdFruitFlySign,
      _ => id,
    };

String farmProblemCare(AppLocalizations t, String id) => switch (id) {
      'rice_blast' => t.farmPbRiceBlastCare,
      'rice_blight' => t.farmPbRiceBlightCare,
      'rice_bph' => t.farmPbRiceBphCare,
      'rice_borer' => t.farmPbRiceBorerCare,
      'potato_late_blight' => t.farmPbPotatoLateBlightCare,
      'potato_wilt' => t.farmPbPotatoWiltCare,
      'jute_stem_rot' => t.farmPbJuteStemRotCare,
      'brinjal_borer' => t.farmPbBrinjalBorerCare,
      'gourd_fruit_fly' => t.farmPbGourdFruitFlyCare,
      _ => id,
    };
