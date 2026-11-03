import '../l10n/app_localizations.dart';
import 'media/media_descriptor.dart' show descriptorIsViewOnce;

/// viewonce — a view-once message is NEVER previewed: notifications, the
/// chat bubble icon and the chat list show only "Photo, view once" /
/// "Video, view once" / "Voice, view once" (no caption, no thumbnail, no
/// file name). The chat list carries it as the pseudo content type
/// `vo_<kind>` so the existing label / icon helpers stay one call each.

const String kVoPrefix = 'vo_';

String voPreviewKind(String ct) => ct.startsWith(kVoPrefix) ? ct : '$kVoPrefix$ct';

bool isVoPreviewKind(String ct) => ct.startsWith(kVoPrefix);

/// True when the server flag or the decrypted descriptor says view-once.
bool isViewOnceMessage({Object? flag, String? plaintext}) =>
    flag == true || (plaintext != null && descriptorIsViewOnce(plaintext));

/// "Photo, view once" … for a `vo_<kind>` type; null otherwise.
String? viewOnceLabel(AppLocalizations t, String ct) {
  if (!isVoPreviewKind(ct)) return null;
  return switch (ct.substring(kVoPrefix.length)) {
    'video' => t.vo1PreviewVideo,
    'voice' || 'audio' => t.vo1PreviewVoice,
    _ => t.vo1PreviewPhoto,
  };
}
