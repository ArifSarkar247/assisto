// p3faith (owner PART 3, 3 Nov 2026): offline Quran — flag `quran`.
//
// Arabic: Tanzil (CC BY 3.0, shown verbatim). English meaning: Pickthall 1930
// (public domain). Bangla: honestly "awaiting licence" — never invented.
// Search, bookmarks, last read; no audio; NO ads (the 'quran' screen key is
// on the never-ads list, ad_rules.dart).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../quran/ayah_view_screen.dart'; // quranview
import '../quran/quran_bilingual_api.dart'; // gap-quranblood Q1
import '../state.dart';
import '../quran/quran_store.dart';
import '../ds/ds.dart';
import '../widgets/skeleton.dart' show SkeletonList;
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_digits.dart';

bool _isBn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// Calm, respectful accent for the Quran screens (works light + dark).
Color _accent(BuildContext c) => Theme.of(c).colorScheme.primary;

class QuranScreen extends StatefulWidget {
  const QuranScreen({super.key, this.initialTab = 0});

  /// 0 suras · 1 paras (gap-quranblood Q4) · 2 bookmarks.
  final int initialTab;
  @override
  State<QuranScreen> createState() => _QuranScreenState();
}

class _QuranScreenState extends State<QuranScreen> {
  QuranData? _data;
  Object? _error;
  AyaRef? _last;
  List<AyaRef> _bookmarks = const [];
  final _q = TextEditingController();
  List<QuranHit>? _hits; // verse search results (after submit)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await QuranStore.load();
      final last = await QuranPrefs.lastRead();
      final bm = await QuranPrefs.bookmarks();
      if (!mounted) return;
      setState(() {
        _data = d;
        _last = last;
        _bookmarks = bm;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _refreshPrefs() async {
    final last = await QuranPrefs.lastRead();
    final bm = await QuranPrefs.bookmarks();
    if (mounted) {
      setState(() {
        _last = last;
        _bookmarks = bm;
      });
    }
  }

  Future<void> _open(int sura, [int aya = 1]) async {
    final d = _data;
    if (d == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => QuranReaderScreen(data: d, sura: sura, aya: aya)));
    _refreshPrefs();
  }

  void _searchVerses() {
    final d = _data;
    if (d == null) return;
    FocusScope.of(context).unfocus();
    setState(() => _hits = d.search(_q.text));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.quranTitle),
          actions: [
            IconButton(
              key: const Key('quran-about'),
              tooltip: t.qrnAbout,
              icon: const Icon(Icons.info_outline_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => QuranAboutScreen(notice: _data?.arabicNotice))),
            ),
          ],
          bottom: _data == null
              ? null
              : TabBar(tabs: [
                  Tab(text: t.qrnTabSuras),
                  Tab(key: const Key('quran-tab-juz'), text: t.qrnTabJuz),
                  Tab(text: t.qrnTabBookmarks),
                ]),
        ),
        body: _body(t),
      ),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_error != null) {
      return ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          const Icon(Icons.menu_book_rounded, size: 48),
          const SizedBox(height: Gap.md),
          Text(t.qrnLoadFailed, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          Center(
            child: FilledButton(
                onPressed: _load, child: Text(t.qrnRetry)),
          ),
        ],
      );
    }
    final d = _data;
    if (d == null) return const SkeletonList();
    return TabBarView(children: [_surasTab(t, d), _juzTab(t, d), _bookmarksTab(t, d)]);
  }

  Widget _surasTab(AppLocalizations t, QuranData d) {
    final q = _q.text.trim();
    final suras = d.findSuras(q);
    final hits = _hits;
    return ListView(
      key: const Key('quran-suras'),
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
      children: [
        TextField(
          key: const Key('quran-search'),
          controller: _q,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: t.qrnSearchHint,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    tooltip: t.qrnClear,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      _q.clear();
                      _hits = null;
                    }),
                  ),
          ),
          onChanged: (_) => setState(() => _hits = null),
          onSubmitted: (_) => _searchVerses(),
        ),
        const SizedBox(height: Gap.xs),
        Text(t.qrnSearchNote,
            style: AType.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        if (q.isEmpty && _last != null) _continueCard(t, d, _last!),
        // gap-quranblood Q3: "2:255" / Bangla digits -> straight to the verse
        if (d.parseJump(q) case final j?)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: FilledButton.tonalIcon(
              key: const Key('quran-jump'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.subdirectory_arrow_right_rounded),
              label: Text(t.qrnGoTo(quranSuraTitle(_isBn(context), d.suras[j.sura - 1]),
                  ld(context, '${j.sura}:${j.aya}'))),
              onPressed: () => _open(j.sura, j.aya),
            ),
          ),
        if (q.length >= 2 && hits == null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const Key('quran-search-verses'),
              icon: const Icon(Icons.manage_search_rounded),
              label: Text(t.qrnSearchVerses(q)),
              onPressed: _searchVerses,
            ),
          ),
        if (hits != null) ..._hitList(t, d, hits),
        // designv2 (calm): the suras in one quiet card — no glow, no motion
        if (suras.isNotEmpty)
          DsGroup(margin: EdgeInsets.zero, children: [for (final s in suras) _suraTile(t, s)]),
      ],
    );
  }

  List<Widget> _hitList(AppLocalizations t, QuranData d, List<QuranHit> hits) {
    if (hits.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.md),
          child: Text(t.qrnNoResults),
        ),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Text(t.qrnResultsCount(ld(context, hits.length)),
            style: AType.titleSmall.copyWith(fontWeight: FontWeight.w600)),
      ),
      for (final h in hits)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => _open(h.ref.sura, h.ref.aya),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${quranSuraTitle(_isBn(context), d.suras[h.ref.sura - 1])} · '
                    '${t.qrnVerseN(ld(context, '${h.ref.sura}:${h.ref.aya}'))}',
                    style: AType.labelLarge.copyWith(color: _accent(context)),
                  ),
                  const SizedBox(height: Gap.xs),
                  Text(h.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textDirection:
                          h.arabic ? TextDirection.rtl : TextDirection.ltr,
                      style: h.arabic
                          ? const TextStyle(fontFamily: kQvArabicFont, fontSize: 20, height: 1.8)
                          : AType.bodyMedium),
                ],
              ),
            ),
          ),
        ),
      const Divider(height: Gap.xl),
    ];
  }

  Widget _continueCard(AppLocalizations t, QuranData d, AyaRef r) {
    final s = d.suras[r.sura - 1];
    // designv2 (calm): continue reading is the soft hero
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: DsHeroCard(
      key: const Key('quran-continue'),
      padding: EdgeInsets.zero,
      child: ListTile(
        minTileHeight: 56,
        leading: Icon(Icons.auto_stories_rounded, color: _accent(context)),
        title: Text(t.qrnContinue,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${quranSuraTitle(_isBn(context), s)} · ${t.qrnVerseN(ld(context, r.aya))}'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _open(r.sura, r.aya),
      ),
      ),
    );
  }

  Widget _suraTile(AppLocalizations t, QuranSura s) {
    final bn = _isBn(context);
    return ListTile(
      key: Key('quran-sura-${s.index}'),
      minTileHeight: 56,
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
      leading: CircleAvatar(
        backgroundColor: _accent(context).withOpacity(0.12),
        child: FittedBox(
          child: Text(ld(context, s.index),
              style: TextStyle(
                  color: _accent(context), fontWeight: FontWeight.w600)),
        ),
      ),
      title: Text(bn ? quranSuraTitle(true, s) : '${s.tname} — ${s.ename}'),
      subtitle: Text(
          '${s.meccan ? t.qrnMeccan : t.qrnMedinan} · '
          '${t.qrnAyasCount(ld(context, s.ayas))}'),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 110),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(s.nameAr,
              textDirection: TextDirection.rtl,
              style: const TextStyle(fontSize: 20)),
        ),
      ),
      onTap: () => _open(s.index),
    );
  }

  /// gap-quranblood Q4: the 30 paras (juz) — most readers in Bangladesh
  /// read by para. Start points are Tanzil metadata (bundled, verbatim).
  Widget _juzTab(AppLocalizations t, QuranData d) {
    final bn = _isBn(context);
    return ListView(
      key: const Key('quran-juz'),
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
      children: [
        DsGroup(margin: EdgeInsets.zero, children: [
          for (var i = 0; i < d.juzStarts.length; i++)
            ListTile(
              key: Key('quran-juz-${i + 1}'),
              minTileHeight: 56,
              leading: CircleAvatar(
                backgroundColor: _accent(context).withOpacity(0.12),
                child: FittedBox(
                  child: Text(ld(context, i + 1),
                      style: AType.labelLarge.copyWith(color: _accent(context), fontWeight: FontWeight.w600)),
                ),
              ),
              title: Text(t.qrnJuzN(ld(context, i + 1))),
              subtitle: Text(t.qrnJuzStarts(
                  quranSuraTitle(bn, d.suras[d.juzStarts[i].sura - 1]),
                  ld(context, d.juzStarts[i].aya))),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _open(d.juzStarts[i].sura, d.juzStarts[i].aya),
            ),
        ]),
      ],
    );
  }

  Widget _bookmarksTab(AppLocalizations t, QuranData d) {
    if (_bookmarks.isEmpty) {
      return ListView(
        key: const Key('quran-bookmarks-empty'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          // designv2 (calm): drawn illustration, a plain primary button (no glow)
          DsCard(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(children: [
              DsIllustration(icon: Icons.bookmark_add_outlined, color: _accent(context), size: 88),
              const SizedBox(height: Gap.md),
              Text(t.qrnBookmarksEmpty,
                  textAlign: TextAlign.center,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: Gap.sm),
              Text(t.qrnBookmarksEmptyHow, textAlign: TextAlign.center),
              const SizedBox(height: Gap.lg),
              // the big primary button (empty-state rule) — plain, no glow (calm)
              FilledButton.icon(
                icon: const Icon(Icons.menu_book_rounded),
                label: Text(t.qrnStartReading),
                onPressed: () => _open(1),
              ),
            ]),
          ),
        ],
      );
    }
    return ListView(
      key: const Key('quran-bookmarks'),
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
      children: [
        for (final r in _bookmarks)
          if (r.sura <= d.suras.length && r.aya <= d.suras[r.sura - 1].ayas)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.md),
                onTap: () => _open(r.sura, r.aya),
                child: Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          '${quranSuraTitle(_isBn(context), d.suras[r.sura - 1])} · '
                          '${t.qrnVerseN(ld(context, r.aya))}',
                          style: AType.labelLarge
                              .copyWith(color: _accent(context))),
                      const SizedBox(height: Gap.xs),
                      Text(d.ar(r),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textDirection: TextDirection.rtl,
                          style: const TextStyle(fontFamily: kQvArabicFont, fontSize: 20, height: 1.8)),
                    ],
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

/// One sura: Arabic (verbatim, RTL, Amiri Quran) + — gap-quranblood Q1 —
/// the Bangla pronunciation (rule engine, "under review"), the Bangla meaning
/// and the English meaning INLINE under every verse (QuranEnc, verbatim,
/// source + version above). Bangla AND English are shown in either app
/// language (the owner's bilingual rule). Each line can be switched off; the
/// choice is shared with the ayah view (QvPrefs). Offline / source down: the
/// bundled English (Pickthall, public domain) + a retry — never invented text.
class QuranReaderScreen extends StatefulWidget {
  final QuranData data;
  final int sura;
  final int aya;

  /// Test / gallery seam (defaults to the signed-in app API).
  final QuranBilingualApi? api;
  const QuranReaderScreen(
      {super.key, required this.data, required this.sura, this.aya = 1, this.api});
  @override
  State<QuranReaderScreen> createState() => _QuranReaderScreenState();
}

class _QuranReaderScreenState extends State<QuranReaderScreen> {
  late int _from; // first aya shown (jump target); "show earlier" resets to 1
  double _size = QuranPrefs.defaultSize;
  Set<int> _marked = {};
  Set<QvLine> _off = {};
  final _keys = <int, GlobalKey>{};
  final _scroll = ScrollController();
  late final QuranBilingualApi _qv;
  Map<String, dynamic>? _meaning, _pron;
  bool _meaningLoading = true;

  QuranSura get _s => widget.data.suras[widget.sura - 1];

  @override
  void initState() {
    super.initState();
    _from = widget.aya.clamp(1, _s.ayas);
    _qv = widget.api ??
        QuranBilingualApi((p) => context.read<AppState>().api.getJson(p));
    _loadPrefs();
    _loadMeaning();
    QuranPrefs.setLastRead(AyaRef(widget.sura, _from));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final size = await QuranPrefs.arabicSize();
    final bm = await QuranPrefs.bookmarks();
    final off = await QvPrefs.hidden();
    // a reader who chose "Arabic only" earlier keeps it
    final old = await QuranPrefs.translation();
    if (!mounted) return;
    setState(() {
      _size = size;
      _off = old == QuranTrans.none ? {...off, QvLine.bn, QvLine.en} : off;
      _marked = {
        for (final r in bm)
          if (r.sura == widget.sura) r.aya
      };
    });
  }

  Future<void> _loadMeaning() async {
    setState(() => _meaningLoading = true);
    final m = _qv.meaning(widget.sura);
    final p = _qv.pron(widget.sura);
    final mm = await m;
    final pp = await p;
    if (!mounted) return;
    setState(() {
      _meaning = mm;
      _pron = pp;
      _meaningLoading = false;
    });
  }

  bool _on(QvLine l) => !_off.contains(l);

  /// The QuranEnc book for [lang] when it carries this sura's verses.
  Map<String, dynamic>? _book(String lang) {
    final b = _meaning?[lang];
    if (b is! Map<String, dynamic>) return null;
    final items = b['items'];
    return items is List && items.isNotEmpty ? b : null;
  }

  Future<void> _toggle(int aya) async {
    final t = AppLocalizations.of(context);
    final on = await QuranPrefs.toggleBookmark(AyaRef(widget.sura, aya));
    if (!mounted) return;
    setState(() => on ? _marked.add(aya) : _marked.remove(aya));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(on ? t.qrnBookmarked : t.qrnUnbookmarked),
        duration: const Duration(seconds: 2)));
  }

  /// Remember the first verse on screen as "last read" when scrolling stops.
  bool _onScroll(ScrollNotification n) {
    if (n is! ScrollEndNotification) return false;
    final listBox = context.findRenderObject() as RenderBox?;
    if (listBox == null) return false;
    final top = listBox.localToGlobal(Offset.zero).dy + kToolbarHeight;
    int? first;
    _keys.forEach((aya, k) {
      final b = k.currentContext?.findRenderObject() as RenderBox?;
      if (b == null || !b.attached) return;
      final y = b.localToGlobal(Offset.zero).dy;
      if (y + b.size.height > top && (first == null || aya < first!)) {
        first = aya;
      }
    });
    if (first != null) QuranPrefs.setLastRead(AyaRef(widget.sura, first!));
    return false;
  }

  Future<void> _settings() async {
    final t = AppLocalizations.of(context);
    String name(QvLine l) => switch (l) {
          QvLine.pron => t.qvLinePron,
          QvLine.bn => t.qvLineBn,
          _ => t.qvLineEn,
        };
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return ListView(
          shrinkWrap: true,
          padding: withNavBarInset(ctx, const EdgeInsets.all(Gap.lg)),
          children: [
            Text(t.qrnReaderSettings,
                style:
                    AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.xs),
            Text(t.qvLinesHint, style: AType.bodySmall),
            for (final l in const [QvLine.pron, QvLine.bn, QvLine.en])
              SwitchListTile(
                key: Key('quran-line-${l.name}'),
                contentPadding: EdgeInsets.zero,
                title: Text(name(l)),
                value: _on(l),
                onChanged: (v) {
                  setState(() => v ? _off.remove(l) : _off.add(l));
                  setSheet(() {});
                  QvPrefs.setHidden(_off);
                  if (v) QuranPrefs.setTranslation(QuranTrans.bn);
                },
              ),
            const SizedBox(height: Gap.sm),
            Text(t.qrnArabicSize,
                style: AType.labelLarge.copyWith(fontWeight: FontWeight.w600)),
            Slider(
              value: _size,
              min: QuranPrefs.minSize,
              max: QuranPrefs.maxSize,
              divisions: 10,
              label: ld(ctx, _size.round()),
              onChanged: (v) {
                setState(() => _size = v);
                setSheet(() {});
              },
              onChangeEnd: QuranPrefs.setArabicSize,
            ),
            // preview = the first verse, verbatim from the bundled text
            Text(widget.data.ar(const AyaRef(1, 1)),
                textAlign: TextAlign.center,
                textDirection: TextDirection.rtl,
                style: TextStyle(fontFamily: kQvArabicFont, fontSize: _size, height: 1.9)),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = _s;
    final bnApp = _isBn(context);
    final count = s.ayas - _from + 1;
    final header = <Widget>[
      _SuraHeader(sura: s, juz: widget.data.juzOf(AyaRef(s.index, _from))),
      _sourcesCard(t),
      if (_from > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: OutlinedButton.icon(
            key: const Key('quran-show-earlier'),
            icon: const Icon(Icons.vertical_align_top_rounded),
            label: Text(t.qrnShowEarlier),
            onPressed: () => setState(() => _from = 1),
          ),
        ),
    ];
    final next = widget.sura < widget.data.suras.length
        ? widget.data.suras[widget.sura]
        : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(quranSuraTitle(bnApp, s)),
        actions: [
          IconButton(
            key: const Key('quran-settings'),
            tooltip: t.qrnReaderSettings,
            icon: const Icon(Icons.text_fields_rounded),
            onPressed: _settings,
          ),
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ListView.builder(
          key: const Key('quran-reader'),
          controller: _scroll,
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
          itemCount: header.length + count + 1,
          itemBuilder: (c, i) {
            if (i < header.length) return header[i];
            if (i == header.length + count) {
              // gap-quranblood Q5: the end of a sura leads to the next one
              if (next == null) return const SizedBox(height: Gap.lg);
              return Padding(
                padding: const EdgeInsets.only(top: Gap.lg),
                child: FilledButton.tonalIcon(
                  key: const Key('quran-next-sura'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: Text(t.qrnNextSura(quranSuraTitle(bnApp, next))),
                  onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) => QuranReaderScreen(
                          data: widget.data, sura: next.index, api: widget.api))),
                ),
              );
            }
            final aya = _from + i - header.length;
            return _ayaTile(t, aya);
          },
        ),
      ),
    );
  }

  /// Source + version of every line shown (QuranEnc terms), the
  /// pronunciation's "under review" label, or an honest offline line.
  Widget _sourcesCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final muted = AType.labelSmall.copyWith(color: scheme.onSurfaceVariant);
    final lines = <Widget>[];
    if (_meaningLoading) {
      lines.add(const LinearProgressIndicator());
    } else {
      final bn = _book('bn'), en = _book('en');
      String src(Map<String, dynamic> b) =>
          t.qvSourceQe('${b['publisher'] ?? ''}', ld(context, '${b['version'] ?? ''}'));
      if (bn != null && _on(QvLine.bn)) {
        lines.add(Text('${t.qvLineBn} · ${src(bn)}', key: const Key('quran-src-bn'), style: muted));
      }
      if (_on(QvLine.en)) {
        lines.add(Text(en != null ? '${t.qvLineEn} · ${src(en)}' : t.qrnEnOffline,
            key: const Key('quran-src-en'), style: muted));
      }
      if (_hasPron && _on(QvLine.pron)) {
        lines.add(Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QvReviewChip(label: t.qvUnderReview),
              Text(t.qvSourcePron, style: muted),
            ]));
      }
      if (bn == null && (_on(QvLine.bn) || _on(QvLine.en))) {
        lines.add(Row(key: const Key('quran-meaning-retry'), children: [
          Expanded(child: Text(t.qrnMeaningOffline, style: AType.bodySmall)),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _loadMeaning,
            child: Text(t.qrnRetry),
          ),
        ]));
      }
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('quran-sources'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final w in lines)
          Padding(padding: const EdgeInsets.only(bottom: Gap.xxs), child: w),
      ]),
    );
  }

  bool get _hasPron {
    final items = _pron?['items'];
    return items is List && items.isNotEmpty;
  }

  // quranview
  void _openAyah(int aya) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          AyahViewScreen(data: widget.data, sura: widget.sura, aya: aya, api: widget.api)));

  Widget _ayaTile(AppLocalizations t, int aya) {
    final ref = AyaRef(widget.sura, aya);
    final marked = _marked.contains(aya);
    final scheme = Theme.of(context).colorScheme;
    final bnBook = _book('bn'), enBook = _book('en');
    final pron = qvItem(_pron, aya);
    final pronText = pron == null || pron['review'] == 'rejected'
        ? ''
        : '${pron['bn'] ?? ''}';
    final bnText = '${qvItem(bnBook, aya)?['text'] ?? ''}';
    // English: QuranEnc (Saheeh) when live, else the bundled Pickthall
    final enText = enBook != null
        ? '${qvItem(enBook, aya)?['text'] ?? ''}'
        : widget.data.en(ref);
    return Container(
      key: _keys.putIfAbsent(aya, () => GlobalKey()),
      padding: const EdgeInsets.symmetric(vertical: Gap.md),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm, vertical: Gap.xxs),
              decoration: BoxDecoration(
                color: _accent(context).withOpacity(0.10),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(ld(context, '${widget.sura}:$aya'),
                  style: AType.labelMedium.copyWith(color: _accent(context))),
            ),
            const Spacer(),
            // quranview: bilingual ayah view (meaning, tafsir, audio)
            IconButton(
              key: Key('quran-ayah-$aya'),
              tooltip: t.qvOpenAyah(ld(context, aya)),
              icon: const Icon(Icons.auto_stories_rounded),
              onPressed: () => _openAyah(aya),
            ),
            IconButton(
              key: Key('quran-bm-$aya'),
              tooltip: marked
                  ? t.qrnBookmarkRemove(ld(context, aya))
                  : t.qrnBookmarkAdd(ld(context, aya)),
              icon: Icon(marked
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded),
              color: marked ? _accent(context) : null,
              onPressed: () => _toggle(aya),
            ),
          ]),
          InkWell(
            onTap: () => _openAyah(aya),
            // Amiri's marks reach below the line box: keep the next line clear
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(widget.data.ar(ref),
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                style: TextStyle(fontFamily: kQvArabicFont, fontSize: _size, height: 1.9)),
            ),
          ),
          if (_on(QvLine.pron) && pronText.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            // bn keeps its ZWNJ marks as sent — never stripped
            Text(pronText,
                key: Key('quran-pron-$aya'),
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          ],
          if (_on(QvLine.bn) && bnText.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(bnText, key: Key('quran-bn-$aya'), style: AType.bodyLarge),
          ],
          if (_on(QvLine.en) && enText.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(enText,
                key: Key('quran-en-$aya'),
                textDirection: TextDirection.ltr,
                style: AType.bodyLarge),
          ],
        ],
      ),
    );
  }
}

class _SuraHeader extends StatelessWidget {
  final QuranSura sura;
  final int juz;
  const _SuraHeader({required this.sura, required this.juz});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.07),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.primary.withOpacity(0.25)),
      ),
      child: Column(children: [
        Text(sura.nameAr,
            textDirection: TextDirection.rtl,
            style: const TextStyle(fontFamily: kQvArabicFont, fontSize: 30, height: 1.6)),
        const SizedBox(height: Gap.xs),
        Text(
          '${quranSuraTitle(_isBn(context), sura)} · ${sura.meccan ? t.qrnMeccan : t.qrnMedinan} · '
          '${t.qrnAyasCount(ld(context, sura.ayas))} · '
          '${t.qrnJuzN(ld(context, juz))}',
          textAlign: TextAlign.center,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

/// Source & licence: what we ship, under which terms, and the Tanzil notice
/// reproduced verbatim (CC BY 3.0 attribution requirement).
class QuranAboutScreen extends StatelessWidget {
  final String? notice;
  const QuranAboutScreen({super.key, this.notice});

  static final Uri tanzil = Uri.parse('https://tanzil.net');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget item(IconData i, String s) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 22, color: _accent(context)),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(s)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: Text(t.qrnAbout)),
      body: ListView(
        key: const Key('quran-about-body'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          item(Icons.menu_book_rounded, t.qrnAboutArabic),
          item(Icons.translate_rounded, t.qrnAboutEnglish),
          // quranview: Bangla + English meaning, tafsir (QuranEnc), audio +
          // word-by-word (Quran Foundation) — credits required by both.
          item(Icons.translate_rounded, t.qvAboutQe),
          item(Icons.headphones_rounded, t.qvQfCredit),
          item(Icons.hourglass_top_rounded, t.qvTafsirPendingNote),
          item(Icons.verified_user_rounded, t.qvNoAi),
          item(Icons.wifi_off_rounded, t.qrnOffline),
          item(Icons.update_rounded, t.qrnAboutUpdates),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(t.qrnOpenTanzil),
              onPressed: () async {
                try {
                  await launchUrl(tanzil, mode: LaunchMode.externalApplication);
                } catch (_) {
                  // best-effort: no browser app; tanzil.net is written above
                }
              },
            ),
          ),
          if ((notice ?? '').isNotEmpty) ...[
            const Divider(height: Gap.xl),
            Text(t.qrnNoticeTitle,
                style: AType.titleSmall.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.sm),
            SelectableText(notice!,
                textDirection: TextDirection.ltr, style: AType.bodySmall),
          ],
        ],
      ),
    );
  }
}
