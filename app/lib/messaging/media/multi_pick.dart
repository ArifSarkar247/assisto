import 'dart:io';

import 'package:image_picker/image_picker.dart';

import '../../services/error_report.dart';
import 'media_prep.dart';
import 'photo_prep.dart';
import 'video_prep.dart';

/// circlemedia — pick up to N photos AND videos at once with the system
/// photo picker (no media permission; Play Photo & Video policy).
///
/// Android 13+ (and older phones with the Play-services back-port) show the
/// system Photo Picker with the limit built in. The oldest phones fall back
/// to the document picker with multi-select, which has no limit of its own:
/// we keep the first [limit] and tell the user honestly.
///
/// Photos come in at the HD size (2560 px, q 88); the preview's HD /
/// Standard switch then decides what is sent (see photo_prep.dart).

const Set<String> kVideoExts = {'mp4', '3gp', 'webm', 'mkv', 'mov', 'm4v'};

bool isVideoPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return kVideoExts.contains(path.substring(dot + 1).toLowerCase());
}

/// Seam for tests: returns the picked file paths ([] = cancelled).
Future<List<String>> Function(int limit) pickMultipleMediaPaths = (limit) async {
  final xs = await ImagePicker().pickMultipleMedia(
    maxWidth: kHdEdge.toDouble(),
    maxHeight: kHdEdge.toDouble(),
    imageQuality: kHdQuality,
    limit: limit < 2 ? 2 : limit,
    requestFullMetadata: false,
  );
  return [for (final x in xs) x.path];
};

/// What came back from one multi pick.
class MultiPickResult {
  final List<MediaDraft> drafts;

  /// Picked beyond the limit (old phones' picker has no limit) — not added.
  final int overLimit;

  /// Videos larger than the video cap — not added.
  final int tooBig;

  /// Files that could not be read.
  final int failed;
  const MultiPickResult(this.drafts,
      {this.overLimit = 0, this.tooBig = 0, this.failed = 0});
}

/// Prepare picked [paths] (in order) into drafts: photos are scrubbed of
/// every metadata segment (location!) and measured; videos are moved in and
/// scrubbed. Keeps at most [limit]; skips videos over [videoMax] bytes.
Future<MultiPickResult> prepareMultiPaths(List<String> paths,
    {required int limit, required int videoMax}) async {
  final drafts = <MediaDraft>[];
  var over = 0, big = 0, failed = 0;
  for (final p in paths) {
    if (drafts.length >= limit) {
      over++;
      _deleteQuietly(p);
      continue;
    }
    try {
      final f = File(p);
      if (!f.existsSync()) {
        failed++;
        continue;
      }
      if (isVideoPath(p)) {
        if (f.lengthSync() > videoMax) {
          big++;
          _deleteQuietly(p);
          continue;
        }
        drafts.add(await prepareVideoFile(f));
      } else {
        final name = p.split(RegExp(r'[\\/]')).last;
        drafts.add(await preparePhotoBytes(await f.readAsBytes(), name));
        _deleteQuietly(p); // the picker's cache copy; ours is in out/
      }
    } catch (e) {
      failed++;
      reportNonFatal('cm_multi_prepare', e);
    }
  }
  return MultiPickResult(drafts, overLimit: over, tooBig: big, failed: failed);
}

/// The system picker with multi-select, then [prepareMultiPaths].
/// null = cancelled.
Future<MultiPickResult?> pickMultiDrafts(
    {required int limit, required int videoMax}) async {
  final paths = await pickMultipleMediaPaths(limit);
  if (paths.isEmpty) return null;
  return prepareMultiPaths(paths, limit: limit, videoMax: videoMax);
}

void _deleteQuietly(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}
