import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../feature_flags.dart' show FeatureFlags;
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart' show openForUser;
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../voice/va_native.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_digits.dart';
import '../widgets/skeleton.dart';
import 'language_pack_screen.dart' show LanguagePackScreen;

/// langkoja — the WORK-ABROAD language paths for Korea (EPS-TOPIK via BOESL)
/// and Japan (JFT-Basic / JLPT for the Specified Skilled Worker visa).
///
///   [WorkLanguagePathTiles] — Probashi corner: "Work in Korea → EPS-TOPIK
///     path", "Work in Japan → JFT-Basic path" (hidden while the
///     `language_packs` switch is off).
///   [WorkPathScreen] — the official path in steps (from the pack's
///     `work_path`, bn + en), the official websites, a big "Start the course"
///     button (the Language Partner pack screen) and phone-voice listening.
///   [ListeningPracticePage] — short lines read by the phone's own TTS voice in
///     the course language (ko-KR / ja-JP), multiple choice, graded on the
///     server. Labelled "phone voice, not exam audio"; never mixed into a mock
///     score. ZERO Bangla literals (strings: ARB; content: server packs).

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';
String _loc(BuildContext c, Map m, String bnKey, String enKey) =>
    '${(_bn(c) ? m[bnKey] : m[enKey]) ?? ''}';
List<Map<String, dynamic>> _list(Object? v) =>
    v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const [];

String courseTitle(AppLocalizations tr, String lang) =>
    lang == 'ko' ? tr.lkCourseKorean : tr.lkCourseJapanese;

Widget _note(BuildContext context, String t, {IconData icon = Icons.info_outline_rounded}) {
  final scheme = Theme.of(context).colorScheme;
  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(icon, size: 18, color: scheme.onSurfaceVariant),
    const SizedBox(width: Gap.xs),
    Expanded(child: Text(t, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4))),
  ]);
}

Widget _failBody(BuildContext context, Object? fail, VoidCallback retry) {
  final tr = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  return StateMessage(
    icon: Icons.cloud_off_rounded,
    tint: scheme.error,
    title: tr.loadFailed,
    message: honestFailText(tr, fail, otherwise: tr.learnCatalogFail),
    action: FilledButton.tonalIcon(
        onPressed: retry, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
  );
}

void _open(BuildContext context, Widget w) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

/// Probashi corner tiles (Korea → EPS-TOPIK, Japan → JFT-Basic).
class WorkLanguagePathTiles extends StatelessWidget {
  /// Gallery/tests only: show the tiles without touching the global switch.
  @visibleForTesting
  final bool debugForceOn;
  const WorkLanguagePathTiles({super.key, this.debugForceOn = false});

  @override
  Widget build(BuildContext context) {
    if (!debugForceOn && !FeatureFlags.instance.isOn('language_packs')) return const SizedBox.shrink();
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget tile(String lang, IconData icon, String title, String sub) => Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(icon, color: scheme.onPrimaryContainer)),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _open(context, WorkPathScreen(lang: lang, title: title)),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      tile('ko', Icons.precision_manufacturing_rounded, tr.lkKoreaPathTitle, tr.lkKoreaPathSub),
      tile('ja', Icons.engineering_rounded, tr.lkJapanPathTitle, tr.lkJapanPathSub),
    ]);
  }
}

class WorkPathScreen extends StatefulWidget {
  final String lang;
  final String title;
  final Map<String, dynamic>? debugPack;
  const WorkPathScreen({super.key, required this.lang, required this.title, this.debugPack});
  @override
  State<WorkPathScreen> createState() => _WorkPathScreenState();
}

class _WorkPathScreenState extends State<WorkPathScreen> {
  Map<String, dynamic>? _pack;
  Object? _fail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.debugPack != null) {
      _pack = widget.debugPack;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    try {
      _pack = await context.read<AppState>().api.getJson('/learn/pack/${widget.lang}');
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final appBar = AppBar(title: Text(widget.title));
    if (_loading) return Scaffold(appBar: appBar, body: const SkeletonList());
    if (_fail != null || _pack == null) {
      return Scaffold(appBar: appBar, body: _failBody(context, _fail, _load));
    }
    final p = _pack!;
    final wp = (p['work_path'] as Map?)?.cast<String, dynamic>();
    final steps = _list(wp?['steps']);
    final links = _list(wp?['links']);
    final est = (p['estimate_label'] as Map?) ?? const {};
    return Scaffold(
      appBar: appBar,
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: () => _open(context,
                LanguagePackScreen(lang: widget.lang, title: courseTitle(tr, widget.lang))),
            icon: const Icon(Icons.school_rounded),
            label: Text(tr.lkStartCourse),
          ),
          const SizedBox(height: Gap.xs),
          Text(tr.lkStartCourseSub,
              textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              minVerticalPadding: Gap.md,
              leading: CircleAvatar(
                  backgroundColor: scheme.secondaryContainer,
                  child: Icon(Icons.hearing_rounded, color: scheme.onSecondaryContainer)),
              title: Text(tr.lkListenTitle),
              subtitle: Text(tr.lkListenSub),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _open(context, ListeningPracticePage(lang: widget.lang, title: tr.lkListenTitle)),
            ),
          ),
          if (wp != null) ...[
            const SizedBox(height: Gap.lg),
            Text(_loc(context, wp, 'title_bn', 'title_en'),
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: scheme.tertiaryContainer,
                    child: Text(ld(context, i + 1),
                        style: TextStyle(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text(_loc(context, steps[i], 'bn', 'en'), style: const TextStyle(height: 1.4))),
                ]),
              ),
            const SizedBox(height: Gap.xs),
            _note(context, tr.lkVerifyNote, icon: Icons.verified_outlined),
            if (links.isNotEmpty) ...[
              const SizedBox(height: Gap.lg),
              Text(tr.lkOfficialLinks, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.sm),
              Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                for (final l in links)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () {
                      final u = Uri.tryParse('${l['url'] ?? ''}');
                      if (u == null || u.scheme != 'https') return;
                      openForUser(context, u, where: 'work_path_link', mode: LaunchMode.externalApplication);
                    },
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(_loc(context, l, 'bn', 'en')),
                  ),
              ]),
            ],
          ],
          const SizedBox(height: Gap.lg),
          _note(context, _loc(context, est, 'bn', 'en')),
        ],
      ),
    );
  }
}

/// Phone-voice listening practice (Korean / Japanese).
class ListeningPracticePage extends StatefulWidget {
  final String lang;
  final String title;
  final Map<String, dynamic>? debugData;
  final Map<String, dynamic>? debugResult;
  @visibleForTesting
  final Future<String?> Function(String text, String locale)? debugSpeak;
  const ListeningPracticePage(
      {super.key, required this.lang, required this.title, this.debugData, this.debugResult, this.debugSpeak});
  @override
  State<ListeningPracticePage> createState() => _ListeningPracticePageState();
}

class _ListeningPracticePageState extends State<ListeningPracticePage> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _result;
  Object? _fail;
  bool _loading = true;
  bool _busy = false;
  final Map<String, int> _answers = {};
  final Set<String> _shown = {};

  @override
  void initState() {
    super.initState();
    _result = widget.debugResult;
    if (widget.debugData != null) {
      _data = widget.debugData;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    try {
      _data = await context.read<AppState>().api.getJson('/learn/${widget.lang}/listening');
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _speak(String text) async {
    final tr = AppLocalizations.of(context);
    final locale = '${_data?['tts_locale'] ?? ''}';
    String? r;
    try {
      r = await (widget.debugSpeak ?? VaNative.speak)(text, locale);
    } catch (_) {
      r = 'no_engine';
    }
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context)..clearSnackBars();
    if (r == 'no_voice') {
      m.showSnackBar(SnackBar(
        content: Text(tr.uwTtsNoVoice),
        action: SnackBarAction(label: tr.uwTtsSettings, onPressed: () => VaNative.openTtsSettings()),
      ));
    } else if (r == null || r == 'no_engine') {
      m.showSnackBar(SnackBar(content: Text(tr.uwTtsUnavailable)));
    }
  }

  Future<void> _check() async {
    final tr = AppLocalizations.of(context);
    if (_answers.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.lkPickOne)));
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await context
          .read<AppState>()
          .api
          .postJson('/learn/${widget.lang}/listening/grade', {'answers': _answers});
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(honestFailText(tr, e, otherwise: tr.learnCatalogFail))));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final appBar = AppBar(title: Text(widget.title));
    if (_loading) return Scaffold(appBar: appBar, body: const SkeletonList());
    if (_fail != null || _data == null) {
      return Scaffold(appBar: appBar, body: _failBody(context, _fail, _load));
    }
    final d = _data!;
    final qs = _list(d['questions']);
    final rows = {for (final r in _list(_result?['rows'])) '${r['id']}': r};
    return Scaffold(
      appBar: appBar,
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          _note(context, _loc(context, d, 'label_bn', 'label_en'), icon: Icons.record_voice_over_outlined),
          const SizedBox(height: Gap.xs),
          _note(context, tr.lkListenHow),
          if (_result != null) ...[
            const SizedBox(height: Gap.md),
            Card(
              color: scheme.primaryContainer,
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr.lkScore(ld(context, _result!['correct'] ?? 0), ld(context, _result!['total'] ?? 0)),
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  Text(_loc(context, (_result!['estimate_label'] as Map?) ?? const {}, 'bn', 'en'),
                      style: TextStyle(color: scheme.onPrimaryContainer)),
                ]),
              ),
            ),
          ],
          const SizedBox(height: Gap.md),
          for (var i = 0; i < qs.length; i++) _question(context, i, qs[i], rows['${qs[i]['id']}']),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _check,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.fact_check_rounded),
            label: Text(tr.lkCheck),
          ),
        ],
      ),
    );
  }

  Widget _question(BuildContext context, int i, Map<String, dynamic> q, Map<String, dynamic>? row) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final id = '${q['id']}';
    final opts = (q['options'] as List? ?? const []).map((e) => '$e').toList();
    final say = '${q['say'] ?? ''}';
    final show = _shown.contains(id) || row != null;
    final graded = row != null;
    final ok = row?['correct'] == true;
    final ans = row?['answer'] is int ? row!['answer'] as int : -1;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: graded
                  ? (ok ? scheme.primaryContainer : scheme.errorContainer)
                  : scheme.surfaceContainerHighest,
              child: Text(ld(context, i + 1),
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: graded
                          ? (ok ? scheme.onPrimaryContainer : scheme.onErrorContainer)
                          : scheme.onSurface)),
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: say.isEmpty ? null : () => _speak(say),
              icon: const Icon(Icons.volume_up_rounded),
              label: Text(tr.uwListen),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text('${q['text'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
          if (show) ...[
            const SizedBox(height: Gap.xs),
            Text(say, style: TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)),
          ] else
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => setState(() => _shown.add(id)),
                child: Text(tr.lkShowLine),
              ),
            ),
          RadioGroup<int>(
            groupValue: _answers[id],
            onChanged: (v) {
              if (graded || v == null) return;
              setState(() => _answers[id] = v);
            },
            child: Column(children: [
              for (var k = 0; k < opts.length; k++)
                RadioListTile<int>(
                  value: k,
                  contentPadding: EdgeInsets.zero,
                  title: Text(opts[k]),
                ),
            ]),
          ),
          if (graded) ...[
            if (!ok && ans >= 0 && ans < opts.length)
              Text(tr.lkRightAnswer(opts[ans]),
                  style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
            Text(_loc(context, row!, 'explain_bn', 'explain_en'), style: const TextStyle(height: 1.4)),
          ],
        ]),
      ),
    );
  }
}
