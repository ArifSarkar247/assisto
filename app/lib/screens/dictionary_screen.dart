import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Dictionary bn<->en (module-5 "Life"). Benchmarked vs offline dictionary apps.
///
/// LICENSING: the backend ships ONLY a tiny open/hand-written sample of common
/// words and NEVER proprietary data (no Bangla Academy). When a word misses the
/// sample, the backend returns a `needs_data` flag and we show the honest state
/// "Available when open dictionary data is added" instead of faking a result.
///
/// Direction auto-detects from the query's script (Bengali -> bn2en). Results
/// come from the backend `/dictionary/lookup` endpoint (mirrors
/// core.logic.dictionary.lookup). No definitions are ever fabricated client-side.
class DictionaryScreen extends StatefulWidget {
  const DictionaryScreen({super.key});
  @override
  State<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends State<DictionaryScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  Map<String, dynamic>? _result;
  bool _loading = false;
  String _direction = 'auto';

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() => _result = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _lookup(v.trim()));
  }

  Future<void> _lookup(String q) async {
    setState(() => _loading = true);
    try {
      final r = await context.read<AppState>().api.getJson(
          '/dictionary/lookup?q=${Uri.encodeQueryComponent(q)}&direction=$_direction');
      if (mounted) setState(() => _result = r);
    } catch (_) {
      if (mounted) setState(() => _result = null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.dictionaryTitle)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t.dictionarySearchHint,
                suffixIcon: _ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _ctrl.clear();
                          setState(() => _result = null);
                        },
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: Gap.sm),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'auto', label: Text(t.dictionaryDirAuto)),
                ButtonSegment(value: 'bn2en', label: Text(t.dictionaryDirBnEn)),
                ButtonSegment(value: 'en2bn', label: Text(t.dictionaryDirEnBn)),
              ],
              selected: {_direction},
              onSelectionChanged: (s) {
                setState(() => _direction = s.first);
                if (_ctrl.text.trim().isNotEmpty) _lookup(_ctrl.text.trim());
              },
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: _body(t)),
      ]),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final r = _result;
    if (r == null) {
      return _Intro(t: t);
    }
    // Honest needs-data state (open-license dictionary not yet wired).
    if (r['needs_data'] == true) {
      return _NeedsData(t: t, isSample: r['is_sample'] == true);
    }
    final results = ((r['results'] ?? []) as List).cast<Map<String, dynamic>>();
    if (results.isEmpty) {
      return _NotFound(t: t, query: '${r['query'] ?? ''}');
    }
    final source = '${r['source'] ?? ''}';
    final sample = r['is_sample'] == true;
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        for (final e in results) _entryCard(e),
        const SizedBox(height: Gap.md),
        Text(
          sample ? t.dictionarySampleNote : t.dictionarySourceNote(source),
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _entryCard(Map<String, dynamic> e) {
    final pos = '${e['pos'] ?? ''}';
    final example = '${e['example'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${e['bn']}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
            const Icon(Icons.swap_horiz, size: 18, color: Colors.grey),
            Expanded(
              child: Text('${e['en']}',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
          ]),
          if (pos.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(pos, style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic)),
          ],
          if (example.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(example, style: const TextStyle(fontSize: 13)),
          ],
        ]),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  final AppLocalizations t;
  const _Intro({required this.t});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.menu_book_outlined, size: 56, color: Colors.grey),
          const SizedBox(height: Gap.md),
          Text(t.dictionaryIntroTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: Gap.xs),
          Text(t.dictionaryIntroBody,
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
        ]),
      ),
    );
  }
}

class _NeedsData extends StatelessWidget {
  final AppLocalizations t;
  final bool isSample;
  const _NeedsData({required this.t, required this.isSample});
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
              color: Brand.warning.withOpacity(0.12),
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

class _NotFound extends StatelessWidget {
  final AppLocalizations t;
  final String query;
  const _NotFound({required this.t, required this.query});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.search_off, size: 48, color: Colors.grey),
          const SizedBox(height: Gap.md),
          Text(t.dictionaryNotFound(query), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
