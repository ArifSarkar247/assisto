// quranread (owner order 3 Nov 11:45, part B): data types for "Learn to read
// Quran". The lessons themselves (our OWN text, Noorani-method ORDER only, no
// book pages copied) live in lib/l10n/quran_learn_content.dart because they
// carry Bangla text (the lang gate allows Bangla script only under l10n/).
//
// Quran words / ayat are NEVER typed into the lessons: an item points at a
// sura:ayah (+ word range) and the text is read from the bundled, verbatim
// Tanzil Uthmani file (CC BY 3.0) by UthmaniText.

/// A text in both app languages.
class QlText {
  final String bn, en;
  const QlText(this.bn, this.en);
  String of(bool bangla) => bangla ? bn : en;
}

/// A place in the Quran: sura:ayah, optionally words [from]..[to] (0-based,
/// inclusive, split on spaces of the Tanzil line).
class QlRef {
  final int sura, ayah;
  final int? from, to;
  const QlRef(this.sura, this.ayah, [this.from, this.to]);

  /// "112:1" or "112:1 (5-8)" in ASCII digits (callers localise digits).
  String label() {
    final f = from, t = to;
    if (f == null || t == null) return '$sura:$ayah';
    return t == f ? '$sura:$ayah (${f + 1})' : '$sura:$ayah (${f + 1}-${t + 1})';
  }
}

/// One thing to learn: an Arabic drill ([ar], our own) or a Quran [ref].
class QlItem {
  final String id;

  /// Drill text written by us (letters, syllables). Null for Quran refs.
  final String? ar;

  /// Quran words / ayah, read from the bundled Tanzil Uthmani text.
  final QlRef? ref;

  /// Approximate pronunciation helper (Bangla script / Latin).
  final QlText? say;

  /// Explanation: makhraj for letters, the rule for tajweed examples.
  final QlText? note;

  /// What the learner says for the recitation helper when it differs from
  /// the shown text (a letter is read by its NAME: ب -> باء).
  final String? check;

  /// A heavy (full-mouth, tafkhim) letter.
  final bool heavy;

  const QlItem(this.id,
      {this.ar, this.ref, this.say, this.note, this.check, this.heavy = false});
}

class QlLesson {
  final String id;
  final QlText title;
  final QlText intro;
  final List<QlItem> items;

  /// Short drills shown as a big tappable grid; long items (ayat) as a list.
  final bool grid;
  const QlLesson(this.id, this.title, this.intro, this.items, {this.grid = true});
}

/// The two courses a certificate can name (agent/learncert).
const kCourseQaida = 'quran_qaida';
const kCourseNazera = 'quran_nazera';

class QlStage {
  final int n;
  final String course;
  final QlText title;
  final QlText summary;
  final List<QlLesson> lessons;
  const QlStage(this.n, this.course, this.title, this.summary, this.lessons);
}
