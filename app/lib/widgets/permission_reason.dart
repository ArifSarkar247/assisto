import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';

/// Shows a clear bilingual reason BEFORE a runtime permission is requested, so
/// the user understands why (better grant rate, Play-policy friendly). Returns
/// true if the user chose to continue.
Future<bool> showPermissionReason(
  BuildContext context, {
  required IconData icon,
  required String reasonBn,
  required String reasonEn,
}) async {
  final en = context.read<AppState>().locale?.languageCode == 'en';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        icon: Icon(icon, size: 36, color: scheme.primary),
        content: Text(en ? reasonEn : reasonBn,
            textAlign: TextAlign.center, style: const TextStyle(height: 1.4)),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(en ? 'Not now' : 'এখন না')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(en ? 'Continue' : 'চালিয়ে যান')),
        ],
      );
    },
  );
  return ok == true;
}

/// Common reasons (bn/en) reused across the app.
class PermReasons {
  PermReasons._();
  static const mic = (
    icon: Icons.mic_none,
    bn: 'আপনি যা বলবেন তা লেখায় বদলাতে মাইক্রোফোন লাগবে। রেকর্ডিং সেভ হয় না।',
    en: "I need the microphone to turn your speech into text. Nothing is recorded or stored."
  );
  static const location = (
    icon: Icons.location_on_outlined,
    bn: 'কাছের জায়গা খুঁজতে / জরুরি অবস্থায় লোকেশন শেয়ার করতে আপনার অবস্থান লাগবে।',
    en: 'Your location is needed to find nearby places / share it in an emergency.'
  );
  static const camera = (
    icon: Icons.photo_camera_outlined,
    bn: 'ডকুমেন্ট/বিলের ছবি তুলতে ক্যামেরা লাগবে। ছবি শুধু আপনার কাছেই থাকে।',
    en: 'The camera is needed to photograph a document/bill. Photos stay only with you.'
  );
}

/// Small helper for a brand-styled empty permission prompt inside a screen.
Widget permissionBlock(BuildContext context,
    {required IconData icon, required String text, required VoidCallback onTap,
    required String button}) {
  final scheme = Theme.of(context).colorScheme;
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(Gap.xxl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 48, color: scheme.primary),
        const SizedBox(height: Gap.lg),
        Text(text, textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),
        FilledButton(onPressed: onTap, child: Text(button)),
      ]),
    ),
  );
}
