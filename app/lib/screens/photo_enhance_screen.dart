import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import '../state.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import '../widgets/photo_strings.dart';
import '../widgets/photo_presets.dart';
import '../widgets/photo_canvas.dart';
import '../widgets/photo_compare.dart';

/// Photo enhance — ADVANCED (SPEC v2.1 §21). OWN photos only.
///
/// GOOD -> ADVANCED upgrade. What ships now, offline, on CPU, 100% faithful
/// (no fabricated/invented content, identity NEVER altered):
///   - pick (gallery/camera) with own-photo attestation + kind declaration;
///   - real basic adjustments: brightness / contrast / saturation / sharpness
///     sliders, 90° rotate, small straighten, square crop, auto-fix, reset;
///   - one-tap presets (document scan / portrait) + a passport/ID-size preset
///     that LINKS OUT to the exact-size web tool (never edits identity);
///   - before/after compare (split slider + press-&-hold original);
///   - save (PNG to device) + share — exporting exactly what you see;
///   - a batch note (one-at-a-time for now, honest).
/// KEY-GATED, HONESTLY: AI upscale / denoise / background cleanup stay off and
/// say so plainly (🔑) — the screen re-checks the server plan and NEVER fakes a
/// result. ID / official documents are hard-blocked server-side.
class PhotoEnhanceScreen extends StatefulWidget {
  const PhotoEnhanceScreen({super.key});
  @override
  State<PhotoEnhanceScreen> createState() => _PhotoEnhanceScreenState();
}

enum _Phase { empty, editing, busy }

class _PhotoEnhanceScreenState extends State<PhotoEnhanceScreen> {
  final _picker = ImagePicker();
  final _captureKey = GlobalKey();

  File? _picked;
  _Phase _phase = _Phase.empty;
  bool _permBlocked = false;

  bool _ownPhoto = false;
  // Declared kind. 'document' reaches the server so its ID hard-block fires
  // (defense-in-depth) — true ID detection needs an ML model (key-gated).
  String _kind = 'personal';

  // Faithful, non-generative adjustments.
  PhotoAdjustments _adj = const PhotoAdjustments();
  String? _presetId;
  bool _showCompare = false;

  // AI enhance (key-gated honest). Selected AI ops + the server plan result.
  final Map<String, bool> _aiOps = {
    'upscale': false,
    'denoise': false,
    'background_replace': false,
  };
  Map<String, dynamic>? _aiPlan;

  // ---- pick ---------------------------------------------------------------
  Future<void> _pick(ImageSource source) async {
    try {
      final x = await _picker.pickImage(source: source, imageQuality: 97);
      if (x != null) {
        setState(() {
          _picked = File(x.path);
          _adj = const PhotoAdjustments();
          _presetId = null;
          _aiPlan = null;
          _permBlocked = false;
          _phase = _Phase.editing;
        });
      }
    } catch (_) {
      // image_picker throws on a hard permission denial.
      setState(() => _permBlocked = true);
    }
  }

  // ---- faithful adjustment helpers ----------------------------------------
  void _set(PhotoAdjustments next) =>
      setState(() {
        _adj = next;
        _presetId = null; // manual tweak clears the active preset badge
      });

  void _autoFix() {
    // A gentle, faithful "auto" grade — the same knobs, nothing invented.
    setState(() {
      _adj = _adj.copyWith(
          brightness: 1.06, contrast: 1.18, saturation: 1.06, sharpness: 0.3);
      _presetId = null;
    });
  }

  void _reset() => setState(() {
        _adj = const PhotoAdjustments();
        _presetId = null;
      });

  void _applyPreset(PhotoPreset p) => setState(() {
        _adj = p.adjustments;
        _presetId = p.id;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).phPresetApplied),
            duration: const Duration(seconds: 1)));
      });

  Future<void> _openPassportTool() async {
    final uri = Uri.parse('${AppConfig.apiBase}/photo');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ---- AI enhance (key-gated, honest; re-checked server-side) -------------
  Future<void> _checkAi() async {
    final messenger = ScaffoldMessenger.of(context);
    final ops = [for (final e in _aiOps.entries) if (e.value) e.key];
    if (ops.isEmpty) return;
    setState(() => _phase = _Phase.busy);
    try {
      final r = await context.read<AppState>().api.photoEnhancePlan(
            kind: _kind,
            ops: ops,
            ownPhoto: _ownPhoto,
          );
      if (!mounted) return;
      setState(() {
        _aiPlan = r;
        _phase = _Phase.editing;
      });
      if (r['allowed'] != true) {
        messenger.showSnackBar(SnackBar(
            content: Text(r['message'] as String? ??
                AppLocalizations.of(context).photoBlocked)));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _Phase.editing);
      messenger.showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).photoOffline)));
    }
  }

  // ---- export: save / share (faithful pixels only) ------------------------
  Future<File?> _export() async {
    // The capture boundary only lives on the plain canvas (not the compare
    // view). Leave compare mode and let it mount for a frame before capturing,
    // so Save/Share always export the faithful result the user is editing.
    if (_showCompare) {
      setState(() => _showCompare = false);
      await WidgetsBinding.instance.endOfFrame;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/assisto_photo_${DateTime.now().millisecondsSinceEpoch}.png';
    return capturePng(_captureKey, path);
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final f = await _export();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
        content: Text(f != null
            ? AppLocalizations.of(context).phSaved
            : AppLocalizations.of(context).phSaveFailed)));
  }

  Future<void> _share() async {
    final f = await _export();
    if (f == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).phSaveFailed)));
      }
      return;
    }
    await Share.shareXFiles([XFile(f.path)]);
  }

  // ---- build --------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.photoTitle), actions: [
        if (_picked != null)
          IconButton(
            tooltip: AppLocalizations.of(context).phChangePhoto,
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => _pick(ImageSource.gallery),
          ),
      ]),
      body: _permBlocked
          ? _permissionState(context)
          : _picked == null
              ? _emptyState(context, t)
              : _editor(context, t),
    );
  }

  // ---- honest states -------------------------------------------------------
  Widget _emptyState(BuildContext context, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _safetyBanner(context, t),
        const SizedBox(height: 24),
        Icon(Icons.add_photo_alternate_outlined,
            size: 64, color: scheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Center(
            child: Text(AppLocalizations.of(context).phEmptyTitle,
                style: Theme.of(context).textTheme.titleMedium)),
        const SizedBox(height: 4),
        Center(
          child: Text(AppLocalizations.of(context).phEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 20),
        _pickRow(context, t),
      ],
    );
  }

  Widget _permissionState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline, size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(AppLocalizations.of(context).phPermTitle,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(AppLocalizations.of(context).phPermBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _pick(ImageSource.gallery),
            icon: const Icon(Icons.refresh),
            label: Text(AppLocalizations.of(context).phRetry),
          ),
        ]),
      ),
    );
  }

  Widget _pickRow(BuildContext context, AppLocalizations t) => Row(children: [
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
      ]);

  Widget _safetyBanner(BuildContext context, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(Icons.verified_user_outlined, color: scheme.onErrorContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.photoNeverDocuments,
                  style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(AppLocalizations.of(context).phNeverIds,
                  style: TextStyle(
                      color: scheme.onErrorContainer, fontSize: 12)),
            ],
          ),
        ),
      ]),
    );
  }

  // ---- editor --------------------------------------------------------------
  Widget _editor(BuildContext context, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final busy = _phase == _Phase.busy;
    return Stack(children: [
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _safetyBanner(context, t),
          const SizedBox(height: 14),

          // Preview — compare mode or plain faithful canvas.
          if (_showCompare)
            PhotoCompare(
              original: Image.file(_picked!,
                  fit: BoxFit.cover, width: double.infinity),
              adjusted: PhotoCanvas(image: _picked!, adj: _adj),
            )
          else
            PhotoCanvas(
                image: _picked!, adj: _adj, captureKey: _captureKey),
          const SizedBox(height: 8),
          Row(children: [
            TextButton.icon(
              onPressed: () => setState(() => _showCompare = !_showCompare),
              icon: Icon(_showCompare
                  ? Icons.image_outlined
                  : Icons.compare_outlined),
              label: Text(AppLocalizations.of(context).phHeadCompare),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _adj.isNeutral ? null : _reset,
              icon: const Icon(Icons.restart_alt),
              label: Text(AppLocalizations.of(context).phReset),
            ),
          ]),
          const Divider(height: 20),

          // Own-photo attestation + kind (reaches the server hard-block).
          CheckboxListTile(
            value: _ownPhoto,
            onChanged: (v) => setState(() => _ownPhoto = v ?? false),
            title: Text(t.photoConfirmOwn),
            contentPadding: EdgeInsets.zero,
          ),
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
          const SizedBox(height: 18),

          // ---- basic faithful adjustments ----
          _sectionTitle(context, AppLocalizations.of(context).phHeadAdjust),
          _slider(context, 'phBrightness', _adj.brightness, 0.6, 1.4,
              (v) => _set(_adj.copyWith(brightness: v))),
          _slider(context, 'phContrast', _adj.contrast, 0.6, 1.6,
              (v) => _set(_adj.copyWith(contrast: v))),
          _slider(context, 'phSaturation', _adj.saturation, 0.0, 1.8,
              (v) => _set(_adj.copyWith(saturation: v))),
          _slider(context, 'phSharpness', _adj.sharpness, 0.0, 1.0,
              (v) => _set(_adj.copyWith(sharpness: v))),
          _slider(context, 'phStraighten', _adj.straightenDeg, -15, 15,
              (v) => _set(_adj.copyWith(straightenDeg: v))),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => _set(_adj.copyWith(
                  rotationQuarters: (_adj.rotationQuarters + 1) % 4)),
              icon: const Icon(Icons.rotate_right),
              label: Text(AppLocalizations.of(context).phRotate),
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  _set(_adj.copyWith(squareCrop: !_adj.squareCrop)),
              icon: Icon(_adj.squareCrop
                  ? Icons.crop_square
                  : Icons.crop_free),
              label: Text(_adj.squareCrop
                  ? AppLocalizations.of(context).phCropSquare
                  : AppLocalizations.of(context).phCropFree),
            ),
            FilledButton.tonalIcon(
              onPressed: _autoFix,
              icon: const Icon(Icons.auto_fix_normal),
              label: Text(AppLocalizations.of(context).phAutoFix),
            ),
          ]),
          const SizedBox(height: 18),

          // ---- presets ----
          _sectionTitle(context, AppLocalizations.of(context).phHeadPresets),
          PhotoPresetBar(
            selectedId: _presetId,
            onApply: _applyPreset,
            onOpenWebTool: _openPassportTool,
          ),
          const SizedBox(height: 10),

          // ---- AI enhance (key-gated, honest) ----
          _sectionTitle(context, AppLocalizations.of(context).phHeadAi),
          _aiSection(context, scheme),
          const SizedBox(height: 16),

          // ---- save / share ----
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : _save,
                icon: const Icon(Icons.download_outlined),
                label: Text(AppLocalizations.of(context).phSave),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _share,
                icon: const Icon(Icons.ios_share),
                label: Text(AppLocalizations.of(context).phShare),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(AppLocalizations.of(context).phExportHint,
              style:
                  TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),

          // ---- batch note (honest) ----
          Row(children: [
            Icon(Icons.collections_outlined,
                size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(AppLocalizations.of(context).phBatchNote,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          ]),
        ],
      ),

      // Loading overlay (server plan check).
      if (busy)
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.35),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 10),
                Text(AppLocalizations.of(context).phLoading,
                    style: const TextStyle(color: Colors.white)),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
      );

  Widget _slider(BuildContext context, String labelKey, double value,
      double min, double max, ValueChanged<double> onChanged) {
    final scheme = Theme.of(context).colorScheme;
    // Percent readout in Bangla-aware digits (keeps numbers localized).
    final pct = (((value - min) / (max - min)) * 100).round();
    return Semantics(
      slider: true,
      label: phLabel(context, labelKey),
      value: '${pNum(context, pct)}%',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text(phLabel(context, labelKey),
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            Text('${pNum(context, pct)}%',
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _aiSection(BuildContext context, ColorScheme scheme) {
    final t = AppLocalizations.of(context);
    final active = _aiPlan?['allowed'] == true && _aiPlan?['path'] == 'cloud';
    final anyAi = _aiOps.values.any((v) => v);
    return Column(children: [
      // Honest gated note — key required. Never a fake result.
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('\u{1F511}', style: TextStyle(fontSize: 15)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    active
                        ? AppLocalizations.of(context).phAiActive
                        : AppLocalizations.of(context).phAiGatedTitle,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (!active)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(AppLocalizations.of(context).phKeyBadge,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.onTertiaryContainer)),
                ),
            ]),
            if (!active) ...[
              const SizedBox(height: 6),
              Text(AppLocalizations.of(context).phAiGatedBody,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
      // AI op choices — selectable so the honest server plan can be requested;
      // the result is never faked (allowed=false shows the real refusal).
      _aiTile(context, 'upscale', 'phAiUpscale'),
      _aiTile(context, 'denoise', 'phAiDenoise'),
      _aiTile(context, 'background_replace', 'phAiBg'),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: (anyAi && _ownPhoto) ? _checkAi : null,
          icon: const Icon(Icons.cloud_sync_outlined),
          label: Text(t.photoEnhanceButton),
        ),
      ),
      if (_aiPlan != null && _aiPlan!['allowed'] == true)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t.photoReady,
              style: TextStyle(color: scheme.primary)),
        ),
    ]);
  }

  Widget _aiTile(BuildContext context, String key, String labelKey) =>
      CheckboxListTile(
        dense: true,
        value: _aiOps[key],
        onChanged: (v) => setState(() {
          _aiOps[key] = v ?? false;
          _aiPlan = null; // re-check required after a change
        }),
        title: Text(phLabel(context, labelKey)),
        secondary: const Text('\u{1F511}', style: TextStyle(fontSize: 14)),
        contentPadding: EdgeInsets.zero,
      );
}
