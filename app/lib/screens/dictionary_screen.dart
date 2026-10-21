import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/dict_store.dart';
import '../widgets/dict_entry_card.dart';
import '../widgets/dict_extras.dart';

/// Dictionary bn<->en (module-5 "Life") — ADVANCED (feature 39, SPEC v2.1 §21).
///
/// LICENSING (STRICT): the backend ships ONLY a tiny open/hand-written sample of
/// common words and NEVER proprietary data (no Bangla Academy / no copyrighted
/// dictionary). A real dictionary appears only when an OPEN-LICENSE dataset is
/// wired server-side via dictionary.load_dataset(). When a word misses the
/// sample, the backend returns `needs_data` and we show the honest
/// "available when open dictionary data is added" state — never a faked result.
///
/// Advanced surface (all Section-21 states designed): bn->en + en->bn (auto),
/// word of the day, search history, recently searched, favourites/saved words,
/// parts of speech, example sentences, synonyms/antonyms, pronunciation note,
/// copy/share, and an OFFLINE cache of looked-up words (served when the network
/// is down). ALL rendered Bangla is backend open-license DATA; chrome is ARB.
class DictionaryScreen extends StatefulWidget {
  const DictionaryScreen({super.key});
  @override
  State<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends State<DictionaryScreen>
    with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  final _store = DictStore();
  late final TabController _tabs;
  Timer? _debounce;

  // search tab state
  Map<String, dynamic>? _result;
  bool _loading = false;
  bool _error = false;
  bool _offline = false; // last lookup was served from the offline cache
  List<DictEntry> _suggestions = [];
  DictEntry? _wotd;
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _loadLocal();
    _primeWordOfTheDay();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    final h = await _store.history();
    if (mounted) setState(() => _history = h);
  }

  /// Fetch word-of-the-day via the single allowed endpoint (empty query carries
  /// it); fall back silently offline.
  Future<void> _primeWordOfTheDay() async {
    try {
      final r = await context.read<AppState>().api.getJson('/dictionary/lookup?q=&direction=auto');
      final w = (r['word_of_the_day'] as Map?)?.cast<String, dynamic>();
      if (w != null && mounted) setState(() => _wotd = DictEntry.fromJson(w));
    } catch (_) {/* offline — intro still works without word of the day */}
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _result = null;
        _error = false;
        _offline = false;
        _suggestions = [];
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _lookup(v.trim()));
  }

  void _submit(String q) {
    q = q.trim();
    if (q.isEmpty) return;
    _ctrl.text = q;
    _ctrl.selection = TextSelection.collapsed(offset: q.length);
    _debounce?.cancel();
    _lookup(q);
  }

  Future<void> _lookup(String q) async {
    setState(() {
      _loading = true;
      _error = false;
      _offline = false;
    });
    final api = context.read<AppState>().api;
    final dir = _directionValue;
    try {
      final r = await api.getJson(
          '/dictionary/lookup?q=${Uri.encodeQueryComponent(q)}&direction=$dir');
      if (!mounted) return;
      final results = _entriesFrom(r['results']);
      // persist for offline + history
      await _store.cacheResults(q, results);
      _history = await _store.pushHistory(q);
      setState(() {
        _result = r;
        _suggestions = _entriesFrom(r['suggestions']);
        _loading = false;
      });
    } on ApiException {
      // server replied with an error status — show the retryable error state
      if (mounted) setState(() {
            _result = null;
            _error = true;
            _loading = false;
          });
    } catch (_) {
      // network down → fall back to the offline cache of looked-up words
      await _offlineFallback(q);
    }
  }

  Future<void> _offlineFallback(String q) async {
    final cached = await _store.cachedFor(q);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _offline = true;
      if (cached.isEmpty) {
        _result = null; // offline-no-cache state rendered by _searchBody
        _suggestions = [];
      } else {
        _result = {
          'results': cached.map((e) => e.toJson()).toList(),
          'offline': true,
        };
        _suggestions = [];
      }
    });
  }

  List<DictEntry> _entriesFrom(dynamic raw) => (raw is List)
      ? raw
          .whereType<Map>()
          .map((e) => DictEntry.fromJson(e.cast<String, dynamic>()))
          .toList()
      : <DictEntry>[];

  String _directionValue = 'auto';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.dictionaryTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: t.dictTabSearch),
            Tab(text: t.dictTabSaved),
            Tab(text: t.dictTabHistory),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _searchTab(t),
          _savedTab(t),
          _historyTab(t),
        ],
      ),
    );
  }

  // ----- SEARCH TAB -------------------------------------------------------
  Widget _searchTab(AppLocalizations t) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: _submit,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: t.dictionarySearchHint,
              suffixIcon: _ctrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                      onPressed: () {
                        _ctrl.clear();
                        _onChanged('');
                      },
                    ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: Gap.sm),
          // segment labels cap at 1.2x: never a mid-word break at large font
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.2,
            child: SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'auto', label: Text(t.dictionaryDirAuto)),
              ButtonSegment(value: 'bn2en', label: Text(t.dictionaryDirBnEn)),
              ButtonSegment(value: 'en2bn', label: Text(t.dictionaryDirEnBn)),
            ],
            selected: {_directionValue},
            onSelectionChanged: (s) {
              setState(() => _directionValue = s.first);
              if (_ctrl.text.trim().isNotEmpty) _lookup(_ctrl.text.trim());
            },
          ),
          ),
        ]),
      ),
      if (_offline && _result != null)
        DictOfflineBanner(text: t.dictOfflineBannerCached),
      const Divider(height: 1),
      Expanded(child: _searchBody(t)),
    ]);
  }

  Widget _searchBody(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error) {
      return DictStateView(
        icon: Icons.error_outline,
        iconColor: Brand.danger,
        title: t.dictErrorTitle,
        body: t.dictErrorBody,
        actionLabel: t.dictRetry,
        onAction: () => _submit(_ctrl.text),
      );
    }
    final r = _result;
    if (r == null) {
      // empty query → intro (word of the day + recent searches), OR offline-no-cache
      if (_offline) {
        return DictStateView(
          icon: Icons.cloud_off,
          iconColor: Brand.warning,
          title: t.dictOfflineNoCache,
          body: t.dictOfflineNoCacheBody,
          actionLabel: t.dictRetry,
          onAction: () => _submit(_ctrl.text),
        );
      }
      return _intro(t);
    }
    if (r['needs_data'] == true) return _NeedsData(t: t);
    final results = _entriesFrom(r['results']);
    if (results.isEmpty) {
      return DictStateView(
        icon: Icons.search_off,
        title: t.dictionaryNotFound('${r['query'] ?? _ctrl.text}'),
      );
    }
    final sample = r['is_sample'] == true;
    final source = '${r['source'] ?? ''}';
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        for (final e in results) DictEntryCard(entry: e, store: _store),
        if (_suggestions.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          DictChipRow(
            title: t.dictSuggestions,
            icon: Icons.lightbulb_outline,
            words: _suggestions
                .map((e) => _directionValue == 'bn2en' || (_directionValue == 'auto' && e.bn.isNotEmpty && !_isAscii(_ctrl.text))
                    ? e.bn
                    : e.en)
                .where((w) => w.isNotEmpty)
                .toSet()
                .toList(),
            onTap: _submit,
          ),
        ],
        const SizedBox(height: Gap.md),
        _sourceFooter(t, sample: sample, source: source),
      ],
    );
  }

  Widget _intro(AppLocalizations t) {
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        if (_wotd != null && !_wotd!.isEmpty) ...[
          DictWordOfTheDayCard(entry: _wotd!, onOpen: _submit),
          const SizedBox(height: Gap.lg),
        ],
        DictChipRow(
          title: t.dictRecentlySearched,
          icon: Icons.history,
          words: _history.take(12).toList(),
          onTap: _submit,
          onClear: _history.isEmpty ? null : () async {
            await _store.clearHistory();
            await _loadLocal();
          },
          clearLabel: _history.isEmpty ? null : t.dictClearHistory,
        ),
        if (_history.isEmpty) ...[
          const SizedBox(height: Gap.xl),
          Icon(Icons.menu_book_outlined, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: Gap.sm),
          Text(t.dictionaryIntroTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: Gap.xs),
          Text(t.dictionaryIntroBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }

  Widget _sourceFooter(AppLocalizations t, {required bool sample, required String source}) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(sample ? t.dictSampleBadge : t.dictOpenLicenceBadge,
            style: TextStyle(fontSize: 10, color: cs.onSecondaryContainer)),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          sample ? t.dictionarySampleNote : t.dictionarySourceNote(source),
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ),
    ]);
  }

  bool _isAscii(String s) => s.runes.every((r) => r < 128);

  // ----- SAVED TAB --------------------------------------------------------
  Widget _savedTab(AppLocalizations t) {
    return FutureBuilder<List<DictEntry>>(
      // rebuild each time the tab is shown so toggles elsewhere reflect here
      future: _store.saved(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final saved = snap.data ?? [];
        if (saved.isEmpty) {
          return DictStateView(
            icon: Icons.star_border,
            title: t.dictSavedEmptyTitle,
            body: t.dictSavedEmptyBody,
          );
        }
        return ListView(
          padding: const EdgeInsets.all(Gap.md),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(t.dictSavedCount(saved.length),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            for (final e in saved)
              DictEntryCard(
                key: ValueKey('saved_${e.key}'),
                entry: e,
                store: _store,
              ),
          ],
        );
      },
    );
  }

  // ----- HISTORY TAB ------------------------------------------------------
  Widget _historyTab(AppLocalizations t) {
    if (_history.isEmpty) {
      return DictStateView(
        icon: Icons.history,
        title: t.dictHistoryEmptyTitle,
        body: t.dictHistoryEmptyBody,
      );
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
        child: Row(children: [
          Expanded(
            child: Text(t.dictSearchHistory,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          TextButton.icon(
            onPressed: () async {
              await _store.clearHistory();
              await _loadLocal();
            },
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(t.dictClearHistory),
          ),
        ]),
      ),
      Expanded(
        child: ListView.separated(
          itemCount: _history.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final w = _history[i];
            return ListTile(
              leading: const Icon(Icons.history),
              title: Text(w),
              trailing: const Icon(Icons.north_west, size: 16),
              onTap: () {
                _tabs.animateTo(0);
                _submit(w);
              },
            );
          },
        ),
      ),
    ]);
  }
}

/// Honest needs-data state (open-license dictionary not yet wired server-side).
class _NeedsData extends StatelessWidget {
  final AppLocalizations t;
  const _NeedsData({required this.t});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.hourglass_empty, size: 48, color: Color(0xFF8A6D00)),
          const SizedBox(height: Gap.md),
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: Brand.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              t.dictionaryNeedsOpenData,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF8A6D00)),
            ),
          ),
          const SizedBox(height: Gap.md),
          Text(t.dictionarySampleNote,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      ),
    );
  }
}
