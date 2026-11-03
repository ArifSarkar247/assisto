import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_counter.dart';
import '../widgets/local_digits.dart';
import '../widgets/skeleton.dart';
import '../widgets/voice_input.dart';
import '../feature_flags.dart' show FeatureFlags;
import 'ielts_screen.dart';
import 'language_partner_screen.dart';
import 'learn_cert_screen.dart' as lc; // learnwire: certificate offer
import 'lang_work_path.dart' show WorkPathScreen, ListeningPracticePage; // learnwire: pack extras
import '../voice/va_native.dart'; // learnwire: "Listen" on lesson lines (phone voice)

/// p2lang — LANGUAGE PARTNER framework (owner design 3 Nov 11:45, flag
/// `language_packs`). Everything is rendered from server packs
/// (backend/core/data/langpacks/<code>.json; owner_actions/LANGUAGE_PACK_FORMAT.md),
/// so adding a language needs no Dart code:
///   [LanguageCatalogSection] — the 8 language cards (owner order, exam names,
///     work-abroad marks); a language without a pack is a DISABLED card that
///     says so (no promise).
///   [LanguagePackScreen] — placement test, lessons (basic → advanced),
///     speaking scenarios with AI role-play (voice in the course language),
///     pronunciation check, timed mock tests with estimated level + weak areas.
/// Every level is labelled an Assisto practice estimate. ZERO Bangla literals.

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';
String _loc(BuildContext c, Map m, String bnKey, String enKey) =>
    '${(_bn(c) ? m[bnKey] : m[enKey]) ?? ''}';
List<Map<String, dynamic>> _list(Object? v) =>
    v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const [];
List<String> _strs(Object? v) => v is List ? v.map((e) => '$e').toList() : const [];

// ---- learnwire: framework gaps (langmulti) ----

/// `<base>_bn` / `<base>_en` for the UI language; the other language only
/// when that one is missing; then the plain `<base>`.
Object? pickLang(bool bn, Map m, String base) {
  bool has(Object? v) => v != null && !(v is String && v.isEmpty) && !(v is List && v.isEmpty);
  final a = m['${base}_${bn ? 'bn' : 'en'}'];
  if (has(a)) return a;
  final b = m['${base}_${bn ? 'en' : 'bn'}'];
  return has(b) ? b : m[base];
}

String _pickText(BuildContext c, Map m) => '${pickLang(_bn(c), m, 'text') ?? ''}';

/// Writing in Chinese / Japanese is counted in characters (letters and
/// ideographs; no spaces or punctuation), else in space-separated words —
/// the same rule as the server (langpacks.count_units).
const kCharCountLangs = {'zh', 'ja'};
int writingCount(String lang, String text) => kCharCountLangs.contains(lang)
    ? RegExp(r'[\p{L}\p{N}]', unicode: true).allMatches(text).length
    : RegExp(r'\S+').allMatches(text).length;

/// The pack's key-word checklist (any phrase, case-insensitive). Not a grade.
List<bool> runChecks(List<Map<String, dynamic>> checks, String text) {
  final t = text.toLowerCase();
  return [
    for (final c in checks)
      t.trim().isNotEmpty && _strs(c['any']).any((w) => w.isNotEmpty && t.contains(w.toLowerCase())),
  ];
}

void _toast(BuildContext context, String msg) => ScaffoldMessenger.of(context)
  ..clearSnackBars()
  ..showSnackBar(SnackBar(content: Text(msg)));

Widget _page(BuildContext context, String title, List<Widget> children, {List<Widget>? actions}) =>
    Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: children,
      ),
    );

Widget _muted(BuildContext context, String t) => Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Text(t,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4)),
    );

Widget _note(BuildContext context, String t) {
  final scheme = Theme.of(context).colorScheme;
  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
    const SizedBox(width: Gap.xs),
    Expanded(child: Text(t, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.35))),
  ]);
}

String _skillLabel(AppLocalizations tr, String s) => switch (s) {
      'reading' => tr.ieltsReading,
      'listening' => tr.ieltsListening,
      'writing' => tr.ieltsWriting,
      'speaking' => tr.ieltsSpeaking,
      'grammar' => tr.learnSkillGrammar,
      _ => tr.learnSkillVocab,
    };

String _purposeLabel(AppLocalizations tr, String? p) => switch (p) {
      'work_korea' => tr.learnPurposeKorea,
      'work_japan' => tr.learnPurposeJapan,
      'work_gulf' => tr.learnPurposeGulf,
      _ => '',
    };

/// Probashi corner link: "learn the language for work abroad" (hidden while
/// the language_packs switch is off).
/// learnwire: Gulf work-abroad zones (UTC+3 Saudi/Kuwait/Qatar/Bahrain,
/// UTC+4 UAE/Oman) — the Probashi tile then opens work Arabic directly.
bool isGulfOffset(int? minutes) => minutes == 180 || minutes == 240;

class LearnForWorkTile extends StatelessWidget {
  /// The Probashi abroad time zone (minutes); a Gulf zone opens Arabic first.
  final int? abroadOffsetMin;
  const LearnForWorkTile({super.key, this.abroadOffsetMin});

  static Widget arabicPack(AppLocalizations tr) => LanguagePackScreen(lang: 'ar', title: tr.lwArabicTitle);

  @override
  Widget build(BuildContext context) {
    if (!FeatureFlags.instance.isOn('language_packs')) return const SizedBox.shrink();
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final gulf = isGulfOffset(abroadOffsetMin);
    void open(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    final fg = scheme.onTertiaryContainer;
    return Card(
      color: scheme.tertiaryContainer,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          key: const Key('lw-work-tile'),
          minVerticalPadding: Gap.md,
          leading: Icon(Icons.translate_rounded, color: fg),
          title: Text(gulf ? tr.lwGulfArabic : tr.learnProbashiTitle,
              style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
          subtitle: Text(gulf ? tr.lwGulfArabicSub : tr.learnProbashiSub, style: TextStyle(color: fg)),
          trailing: Icon(Icons.chevron_right_rounded, color: fg),
          onTap: () => open(gulf ? arabicPack(tr) : const LanguagePartnerScreen()),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, 0, Gap.sm, Gap.sm),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('lw-work-other'),
              style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(kMinTap, kMinTap)),
              onPressed: () => open(gulf ? const LanguagePartnerScreen() : arabicPack(tr)),
              icon: Icon(gulf ? Icons.language_rounded : Icons.work_rounded),
              label: Text(gulf ? tr.lwAllLanguages : tr.lwGulfArabic),
            ),
          ),
        ),
      ]),
    );
  }
}

// ======================= catalog (Language Partner home) =======================

/// The 8 language cards. Public: Language Partner home + Probashi corner.
class LanguageCatalogSection extends StatefulWidget {
  final Map<String, dynamic>? debugCatalog;
  const LanguageCatalogSection({super.key, this.debugCatalog});
  @override
  State<LanguageCatalogSection> createState() => _LanguageCatalogSectionState();
}

class _LanguageCatalogSectionState extends State<LanguageCatalogSection> {
  Map<String, dynamic>? _cat;
  Object? _fail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.debugCatalog != null) {
      _cat = widget.debugCatalog;
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
      _cat = await context.read<AppState>().api.getJson('/learn/catalog');
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
          padding: EdgeInsets.all(Gap.lg), child: Center(child: CircularProgressIndicator()));
    }
    if (_fail != null || _cat == null) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.cloud_off_rounded, color: scheme.error),
          title: Text(honestFailText(tr, _fail, otherwise: tr.learnCatalogFail)),
          trailing: TextButton(onPressed: _load, child: Text(tr.retry)),
        ),
      );
    }
    final langs = _list(_cat!['languages']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr.learnPickLanguage,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.xs),
      _muted(context, tr.learnPickLanguageSub),
      for (final l in langs) _LangCard(lang: l),
      const SizedBox(height: Gap.sm),
      _note(context, _loc(context, (_cat!['estimate_label'] as Map?) ?? const {}, 'bn', 'en')),
    ]);
  }
}

String _initial(String s) => s.isEmpty ? '' : String.fromCharCode(s.runes.first);

class _LangCard extends StatelessWidget {
  final Map<String, dynamic> lang;
  const _LangCard({required this.lang});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final on = lang['available'] == true;
    final purpose = _purposeLabel(tr, lang['purpose'] as String?);
    final name = _loc(context, lang, 'name_bn', 'name_en');
    final fg = on ? scheme.onSurface : scheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      color: on ? null : scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: on
            ? () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LanguagePackScreen(lang: '${lang['code']}', title: name)))
            : null,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: on ? scheme.primaryContainer : scheme.surface,
              child: Text(_initial('${lang['native'] ?? ''}'),
                  style: TextStyle(
                      fontSize: 20, color: on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$name · ${lang['native'] ?? ''}',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: fg)),
                Text(_loc(context, lang, 'exams_bn', 'exams_en'), style: TextStyle(color: fg)),
                if (purpose.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text(purpose,
                        style: TextStyle(
                            color: Brand.onTint(context, Brand.info), fontWeight: FontWeight.w600)),
                  ),
                if (!on)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text(tr.learnNotAdded, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
              ]),
            ),
            if (on) const Icon(Icons.chevron_right_rounded),
          ]),
        ),
      ),
    );
  }
}

// ======================= one language =======================

class LanguagePackScreen extends StatefulWidget {
  final String lang;
  final String title;
  final Map<String, dynamic>? debugPack;
  const LanguagePackScreen({super.key, required this.lang, required this.title, this.debugPack});
  @override
  State<LanguagePackScreen> createState() => _LanguagePackScreenState();
}

/// What every module page needs.
class _Pack {
  final String lang;
  final Map<String, dynamic> data;
  _Pack(this.lang, this.data);
  String get locale => '${data['stt_locale'] ?? 'en-US'}';
  String get ttsLocale => '${data['tts_locale'] ?? data['stt_locale'] ?? ''}';
  bool get aiReady => data['ai_ready'] == true;
  String estimate(BuildContext c) => _loc(c, (data['estimate_label'] as Map?) ?? const {}, 'bn', 'en');
  String levelName(BuildContext c, String id) {
    for (final l in _list(data['levels'])) {
      if (l['id'] == id) return _loc(c, l, 'bn', 'en');
    }
    return id;
  }
}

class _LanguagePackScreenState extends State<LanguagePackScreen> {
  Map<String, dynamic>? _data;
  Object? _fail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.debugPack != null) {
      _data = widget.debugPack;
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
      _data = await context.read<AppState>().api.getJson('/learn/pack/${widget.lang}');
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(appBar: AppBar(title: Text(widget.title)), body: const SkeletonList());
    }
    if (_fail != null || _data == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _fail, otherwise: tr.learnCatalogFail),
          action: FilledButton.tonalIcon(
              onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
        ),
      );
    }
    final p = _Pack(widget.lang, _data!);
    void open(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    // learnwire: per-pack extras tiles (IELTS hub, work path, phone-voice listening)
    final extras = [
      for (final e in _list(p.data['extras']))
        if (e['id'] == 'ielts')
          (Icons.school_rounded, tr.ieltsTitle, tr.ieltsEntrySubtitle, () => open(const IeltsScreen()))
        else if (e['id'] == 'work_path')
          (Icons.work_rounded, _loc(context, e, 'bn', 'en'), tr.lkOfficialLinks,
              () => open(WorkPathScreen(lang: widget.lang, title: _loc(context, e, 'bn', 'en'))))
        else if (e['id'] == 'listening')
          (Icons.hearing_rounded, _loc(context, e, 'bn', 'en'), tr.lkListenSub,
              () => open(ListeningPracticePage(lang: widget.lang, title: _loc(context, e, 'bn', 'en')))),
    ];
    final tiles = <(IconData, String, String, VoidCallback)>[
      (Icons.flag_rounded, tr.learnPlacement, tr.learnPlacementSub, () => open(_PlacementPage(pack: p))),
      (Icons.menu_book_rounded, tr.learnLessons, tr.learnLessonsSub, () => open(_LessonsPage(pack: p))),
      if (_list(p.data['scenarios']).isNotEmpty)
        (Icons.flight_takeoff_rounded, tr.learnScenarios, tr.learnScenariosSub,
            () => open(_ScenarioListPage(pack: p))),
      if (_list(p.data['pron']).isNotEmpty)
        (Icons.record_voice_over_rounded, tr.ieltsPron, tr.learnPronSub, () => open(_PronListPage(pack: p))),
      if (_list(p.data['mock']).isNotEmpty)
        (Icons.timer_rounded, tr.learnMock, tr.learnMockSub, () => open(_MockListPage(pack: p))),
      ...extras,
    ];
    return _page(context, widget.title, [
      _note(context, p.estimate(context)),
      const SizedBox(height: Gap.md),
      for (final t in tiles)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            leading: CircleAvatar(
                backgroundColor: scheme.secondaryContainer,
                child: Icon(t.$1, color: scheme.onSecondaryContainer)),
            title: Text(t.$2),
            subtitle: Text(t.$3),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: t.$4,
          ),
        ),
    ]);
  }
}

// ======================= shared MCQ block =======================

class _McqBlock extends StatelessWidget {
  final int index;
  final Map<String, dynamic> q;
  final int? picked;
  final Map<String, dynamic>? graded; // server row after grading
  final ValueChanged<int>? onPick;
  const _McqBlock({required this.index, required this.q, this.picked, this.graded, this.onPick});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final opts = _strs(pickLang(_bn(context), q, 'options'));
    final g = graded;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${ld(context, index + 1)}. ${_pickText(context, q)}',
            style: const TextStyle(fontWeight: FontWeight.w600, height: 1.4)),
        for (var k = 0; k < opts.length; k++)
          Semantics(
            selected: picked == k,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: Gap.xs),
              leading: Icon(picked == k
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded),
              title: Text(opts[k]),
              onTap: onPick == null ? null : () => onPick!(k),
            ),
          ),
        if (g != null)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(g['correct'] == true ? Icons.check_circle_rounded : Icons.cancel_rounded,
                color: Brand.onTint(context, g['correct'] == true ? Brand.success : Brand.danger)),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(
                  '${tr.ieltsCorrectAnswer((g['answer'] is int && (g['answer'] as int) < opts.length) ? opts[g['answer'] as int] : '')}\n${_loc(context, g, 'explain_bn', 'explain_en')}',
                  style: const TextStyle(height: 1.4)),
            ),
          ]),
      ]),
    );
  }
}

/// Level + score + weak areas card (placement and mock results).
class LearnResultCard extends StatelessWidget {
  final Map<String, dynamic> result;
  final String levelName;
  final String estimate;
  const LearnResultCard({super.key, required this.result, required this.levelName, required this.estimate});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final weak = _strs(result['weak']);
    final sections = _list(result['sections']);
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ld(context, tr.learnYourLevel(levelName)),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer)),
          Text(ld(context, tr.ieltsScore(result['correct'] ?? 0, result['total'] ?? 0)),
              style: TextStyle(color: scheme.onPrimaryContainer)),
          for (final s in sections)
            Text(ld(context, '${_skillLabel(tr, '${s['skill']}')}: ${s['pct']}%'),
                style: TextStyle(color: scheme.onPrimaryContainer)),
          const SizedBox(height: Gap.sm),
          Text(weak.isEmpty ? tr.learnNoWeak : tr.learnWeak(weak.map((w) => _skillLabel(tr, w)).join(', ')),
              style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
          if (result['timed_out'] == true)
            Text(tr.learnTimedOut, style: TextStyle(color: scheme.onPrimaryContainer)),
          const SizedBox(height: Gap.sm),
          Text(estimate, style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 13)),
        ]),
      ),
    );
  }
}

// ======================= placement =======================

class _PlacementPage extends StatefulWidget {
  final _Pack pack;
  const _PlacementPage({required this.pack});
  @override
  State<_PlacementPage> createState() => _PlacementPageState();
}

class _PlacementPageState extends State<_PlacementPage> {
  final Map<String, int> _answers = {};
  Map<String, dynamic>? _result;
  bool _busy = false;

  Future<void> _submit() async {
    final tr = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await context
          .read<AppState>()
          .api
          .postJson('/learn/${widget.pack.lang}/placement', {'answers': _answers});
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) _toast(context, honestFailText(tr, e, otherwise: tr.learnCatalogFail));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final qs = _list((widget.pack.data['placement'] as Map?)?['questions']);
    final graded = {for (final r in _list(_result?['rows'])) '${r['id']}': r};
    return _page(context, tr.learnPlacement, [
      _muted(context, tr.learnPlacementHow),
      if (_result != null) ...[
        LearnResultCard(
            result: _result!,
            levelName: widget.pack.levelName(context, '${_result!['level']}'),
            estimate: widget.pack.estimate(context)),
        CertOfferButton(offer: _result!['cert']),
        const SizedBox(height: Gap.md),
      ],
      for (var i = 0; i < qs.length; i++)
        _McqBlock(
          index: i,
          q: qs[i],
          picked: _answers['${qs[i]['id']}'],
          graded: graded['${qs[i]['id']}'],
          onPick: _result != null ? null : (k) => setState(() => _answers['${qs[i]['id']}'] = k),
        ),
      if (_result == null)
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy || _answers.isEmpty ? null : _submit,
          icon: const Icon(Icons.fact_check_rounded),
          label: Text(tr.ieltsSubmitAnswers),
        )
      else
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => setState(() {
            _result = null;
            _answers.clear();
          }),
          icon: const Icon(Icons.replay_rounded),
          label: Text(tr.ieltsTryAgain),
        ),
    ]);
  }
}

// ======================= lessons =======================

class _LessonsPage extends StatelessWidget {
  final _Pack pack;
  const _LessonsPage({required this.pack});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final lessons = _list(pack.data['lessons']);
    final levels = _list(pack.data['levels']);
    return _page(context, tr.learnLessons, [
      _muted(context, tr.learnLessonsHow),
      for (final lv in levels) ...[
        if (lessons.any((l) => l['level'] == lv['id']))
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xs),
            child: Text(ld(context, _loc(context, lv, 'bn', 'en')),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
        for (final l in lessons.where((l) => l['level'] == lv['id']))
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: ListTile(
              minVerticalPadding: Gap.md,
              title: Text(_loc(context, l, 'title_bn', 'title_en')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => LessonPage(pack: pack, lesson: l))),
            ),
          ),
      ],
    ]);
  }
}

/// One lesson: items (target + meaning + note) and sentences to say.
class LessonPage extends StatelessWidget {
  final Object pack; // _Pack
  final Map<String, dynamic> lesson;
  /// Phone-voice locale for "Listen" when [pack] is not a pack (tests / gallery).
  final String? ttsLocale;
  const LessonPage({super.key, required this.pack, required this.lesson, this.ttsLocale});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = pack;
    final locale = p is _Pack ? p.locale : 'en-US';
    final tts = p is _Pack ? p.ttsLocale : (ttsLocale ?? '');
    return _page(context, _loc(context, lesson, 'title_bn', 'title_en'), [
      for (final it in _list(lesson['items']))
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text('${it['target']}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (tts.isNotEmpty && it['kind'] != 'note' && '${it['target'] ?? ''}'.trim().isNotEmpty)
                  IconButton(
                    key: Key('lw-listen-${it['target']}'),
                    tooltip: tr.lwListen,
                    icon: const Icon(Icons.volume_up_rounded),
                    onPressed: () => speakPackLine(context, '${it['target']}', tts),
                  ),
              ]),
              if ((it['roman'] ?? '').toString().isNotEmpty)
                Text('${it['roman']}', style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.xs),
              Text(_loc(context, it, 'bn', 'en'), style: const TextStyle(height: 1.4)),
              if ((it['note_bn'] ?? '').toString().isNotEmpty)
                Text(_loc(context, it, 'note_bn', 'note_en'),
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            ]),
          ),
        ),
      if (_strs(lesson['practice']).isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Text(tr.learnSayIt, style: Theme.of(context).textTheme.titleMedium),
        for (final s in _strs(lesson['practice']))
          Card(
            margin: const EdgeInsets.only(top: Gap.sm),
            child: ListTile(
              minVerticalPadding: Gap.md,
              leading: const Icon(Icons.mic_rounded),
              title: Text(s),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => IeltsPronPractice(
                      ctx: Object(), row: {'text': s}, localeId: locale, title: tr.ieltsPron))),
            ),
          ),
      ],
    ]);
  }
}

// ======================= pronunciation =======================

class _PronListPage extends StatelessWidget {
  final _Pack pack;
  const _PronListPage({required this.pack});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return _page(context, tr.ieltsPron, [
      _muted(context, tr.ieltsPronHow),
      for (final r in _list(pack.data['pron']))
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            title: Text('${r['text']}'),
            subtitle: Text(_loc(context, r, 'tip_bn', 'tip_en'), maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => IeltsPronPractice(ctx: Object(), row: r, localeId: pack.locale))),
          ),
        ),
    ]);
  }
}

// ======================= speaking scenarios (AI role-play) =======================

class _ScenarioListPage extends StatelessWidget {
  final _Pack pack;
  const _ScenarioListPage({required this.pack});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return _page(context, tr.learnScenarios, [
      _muted(context, tr.learnScenariosHow),
      for (final s in _list(pack.data['scenarios']))
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            leading: Icon(switch ('${s['id']}') {
              'airport' => Icons.flight_rounded,
              'workplace' => Icons.engineering_rounded,
              'doctor' => Icons.local_hospital_rounded,
              'renting' => Icons.home_rounded,
              'shopping' => Icons.shopping_cart_rounded,
              'salary_rights' => Icons.payments_rounded, // learnwire: pack extras
              'immigration_office' => Icons.badge_rounded,
              _ => Icons.forum_rounded,
            }),
            title: Text(_loc(context, s, 'title_bn', 'title_en')),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => ScenarioChatPage(pack: pack, scenario: s))),
          ),
        ),
    ]);
  }
}

class ScenarioChatPage extends StatefulWidget {
  final Object pack; // _Pack
  final Map<String, dynamic> scenario;
  const ScenarioChatPage({super.key, required this.pack, required this.scenario});
  @override
  State<ScenarioChatPage> createState() => _ScenarioChatPageState();
}

class _ScenarioChatPageState extends State<ScenarioChatPage> {
  final _input = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation(
      mode: 'en', learnLocale: widget.pack is _Pack ? (widget.pack as _Pack).locale : null);
  late final List<Map<String, String>> _turns = [
    {'role': 'assistant', 'content': '${widget.scenario['opening'] ?? ''}'},
  ];
  final List<Map<String, String>> _fixes = [];
  bool _busy = false;
  String? _state; // ai_state of the last answer when not 'used'
  int? _left;

  String get _lang => widget.pack is _Pack ? (widget.pack as _Pack).lang : 'en';
  bool get _aiReady => widget.pack is _Pack && (widget.pack as _Pack).aiReady;

  @override
  void dispose() {
    _voice.stop();
    _voice.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final tr = AppLocalizations.of(context);
    final msg = _input.text.trim();
    if (msg.isEmpty) {
      _toast(context, tr.ieltsEmptyAnswer);
      return;
    }
    await _voice.stop();
    final history = List<Map<String, String>>.of(_turns);
    setState(() {
      _busy = true;
      _turns.add({'role': 'user', 'content': msg});
      _input.clear();
    });
    try {
      final r = await context.read<AppState>().api.postJson('/learn/$_lang/roleplay', {
        'scenario_id': widget.scenario['id'],
        'history': history,
        'message': msg,
      });
      if (!mounted) return;
      setState(() {
        final st = '${r['ai_state']}';
        _state = st == 'used' ? null : st;
        if (r['ai_left_today'] is int) _left = r['ai_left_today'] as int;
        if (st == 'used' && (r['reply'] ?? '').toString().isNotEmpty) {
          _turns.add({'role': 'assistant', 'content': '${r['reply']}'});
          if ('${r['fix_en'] ?? ''}'.isNotEmpty) {
            _fixes.add({'bn': '${r['fix_bn']}', 'en': '${r['fix_en']}'});
          }
        }
      });
    } catch (e) {
      if (mounted) _toast(context, honestFailText(tr, e, otherwise: tr.learnCatalogFail));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sc = widget.scenario;
    final stateMsg = switch (_state) {
      'no_key' => tr.learnAiNotConnected,
      'credits' || 'user_limit' => tr.learnAiNoCredits,
      'budget' || 'busy' => tr.ieltsAiBusy,
      _ => null,
    };
    return Scaffold(
      appBar: AppBar(title: Text(_loc(context, sc, 'title_bn', 'title_en'))),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
            children: [
              Text(tr.learnGoals, style: const TextStyle(fontWeight: FontWeight.w700)),
              for (final g in _strs(_bn(context) ? sc['goals_bn'] : sc['goals_en']))
                Text('• $g', style: const TextStyle(height: 1.5)),
              const SizedBox(height: Gap.sm),
              if (_list(sc['useful']).isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(tr.learnUseful),
                  children: [
                    for (final u in _list(sc['useful']))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${u['target']}'),
                        subtitle: Text(_loc(context, u, 'bn', 'en')),
                        trailing: IconButton(
                          tooltip: tr.learnUsePhrase,
                          icon: const Icon(Icons.north_west_rounded),
                          onPressed: () => _input.text = '${u['target']}',
                        ),
                      ),
                  ],
                ),
              if (!_aiReady)
                Card(
                  color: scheme.surfaceContainerHighest,
                  child: Padding(
                      padding: const EdgeInsets.all(Gap.md), child: Text(tr.learnAiNotConnected)),
                ),
              for (final t in _turns)
                Align(
                  alignment: t['role'] == 'user' ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(top: Gap.sm),
                    padding: const EdgeInsets.all(Gap.md),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    decoration: BoxDecoration(
                      color: t['role'] == 'user' ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text('${t['content']}',
                        style: TextStyle(
                            color: t['role'] == 'user' ? scheme.onPrimaryContainer : scheme.onSurface)),
                  ),
                ),
              for (final f in _fixes)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.lightbulb_outline_rounded, color: Brand.warnInk(context)),
                    const SizedBox(width: Gap.xs),
                    Expanded(child: Text(_bn(context) ? '${f['bn']}' : '${f['en']}')),
                  ]),
                ),
              if (stateMsg != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text(stateMsg, style: TextStyle(color: scheme.error)),
                ),
              if (_left != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text(ld(context, tr.learnAiLeft(_left!)),
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm, 0, Gap.sm, Gap.sm),
            child: Row(children: [
              VoiceMicButton(voice: _voice, input: _input),
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 600,
                  buildCounter: localCounter,
                  decoration: InputDecoration(hintText: tr.learnTypeOrSpeak, border: const OutlineInputBorder()),
                ),
              ),
              IconButton(
                tooltip: tr.learnSend,
                onPressed: _busy || !_aiReady ? null : _send,
                icon: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ======================= mock tests =======================

class _MockListPage extends StatelessWidget {
  final _Pack pack;
  const _MockListPage({required this.pack});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return _page(context, tr.learnMock, [
      _muted(context, tr.learnMockHow),
      for (final m in _list(pack.data['mock']))
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            title: Text(_loc(context, m, 'title_bn', 'title_en')),
            subtitle: Text(ld(context,
                '${_loc(context, m, 'format_bn', 'format_en')}\n${tr.learnMinutes(m['minutes'] ?? 0)}')),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => MockTestPage(pack: pack, mock: m))),
          ),
        ),
    ]);
  }
}

class MockTestPage extends StatefulWidget {
  final Object pack; // _Pack
  final Map<String, dynamic> mock;
  final Map<String, dynamic>? debugResult;
  /// Course language when [pack] is not a pack (tests / gallery).
  final String? lang;
  const MockTestPage({super.key, required this.pack, required this.mock, this.debugResult, this.lang});
  @override
  State<MockTestPage> createState() => _MockTestPageState();
}

class _MockTestPageState extends State<MockTestPage> {
  final Map<String, int> _answers = {};
  final Map<String, TextEditingController> _texts = {};
  final _clock = Stopwatch()..start();
  Timer? _tick;
  late Map<String, dynamic>? _result = widget.debugResult;
  bool _busy = false;

  _Pack? get _p => widget.pack is _Pack ? widget.pack as _Pack : null;
  String get _lang => _p?.lang ?? widget.lang ?? '';

  // learnwire: JFT-style rule (`no_back`) — one section at a time, no going
  // back, each section with its own timer; time up moves on (last: submits).
  int _sec = 0;
  bool _timeUpSubmitted = false;
  final _secClock = Stopwatch()..start();
  bool get _noBack => widget.mock['no_back'] == true && _result == null;
  List<Map<String, dynamic>> get _secs => _list(widget.mock['sections']);
  int _secLeft() {
    final total = ((_secs.elementAtOrNull(_sec)?['minutes'] as num?)?.toInt() ?? 0) * 60;
    return (total - _secClock.elapsed.inSeconds).clamp(0, total);
  }

  void _nextSection({bool timeUp = false}) {
    if (_sec >= _secs.length - 1) {
      // the last section's time is up: submit once (a failed submit leaves
      // the Finish button; it is not retried every second)
      if (!_busy && !_timeUpSubmitted) {
        _timeUpSubmitted = true;
        _submit();
      }
      return;
    }
    setState(() {
      _sec++;
      _secClock
        ..reset()
        ..start();
    });
    if (timeUp) _toast(context, AppLocalizations.of(context).lwSectionTimeUp);
  }

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _result != null) return;
      if (_noBack && !_busy && _secLeft() == 0) {
        _nextSection(timeUp: true);
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctl(String id) => _texts.putIfAbsent(id, TextEditingController.new);

  /// Server checklist results for open answer [id] (after grading), else null.
  List<bool>? _openChecks(String id) {
    final row = _list(_result?['open']).where((o) => '${o['id']}' == id).firstOrNull;
    if (row == null) return null;
    return [for (final c in _list(row['checks'])) c['ok'] == true];
  }

  Future<void> _submit() async {
    final tr = AppLocalizations.of(context);
    final p = _p;
    if (p == null) return;
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.postJson('/learn/${p.lang}/mock', {
        'mock_id': widget.mock['id'],
        'answers': _answers,
        'texts': {for (final e in _texts.entries) e.key: e.value.text},
        'seconds': _clock.elapsed.inSeconds,
      });
      _clock.stop();
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) _toast(context, honestFailText(tr, e, otherwise: tr.learnCatalogFail));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final m = widget.mock;
    final total = ((m['minutes'] as num?)?.toInt() ?? 0) * 60;
    final noBack = _noBack;
    final left = noBack ? _secLeft() : (total - _clock.elapsed.inSeconds).clamp(0, total);
    final mmss = '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
    final graded = {for (final r in _list(_result?['rows'])) '${r['id']}': r};
    final secs = _secs;
    final starts = <int>[];
    var acc = 0;
    for (final s in secs) {
      starts.add(acc);
      acc += _list(s['questions']).length;
    }
    final lastSec = !noBack || _sec >= secs.length - 1;
    return _page(context, _loc(context, m, 'title_bn', 'title_en'), actions: [
      if (_result == null)
        Center(
          child: Padding(
            padding: const EdgeInsets.only(right: Gap.md),
            child: Semantics(
              label: tr.learnTimeLeft,
              child: Text(ld(context, mmss),
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: left == 0 ? Theme.of(context).colorScheme.error : null)),
            ),
          ),
        ),
    ], [
      _muted(context, _loc(context, m, 'format_bn', 'format_en')),
      if (_result != null) ...[
        LearnResultCard(
            result: _result!,
            levelName: _p?.levelName(context, '${_result!['level']}') ?? '${_result!['level']}',
            estimate: _p?.estimate(context) ?? ''),
        CertOfferButton(offer: _result!['cert']),
        const SizedBox(height: Gap.md),
      ],
      if (noBack) ...[
        Text(ld(context, tr.lwSectionOf(_sec + 1, secs.length)),
            key: const Key('lw-section-of'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        _note(context, tr.lwNoBackNote),
      ],
      for (final (si, s) in secs.indexed)
        if (!noBack || si == _sec) ...[
        Padding(
          padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.sm),
          child: Text(_loc(context, s, 'title_bn', 'title_en'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        for (final para in _strs(s['passage']))
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(para, style: const TextStyle(height: 1.5)),
          ),
        for (final (qj, q) in _list(s['questions']).indexed)
          _McqBlock(
            index: starts[si] + qj,
            q: q,
            picked: _answers['${q['id']}'],
            graded: graded['${q['id']}'],
            onPick: _result != null ? null : (k) => setState(() => _answers['${q['id']}'] = k),
          ),
        for (final pr in _list(s['prompts'])) ...[
          Text(_pickText(context, pr), style: const TextStyle(height: 1.45)),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _ctl('${pr['id']}'),
            readOnly: _result != null,
            minLines: 4,
            maxLines: 12,
            maxLength: 6000,
            buildCounter: localCounter,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: tr.ieltsYourAnswer, border: const OutlineInputBorder()),
          ),
          WritingCountLine(lang: _lang, text: _ctl('${pr['id']}').text, prompt: pr),
          if (_list(pr['checks']).isNotEmpty)
            PackChecklist(
              checks: _list(pr['checks']),
              results: _openChecks('${pr['id']}'),
            ),
          const SizedBox(height: Gap.md),
        ],
        for (final sp in _list(s['speak_prompts']))
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: ListTile(
              minVerticalPadding: Gap.md,
              leading: const Icon(Icons.record_voice_over_rounded),
              title: Text(_pickText(context, sp)),
              subtitle: (sp['seconds'] is num)
                  ? Text(ld(context, tr.lwSpeakSeconds(sp['seconds'])))
                  : null,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SpeakPromptPage(prompt: sp, localeId: _p?.locale))),
            ),
          ),
        for (final ra in _strs(s['read_aloud']))
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: ListTile(
              minVerticalPadding: Gap.md,
              leading: const Icon(Icons.mic_rounded),
              title: Text(ra),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => IeltsPronPractice(
                      ctx: Object(), row: {'text': ra}, localeId: _p?.locale, title: tr.ieltsPron))),
            ),
          ),
      ],
      const SizedBox(height: Gap.md),
      if (_result == null && !lastSec)
        FilledButton.icon(
          key: const Key('lw-next-section'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : () => _nextSection(),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(tr.lwNextSection),
        )
      else if (_result == null)
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : _submit,
          icon: const Icon(Icons.fact_check_rounded),
          label: Text(tr.learnFinishTest),
        ),
    ]);
  }
}

// ======================= learnwire: writing count, checklist, speaking, certificate =======================

/// "12 words · Aim: 20 to 60" (Chinese / Japanese: characters, spaces not
/// counted) under a writing box.
class WritingCountLine extends StatelessWidget {
  final String lang;
  final String text;
  final Map<String, dynamic> prompt;
  const WritingCountLine({super.key, required this.lang, required this.text, required this.prompt});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final n = writingCount(lang, text);
    final lo = (prompt['min_words'] as num?)?.toInt() ?? 0;
    final hi = (prompt['max_words'] as num?)?.toInt();
    final count = kCharCountLangs.contains(lang) ? tr.lwCountChars(n) : tr.lwCountWords(n);
    final aim = hi != null ? tr.lwCountAim(lo, hi) : (lo > 0 ? tr.lwCountAimMin(lo) : '');
    final outside = n > 0 && (n < lo || (hi != null && n > hi));
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: Text(ld(context, aim.isEmpty ? count : '$count · $aim'),
          key: const Key('lw-count'),
          style: TextStyle(
              color: outside ? scheme.error : scheme.onSurfaceVariant,
              fontWeight: outside ? FontWeight.w600 : null)),
    );
  }
}

/// The pack's key-word checklist. Before grading: what to include; after:
/// a tick or a cross per line ([results]). Never a grade.
class PackChecklist extends StatelessWidget {
  final List<Map<String, dynamic>> checks;
  final List<bool>? results;
  final String? title;
  const PackChecklist({super.key, required this.checks, this.results, this.title});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = results;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title ?? tr.lwChecklist,
            style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface)),
        for (var i = 0; i < checks.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (r == null || i >= r.length)
                Icon(Icons.radio_button_unchecked_rounded, size: 20, color: scheme.onSurfaceVariant)
              else
                Icon(r[i] ? Icons.check_circle_rounded : Icons.cancel_rounded,
                    size: 20,
                    color: Brand.onTint(context, r[i] ? Brand.success : Brand.danger),
                    semanticLabel: r[i] ? tr.lwCheckOk : tr.lwCheckMissing),
              const SizedBox(width: Gap.xs),
              Expanded(child: Text(_loc(context, checks[i], 'bn', 'en'), style: const TextStyle(height: 1.35))),
            ]),
          ),
      ]),
    );
  }
}

/// Free speaking task from a pack mock (`speak_prompts`): the prompt in the
/// UI language, speak in the course language (phone speech-to-text), then a
/// key-word checklist — honestly labelled, not a speaking score.
class SpeakPromptPage extends StatefulWidget {
  final Map<String, dynamic> prompt;
  final String? localeId;
  final String? debugHeard; // gallery / tests: a finished attempt
  const SpeakPromptPage({super.key, required this.prompt, this.localeId, this.debugHeard});
  @override
  State<SpeakPromptPage> createState() => _SpeakPromptPageState();
}

class _SpeakPromptPageState extends State<SpeakPromptPage> {
  final _heard = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation(mode: 'en', learnLocale: widget.localeId);
  List<bool>? _res;

  List<Map<String, dynamic>> get _checks => _list(widget.prompt['checks']);

  @override
  void initState() {
    super.initState();
    if (widget.debugHeard != null) {
      _heard.text = widget.debugHeard!;
      _res = runChecks(_checks, widget.debugHeard!);
    }
  }

  @override
  void dispose() {
    _voice.stop();
    _voice.dispose();
    _heard.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    if (_voice.listening) {
      await _voice.stop();
      return;
    }
    _heard.clear();
    setState(() => _res = null);
    await _voice.start(context, _heard, pauseFor: const Duration(seconds: 4));
  }

  void _check() {
    final tr = AppLocalizations.of(context);
    if (_heard.text.trim().isEmpty) {
      _toast(context, tr.lwNothingHeard);
      return;
    }
    setState(() => _res = runChecks(_checks, _heard.text));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final sp = widget.prompt;
    return _page(context, tr.lwSpeakTitle, [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Text(_pickText(context, sp),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(height: 1.35)),
        ),
      ),
      if (sp['seconds'] is num) _muted(context, ld(context, tr.lwSpeakSeconds(sp['seconds']))),
      if (_checks.isNotEmpty) PackChecklist(checks: _checks, results: _res, title: tr.lwSpeakTry),
      const SizedBox(height: Gap.sm),
      ListenableBuilder(
        listenable: _voice,
        builder: (context, _) => FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _record,
          icon: Icon(_voice.listening ? Icons.stop_rounded : Icons.mic_rounded),
          label: Text(_voice.listening ? tr.ieltsStop : tr.ieltsRecord),
        ),
      ),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _heard,
        readOnly: true,
        minLines: 1,
        maxLines: 6,
        decoration: InputDecoration(labelText: tr.ieltsHeardLabel, border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.sm),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _check,
        icon: const Icon(Icons.fact_check_rounded),
        label: Text(tr.ieltsCheck),
      ),
      const SizedBox(height: Gap.md),
      _note(context, tr.lwSpeakHonest),
    ]);
  }
}

/// "Get my certificate" under a server-graded result. Shown only when the
/// server signed an offer AND the learning_certificate switch is on; the
/// certificate itself is issued by the server (/learn/certs/claim).
class CertOfferButton extends StatelessWidget {
  final Object? offer;
  const CertOfferButton({super.key, required this.offer});
  @override
  Widget build(BuildContext context) {
    final o = offer;
    if (o is! Map || '${o['token'] ?? ''}'.isEmpty) return const SizedBox.shrink();
    if (!FeatureFlags.instance.isOn(lc.kLearnCertFlag)) return const SizedBox.shrink();
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: FilledButton.tonalIcon(
        key: const Key('lw-cert-offer'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: () => lc.courseResult(context,
            course: '${o['course']}',
            level: '${o['level']}',
            score: o['score'] is num ? o['score'] as num : null,
            token: '${o['token']}'),
        icon: const Icon(Icons.workspace_premium_rounded),
        label: Text(tr.lcGetCert),
      ),
    );
  }
}

/// Tests: replaces the phone voice ([VaNative.speak]).
@visibleForTesting
Future<String?> Function(String text, String locale)? debugPackSpeak;

/// learnwire: read one lesson line aloud with the phone's own voice in the
/// course language (Android TTS; ko-KR / ja-JP supported by
/// AssistoVoiceChannel). Practice only — never exam audio, never scored.
Future<void> speakPackLine(BuildContext context, String text, String locale) async {
  final tr = AppLocalizations.of(context);
  String? r;
  try {
    r = await (debugPackSpeak ?? VaNative.speak)(text, locale);
  } catch (_) {
    r = 'no_engine';
  }
  if (!context.mounted) return;
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
