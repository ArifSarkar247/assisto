import 'dart:math' as math;
import 'dart:typed_data';

/// Call tones GENERATED IN CODE (no audio files, nothing copyrighted).
///
/// * ringback  — 425 Hz, 1 s on / 4 s off (one 5 s cycle, looped natively);
///   played ONLY while the callee's phone reports it is ringing.
/// * busy      — 425 Hz, 0.5 s on / 0.5 s off x 4.
/// * declined  — 425 Hz, 0.25 s on / 0.25 s off x 3 (a shorter "rejected").
/// * ended     — two short 425 Hz pips (call over / failed).
/// * signature — the optional "Assisto" ringtone: an ORIGINAL melody written
///   for Assisto (see .phaseB/MODEL_LICENSES.md), synthesised with a soft
///   bell-like voice. Not the default; the phone's ringtone is.
///
/// All output is 16-bit signed little-endian mono PCM.
class ToneSpec {
  const ToneSpec(this.pcm, this.sampleRate, {this.loop = false});
  final Int16List pcm;
  final int sampleRate;
  final bool loop;

  Duration get duration =>
      Duration(microseconds: pcm.length * 1000000 ~/ sampleRate);

  /// Little-endian bytes for the native AudioTrack.
  Uint8List get bytes => pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
}

class ToneGenerator {
  ToneGenerator._();

  static const int rate = 16000;
  static const int signatureRate = 22050;
  static const double ringbackHz = 425;

  /// Short raised-cosine fade so tones never click.
  static const double _fadeS = 0.008;

  static Int16List _pattern(double hz, List<(double on, double off)> parts,
      {int sampleRate = rate, double amp = 0.5}) {
    var total = 0;
    for (final (on, off) in parts) {
      total += (on * sampleRate).round() + (off * sampleRate).round();
    }
    final out = Int16List(total);
    var i = 0;
    final fade = (_fadeS * sampleRate).round();
    for (final (on, off) in parts) {
      final n = (on * sampleRate).round();
      for (var k = 0; k < n; k++) {
        var env = 1.0;
        if (k < fade) env = 0.5 - 0.5 * math.cos(math.pi * k / fade);
        if (k > n - fade) env = 0.5 - 0.5 * math.cos(math.pi * (n - k) / fade);
        final v = math.sin(2 * math.pi * hz * k / sampleRate) * amp * env;
        out[i++] = (v * 32767).round().clamp(-32768, 32767);
      }
      i += (off * sampleRate).round(); // zeros
    }
    return out;
  }

  /// One ringback cycle (1 s tone + 4 s silence) — loop it.
  static ToneSpec ringback() =>
      ToneSpec(_pattern(ringbackHz, const [(1.0, 4.0)]), rate, loop: true);

  static ToneSpec busy() => ToneSpec(
      _pattern(ringbackHz,
          const [(0.5, 0.5), (0.5, 0.5), (0.5, 0.5), (0.5, 0.5)]),
      rate);

  static ToneSpec declined() => ToneSpec(
      _pattern(ringbackHz, const [(0.25, 0.25), (0.25, 0.25), (0.25, 0.25)]),
      rate);

  static ToneSpec ended() => ToneSpec(
      _pattern(ringbackHz, const [(0.15, 0.12), (0.15, 0.2)], amp: 0.4), rate);

  /// The original Assisto melody: a rising four-note call, an answer phrase,
  /// then rest — (semitones above A4, beats). Written for Assisto in 2026;
  /// not derived from any existing tune.
  static const List<(int? semi, double beats)> signatureScore = [
    (7, 0.5), (11, 0.5), (14, 0.5), (19, 1.0), // E5 G#5 B5 E6 (call)
    (null, 0.25),
    (17, 0.5), (14, 0.5), (16, 1.5), // D6 B5 C#6 (answer)
    (null, 0.5),
    (7, 0.5), (11, 0.5), (14, 0.5), (19, 0.75), (21, 1.25), // E5 G#5 B5 E6 F#6
    (null, 2.0),
  ];

  static ToneSpec signature({double bpm = 132}) {
    final beat = 60.0 / bpm;
    var total = 0;
    for (final (_, b) in signatureScore) {
      total += (b * beat * signatureRate).round();
    }
    final out = Int16List(total);
    var i = 0;
    for (final (semi, b) in signatureScore) {
      final n = (b * beat * signatureRate).round();
      if (semi != null) {
        final hz = 440.0 * math.pow(2, semi / 12.0);
        final attack = (0.01 * signatureRate).round();
        for (var k = 0; k < n; k++) {
          final t = k / signatureRate;
          // bell-ish: fast attack, exponential decay, soft 2nd/3rd partials
          final env = (k < attack ? k / attack : 1.0) * math.exp(-3.2 * t);
          final release = k > n - 200 ? (n - k) / 200 : 1.0;
          final v = (math.sin(2 * math.pi * hz * t) +
                  0.35 * math.sin(2 * math.pi * 2 * hz * t) +
                  0.12 * math.sin(2 * math.pi * 3 * hz * t)) /
              1.47;
          out[i + k] =
              (v * env * release * 0.6 * 32767).round().clamp(-32768, 32767);
        }
      }
      i += n;
    }
    return ToneSpec(out, signatureRate, loop: true);
  }

  /// RIFF/WAVE wrapper (for installing the signature tone as a phone
  /// ringtone, so the locked-screen ring can use it too).
  static Uint8List wav(ToneSpec t) {
    final data = t.bytes;
    final b = BytesBuilder();
    void s(String x) => b.add(x.codeUnits);
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little))
        .buffer
        .asUint8List());
    void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little))
        .buffer
        .asUint8List());
    s('RIFF');
    u32(36 + data.length);
    s('WAVE');
    s('fmt ');
    u32(16);
    u16(1); // PCM
    u16(1); // mono
    u32(t.sampleRate);
    u32(t.sampleRate * 2);
    u16(2);
    u16(16);
    s('data');
    u32(data.length);
    b.add(data);
    return b.toBytes();
  }
}
