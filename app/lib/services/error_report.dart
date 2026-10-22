import '../diag/non_fatal.dart';

/// sc1 — the ONE hook other code calls for "something failed, app carries on"
/// (SecretStore / IdentityVault / logout failures, key publishing, ...).
///
/// Safe anywhere (also before the first frame and in background isolates):
/// it never throws and never blocks. The error is scrubbed (lib/diag/
/// crash_scrub.dart: no quoted text, numbers, e-mails, links, file paths or
/// tokens) and only sent — to Crashlytics and Owner Admin → Reports → App
/// errors — once the user is signed in and past onboarding. Pass the error
/// OBJECT; never put a secret, message text or a phone number in [where]
/// (use a short dotted tag like 'secret_store.read').
void reportNonFatal(String where, Object error, [StackTrace? stack]) =>
    NonFatal.report(where, error, stack ?? StackTrace.current);
