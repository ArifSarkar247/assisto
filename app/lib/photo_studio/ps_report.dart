/// Photo Studio — failure reports + live progress (d1-photo).
///
/// Root cause of the owner's "enhance failed" (D1_ROOT_CAUSE.md): every
/// Photo Studio failure was swallowed by a bare `catch (_)`, so nothing ever
/// reached Owner Admin -> Reports -> App errors. Now each failure goes through
/// [PsReporter] -> `reportNonFatal` (the existing sc1 crash-report pipe:
/// scrubbed, consent-gated, device model + Android version added by
/// DeviceFacts) with only non-PII facts: stage, error code, model version,
/// execution provider. Never image data, never a file path, never user text.
library;

import '../services/error_report.dart';

/// One Photo Studio failure (the object the crash pipe reports).
class PhotoStudioFailure implements Exception {
  const PhotoStudioFailure(this.stage, this.code, {this.model = '', this.ep = ''});

  /// download | upscale | segment | enhance | tool | server | batch | export
  final String stage;

  /// Short machine code, e.g. `http 503`, `sha256`, `ort_session`,
  /// `model_shape`, `OutOfMemoryError`, `decode`.
  final String code;
  final String model;
  final String ep;

  @override
  String toString() =>
      'PhotoStudioFailure(stage=$stage code=$code model=$model ep=$ep)';
}

typedef PsReporter = void Function(PhotoStudioFailure f);

/// Default reporter: the app's crash-report pipe.
void defaultPsReporter(PhotoStudioFailure f) =>
    reportNonFatal('photo_studio.${f.stage}', f);

/// A short, PII-free code for any error object or native error string.
/// Native errors look like "ort_session: OrtException" or a bare class name;
/// anything else is reduced to its type (messages may hold paths).
String psErrorCode(Object? e) {
  if (e == null) return 'unknown';
  if (e is String) {
    final s = e.trim();
    final m = RegExp(r'^[a-z_]{2,24}(: ?[A-Za-z_.$]{2,60})?').firstMatch(s);
    if (m != null) return m.group(0)!;
    return s.isEmpty ? 'unknown' : 'native';
  }
  final t = '${e.runtimeType}';
  final i = t.indexOf('<');
  return i > 0 ? t.substring(0, i) : t;
}

/// What the busy overlay shows: honest stage + real counts from the engine.
enum PsStage { download, analyse, ai, mask, classic, server, batch }

class PsProgress {
  const PsProgress(this.stage, {this.done = 0, this.total = 0, this.etaMs, this.item = 0, this.items = 0});
  final PsStage stage;

  /// Units done / total (AI tiles, bytes, batch photos). total 0 = unknown.
  final int done, total;

  /// Estimated remaining time from MEASURED per-tile speed on this phone
  /// (null = not known yet — the screen then shows no number).
  final int? etaMs;

  /// Batch: which photo (1-based) of how many.
  final int item, items;

  double? get fraction => total > 0 ? (done / total).clamp(0, 1).toDouble() : null;
}

typedef PsProgressFn = void Function(PsProgress p);

/// The user pressed Cancel: no result, nothing charged, nothing kept.
class PsCancelled implements Exception {
  const PsCancelled();
}
