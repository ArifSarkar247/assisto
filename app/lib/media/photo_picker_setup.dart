import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// play-perm: every image/video pick in the app (chat, vault, Photo Studio,
/// profile, status, shop, business catalog, scanner …) goes through
/// `image_picker`. Switching its Android side to the system Photo Picker means
/// the app needs NO photo/video library permission (Google Play Photo & Video
/// policy) and the user picks exactly what they share. On phones without the
/// Photo Picker, Google Play services back-ports it; on the oldest ones the
/// system document picker is used — also permission-free. A field flip: no
/// I/O, safe to call before runApp.
void usePhotoPicker() {
  try {
    final p = ImagePickerPlatform.instance;
    if (p is ImagePickerAndroid) p.useAndroidPhotoPicker = true;
  } catch (_) {
    // not Android / plugin not registered (tests): nothing to switch
  }
}
