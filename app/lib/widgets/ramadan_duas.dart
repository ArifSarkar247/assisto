import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Source-noted Ramadan duas. Authentic texts only, each with its collection
/// reference (shown to the user). The Arabic is kept VERBATIM as data (Arabic
/// is allowed as data in source); titles and meanings are localised via l10n
/// (so no Bangla glyphs live in this file). This is a reference, not a ruling —
/// we present the hadith source and never claim religious authority.
/// Mirrors `core.logic.ramadan.DUAS` (same texts + same sources).
class RamadanDuas extends StatelessWidget {
  const RamadanDuas({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final duas = <_Dua>[
      _Dua(
        title: t.ramadanDuaSehriTitle,
        arabic: 'وَبِصَوْمِ غَدٍ نَّوَيْتُ مِنْ شَهْرِ رَمَضَانَ',
        meaning: t.ramadanDuaSehriMeaning,
        source: 'Sunan Abi Dawud 2454',
      ),
      _Dua(
        title: t.ramadanDuaIftarTitle,
        arabic:
            'ذَهَبَ الظَّمَأُ وَابْتَلَّتِ الْعُرُوقُ وَثَبَتَ الْأَجْرُ إِنْ شَاءَ اللَّهُ',
        meaning: t.ramadanDuaIftarMeaning,
        source: 'Sunan Abi Dawud 2357 (Hasan)',
      ),
      _Dua(
        title: t.ramadanDuaQadrTitle,
        arabic: 'اللَّهُمَّ إِنَّكَ عَفُوٌّ تُحِبُّ الْعَفْوَ فَاعْفُ عَنِّي',
        meaning: t.ramadanDuaQadrMeaning,
        source: 'Sunan al-Tirmidhi 3513 (Sahih)',
      ),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.menu_book_outlined, color: Brand.purple),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.ramadanDuasTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.ramadanDuasSourceNote,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          ...duas.map((d) => _tile(context, d)),
        ]),
      ),
    );
  }

  Widget _tile(BuildContext context, _Dua d) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(d.title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        // Arabic — right-to-left, larger, as data (verbatim scripture text).
        Directionality(
          textDirection: TextDirection.rtl,
          child: Text(d.arabic,
              style: const TextStyle(fontSize: 20, height: 1.8)),
        ),
        const SizedBox(height: 4),
        Text(d.meaning, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 2),
        Text('— ${d.source}',
            style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontStyle: FontStyle.italic)),
      ]),
    );
  }
}

class _Dua {
  final String title;
  final String arabic;
  final String meaning;
  final String source;
  _Dua(
      {required this.title,
      required this.arabic,
      required this.meaning,
      required this.source});
}
