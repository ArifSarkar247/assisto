// p3faith: small seams for other features (e.g. agent/quranread "Learn to
// read Quran"). Text = the bundled Tanzil file, VERBATIM (CC BY 3.0: show
// "Tanzil Project" + a tanzil.net link wherever it is displayed — reuse
// QuranAboutScreen). Riwayah: Hafs 'an 'Asim (Tanzil follows the Medina
// mushaf). The bundled edition is "Simple"; Tanzil's "Uthmani" edition is
// under the same CC BY 3.0 terms and can be added as a second asset later.
// Licence notes: assets/quran/SOURCES.txt, owner_actions/FEATURE_CARD_QURAN_BN.md.
import 'quran_store.dart';

/// Arabic text of [surah]:[ayah] (verbatim), or null when out of range.
Future<String?> quranText(int surah, int ayah) async {
  if (surah < 1 || surah > 114 || ayah < 1) return null;
  final d = await QuranStore.load();
  if (ayah > d.suras[surah - 1].ayas) return null;
  return d.ar(AyaRef(surah, ayah));
}

/// English meaning (Pickthall 1930, public domain) or null.
Future<String?> quranMeaningEn(int surah, int ayah) async {
  if (surah < 1 || surah > 114 || ayah < 1) return null;
  final d = await QuranStore.load();
  if (ayah > d.suras[surah - 1].ayas) return null;
  return d.en(AyaRef(surah, ayah));
}

/// A reciter whose audio we may redistribute (written/open licence on file).
class QuranReciter {
  final String id, name, licence, sourceUrl;
  const QuranReciter(this.id, this.name, this.licence, this.sourceUrl);
}

/// Reciters with a VERIFIED redistribution licence. Empty today: no
/// recitation licence has been verified (owner action in
/// FEATURE_CARD_QURAN_BN.md section 6). Add an entry only with proof.
const List<QuranReciter> kLicensedReciters = [];

/// Audio URL for [surah]:[ayah] by [reciterId], or null when no licensed
/// reciter exists (callers must hide audio UI on null — never a dead button).
Future<Uri?> reciterAudio(int surah, int ayah, {String? reciterId}) async {
  if (kLicensedReciters.isEmpty) return null;
  return null; // seam: wire the licensed source here once one is on file
}
