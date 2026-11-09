// cctvact (CCTV GUARD V3 D) — the TIMESTAMP WATERMARK for the evidence pack,
// made on this phone. The ORIGINAL photo / frames stay byte-for-byte as they
// came (their SHA-256 in manifest.json proves it); the pack ADDS a
// "watermarked/" copy of each picture with the Dhaka time, the alert number
// and "Assisto" burned into a dark band at the bottom, for printing and for
// a police officer reading it on paper. Every copy is hashed in the manifest
// too. Pure Dart (package:image); runs off the UI thread in the export flow.
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'evidence_pack.dart';

/// "2026-11-09 14:20:05 +06:00" — Bangladesh time (UTC+6, no DST).
String dhakaStamp(DateTime at) {
  final d = at.toUtc().add(const Duration(hours: 6));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)} +06:00';
}

/// The burned-in line (Latin digits: readable on any printer / font).
String watermarkLabel(Object eventId, DateTime? at, {String camera = ''}) {
  final when = at == null ? 'time unknown' : dhakaStamp(at);
  final cam = camera.trim().isEmpty ? '' : ' | ${_ascii(camera)}';
  return 'ASSISTO CCTV | alert #$eventId | $when$cam';
}

String _ascii(String s) {
  final out = s.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
  return out.length > 24 ? out.substring(0, 24) : out;
}

/// One JPEG with [label] in a dark band at the bottom, or null when the
/// bytes are not a decodable picture (the original still goes in the pack).
Uint8List? watermarkJpeg(Uint8List bytes, String label) {
  final src = img.decodeImage(bytes);
  if (src == null) return null;
  final font = src.width >= 900 ? img.arial48 : (src.width >= 480 ? img.arial24 : img.arial14);
  final band = font.lineHeight + 12;
  final out = img.Image.from(src);
  img.fillRect(out,
      x1: 0, y1: out.height - band, x2: out.width - 1, y2: out.height - 1,
      color: img.ColorRgba8(0, 0, 0, 190));
  img.drawString(out, label,
      font: font, x: 8, y: out.height - band + 6, color: img.ColorRgb8(255, 255, 255));
  return Uint8List.fromList(img.encodeJpg(out, quality: 90));
}

/// Watermarked copies of every picture in [media] (photo + clip frames),
/// named "watermarked/<original name>". Video (.ts) is left as it is.
List<EvidenceFile> watermarkedCopies(List<EvidenceFile> media, Object eventId,
    {String camera = ''}) {
  final out = <EvidenceFile>[];
  for (final f in media) {
    if (!f.name.toLowerCase().endsWith('.jpg')) continue;
    final w = watermarkJpeg(f.bytes, watermarkLabel(eventId, f.at, camera: camera));
    if (w != null) out.add(EvidenceFile('watermarked/${f.name}', w, at: f.at));
  }
  return out;
}
