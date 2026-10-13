import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';

/// Photo enhance (launch gap E) — OWN photos only. Hard rules surfaced in the
/// UI: the user must confirm the photo is their own and NOT an ID / official
/// document (hard block + warning); only faithful, non-generative operations
/// are offered (no fabricated content). A higher-quality cloud path is gated
/// off until an owner photo provider is connected — the screen shows the
/// on-device path and an "Available when ___" note.
class PhotoEnhanceScreen extends StatefulWidget {
  const PhotoEnhanceScreen({super.key});
  @override
  State<PhotoEnhanceScreen> createState() => _PhotoEnhanceScreenState();
}

class _PhotoEnhanceScreenState extends State<PhotoEnhanceScreen> {
  final _picker = ImagePicker();
  File? _picked;
  bool _ownPhoto = false;
  // User-declared photo kind. We pass this real kind to the server so its
  // document hard-block is reachable as defense-in-depth (true ID detection
  // needs an ML model = key-gated). 'personal' = an ordinary own photo;
  // 'document' = an ID / official document, which the server refuses.
  String _kind = 'personal';
  // faithful, non-generative operations only
  final Map<String, bool> _ops = {
    'denoise': true,
    'sharpen': true,
    'auto_levels': false,
    'contrast': false,
    'upscale': false,
  };
  bool _busy = false;
  Map<String, dynamic>? _plan;

  Future<void> _pick(ImageSource source) async {
    final x = await _picker.pickImage(source: source, imageQuality: 95);
    if (x != null) {
      setState(() {
        _picked = File(x.path);
        _plan = null;
      });
    }
  }

  bool get _canRun =>
      _picked != null &&
      _ownPhoto &&
      // NOTE: we intentionally do NOT gate on kind here. A "document" selection
      // is allowed to reach the server so its hard-block fires (defense-in-
      // depth) and the user sees the honest refusal, rather than a silently
      // disabled button. Own-photo attestation is still required.
      _ops.values.any((v) => v);

  Future<void> _run() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ops = [for (final e in _ops.entries) if (e.value) e.key];
    setState(() => _busy = true);
    try {
      // Backend confirms the plan is allowed (re-checks the document/own-photo
      // and faithful-ops rules server-side) and returns the processing path.
      final r = await context.read<AppState>().api.photoEnhancePlan(
            kind: _kind,
            ops: ops,
            ownPhoto: _ownPhoto,
          );
      setState(() => _plan = r);
      if (r['allowed'] != true) {
        messenger.showSnackBar(
            SnackBar(content: Text(r['message'] as String? ?? t.photoBlocked)));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.photoOffline)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cloud = _plan?['path'] == 'cloud';
    return Scaffold(
      appBar: AppBar(title: Text(t.photoTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Hard safety warning — always visible.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded,
                  color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(t.photoNeverDocuments,
                    style: TextStyle(color: scheme.onErrorContainer)),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          if (_picked != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(_picked!, height: 200, fit: BoxFit.cover,
                  width: double.infinity),
            )
          else
            Container(
              height: 160,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(child: Text(t.photoPickHint)),
            ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(t.photoFromGallery),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pick(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(t.photoFromCamera),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _ownPhoto,
            onChanged: (v) => setState(() => _ownPhoto = v ?? false),
            title: Text(t.photoConfirmOwn),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 4),
          // User DECLARES the kind. Picking "ID / document" sets kind=document
          // so the server hard-block is reachable (defense-in-depth). True ID
          // detection needs an ML model (key-gated); this keeps us honest.
          Align(
            alignment: Alignment.centerLeft,
            child: Text(t.photoConfirmNotDocument,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                  value: 'personal',
                  icon: const Icon(Icons.person_outline, size: 16),
                  label: Text(t.photoKindPersonal)),
              ButtonSegment(
                  value: 'document',
                  icon: const Icon(Icons.badge_outlined, size: 16),
                  label: Text(t.photoKindDocument)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 8),
          Text(t.photoOpsLabel,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          for (final key in _ops.keys)
            CheckboxListTile(
              dense: true,
              value: _ops[key],
              onChanged: (v) => setState(() => _ops[key] = v ?? false),
              title: Text(_opLabel(t, key)),
              contentPadding: EdgeInsets.zero,
            ),
          const SizedBox(height: 8),
          // Cloud path key-gated note.
          Card(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                const Icon(Icons.cloud_queue),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(
                        cloud ? t.photoCloudActive : t.photoCloudUnavailable,
                        style: const TextStyle(fontSize: 13))),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_canRun && !_busy) ? _run : null,
              icon: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_fix_high_outlined),
              label: Text(t.photoEnhanceButton),
            ),
          ),
          if (_plan != null && _plan!['allowed'] == true) ...[
            const SizedBox(height: 12),
            Text(t.photoReady, style: TextStyle(color: scheme.primary)),
          ],
        ],
      ),
    );
  }

  String _opLabel(AppLocalizations t, String key) {
    switch (key) {
      case 'denoise':
        return t.photoOpDenoise;
      case 'sharpen':
        return t.photoOpSharpen;
      case 'auto_levels':
        return t.photoOpAutoLevels;
      case 'contrast':
        return t.photoOpContrast;
      case 'upscale':
        return t.photoOpUpscale;
    }
    return key;
  }
}
