// cctvx — the EVIDENCE PACK for a police General Diary, built ON THIS PHONE
// (the server never sees the plain clip): the alert photo, the clip frames
// this phone decrypted (each with its time), manifest.json with the SHA-256
// of every file, the manifest's own SHA-256 (printed in the GD letter), the
// GD draft and SHA256SUMS.txt (the standard `sha256sum -c` format).
// Pure Dart: a "stored" ZIP (no compression — JPEGs do not shrink) with a
// CRC-32 per entry. Unit-tested (test/cctvx_test.dart).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

class EvidenceFile {
  final String name;
  final Uint8List bytes;

  /// When this file's moment happened (photo = the alert, frame = +t s).
  final DateTime? at;
  const EvidenceFile(this.name, this.bytes, {this.at});
}

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// The media files in a stable order: photo.jpg, then frame_001.jpg ...
List<EvidenceFile> evidenceMedia({
  Uint8List? photo,
  DateTime? alertAt,
  List<Uint8List> frames = const [],
  List<double> frameTimes = const [],
  DateTime? clipStart,
}) {
  final out = <EvidenceFile>[];
  if (photo != null && photo.isNotEmpty) out.add(EvidenceFile('photo.jpg', photo, at: alertAt));
  for (var i = 0; i < frames.length; i++) {
    final t = i < frameTimes.length ? frameTimes[i] : null;
    final at = (clipStart != null && t != null)
        ? clipStart.add(Duration(milliseconds: (t * 1000).round()))
        : null;
    out.add(EvidenceFile('clip/frame_${(i + 1).toString().padLeft(3, '0')}.jpg', frames[i],
        at: at));
  }
  return out;
}

/// manifest.json bytes (pretty, stable key order) for [media].
Uint8List evidenceManifest(List<EvidenceFile> media, Map<String, Object?> facts,
    {required DateTime exportedAt}) {
  final m = <String, Object?>{
    'v': 1,
    'kind': 'assisto-cctv-evidence',
    'hash': 'sha256',
    'facts': facts,
    'exported_at': exportedAt.toUtc().toIso8601String(),
    'files': [
      for (final f in media)
        {
          'name': f.name,
          'bytes': f.bytes.length,
          'sha256': sha256Hex(f.bytes),
          if (f.at != null) 'time': f.at!.toUtc().toIso8601String(),
        }
    ],
  };
  return Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(m)));
}

/// `sha256sum` lines for every file (two spaces, binary-safe names).
String sha256Sums(List<EvidenceFile> files) =>
    files.map((f) => '${sha256Hex(f.bytes)}  ${f.name}').join('\n') + '\n';

// ------------------------------------------------------------------ ZIP
final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int _dosTime(DateTime t) => (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
int _dosDate(DateTime t) => ((t.year - 1980).clamp(0, 127) << 9) | (t.month << 5) | t.day;

/// A "stored" (method 0) ZIP with UTF-8 names. [when] stamps every entry.
Uint8List storedZip(List<EvidenceFile> files, {required DateTime when}) {
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  final dt = _dosTime(when), dd = _dosDate(when);
  var offset = 0;

  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  for (final f in files) {
    final name = utf8.encode(f.name);
    final crc = crc32(f.bytes);
    final local = BytesBuilder(copy: false);
    u32(local, 0x04034b50);
    u16(local, 20);
    u16(local, 0x0800);
    u16(local, 0);
    u16(local, dt);
    u16(local, dd);
    u32(local, crc);
    u32(local, f.bytes.length);
    u32(local, f.bytes.length);
    u16(local, name.length);
    u16(local, 0);
    local.add(name);
    final lb = local.takeBytes();
    out.add(lb);
    out.add(f.bytes);

    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 0);
    u16(central, dt);
    u16(central, dd);
    u32(central, crc);
    u32(central, f.bytes.length);
    u32(central, f.bytes.length);
    u16(central, name.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(name);
    offset += lb.length + f.bytes.length;
  }
  final cd = central.takeBytes();
  out.add(cd);
  final end = BytesBuilder(copy: false);
  u32(end, 0x06054b50);
  u16(end, 0);
  u16(end, 0);
  u16(end, files.length);
  u16(end, files.length);
  u32(end, cd.length);
  u32(end, offset);
  u16(end, 0);
  out.add(end.takeBytes());
  return out.takeBytes();
}

/// Read back a stored ZIP's entries (tests + a self-check before sharing).
Map<String, Uint8List> readStoredZip(Uint8List zip) {
  final bd = ByteData.sublistView(zip);
  final out = <String, Uint8List>{};
  var off = 0;
  while (off + 30 <= zip.length && bd.getUint32(off, Endian.little) == 0x04034b50) {
    final crc = bd.getUint32(off + 14, Endian.little);
    final size = bd.getUint32(off + 18, Endian.little);
    final nl = bd.getUint16(off + 26, Endian.little);
    final xl = bd.getUint16(off + 28, Endian.little);
    final name = utf8.decode(zip.sublist(off + 30, off + 30 + nl));
    final start = off + 30 + nl + xl;
    final data = Uint8List.sublistView(zip, start, start + size);
    if (crc32(data) != crc) throw const FormatException('crc');
    out[name] = data;
    off = start + size;
  }
  return out;
}

/// The whole pack: media + manifest.json + the GD letter (which quotes the
/// manifest's SHA-256) + SHA256SUMS.txt over all of them.
Uint8List assembleEvidencePack({
  required List<EvidenceFile> media,
  required Uint8List manifest,
  required String letter,
  required DateTime now,
}) {
  final all = <EvidenceFile>[
    ...media,
    EvidenceFile('manifest.json', manifest),
    EvidenceFile('gd_letter.txt', Uint8List.fromList(utf8.encode(letter))),
  ];
  final sums = Uint8List.fromList(utf8.encode(sha256Sums(all)));
  return storedZip([...all, EvidenceFile('SHA256SUMS.txt', sums)], when: now);
}
