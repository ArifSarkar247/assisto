import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'bp_common.dart';

/// blood (owner 2 Nov) — "verified donor" badge from a donation slip photo.
/// Seen ONLY by the Assisto team in Owner Admin; the photo is deleted as soon
/// as it is reviewed; never shown to other users. Camera or gallery (the
/// system picker — no storage permission). Pops `true` when sent.
class BloodVerifyScreen extends StatefulWidget {
  const BloodVerifyScreen({super.key, this.pick});
  final Future<Uint8List?> Function(ImageSource src)? pick;

  @override
  State<BloodVerifyScreen> createState() => _BloodVerifyScreenState();
}

class _BloodVerifyScreenState extends State<BloodVerifyScreen> {
  Uint8List? _photo;
  bool _busy = false;

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _pick(ImageSource src) async {
    Uint8List? bytes;
    try {
      if (widget.pick != null) {
        bytes = await widget.pick!(src);
      } else {
        final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, imageQuality: 85);
        bytes = x == null ? null : await x.readAsBytes();
      }
    } catch (_) {
      bytes = null;
    }
    if (!mounted || bytes == null) return;
    setState(() => _photo = bytes);
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final p = _photo;
    if (p == null) return;
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.bpVerify(base64Encode(p));
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['ok'] == true) {
        _snack(t.bpVerifySent);
        Navigator.of(context).pop(true);
      } else {
        _snack(bpReason(t, r['reason'] as String?));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(t.bpErrGeneric);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.bpVerifyCta)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(t.bpVerifyLead, style: text.bodyMedium),
          const SizedBox(height: Gap.md),
          Text(t.bpVerifyPrivacy, style: text.bodySmall),
          const SizedBox(height: Gap.lg),
          if (_photo != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.md),
              child: Image.memory(_photo!, height: 220, fit: BoxFit.contain),
            ),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 48),
              child: OutlinedButton.icon(
                key: const ValueKey('bp-verify-camera'),
                onPressed: () => _pick(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(t.bpVerifyCamera),
              ),
            ),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 48),
              child: OutlinedButton.icon(
                key: const ValueKey('bp-verify-gallery'),
                onPressed: () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(t.bpVerifyGallery),
              ),
            ),
          ]),
          const SizedBox(height: Gap.lg),
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton(
              key: const ValueKey('bp-verify-send'),
              onPressed: _photo == null || _busy ? null : _send,
              child: Text(t.bpVerifySend),
            ),
          ),
        ],
      ),
    );
  }
}
