// perf2gb: a camera-sized test photo built in pure Dart (no GPU read-back,
// no asset): an RGB PNG with gradients + texture so the image is not a flat
// colour a decoder/filter could short-cut. Default 4000x3000 = 12 MP, what
// the 13 MP camera of a typical 2 GB phone produces.
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

Uint8List makeTestPng({int width = 4000, int height = 3000}) {
  final row = width * 3 + 1; // filter byte + RGB
  final raw = Uint8List(row * height);
  for (var y = 0; y < height; y++) {
    final o = y * row;
    raw[o] = 0; // filter: none
    final gy = (y * 255) ~/ height;
    for (var x = 0; x < width; x++) {
      final p = o + 1 + x * 3;
      final n = ((x * 7919) ^ (y * 104729)) & 31; // cheap deterministic grain
      raw[p] = ((x * 255) ~/ width + n) & 0xFF;
      raw[p + 1] = (gy + n) & 0xFF;
      raw[p + 2] = ((x + y) & 0xFF) ^ (n << 2);
    }
  }
  final idat = ZLibEncoder(level: 1).convert(raw);
  final out = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final t = type.codeUnits;
    out.add(_u32(data.length));
    out.add(t);
    out.add(data);
    out.add(_u32(_crc32(data, _crc32(t, 0xFFFFFFFF, false))));
  }

  final ihdr = BytesBuilder()
    ..add(_u32(width))
    ..add(_u32(height))
    ..add(const [8, 2, 0, 0, 0]); // 8-bit, RGB, deflate, no filter, no interlace
  chunk('IHDR', ihdr.toBytes());
  chunk('IDAT', idat);
  chunk('IEND', const []);
  return out.toBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes, [int start = 0xFFFFFFFF, bool finish = true]) {
  var c = start;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return finish ? c ^ 0xFFFFFFFF : c;
}
