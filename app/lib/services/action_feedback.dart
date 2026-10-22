// db1 — honest feedback for a user action that failed.
//
// Owner rule: a tap must never fail silently. Every user-action catch either
// shows this short message (bn/en) or is marked `// best-effort:` with a reason
// (see test/swallowed_catch_test.dart).
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import 'error_report.dart';

/// Reports [error] as non-fatal under [where] and shows a short SnackBar:
/// "Couldn't open it on this phone." when [open] (a link/app/map/share target
/// could not be launched), else "Couldn't do that. Please try again.".
void showActionFailed(BuildContext context, String where, Object error,
    {bool open = false}) {
  reportNonFatal(where, error);
  if (!context.mounted) return;
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  final t = AppLocalizations.of(context);
  m.showSnackBar(
      SnackBar(content: Text(open ? t.actionCantOpen : t.actionFailedRetry)));
}

/// A submit/check/send tap with an empty required field: say so instead of
/// silently doing nothing ("Type something first.").
void showNeedInput(BuildContext context) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).actionNeedInput)));
}

/// Runs a user-tap action; if it throws (offline, server error) the user sees
/// "Couldn't do that. Please try again." instead of nothing.
Future<void> runUserAction(BuildContext context, String where,
    Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) showActionFailed(context, where, e);
  }
}

/// Opens [uri] (dialer, maps, browser, SMS…) for a user tap. If no app can
/// take it, or the launch throws, the user is told ("Couldn't open it on this
/// phone.") — never a silent dead tap.
Future<bool> openForUser(BuildContext context, Uri uri,
    {String where = 'open',
    LaunchMode mode = LaunchMode.platformDefault}) async {
  try {
    if (await launchUrl(uri, mode: mode)) return true;
    throw StateError('no app for ${uri.scheme}');
  } catch (e) {
    if (context.mounted) showActionFailed(context, where, e, open: true);
    return false;
  }
}
