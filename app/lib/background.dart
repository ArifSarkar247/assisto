/// Background family alerts — WorkManager DISABLED (safe build).
///
/// WorkManager (androidx.work) registers a startup `ContentProvider`
/// (`androidx.startup.InitializationProvider`) that runs before any Dart code,
/// so a failure there crashes the app on launch — exactly the symptom reported
/// on ColorOS/Realme. Background execution is also heavily throttled on those
/// devices, so WorkManager is a poor fit regardless.
///
/// These are intentional no-ops. The Realme-safe replacement polls `/alerts`
/// when the app opens / resumes (foreground, pure-Dart, see AppState) and raises
/// local notifications; proper push (FCM) can come later.
class Background {
  static Future<void> start() async {}
  static Future<void> stop() async {}
}
