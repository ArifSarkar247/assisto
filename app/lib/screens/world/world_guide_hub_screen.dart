import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../chat_vision/chat_photo.dart';
import '../../chat_vision/cv_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../payments/credits_out_sheet.dart'; // credout
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/voice_input.dart';
import '../../world/world_api.dart';
import '../../world/world_widgets.dart';
import '../exam_result_screen.dart';
import '../farmer_mode_screen.dart';
import '../guide_screen.dart';
import '../medicine_db_screen.dart';
import '../../feature_gates.dart' show kMedicalFeaturesAllowed;
import '../probashi_screen.dart';
import '../student_corner_screen.dart';
import 'world_mcq_screen.dart';
import '../../feature_flags.dart' show FeatureFlags; // feature-flags

/// p4-world GUIDE HUBS — Expats, Students, Farmers, Government services and
/// Health helpers. Content is Assisto's own bilingual guide text with OFFICIAL
/// links, fees with their source and a "last reviewed" date. Optional parts:
///   * a photo helper (Farmers: crop photo -> likely problem + general care,
///     always "ask your Upazila Agriculture Officer / call 16123"; Health:
///     prescription reader that lists medicines as written + "consult a
///     doctor/pharmacist") through the existing image-in-chat path (credits /
///     ads / pool, Profit Guard) — shown only when a vision key is connected;
///   * paid AI help (credits) — shown only when AI is switched on. On the
///     Government hub it explains form fields and drafts text to copy; it
///     never submits anything.
class WorldGuideHubScreen extends StatefulWidget {
  const WorldGuideHubScreen(
      {super.key, required this.hubId, this.api, this.cvBackend});
  final String hubId;
  final WorldApi? api;

  /// Tests / gallery: a fake image backend.
  final CvBackend? cvBackend;

  @override
  State<WorldGuideHubScreen> createState() => _WorldGuideHubScreenState();
}

class _WorldGuideHubScreenState extends State<WorldGuideHubScreen> {
  late final WorldApi api =
      widget.api ?? ApiWorldApi(context.read<AppState>().api);
  Map<String, dynamic>? _d;
  bool _loading = true;
  bool _error = false;
  bool _fromCache = false;
  final _q = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation();
  bool _asking = false;
  Map<String, dynamic>? _aiReply;
  final List<ChatPhotoRequest> _photos = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _q.dispose();
    _voice.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final lang = uwLang(context);
    setState(() {
      _loading = _d == null;
      _error = false;
    });
    Map<String, dynamic>? j;
    var cached = false;
    try {
      j = await api.hub(widget.hubId).timeout(const Duration(seconds: 20));
      if (worldStatus(j) != 200) j = null;
      if (j != null) await WorldCache.save('hub_${widget.hubId}', lang, j);
    } catch (_) {
      j = null;
    }
    if (j == null) {
      j = await WorldCache.read('hub_${widget.hubId}', lang);
      cached = j != null;
    }
    if (!mounted) return;
    setState(() {
      _d = j;
      _fromCache = cached;
      _error = j == null;
      _loading = false;
    });
  }

  String _title(AppLocalizations t) => switch (widget.hubId) {
        'expat' => t.uwHubExpat,
        'students' => t.uwHubStudents,
        'farmers' => t.uwHubFarmers,
        'gov' => t.uwHubGov,
        _ => t.uwHubHealth,
      };

  Future<void> _askAi({bool creditsRetry = false}) async {
    final q = _q.text.trim();
    if (q.length < 3 || _asking) return;
    setState(() {
      _asking = true;
      _aiReply = null;
    });
    Map<String, dynamic> r;
    try {
      r = await api
          .hubAi(widget.hubId, q, uwLang(context))
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      r = {'_status': 0, 'ok': false};
    }
    if (!mounted) return;
    // credout: out of credits -> the buy sheet at once (the question stays in
    // the box); after credits really land, the same question once. No ads
    // here (guide hubs include health).
    if (!creditsRetry && worldStatus(r) == 402 && isOutOfCreditsBody(r)) {
      setState(() => _asking = false);
      final ok = await CreditsOut.offer(context, screen: 'world_hub', draftKept: true);
      if (!mounted) return;
      if (ok && _q.text.trim() == q) return _askAi(creditsRetry: true);
    }
    setState(() {
      _aiReply = r;
      _asking = false;
    });
  }

  void _open(Widget w) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_title(t))),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: t.uwOffline,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry)))
              : RefreshIndicator(onRefresh: _load, child: _body(t, scheme)),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    final d = _d!;
    final sections = worldList(d['sections']);
    final photo = '${d['photo'] ?? ''}';
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
      children: [
        if (_fromCache) ...[
          UwNote(icon: Icons.offline_bolt_rounded, text: t.uwCachedCopy),
          const SizedBox(height: Gap.sm),
        ],
        Text('${d['intro'] ?? ''}',
            style:
                Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4)),
        const SizedBox(height: Gap.sm),
        UwNote(text: '${d['verify'] ?? ''}', icon: Icons.verified_rounded),
        // play-nomed: the prescription reader ('rx') is hidden in Play.
        if (photo.isNotEmpty &&
            d['photo_ready'] == true &&
            (photo != 'rx' || kMedicalFeaturesAllowed))
          _photoBlock(t, scheme, photo),
        if (widget.hubId == 'students') ...[
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            onPressed: () => _open(WorldMcqScreen(api: api)),
            icon: const Icon(Icons.quiz_rounded),
            label: Text(t.uwMcqStart),
          ),
        ],
        for (final s in sections) ...[
          UwHeader('${s['title']}'),
          for (final it in worldList(s['items'])) _ItemCard(item: it),
        ],
        if (d['ai_ready'] == true) _aiBlock(t, scheme, d['form_help'] == true),
        ..._screenLinks(t, d),
        const SizedBox(height: Gap.md),
        Text(
            t.uwReviewedOn(
                uwWhen(context, '${d['reviewed'] ?? ''}', time: false)),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }

  List<Widget> _screenLinks(AppLocalizations t, Map<String, dynamic> d) {
    final ids = (d['screens'] is List)
        ? (d['screens'] as List).map((e) => '$e').toList()
        : <String>[];
    final out = <Widget>[];
    for (final id in ids) {
      final (String label, Widget Function() build)? m = switch (id) {
        'probashi' => (t.uwOpenProbashi, () => const ProbashiScreen()),
        'exam_result' => (t.uwOpenExamResult, () => const ExamResultScreen()),
        'student_corner' => (
            t.uwOpenStudentCorner,
            () => const StudentCornerScreen()
          ),
        'farmer_mode' => (t.uwOpenFarmerMode, () => const FarmerModeScreen()),
        'service_guide' => (t.uwOpenServiceGuide, () => const GuideScreen()),
        // medicine price lookup only when a lawful (DGDA) list is loaded
        'medicine_db' => kMedicalFeaturesAllowed &&
                d['medicine_price_ready'] == true
            ? (t.uwOpenMedicinePrice, () => const MedicineDbScreen())
            : null,
        _ => null,
      };
      // feature-flags: never link to a module whose flag is off.
      if (m == null || !FeatureFlags.instance.isOn(id)) continue;
      out.add(Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: OutlinedButton.icon(
          onPressed: () => _open(m.$2()),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(m.$1),
        ),
      ));
    }
    if (out.isNotEmpty) out.insert(0, UwHeader(t.uwMoreTools));
    return out;
  }

  Widget _photoBlock(AppLocalizations t, ColorScheme scheme, String purpose) {
    final crop = purpose == 'crop';
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Card(
        margin: EdgeInsets.zero,
        color: scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(crop ? Icons.eco_rounded : Icons.receipt_long_rounded,
                  color: scheme.onSecondaryContainer),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(crop ? t.uwCropTitle : t.uwRxTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w700)),
              ),
              ChatPhotoAttachButton(
                onPicked: (Uint8List b) => setState(() => _photos.insert(
                    0,
                    ChatPhotoRequest(
                        b, crop ? t.uwCropQuestion : t.uwRxQuestion))),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(crop ? t.uwCropBody : t.uwRxBody,
                style:
                    TextStyle(color: scheme.onSecondaryContainer, height: 1.4)),
            for (final p in _photos)
              ChatPhotoTurn(
                key: ObjectKey(p),
                request: p,
                backend: widget.cvBackend ??
                    ApiCvBackend(context.read<AppState>().api,
                        purpose: purpose),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _aiBlock(AppLocalizations t, ColorScheme scheme, bool forms) {
    final r = _aiReply;
    final ok = r != null && r['ok'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      UwHeader(forms ? t.uwFormHelpTitle : t.uwAiHelpTitle),
      Text(forms ? t.uwFormHelpBody : t.uwAiHelpBody,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      const SizedBox(height: Gap.sm),
      Row(children: [
        VoiceMicButton(voice: _voice, input: _q),
        Expanded(
          child: TextField(
            controller: _q,
            minLines: 1,
            maxLines: 4,
            maxLength: 800,
            decoration: InputDecoration(
              hintText: forms ? t.uwFormHelpHint : t.uwAiHelpHint,
              counterText: '',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
      ]),
      const SizedBox(height: Gap.sm),
      ValueListenableBuilder<TextEditingValue>(
          valueListenable: _q,
          builder: (_, v, __) => FilledButton.icon(
                onPressed:
                    (_asking || v.text.trim().length < 3) ? null : _askAi,
                icon: _asking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(t.uwAiAsk),
              )),
      const SizedBox(height: Gap.xs),
      Text(t.uwAiCostNote,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant)),
      if (r != null)
        Card(
          margin: const EdgeInsets.only(top: Gap.md),
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: ok
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        SelectableText('${r['answer'] ?? ''}',
                            style: const TextStyle(height: 1.5)),
                        const SizedBox(height: Gap.sm),
                        UwNote(text: '${r['note'] ?? ''}', warn: true),
                        Row(children: [
                          Expanded(
                              child: Text(t.uwAiReview,
                                  style:
                                      Theme.of(context).textTheme.bodySmall)),
                          UwSpeakButton(
                              text: '${r['answer'] ?? ''}', compact: true),
                        ]),
                      ])
                : Text('${r['message'] ?? ''}'.isNotEmpty
                    ? '${r['message']}'
                    : (worldStatus(r) == 0 ? t.uwOffline : t.uwAskFailed)),
          ),
        ),
    ]);
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item});
  final Map<String, dynamic> item;

  List<String> _l(String k) =>
      item[k] is List ? (item[k] as List).map((e) => '$e').toList() : const [];

  String _speech() => [
        '${item['title'] ?? ''}',
        '${item['body'] ?? ''}',
        ..._l('steps'),
        ..._l('tips'),
      ].where((s) => s.trim().isNotEmpty).join('। ');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final steps = _l('steps');
    final docs = _l('docs');
    final tips = _l('tips');
    final links = worldList(item['links']);
    final fee = '${item['fee'] ?? ''}';
    final call = item['kind'] == 'call';
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(call ? Icons.call_rounded : Icons.article_rounded,
            color: scheme.primary),
        title: Text('${item['title']}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ('${item['body'] ?? ''}'.isNotEmpty)
            Text('${item['body']}', style: const TextStyle(height: 1.45)),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.uwSteps, style: Theme.of(context).textTheme.labelLarge),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${uwDigits(context, i + 1)}. ',
                          style: TextStyle(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700)),
                      Expanded(
                          child: Text(steps[i],
                              style: const TextStyle(height: 1.4))),
                    ]),
              ),
          ],
          if (docs.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.uwDocs, style: Theme.of(context).textTheme.labelLarge),
            for (final x in docs)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_box_outline_blank_rounded,
                          size: 18, color: scheme.onSurfaceVariant),
                      const SizedBox(width: Gap.sm),
                      Expanded(child: Text(x)),
                    ]),
              ),
          ],
          if (fee.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.uwFee,
                        style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: Gap.xs),
                    Text(fee, style: const TextStyle(height: 1.4)),
                    if ('${item['fee_source'] ?? ''}'.isNotEmpty)
                      UwSourceLine(
                          source: Uri.tryParse('${item['fee_source']}')
                                  ?.host
                                  .replaceFirst('www.', '') ??
                              '',
                          url: '${item['fee_source']}'),
                    Text(
                        t.uwReviewedOn(uwWhen(
                            context, '${item['reviewed'] ?? ''}', time: false)),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ]),
            ),
          ],
          if (tips.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.uwTips, style: Theme.of(context).textTheme.labelLarge),
            for (final x in tips)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline_rounded,
                          size: 18, color: scheme.tertiary),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                          child: Text(x, style: const TextStyle(height: 1.4))),
                    ]),
              ),
          ],
          if (links.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            for (final l in links)
              UwLinkTile(label: '${l['label']}', url: '${l['url']}'),
          ],
          Align(
              alignment: Alignment.centerRight,
              child: UwSpeakButton(text: _speech(), compact: true)),
        ],
      ),
    );
  }
}
