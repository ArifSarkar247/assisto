import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/voice_input.dart';
import '../../world/world_api.dart';
import '../../world/world_widgets.dart';
import '../../payments/credits_out_sheet.dart'; // credout

/// p4-world "Ask anything": a LIVE web search answered by AI with numbered
/// sources [1][2] that open the original page. Costs credits per new answer
/// (shown up front); a recent identical question is answered from cache for
/// free. Voice in (mic) and out (read aloud). Health / legal / money answers
/// always carry a "verify with a professional" note from the server.
class WorldAskScreen extends StatefulWidget {
  const WorldAskScreen({super.key, this.api, this.credits = 0, this.initial});
  final WorldApi? api;
  final int credits;

  /// Gallery/tests: a pre-filled answer turn.
  final Map<String, dynamic>? initial;

  @override
  State<WorldAskScreen> createState() => _WorldAskScreenState();
}

class _Turn {
  _Turn(this.question);
  final String question;
  Map<String, dynamic>? body;
  bool loading = true;
}

class _WorldAskScreenState extends State<WorldAskScreen> {
  late final WorldApi api =
      widget.api ?? ApiWorldApi(context.read<AppState>().api);
  final _input = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation();
  final List<_Turn> _turns = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null) {
      _turns.add(_Turn('${init['question'] ?? ''}')
        ..body = init
        ..loading = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _voice.dispose();
    super.dispose();
  }

  Future<void> _send({bool creditsRetry = false}) async {
    final q = _input.text.trim();
    if (q.length < 3 || _busy) return;
    final turn = _Turn(q);
    setState(() {
      _busy = true;
      _turns.insert(0, turn);
      _input.clear();
    });
    Map<String, dynamic> body;
    try {
      body = await api
          .ask(q, uwLang(context))
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      body = {'_status': 0, 'ok': false};
    }
    if (!mounted) return;
    // credout: out of credits -> the question goes back into the box, the
    // buy-credits sheet opens at once, and after credits land it is asked
    // again once. Cancel keeps the question in the box.
    if (!creditsRetry && worldStatus(body) == 402 && isOutOfCreditsBody(body)) {
      setState(() {
        _turns.remove(turn);
        _busy = false;
        if (_input.text.trim().isEmpty) _input.text = q;
      });
      final ok = await CreditsOut.offer(context, screen: 'world', draftKept: true);
      if (ok && mounted && _input.text.trim() == q) {
        return _send(creditsRetry: true);
      }
      return;
    }
    setState(() {
      turn.body = body;
      turn.loading = false;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.uwAskTitle)),
      body: Column(children: [
        Expanded(
          child: _turns.isEmpty
              ? _welcome(t, scheme)
              : ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg),
                  itemCount: _turns.length,
                  itemBuilder: (_, i) => _TurnCard(turn: _turns[i]),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.md),
            child: Row(children: [
              VoiceMicButton(voice: _voice, input: _input),
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 300,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: t.uwAskHint,
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.xl)),
                  ),
                ),
              ),
              const SizedBox(width: Gap.xs),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _input,
                builder: (_, v, __) => IconButton.filled(
                  tooltip: t.uwAskSend,
                  onPressed: (_busy || v.text.trim().length < 3) ? null : _send,
                  icon: const Icon(Icons.send_rounded),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _welcome(AppLocalizations t, ColorScheme scheme) => ListView(
        padding: const EdgeInsets.all(Gap.xl),
        children: [
          Icon(Icons.travel_explore_rounded, size: 56, color: scheme.primary),
          const SizedBox(height: Gap.md),
          Text(t.uwAskWelcomeTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(t.uwAskWelcomeBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.md),
          if (widget.credits > 0)
            UwNote(
                icon: Icons.toll_rounded,
                text: t.uwAskCost(uwDigits(context, widget.credits))),
          const SizedBox(height: Gap.md),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            alignment: WrapAlignment.center,
            children: [
              for (final s in [t.uwAskEx1, t.uwAskEx2, t.uwAskEx3])
                ActionChip(
                  label: Text(s),
                  onPressed: () => setState(() => _input.text = s),
                ),
            ],
          ),
        ],
      );
}

class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.turn});
  final _Turn turn;

  String _errorText(AppLocalizations t, Map<String, dynamic> b) {
    final m = '${b['message'] ?? ''}';
    if (m.isNotEmpty) return m;
    return worldStatus(b) == 0 ? t.uwOffline : t.uwAskFailed;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final b = turn.body;
    final ok = b != null && b['ok'] == true;
    final sources = worldList(b?['sources']);
    final caution = (b?['caution'] is List)
        ? (b!['caution'] as List).map((e) => '$e').toList()
        : <String>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8),
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.md, vertical: Gap.sm),
            decoration: BoxDecoration(
                color: scheme.primary, borderRadius: BorderRadius.circular(18)),
            child:
                Text(turn.question, style: TextStyle(color: scheme.onPrimary)),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: turn.loading
                ? Row(children: [
                    const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: Gap.md),
                    Expanded(child: Text(t.uwAskSearching)),
                  ])
                : !ok
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Text(_errorText(t, b ?? const {})),
                            if (worldStatus(b ?? const {}) == 402)
                              Padding(
                                padding: const EdgeInsets.only(top: Gap.sm),
                                child: FilledButton.tonal(
                                  onPressed: () => CreditsOut.offer(context,
                                      screen: 'world'),
                                  child: Text(t.uwGetCredits),
                                ),
                              ),
                          ])
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            SelectableText('${b['answer'] ?? ''}',
                                style: const TextStyle(height: 1.5)),
                            if (sources.isNotEmpty) ...[
                              const SizedBox(height: Gap.md),
                              Text(t.uwSources,
                                  style:
                                      Theme.of(context).textTheme.labelLarge),
                              for (final s in sources)
                                InkWell(
                                  onTap: () => uwOpen(context, '${s['url']}'),
                                  // a11y1: each source row is >= 48 dp tall.
                                  child: Container(
                                    constraints: const BoxConstraints(
                                        minHeight: kMinTap),
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: Gap.xs),
                                      child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                                '[${uwDigits(context, s['n'] ?? '')}] ',
                                                style: TextStyle(
                                                    color: scheme.primary,
                                                    fontWeight: FontWeight.w700)),
                                            Expanded(
                                              child: Text(
                                                  '${s['title']} — ${s['site']}',
                                                  style: TextStyle(
                                                      color: scheme.primary,
                                                      decoration: TextDecoration
                                                          .underline,
                                                      decorationColor:
                                                          scheme.primary)),
                                            ),
                                          ]),
                                    ),
                                  ),
                                ),
                            ],
                            for (final c in caution) ...[
                              const SizedBox(height: Gap.sm),
                              UwNote(
                                  text: c,
                                  icon: Icons.health_and_safety_rounded,
                                  warn: true),
                            ],
                            const SizedBox(height: Gap.sm),
                            Row(children: [
                              Expanded(
                                child: Text(
                                  b['cached'] == true
                                      ? t.uwAskCached
                                      : t.uwAskCharged(
                                          uwDigits(context, b['charged'] ?? 0)),
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: scheme.onSurfaceVariant),
                                ),
                              ),
                              UwSpeakButton(
                                  text: '${b['answer'] ?? ''}', compact: true),
                            ]),
                            Text(t.uwAiReview,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant)),
                          ]),
          ),
        ),
      ]),
    );
  }
}
