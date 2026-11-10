/// lpapp — Writing / Speaking AI scoring (POST /lp/score/writing|speaking):
/// per-criterion bands with notes, corrected version, every mistake with a
/// Bangla explanation (yellow cards), practice label. Credits are charged by
/// the server ONLY when ai_state == "used"; every other state is explained.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../plans_screen.dart' show PlansScreen;
import '../../widgets/rewarded_ad_sheet.dart';
import 'lp_engine.dart';
import 'lp_life.dart' show lpVoice;
import 'lp_ui.dart';

String lpCriterionName(AppLocalizations tr, String k) => switch (k) {
      'TA' => tr.lp2CritTA,
      'TR' => tr.lp2CritTR,
      'CC' => tr.lp2CritCC,
      'LR' => tr.lp2CritLR,
      'GRA' => tr.lp2CritGRA,
      'FC' => tr.lp2CritFC,
      'P' => tr.lp2CritP,
      _ => k,
    };

/// Why a score did not happen (null when it did).
String? lpAiStateText(AppLocalizations tr, String st) => switch (st) {
      'used' => null,
      'credits' => tr.lp2AiNoCredits,
      'premium' => tr.lp2AiPremium,
      'no_key' => tr.lp2AiNotConnected,
      'cut' => tr.lp2AiCut,
      'unreadable' => tr.lp2AiUnreadable,
      _ => tr.lp2AiBusy,
    };

/// Band from a score response, or null when it was not scored.
double? lpScoreBand(Map<String, dynamic>? r) =>
    r != null && r['ai_state'] == 'used' && r['band'] is num ? (r['band'] as num).toDouble() : null;

/// Rounds a mean to the IELTS half band (.25 → .5, .75 → next whole).
double lpHalf(double v) {
  final w = v.floorToDouble(), f = v - w;
  return f < 0.25 ? w : (f < 0.75 ? w + 0.5 : w + 1);
}

/// Shows one AI score: band, criteria, corrected version, mistakes.
class LpScoreView extends StatelessWidget {
  final Map<String, dynamic> r;
  final String title;
  const LpScoreView({super.key, required this.r, required this.title});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final st = '${r['ai_state']}';
    final why = lpAiStateText(tr, st);
    if (why != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            Text(why, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            if (st == 'credits' || st == 'premium')
              Wrap(spacing: Gap.sm, children: [
                if (st == 'credits')
                  TextButton.icon(
                    key: const Key('lp2-rewarded-score'),
                    style: TextButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
                    onPressed: () => RewardedAdSheet.show(context),
                    icon: const Icon(Icons.ondemand_video_rounded),
                    label: Text(tr.lp2WatchAdCredits),
                  ),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlansScreen())),
                  child: Text(tr.lp2SeePlans),
                ),
              ]),
          ]),
        ),
      );
    }
    final band = (r['band'] as num?)?.toDouble() ?? 0;
    final crit = (r['criteria'] as Map?) ?? const {};
    final notes = (r['criteria_notes'] as Map?) ?? const {};
    final bn = lpBn(context);
    final mistakes = (r['mistakes'] as List?)?.whereType<Map>().toList() ?? const [];
    final corrected = '${r['corrected'] ?? ''}';
    final label = (r['practice_label'] as Map?);
    return Card(
      key: const Key('lp2-score'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(tr.lp2BandIs(ld(context, bandText(band))),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ]),
          for (final e in crit.entries)
            LpBandBar(
              label: lpCriterionName(tr, '${e.key}'),
              band: (e.value as num?)?.toDouble(),
              note: () {
                final n = notes[e.key];
                if (n is! Map) return null;
                return '${(bn ? n['bn'] : n['en']) ?? n['en'] ?? ''}';
              }(),
            ),
          if (mistakes.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(tr.lp2Mistakes(ld(context, mistakes.length)), style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            for (final m in mistakes.take(12))
              LpFixCard(
                wrong: '${m['wrong'] ?? ''}',
                right: '${m['right'] ?? ''}',
                why: '${(bn ? m['bn'] : m['en']) ?? m['en'] ?? ''}',
              ),
          ],
          if (corrected.trim().isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(tr.lp2Corrected, style: const TextStyle(fontWeight: FontWeight.w700)),
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: SelectableText(corrected, style: const TextStyle(height: 1.5))),
                  LpListenButton(text: corrected),
                ]),
              ],
            ),
          if ((r['credits_used'] as num?) != null && (r['credits_used'] as num) > 0)
            Text(tr.lp2CreditsUsed(ld(context, r['credits_used'])),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          LpPracticeFooter(text: label == null ? null : '${(bn ? label['bn'] : label['en']) ?? ''}'),
        ]),
      ),
    );
  }
}

/// Book companion: score a Writing or Speaking answer to a book prompt the
/// user types (the prompt is sent for this one score and not kept by the app).
class LpAiScoreScreen extends StatefulWidget {
  final String kind; // writing | speaking
  const LpAiScoreScreen({super.key, required this.kind});
  @override
  State<LpAiScoreScreen> createState() => _LpAiScoreScreenState();
}

class _LpAiScoreScreenState extends State<LpAiScoreScreen> {
  final _prompt = TextEditingController();
  final _answer = TextEditingController();
  final _heard = TextEditingController();
  late final _voice = lpVoice();
  int _task = 2;
  String _variant = 'academic';
  bool _best = false, _busy = false;
  Duration _spoken = Duration.zero;
  Map<String, dynamic>? _r;

  bool get _w => widget.kind == 'writing';

  @override
  void dispose() {
    _voice.stop();
    _voice.dispose();
    _prompt.dispose();
    _answer.dispose();
    _heard.dispose();
    super.dispose();
  }

  Future<void> _score() async {
    final tr = AppLocalizations.of(context);
    final text = _answer.text.trim();
    if (_prompt.text.trim().isEmpty || text.isEmpty) {
      lpToast(context, tr.lp2NeedPromptAnswer);
      return;
    }
    if (_w && wordCount(text) < 40) {
      lpToast(context, tr.lp2TooShort);
      return;
    }
    setState(() {
      _busy = true;
      _r = null;
    });
    try {
      final api = context.read<AppState>().api;
      final r = _w
          ? await api.postJson('/lp/score/writing', {
              'task': _task,
              'variant': _variant,
              'prompt': _prompt.text.trim(),
              'text': text,
              'level': _best ? 'best' : 'normal',
            })
          : await api.postJson('/lp/score/speaking', {
              'part': _task,
              'prompt': _prompt.text.trim(),
              'transcript': text,
              'seconds': _spoken.inSeconds,
              'level': _best ? 'best' : 'normal',
            });
      if (mounted) setState(() => _r = r);
    } catch (e) {
      if (mounted) lpToast(context, honestFailText(tr, e, otherwise: tr.lp2AiFail));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final words = wordCount(_answer.text);
    final parts = _w ? const [1, 2] : const [1, 2, 3];
    if (!parts.contains(_task)) _task = parts.last;
    return Scaffold(
      appBar: AppBar(title: Text(_w ? tr.lp2ScoreWriting : tr.lp2ScoreSpeaking)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final p in parts)
              ChoiceChip(
                label: Text(_w ? tr.lp2TaskN(ld(context, p)) : tr.lp2PartN(ld(context, p))),
                selected: _task == p,
                onSelected: (_) => setState(() => _task = p),
              ),
            if (_w)
              for (final v in ['academic', 'general'])
                ChoiceChip(
                  label: Text(v == 'academic' ? tr.lp2Academic : tr.lp2General),
                  selected: _variant == v,
                  onSelected: (_) => setState(() => _variant = v),
                ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _prompt,
            maxLength: 1500,
            buildCounter: localCounter,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
                labelText: tr.lp2PromptLabel, helperText: tr.lp2PromptHelp, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          if (!_w) ...[
            LpHoldToSpeak(
              voice: _voice,
              heard: _heard,
              onHeld: (d) => _spoken += d,
              onDone: (t) => setState(() => _answer.text = '${_answer.text} $t'.trim()),
            ),
            const SizedBox(height: Gap.sm),
          ],
          TextField(
            controller: _answer,
            maxLength: 6000,
            buildCounter: localCounter,
            minLines: _w ? 8 : 3,
            maxLines: 20,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: _w ? tr.lp2YourAnswer : tr.lp2WhatPhoneHeard, border: const OutlineInputBorder()),
          ),
          Text(tr.lp2WordCount(ld(context, words)), style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _best,
            onChanged: (v) => setState(() => _best = v),
            title: Text(tr.lp2BestLevel),
            subtitle: Text(tr.lp2BestLevelSub),
          ),
          FilledButton.icon(
            key: const Key('lp2-score-btn'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _score,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.grading_rounded),
            label: Text(tr.lp2ScoreMyAnswer),
          ),
          const SizedBox(height: Gap.md),
          if (_r != null) LpScoreView(r: _r!, title: _w ? tr.lp2TaskN(ld(context, _task)) : tr.lp2PartN(ld(context, _task))),
          LpPracticeFooter(text: tr.lp2NoContentLine, icon: Icons.lock_outline_rounded),
        ],
      ),
    );
  }
}
