// quranread: audio for the lessons - HONESTLY EMPTY today.
//
// Licence check (3 Nov 2026, FEATURE_CARD_QURAN_READING_BN.md section 3):
//  * EveryAyah.com states no licence -> not used.
//  * QuranicAudio.com: "personal use", "you may not use these files for
//    commercial purposes" -> not used (Assisto is commercial).
//  * No openly licensed letter-by-letter (Qaida) recording was confirmed.
//    Lead: Qamar Apps says "All Qamar Apps publications are licensed under
//    CC BY-SA 4.0" - whether their Noorani Qaida AUDIO is included is not
//    written; owner action: confirm in writing before use.
//  * Machine voice (TTS) for Quran letters/ayat: NEVER (wrong pronunciation
//    would be taught; respect).
//
// To add a commissioned / licensed recording: put the files under
// assets/quran_learn/audio/<item id>.m4a, list the reciter + licence here,
// play them through VoicePlayer (registered with AudioRouteService), and
// flip [qaidaAudioAvailable]. Until then the "Listen" button explains why
// there is no audio - it never plays a fake sound.
import 'qaida_model.dart';

class QaidaRecording {
  final String reciter, licence, source;
  const QaidaRecording(this.reciter, this.licence, this.source);
}

/// The licensed Qaida recording on file. None yet.
const QaidaRecording? kQaidaRecording = null;

/// Whether a licensed recording can be PLAYED for [item]. False until a
/// recording is on file AND playback is wired (drills: kQaidaRecording;
/// Quran refs: quran_api.dart kLicensedReciters / reciterAudio()).
bool qaidaAudioAvailable(QlItem item) => false;
