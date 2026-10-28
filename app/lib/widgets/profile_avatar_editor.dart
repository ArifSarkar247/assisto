import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'msgr_avatar.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// ADVANCED profile photo control (SPEC v2.1 §21, #98).
///
/// Shows the current avatar (photo, or a brand-tinted initial fallback via
/// [MsgrAvatar]) with a camera badge. Tapping opens a sheet to:
///   • take a photo (camera),
///   • choose from gallery,
///   • crop/reposition the chosen image to a square (real in-app crop), and
///   • remove the current photo.
///
/// Reports changes through [onChanged]: a non-empty base64 string sets a new
/// photo, `''` removes it, and `null` is never emitted (untouched = no call).
/// ORIGINAL look: Assisto gradient fallback, our own icons/wording. ZERO Bangla
/// glyphs in this file (all copy via ARB or [pStr]).
class ProfileAvatarEditor extends StatelessWidget {
  final String name;
  final String currentPhoto; // https/base64; '' => none
  final ValueChanged<String> onChanged; // '' removes, base64 sets
  final double radius;
  const ProfileAvatarEditor({
    super.key,
    required this.name,
    required this.currentPhoto,
    required this.onChanged,
    this.radius = 52,
  });

  Future<void> _openSheet(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final choice = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_rounded),
            title: Text(t.msgrTakePhoto),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: Text(t.msgrPickFromGallery),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          if (currentPhoto.isNotEmpty)
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
              title: Text(t.msgrRemovePhoto,
                  style: TextStyle(color: scheme.error)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
        ]),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 'remove') {
      onChanged('');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).pfPhotoRemoved)));
      return;
    }
    final picker = ImagePicker();
    // A modest square source cap; the real crop happens in [_CropDialog].
    final x = await picker.pickImage(
      source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 90,
    );
    if (x == null || !context.mounted) return;
    final bytes = await x.readAsBytes();
    if (!context.mounted) return;
    final cropped = await showDialog<Uint8List>(
      context: context,
      builder: (_) => _CropDialog(bytes: bytes),
    );
    if (cropped != null) onChanged(base64Encode(cropped));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(children: [
        Semantics(
          button: true,
          label: t.msgrChangePhoto,
          child: Stack(children: [
            MsgrAvatar(name: name, photoUrl: currentPhoto, radius: radius),
            Positioned(
              right: 0,
              bottom: 0,
              child: Material(
                color: scheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _openSheet(context),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.photo_camera_rounded,
                        size: 18, color: scheme.onPrimary),
                  ),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: () => _openSheet(context),
          child: Text(t.msgrChangePhoto),
        ),
        if (currentPhoto.isEmpty)
          Text(AppLocalizations.of(context).pfNoPhotoYet,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// Real square crop: pan/zoom the source inside a fixed square viewport, then
/// capture exactly that viewport to PNG bytes. No extra plugins — uses an
/// [InteractiveViewer] inside a [RepaintBoundary].
class _CropDialog extends StatefulWidget {
  final Uint8List bytes;
  const _CropDialog({required this.bytes});
  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  final _boundaryKey = GlobalKey();
  bool _busy = false;

  Future<void> _use() async {
    setState(() => _busy = true);
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) Navigator.pop(context);
        return;
      }
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted) return;
      Navigator.pop(context, data?.buffer.asUint8List());
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(AppLocalizations.of(context).pfCropTitle),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(AppLocalizations.of(context).pfCropHint,
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: RepaintBoundary(
              key: _boundaryKey,
              child: Container(
                color: Colors.black,
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4,
                  clipBehavior: Clip.hardEdge,
                  child: Image.memory(widget.bytes, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(t.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _use,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(AppLocalizations.of(context).pfCropUse),
        ),
      ],
    );
  }
}
