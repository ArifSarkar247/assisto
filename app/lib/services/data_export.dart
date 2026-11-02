import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// framebar — "Export my data" that the person can actually KEEP.
///
/// Before: the JSON went to the app's private documents folder and the user
/// saw a path they could never open (and the file died with the app or the
/// account). Now the file is written to the temp folder and handed to the
/// Android share sheet, so it can be saved to Files / Drive / email.
///
/// Test seams: [fetch] is the caller's API call; [sharer] and [dirOf] can be
/// replaced in widget tests so nothing touches the platform.
class DataExport {
  DataExport._();

  static const fileName = 'assisto-my-data.json';

  /// Shares the file at [path] with [subject]. Returns true when the share
  /// sheet opened (the user may still cancel it — that is their choice).
  static Future<bool> Function(String path, String subject) sharer =
      _shareFile;

  /// Where the export file is written (temp: the OS may clean it later; the
  /// user's copy is the one they save from the share sheet).
  static Future<Directory> Function() dirOf = getTemporaryDirectory;

  static Future<bool> _shareFile(String path, String subject) async {
    await Share.shareXFiles([XFile(path, mimeType: 'application/json')],
        subject: subject);
    return true;
  }

  /// Fetch the export, write it, open the share sheet. Throws when the fetch
  /// fails (caller shows its honest error); a share-sheet failure returns
  /// false.
  static Future<bool> run(Future<String> Function() fetch,
      {required String subject}) async {
    final raw = await fetch();
    final dir = await dirOf();
    final f = File('${dir.path}/$fileName');
    await f.writeAsString(raw, flush: true);
    try {
      return await sharer(f.path, subject);
    } catch (_) {
      return false;
    }
  }
}
