import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One state of the photo. Version 0 is ALWAYS the untouched original.
class PhotoVersion {
  PhotoVersion({
    required this.bytes,
    required this.feature,
    this.jobId,
    this.aiEdited = false,
    this.previewOnly = false,
    this.fullQuality = false,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// Encoded image (what the user sees; for free users a reduced preview).
  final Uint8List bytes;

  /// 'original' | 'enhance_hd' | 'enhance_cloud' | 'prompt_edit' | 'generate'
  final String feature;
  final int? jobId;
  final bool aiEdited;

  /// true when [bytes] is a reduced, watermarked preview (full quality only
  /// comes through the export gate).
  final bool previewOnly;

  /// d1-photo: [bytes] already ARE the full-quality result (an on-device
  /// tool / batch result) — the export uses them after the gate instead of
  /// re-rendering.
  final bool fullQuality;
  final DateTime at;
}

/// Original kept + undo / redo + version history. Versions are never
/// destroyed by undo; a new edit is appended and becomes current.
class PhotoSession extends ChangeNotifier {
  PhotoSession(Uint8List original)
      : _versions = [PhotoVersion(bytes: original, feature: 'original')];

  final List<PhotoVersion> _versions;
  int _index = 0;

  List<PhotoVersion> get versions => List.unmodifiable(_versions);
  int get index => _index;
  PhotoVersion get original => _versions.first;
  PhotoVersion get current => _versions[_index];
  bool get canUndo => _index > 0;
  bool get canRedo => _index < _versions.length - 1;
  bool get edited => _index > 0;

  void push(PhotoVersion v) {
    _versions.add(v);
    _index = _versions.length - 1;
    notifyListeners();
  }

  void undo() {
    if (!canUndo) return;
    _index--;
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _index++;
    notifyListeners();
  }

  void select(int i) {
    if (i < 0 || i >= _versions.length || i == _index) return;
    _index = i;
    notifyListeners();
  }

  void revertToOriginal() => select(0);
}

// =========================================================================
// AI-edit metadata (PNG tEXt / iTXt chunks)
// =========================================================================
class PngMeta {
  PngMeta._();

  static const _sig = [137, 80, 78, 71, 13, 10, 26, 10];
  static final List<int> _table = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int crc32(List<int> bytes) {
    var c = 0xFFFFFFFF;
    for (final b in bytes) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static bool isPng(Uint8List b) {
    if (b.length < 8) return false;
    for (var i = 0; i < 8; i++) {
      if (b[i] != _sig[i]) return false;
    }
    return true;
  }

  static List<int> _chunk(String type, List<int> data) {
    final t = ascii.encode(type);
    final len = data.length;
    final crc = crc32([...t, ...data]);
    return [
      (len >> 24) & 0xFF, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF,
      ...t, ...data,
      (crc >> 24) & 0xFF, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF,
    ];
  }

  /// IPTC digital-source type for AI-assisted edits / generated images.
  static const iptcComposite =
      'http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia';
  static const iptcGenerated =
      'http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia';

  /// Insert Software / Comment tEXt and an XMP iTXt (IPTC DigitalSourceType)
  /// right after IHDR. Returns [png] unchanged if it isn't a PNG.
  static Uint8List markAiEdited(Uint8List png,
      {required String note, bool generated = false}) {
    if (!isPng(png) || png.length < 33) return png;
    const ihdrEnd = 8 + 25; // sig + IHDR chunk (4 len + 4 type + 13 data + 4 crc)
    final xmp = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF '
        'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        '<rdf:Description xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/" '
        'Iptc4xmpExt:DigitalSourceType="${generated ? iptcGenerated : iptcComposite}" '
        'xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:CreatorTool="Assisto Photo Studio"/>'
        '</rdf:RDF></x:xmpmeta>';
    final extra = <int>[
      ..._chunk('tEXt', [...latin1.encode('Software'), 0, ...latin1.encode('Assisto Photo Studio')]),
      ..._chunk('tEXt', [...latin1.encode('Comment'), 0, ...latin1.encode(note)]),
      // iTXt: keyword \0 compression-flag(0) method(0) lang \0 translated \0 text
      ..._chunk('iTXt', [...latin1.encode('XML:com.adobe.xmp'), 0, 0, 0, 0, 0, ...utf8.encode(xmp)]),
    ];
    return Uint8List.fromList([
      ...png.sublist(0, ihdrEnd),
      ...extra,
      ...png.sublist(ihdrEnd),
    ]);
  }

  /// tEXt key/values (for tests and "file info" display).
  static Map<String, String> readText(Uint8List png) {
    final out = <String, String>{};
    if (!isPng(png)) return out;
    var p = 8;
    while (p + 8 <= png.length) {
      final len = (png[p] << 24) | (png[p + 1] << 16) | (png[p + 2] << 8) | png[p + 3];
      final type = ascii.decode(png.sublist(p + 4, p + 8));
      if (p + 12 + len > png.length) break;
      final data = png.sublist(p + 8, p + 8 + len);
      if (type == 'tEXt') {
        final z = data.indexOf(0);
        if (z > 0) out[latin1.decode(data.sublist(0, z))] = latin1.decode(data.sublist(z + 1));
      }
      if (type == 'IEND') break;
      p += 12 + len;
    }
    return out;
  }
}
