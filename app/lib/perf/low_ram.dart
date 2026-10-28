// perf2gb: smaller decoded-image cache on 2–3 GB phones.
//
// Flutter keeps up to 100 MB / 1000 decoded images by default. On a 2 GB
// phone that cache alone is a large share of what Android lets a foreground
// app keep before the low-memory killer steps in, so on low-RAM phones we
// cap it. Read once, AFTER the first frame (main.dart deferred init), through
// device_info_plus (ActivityManager.isLowRamDevice + MemoryInfo.totalMem) —
// time-boxed, crash-guarded, Android only; on any failure nothing changes.
import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

class ImageCacheBudget {
  const ImageCacheBudget(this.bytes, this.count);
  final int bytes;
  final int count;
  @override
  bool operator ==(Object o) => o is ImageCacheBudget && o.bytes == bytes && o.count == count;
  @override
  int get hashCode => Object.hash(bytes, count);
  @override
  String toString() => 'ImageCacheBudget(${bytes >> 20} MB, $count)';
}

class LowRamTuning {
  LowRamTuning._();

  /// The cap for a phone with [ramMb] of RAM (MemoryInfo.totalMem; a "2 GB"
  /// phone reports ~1.8–1.9 GB, a "3 GB" one ~2.7–2.9 GB). null = keep
  /// Flutter's default (100 MB / 1000 images).
  static ImageCacheBudget? budgetFor({required int ramMb, required bool lowRam}) {
    if (lowRam || (ramMb > 0 && ramMb <= 2304)) return const ImageCacheBudget(40 << 20, 300);
    if (ramMb > 0 && ramMb <= 3328) return const ImageCacheBudget(64 << 20, 500);
    return null;
  }

  static bool _done = false;

  /// Applied budget (null = default kept or not on Android) — for tests/diag.
  static ImageCacheBudget? applied;

  /// photoperf: what Android reported (0 / false = unknown: not read yet,
  /// not Android, or the read failed). Photo Studio sizes its editing proxy
  /// from this.
  static int ramMb = 0;
  static bool lowRam = false;

  static Future<void> apply({Future<AndroidDeviceInfo> Function()? read}) async {
    if (_done) return;
    _done = true;
    try {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
      final a = await (read ?? () => DeviceInfoPlugin().androidInfo)()
          .timeout(const Duration(seconds: 3));
      ramMb = a.physicalRamSize;
      lowRam = a.isLowRamDevice;
      final b = budgetFor(ramMb: a.physicalRamSize, lowRam: a.isLowRamDevice);
      if (b == null) return;
      final cache = PaintingBinding.instance.imageCache;
      cache.maximumSizeBytes = b.bytes;
      cache.maximumSize = b.count;
      applied = b;
    } catch (_) {
      // plugin missing / slow / old OS: keep the defaults
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _done = false;
    applied = null;
    ramMb = 0;
    lowRam = false;
  }
}
