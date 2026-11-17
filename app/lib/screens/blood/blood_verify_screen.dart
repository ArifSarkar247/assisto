import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../ds/ds.dart';
import '../../widgets/app_sheet.dart';
import 'bp_common.dart';
import 'package:assisto/ads/ad_block_context.dart' show AdBlockedState;

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

class _BloodVerifyScreenState extends State<BloodVerifyScreen>
    with AdBlockedState<BloodVerifyScreen> {
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
    final ds = DsTokens.of(context);
    final text = Theme.of(context).textTheme;
    // designv2: hero (what + privacy) → photo slot → two pick buttons → send
    return Scaffold(
      appBar: AppBar(title: Text(t.bpVerifyCta)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          DsHeroCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(Icons.verified_rounded, color: ds.primaryInk, size: 28),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(t.bpVerifyLead,
                    style: text.bodyLarge?.copyWith(color: ds.text, fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: Gap.sm),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.lock_rounded, color: ds.muted, size: 18),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(t.bpVerifyPrivacy,
                    style: text.bodySmall?.copyWith(color: ds.muted))),
              ]),
            ]),
          ),
          const SizedBox(height: Gap.md),
          if (_photo != null) ...[
            DsCard(
              padding: const EdgeInsets.all(Gap.sm),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(DsRadius.small),
                child: Image.memory(_photo!, height: 220, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: Gap.md),
          ],
          Row(children: [
            Expanded(child: DsButton.secondary(
              key: const ValueKey('bp-verify-camera'),
              label: t.bpVerifyCamera,
              icon: Icons.photo_camera_outlined,
              expand: true,
              onPressed: () => unawaited(_pick(ImageSource.camera)),
            )),
            const SizedBox(width: Gap.sm),
            Expanded(child: DsButton.secondary(
              key: const ValueKey('bp-verify-gallery'),
              label: t.bpVerifyGallery,
              icon: Icons.photo_library_outlined,
              expand: true,
              onPressed: () => unawaited(_pick(ImageSource.gallery)),
            )),
          ]),
          const SizedBox(height: Gap.lg),
          DsButton(
            key: const ValueKey('bp-verify-send'),
            label: t.bpVerifySend,
            icon: Icons.send_rounded,
            expand: true,
            busy: _busy,
            onPressed: _photo == null ? null : _send,
          ),
        ],
      ),
    );
  }
}
