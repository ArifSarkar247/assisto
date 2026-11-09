// quranshikhi (owner order 9 Nov 21:55, lane 16): the Quran Shikhi letter
// lesson pieces.
//  * Bangla AND English shown together (the owner's one exception to strict
//    language separation); the learner can hide either line (never both).
//  * The four letter forms (alone / start / middle / end) built from the
//    letter + tatweel - our own drill, never Quran text.
//  * "Under review" mark on every explanation until an alem / qari approves.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/quran_shikhi_text.dart';
import '../theme.dart';
import '../widgets/local_digits.dart' show toLocalDigits;
import 'qaida_model.dart';
import 'recite_sheet.dart' show qlArabic;

// ------------------------------------------------------------ line toggles
/// Which explanation lines are visible. Both on by default.
class QsLines {
  final bool bn, en;
  const QsLines({this.bn = true, this.en = true});
}

class QsLinePrefs {
  static const prefsKey = 'qs_lines_v1';
  static final ValueNotifier<QsLines> lines = ValueNotifier(const QsLines());
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(prefsKey);
      if (v == 'bn') lines.value = const QsLines(en: false);
      if (v == 'en') lines.value = const QsLines(bn: false);
    } catch (_) {/* defaults: both lines */}
  }

  /// Turn one line on/off. The last visible line can not be hidden.
  static Future<void> toggle({required bool bangla}) async {
    final c = lines.value;
    final next = bangla
        ? QsLines(bn: !c.bn, en: c.en)
        : QsLines(bn: c.bn, en: !c.en);
    if (!next.bn && !next.en) return;
    lines.value = next;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(prefsKey, next.bn && next.en ? 'both' : (next.bn ? 'bn' : 'en'));
    } catch (_) {}
  }

  /// Tests: forget the loaded state.
  static void debugReset() {
    _loaded = false;
    lines.value = const QsLines();
  }
}

bool _appBn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// Two chips (Bangla, English) - show or hide that line.
class QsLineToggles extends StatelessWidget {
  const QsLineToggles({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<QsLines>(
      valueListenable: QsLinePrefs.lines,
      builder: (context, l, _) => Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.xs,
        children: [
          FilterChip(
            key: const Key('qs-line-bn'),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            label: const Text(kQsLineBn),
            selected: l.bn,
            onSelected: (_) => QsLinePrefs.toggle(bangla: true),
          ),
          FilterChip(
            key: const Key('qs-line-en'),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            label: const Text(kQsLineEn),
            selected: l.en,
            onSelected: (_) => QsLinePrefs.toggle(bangla: false),
          ),
        ],
      ),
    );
  }
}

/// A text in Bangla and English together. The app language comes first;
/// the other line is a little lighter. In the Bangla app the English line
/// uses Bangla digits too (owner rule).
class QsBilingual extends StatelessWidget {
  final QlText text;
  final TextStyle style;
  final TextAlign align;
  final String keyPrefix;
  const QsBilingual(this.text,
      {super.key, required this.style, this.align = TextAlign.start, this.keyPrefix = 'qs'});

  @override
  Widget build(BuildContext context) {
    final appBn = _appBn(context);
    final muted = AssistoTokens.of(context).textMuted;
    return ValueListenableBuilder<QsLines>(
      valueListenable: QsLinePrefs.lines,
      builder: (context, l, _) {
        final bnLine = l.bn
            ? Text(text.bn,
                key: Key('$keyPrefix-bn'),
                textAlign: align,
                locale: const Locale('bn'),
                style: appBn ? style : style.copyWith(color: muted))
            : null;
        final enLine = l.en
            ? Text(appBn ? toLocalDigits(text.en, true) : text.en,
                key: Key('$keyPrefix-en'),
                textAlign: align,
                locale: const Locale('en'),
                style: appBn ? style.copyWith(color: muted) : style)
            : null;
        final lines = appBn ? [bnLine, enLine] : [enLine, bnLine];
        return Column(
          crossAxisAlignment: align == TextAlign.center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.stretch,
          children: [
            for (final w in lines)
              if (w != null) w,
          ],
        );
      },
    );
  }
}

/// "Under review by an alem / qari" - on every explanation we wrote.
class QsUnderReview extends StatelessWidget {
  const QsUnderReview({super.key});

  @override
  Widget build(BuildContext context) {
    final tok = AssistoTokens.of(context);
    return Semantics(
      container: true,
      child: Container(
        key: const Key('qs-under-review'),
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(
            color: tok.warningContainer, borderRadius: BorderRadius.circular(Radii.md)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.rate_review_outlined, size: 16, color: tok.onWarningContainer),
          ),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: QsBilingual(kQsUnderReview,
                keyPrefix: 'qs-review',
                style: AType.bodySmall.copyWith(color: tok.onWarningContainer)),
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------ letter forms
const _tatweel = 'ـ';

/// Letters that join the letter before them but never the one after.
const kQsNonLeftJoining = {'ا', 'د', 'ذ', 'ر', 'ز', 'و'};

/// A single Arabic letter of the alphabet lesson (not a drill or a Quran ref).
bool qsIsLetter(QlItem i) =>
    i.ref == null && i.ar != null && i.ar!.runes.length == 1 && i.check != null;

/// The forms of [ch] in reading order (right to left): alone, start, middle,
/// end. Non-joining letters have two (alone, end); hamza has one.
List<(QlText, String)> qsLetterForms(String ch) {
  if (ch == 'ء') return [(kQsIsolated, ch)];
  if (kQsNonLeftJoining.contains(ch)) {
    return [(kQsIsolated, ch), (kQsFinal, '$_tatweel$ch')];
  }
  return [
    (kQsIsolated, ch),
    (kQsInitial, '$ch$_tatweel'),
    (kQsMedial, '$_tatweel$ch$_tatweel'),
    (kQsFinal, '$_tatweel$ch'),
  ];
}

class QsLetterForms extends StatelessWidget {
  final String letter;
  const QsLetterForms(this.letter, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final forms = qsLetterForms(letter);
    return Column(
      key: const Key('qs-forms'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        QsBilingual(kQsForms,
            keyPrefix: 'qs-forms-title',
            style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Wrap(
          textDirection: TextDirection.rtl,
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          children: [
            for (var k = 0; k < forms.length; k++)
              Container(
                key: Key('qs-form-$k'),
                width: 76,
                padding: const EdgeInsets.all(Gap.xs),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Column(children: [
                  Text(forms[k].$2,
                      textDirection: TextDirection.rtl,
                      style: qlArabic(34, color: cs.onSurface)),
                  QsBilingual(forms[k].$1,
                      keyPrefix: 'qs-form-label',
                      align: TextAlign.center,
                      style: AType.labelSmall),
                ]),
              ),
          ],
        ),
        if (forms.length < 4) ...[
          const SizedBox(height: Gap.xs),
          QsBilingual(forms.length == 1 ? kQsNoJoin : kQsNoLeftJoin,
              keyPrefix: 'qs-forms-note', style: AType.bodySmall),
        ],
      ],
    );
  }
}

/// The streak chip for the lesson header (0 = hidden).
class QsStreakChip extends StatelessWidget {
  final int days;
  final String label;
  const QsStreakChip({super.key, required this.days, required this.label});

  @override
  Widget build(BuildContext context) {
    if (days <= 0) return const SizedBox.shrink();
    return Chip(
      key: const Key('qs-streak'),
      avatar: Icon(Icons.local_fire_department_rounded,
          size: 18, color: AssistoTokens.of(context).warning),
      label: Text(label),
    );
  }
}
