import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// circlemedia — several photos / videos sent together as ONE album.
///
/// Every item still travels as its own normal E2E media message (the same
/// per-recipient encryption, upload, progress, retry and offline outbox as a
/// single photo). The album link rides INSIDE each item's encrypted media
/// descriptor as `"alb": {"id": <random>, "i": <index>, "n": <count>}`, so the
/// server never learns which messages belong together; the phones group them
/// back into one bubble. Older app versions simply show the items one by one.
@immutable
class AlbumRef {
  final String id;
  final int index;
  final int count;
  const AlbumRef({required this.id, required this.index, required this.count});

  Map<String, dynamic> toJson() => {'id': id, 'i': index, 'n': count};

  /// null when the value is missing or malformed (never throws).
  static AlbumRef? tryParse(Object? v) {
    if (v is! Map) return null;
    final id = '${v['id'] ?? ''}';
    final i = v['i'], n = v['n'];
    if (id.isEmpty || id.length > 64 || i is! num || n is! num) return null;
    final count = n.toInt(), index = i.toInt();
    if (count < 2 || count > 100 || index < 0 || index >= count) return null;
    return AlbumRef(id: id, index: index, count: count);
  }

  @override
  bool operator ==(Object other) =>
      other is AlbumRef && other.id == id && other.index == index && other.count == count;
  @override
  int get hashCode => Object.hash(id, index, count);
}

/// A fresh album id (random, not guessable from the time alone).
String newAlbumId() {
  final r = math.Random.secure();
  return 'a${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${r.nextInt(1 << 30).toRadixString(36)}';
}

/// One tile of an album grid, in fractions of the album WIDTH (x, y, w, h).
@immutable
class AlbumTileSpec {
  final double x, y, w, h;
  const AlbumTileSpec(this.x, this.y, this.w, this.h);
}

/// The grid for [n] items: the tiles (at most 4), the grid height as a
/// fraction of its width, and how many items are not shown (+N on the last
/// tile).
///   1 → one tile · 2 → side by side · 3 → one large on top + two small ·
///   4 → 2×2 · more than 4 → 2×2 with "+N" on the fourth.
@immutable
class AlbumLayout {
  final List<AlbumTileSpec> tiles;
  final double heightFactor;
  final int overflow;
  const AlbumLayout(this.tiles, this.heightFactor, this.overflow);
}

AlbumLayout albumLayout(int n) {
  if (n <= 1) return const AlbumLayout([AlbumTileSpec(0, 0, 1, 1)], 1, 0);
  if (n == 2) {
    return const AlbumLayout(
        [AlbumTileSpec(0, 0, 0.5, 0.625), AlbumTileSpec(0.5, 0, 0.5, 0.625)], 0.625, 0);
  }
  if (n == 3) {
    return const AlbumLayout([
      AlbumTileSpec(0, 0, 1, 0.6),
      AlbumTileSpec(0, 0.6, 0.5, 0.45),
      AlbumTileSpec(0.5, 0.6, 0.5, 0.45),
    ], 1.05, 0);
  }
  return AlbumLayout(const [
    AlbumTileSpec(0, 0, 0.5, 0.5),
    AlbumTileSpec(0.5, 0, 0.5, 0.5),
    AlbumTileSpec(0, 0.5, 0.5, 0.5),
    AlbumTileSpec(0.5, 0.5, 0.5, 0.5),
  ], 1, n > 4 ? n - 4 : 0);
}

/// Folds the members of each album into ONE row, in chronological lists.
///
/// [albumOf] returns the album key of a row (null = not an album item);
/// [indexOf] the item's place in the album. The merged row sits where the
/// album's first (oldest) member was; [merge] builds it from the members in
/// album order (the member with the lowest index first). An album with only
/// one member present stays a normal row.
List<T> collapseAlbums<T>(
  List<T> chrono, {
  required String? Function(T row) albumOf,
  required int Function(T row) indexOf,
  required T Function(List<T> members) merge,
}) {
  final groups = <String, List<T>>{};
  for (final r in chrono) {
    final k = albumOf(r);
    if (k != null) (groups[k] ??= <T>[]).add(r);
  }
  if (groups.values.every((g) => g.length < 2)) return chrono;
  final out = <T>[];
  final done = <String>{};
  for (final r in chrono) {
    final k = albumOf(r);
    final g = k == null ? null : groups[k];
    if (g == null || g.length < 2) {
      out.add(r);
      continue;
    }
    if (!done.add(k!)) continue;
    final sorted = [...g]..sort((a, b) => indexOf(a).compareTo(indexOf(b)));
    out.add(merge(sorted));
  }
  return out;
}

/// Bubble size for one photo: the real aspect ratio inside min/max bounds.
/// [maxW] is the widest the bubble may be on this screen.
({double w, double h}) photoBubbleSize(int? w, int? h, double maxW) {
  final mw = maxW.clamp(160.0, 300.0);
  const minW = 150.0, minH = 110.0;
  final maxH = mw * 1.33;
  if (w == null || h == null || w <= 0 || h <= 0) return (w: mw, h: mw * 0.75);
  final r = w / h;
  var bw = mw, bh = mw / r;
  if (bh > maxH) {
    bh = maxH;
    bw = maxH * r;
  }
  return (w: bw.clamp(minW, mw), h: bh.clamp(minH, maxH));
}
