import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../photo_studio/ps_backend.dart';
import '../photo_studio/ps_controller.dart';
import '../photo_studio/ps_engines.dart';
import '../photo_studio/ps_enhance.dart' show AiPlan, StudioEnhanceEngine;
import '../photo_studio/ps_gate_sheet.dart';
import '../photo_studio/ps_models.dart';
import '../photo_studio/ps_report.dart';
import '../photo_studio/ps_tools.dart';
import '../photo_studio/ps_web_import.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../widgets/photo_compare.dart';
import '../widgets/skeleton.dart';
import '../widgets/voice_input.dart';
import 'plans_screen.dart';

/// PHOTO STUDIO (ps1-photo) — "your face stays yours, just at its best".
///
/// * Free users: entry interstitial first (server-capped, default 30 min),
///   reduced watermarked preview, and EVERY exit (save / share / wallpaper /
///   copy / open-in) goes through [PhotoStudioController.export] -> the one
///   export gate (rewarded ads verified server-side, or credits).
/// * Premium / Business: no ads ever, clean full-quality saves.
/// * One-tap enhance runs on-device ([StudioEnhanceEngine]): the instant
///   classical pipeline on every phone + optional AI restore (downloaded once
///   from our server, then offline), the AI result kept only when the face
///   check passes.
/// * Prompt edits need the cloud image-AI key: without it the section is
///   hidden; the owner sees a small "add a key" note instead.
class PhotoStudioScreen extends StatefulWidget {
  const PhotoStudioScreen(
      {super.key, this.deps, this.controller, this.webImport});

  /// w1-webphoto: a photo made on lifeassisto.com/photo, opened by the deep
  /// link. Exported through the same gate as every other result.
  final WebPhotoImport? webImport;

  /// Inject for tests / the screenshot gallery; default talks to the server.
  final PsDeps? deps;

  /// A pre-built controller (gallery states). Not disposed by the screen.
  final PhotoStudioController? controller;

  @override
  State<PhotoStudioScreen> createState() => _PhotoStudioScreenState();
}

class _PhotoStudioScreenState extends State<PhotoStudioScreen> {
  late final PhotoStudioController _c;
  late final bool _ownsController;
  final _prompt = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation();

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _c = widget.controller ??
        PhotoStudioController(widget.deps ??
            PsDeps(backend: ApiPsBackend(context.read<AppState>().api)));
    _c.addListener(_onChange);
    if (_ownsController) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _c.init();
        final w = widget.webImport;
        if (w != null && !_c.disposed && _c.phase == PsPhase.open) {
          _c.loadWebImport(w);
        }
      });
    }
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    final n = _c.notice;
    if (n == PsNotice.none || n == PsNotice.refused) return;
    final text = _noticeText(AppLocalizations.of(context), n);
    if (text.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    if (_ownsController) _c.dispose();
    _prompt.dispose();
    _voice.dispose();
    super.dispose();
  }

  String _noticeText(AppLocalizations t, PsNotice n) => switch (n) {
        PsNotice.enhancePreparing => t.psEnhancePreparing,
        PsNotice.identityCheckMissing => t.psIdentityUnavailable,
        PsNotice.aiFellBack => t.psAiFellBack,
        PsNotice.aiDownloadFailed => t.psAiDownloadFailed,
        PsNotice.identityFailed => t.psIdentityFailed,
        PsNotice.providerMissing => t.psProviderMissing(_c.noticeText),
        PsNotice.sinkUnavailable => t.psSinkUnavailable,
        PsNotice.adUnavailable => t.psAdUnavailable,
        PsNotice.insufficient =>
          _c.noticeText.isNotEmpty ? _c.noticeText : t.psInsufficient,
        PsNotice.failed =>
          _c.noticeText.isNotEmpty ? _c.noticeText : t.psFailed,
        PsNotice.saved => t.psSaved,
        PsNotice.shared => t.psShared,
        PsNotice.opened => t.psOpened,
        PsNotice.cancelled => t.psCancelled,
        PsNotice.needPhoto => t.psNeedPhoto,
        PsNotice.needPrompt => t.psNeedPrompt,
        PsNotice.webImportNoEdit => t.psWebEditNote,
        PsNotice.aiStepFailed => t.d1psAiStepFailed,
        PsNotice.toolFailed => t.d1psToolFailed,
        PsNotice.noSubject => t.d1psNoSubject,
        PsNotice.tooBig => t.d1psTooBig,
        PsNotice.batchDone => t.d1psBatchDone,
        PsNotice.refused || PsNotice.none => '',
      };

  // ------------------------------------------------------------------ d1-photo helpers
  /// "12 s" / "2 min" (localised) from milliseconds (rounded up, never 0).
  String _dur(AppLocalizations t, int ms) {
    final sec = math.max(1, (ms / 1000).ceil());
    if (sec < 90) return t.d1psSeconds(fmtInt(context, sec));
    return t.d1psMinutes(fmtInt(context, (sec / 60).ceil()));
  }

  String _mb(int bytes) {
    final tenths = (bytes / (1024 * 1024) * 10).round();
    return '${fmtInt(context, tenths ~/ 10)}.${fmtInt(context, tenths % 10)} MB';
  }

  String _toolLabel(AppLocalizations t, PsTool tool) => switch (tool) {
        PsTool.upscale2x => t.d1psToolUpscale2x,
        PsTool.upscale4x => t.d1psToolUpscale4x,
        PsTool.denoise => t.d1psToolDenoise,
        PsTool.lowLight => t.d1psToolLowLight,
        PsTool.bgBlur => t.d1psToolBgBlur,
      };

  IconData _toolIcon(PsTool tool) => switch (tool) {
        PsTool.upscale2x => Icons.zoom_in_rounded,
        PsTool.upscale4x => Icons.zoom_out_map_rounded,
        PsTool.denoise => Icons.grain_rounded,
        PsTool.lowLight => Icons.light_mode_outlined,
        PsTool.bgBlur => Icons.blur_on_rounded,
      };

  String _restoreLabel(AppLocalizations t, PsFeature f) => switch (f) {
        PsFeature.deblur => t.d1psRestoreDeblur,
        PsFeature.colorize => t.d1psRestoreColorize,
        PsFeature.oldRestore => t.d1psRestoreOld,
        _ => f.wire,
      };

  String _stageText(AppLocalizations t, PsProgress p) => switch (p.stage) {
        PsStage.download => t.d1psStageDownload(p.fraction == null
            ? ''
            : '${fmtInt(context, (p.fraction! * 100).round())}%'),
        PsStage.analyse => t.d1psStageAnalyse,
        PsStage.ai => p.total > 0
            ? t.d1psStageAi(fmtInt(context, p.done), fmtInt(context, p.total))
            : t.psWorking,
        PsStage.mask => t.d1psStageMask,
        PsStage.classic => t.d1psStageClassic,
        PsStage.server => t.d1psStageServer,
        PsStage.batch => t.d1psStageBatch(fmtInt(context, p.item), fmtInt(context, p.items)),
      };

  void _openPlans() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const PlansScreen()));

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = _c.session;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.psTitle),
        actions: [
          if (s != null) ...[
            IconButton(
                tooltip: t.psUndo,
                onPressed: s.canUndo ? _c.undo : null,
                icon: const Icon(Icons.undo_rounded)),
            IconButton(
                tooltip: t.psRedo,
                onPressed: s.canRedo ? _c.redo : null,
                icon: const Icon(Icons.redo_rounded)),
            IconButton(
                key: const Key('psHistory'),
                tooltip: t.psHistory,
                onPressed: _history,
                icon: const Icon(Icons.history_rounded)),
          ],
        ],
      ),
      body: switch (_c.phase) {
        PsPhase.loading => const SkeletonList(),
        PsPhase.entryAd => _entryTransition(t),
        PsPhase.error => StateMessage(
            icon: Icons.cloud_off_outlined,
            title: t.loadFailed,
            message: t.loadFailedBody,
            tint: Brand.danger,
            action: FilledButton.icon(
                onPressed: _c.init,
                icon: const Icon(Icons.refresh),
                label: Text(t.retry)),
          ),
        PsPhase.open => _studio(t),
      },
    );
  }

  Widget _entryTransition(AppLocalizations t) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
                gradient: Brand.gradient, shape: BoxShape.circle),
            child:
                const Icon(Icons.auto_awesome, color: Colors.white, size: 34),
          ),
          const SizedBox(height: Gap.lg),
          Text(t.psOpening, style: Theme.of(context).textTheme.titleMedium),
        ]),
      );

  Widget _studio(AppLocalizations t) {
    final s = _c.session;
    return Stack(children: [
      ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl * 2),
        children: [
          if (s == null) _hero(t) else _preview(t),
          const SizedBox(height: Gap.lg),
          if (_c.refusal != null) ...[
            _refusalCard(t),
            const SizedBox(height: Gap.lg)
          ],
          if (_c.webImport)
            _webCard(t)
          else ...[
            if (_c.batch.isNotEmpty) ...[
              _batchCard(t),
              const SizedBox(height: Gap.lg)
            ],
            if (s != null && _c.enhance.ready) ...[
              _enhanceCard(t),
              const SizedBox(height: Gap.lg)
            ],
            if (s != null && _c.tools.any) ...[
              _toolsCard(t),
              const SizedBox(height: Gap.lg)
            ],
            if (s != null && _showRestore) ...[
              _restoreCard(t),
              const SizedBox(height: Gap.lg)
            ],
            // d) prompt edits only exist with a cloud image-AI key; without
            // one users see nothing (never a dead button), the owner a note.
            if (_c.config.providerReady)
              _promptCard(t)
            else if (_c.config.isOwner)
              _ownerKeyNote(t),
          ],
          const SizedBox(height: Gap.lg),
          if (s != null) _exportCard(t),
          const SizedBox(height: Gap.md),
          _footNotes(t),
        ],
      ),
      if (_c.busy)
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black26,
            child: Center(child: _progressCard(t)),
          ),
        ),
    ]);
  }

  /// d1-photo: honest progress — the real stage, real tile/photo counts from
  /// the engine, a time left estimate from THIS phone's measured speed, and
  /// Cancel (nothing is kept or charged).
  Widget _progressCard(AppLocalizations t) {
    final p = _c.progress;
    final scheme = Theme.of(context).colorScheme;
    final canCancel = p != null && p.stage != PsStage.server;
    final eta = p?.etaMs;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Card(
        key: const Key('psProgress'),
        margin: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
              const SizedBox(width: Gap.md),
              Expanded(
                  child: Text(p == null ? t.psWorking : _stageText(t, p),
                      style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
            if (p?.fraction != null) ...[
              const SizedBox(height: Gap.md),
              LinearProgressIndicator(key: const Key('psProgressBar'), value: p!.fraction),
            ],
            if (eta != null && eta > 0) ...[
              const SizedBox(height: Gap.xs),
              Text(t.d1psLeft(_dur(t, eta)),
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ],
            if (canCancel) ...[
              const SizedBox(height: Gap.sm),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  key: const Key('psCancelRun'),
                  onPressed: _c.cancelRun,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: Text(t.cancel),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ d1 tools
  Widget _toolsCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final av = _c.tools;
    final list = [for (final x in PsTool.values) if (av.has(x)) x];
    final dl = (av.needsUpscaleModel ? _c.enhance.aiBytes : 0) +
        (av.needsMaskModel ? (_c.config.aiModel.segment?.size ?? 0) : 0);
    return _card(icon: Icons.handyman_outlined, title: t.d1psToolsTitle, children: [
      Text(t.d1psToolsBody, style: TextStyle(color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final tool in list)
          ActionChip(
            key: Key('psTool_${tool.wire}'),
            avatar: Icon(_toolIcon(tool), size: 18, color: scheme.primary),
            label: Text(av.etaMs[tool] == null
                ? _toolLabel(t, tool)
                : '${_toolLabel(t, tool)} · ${t.d1psAbout(_dur(t, av.etaMs[tool]!))}'),
            onPressed: _c.busy ? null : () => _c.runTool(tool),
          ),
      ]),
      if (dl > 0) _infoLine(Icons.download_outlined, t.d1psFirstDownload(_mb(dl))),
      if (_c.free) ...[
        const SizedBox(height: Gap.sm),
        _costLine(t, _c.config.quote(PsFeature.enhanceHd)),
      ],
    ]);
  }

  /// Server / GPU restore: only the jobs the server can really run AND
  /// price are shown; the owner sees what is still missing.
  Widget _restoreCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    const feats = [PsFeature.oldRestore, PsFeature.colorize, PsFeature.deblur];
    final ready = [for (final f in feats) if (_c.config.restoreReady(f)) f];
    final owner = _c.config.isOwner;
    return _card(icon: Icons.auto_fix_normal_outlined, title: t.d1psRestoreTitle, children: [
      Text(t.d1psRestoreBody, style: TextStyle(color: scheme.onSurfaceVariant)),
      if (ready.isNotEmpty) ...[
        const SizedBox(height: Gap.md),
        for (final f in ready) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: Key('psRestore_${f.wire}'),
              onPressed: _c.busy
                  ? null
                  : () => _c.runRestore(
                      f, SheetGateUi(context, forRun: true, onPremium: _c.free ? _openPlans : null)),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text(_restoreLabel(t, f)),
            ),
          ),
          if (f == PsFeature.oldRestore)
            SwitchListTile(
              key: const Key('psRestoreColorize'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.d1psRestoreColorizeToo),
              value: _c.restoreColorize,
              onChanged: _c.busy ? null : (v) => setState(() => _c.restoreColorize = v),
            ),
          if (_c.free) _costLine(t, _c.config.quote(f)),
          const SizedBox(height: Gap.sm),
        ],
      ],
      if (owner) ...[
        for (final f in feats)
          if (!_c.config.restoreReady(f))
            _infoLine(
                Icons.key_outlined,
                t.d1psOwnerRestoreNeeds(_restoreLabel(t, f),
                    _c.config.restoreNeeds[f.wire] ?? _c.config.quote(f).message)),
        _infoLine(Icons.face_outlined, t.d1psOwnerNoFaceModel),
      ],
    ]);
  }

  bool get _showRestore {
    const feats = [PsFeature.oldRestore, PsFeature.colorize, PsFeature.deblur];
    return _c.config.isOwner || feats.any(_c.config.restoreReady);
  }

  // ------------------------------------------------------------------ d1 batch
  Widget _batchCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final av = _c.tools;
    String status(BatchItem it) => switch (it.status) {
          BatchStatus.waiting => t.d1psBatchWaiting,
          BatchStatus.running => t.d1psBatchRunning,
          BatchStatus.done => t.d1psBatchOpen,
          BatchStatus.failed => t.d1psBatchFailed,
          BatchStatus.skipped => t.d1psBatchSkipped,
          BatchStatus.cancelled => t.d1psBatchStopped,
        };
    final running = _c.batchRunning;
    return _card(
        icon: Icons.burst_mode_outlined,
        title: t.d1psBatchTitle(fmtInt(context, _c.batch.length)),
        children: [
          Text(t.d1psBatchBody, style: TextStyle(color: scheme.onSurfaceVariant)),
          _infoLine(Icons.info_outline, t.d1psBatchLimit(fmtInt(context, PhotoStudioController.batchMax))),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            FilledButton.icon(
              key: const Key('psBatchEnhance'),
              onPressed: running || _c.busy ? null : () => _c.runBatch(),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(t.d1psBatchEnhance),
            ),
            for (final tool in const [PsTool.lowLight, PsTool.denoise, PsTool.bgBlur])
              if (tool != PsTool.bgBlur || av.bgBlur)
                OutlinedButton.icon(
                  key: Key('psBatch_${tool.wire}'),
                  onPressed: running || _c.busy ? null : () => _c.runBatch(tool: tool),
                  icon: Icon(_toolIcon(tool), size: 18),
                  label: Text(_toolLabel(t, tool)),
                ),
          ]),
          const SizedBox(height: Gap.md),
          for (var i = 0; i < _c.batch.length; i++)
            ListTile(
              key: Key('psBatchItem_$i'),
              contentPadding: EdgeInsets.zero,
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.xs),
                child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Image.memory(_c.batch[i].output ?? _c.batch[i].input,
                        fit: BoxFit.cover, cacheWidth: 96, gaplessPlayback: true)),
              ),
              title: Text(t.d1psBatchPhoto(fmtInt(context, i + 1))),
              subtitle: Text(_c.batch[i].status == BatchStatus.skipped ||
                      _c.batch[i].status == BatchStatus.failed
                  ? '${status(_c.batch[i])} — ${_noticeText(t, _c.batch[i].reason)}'
                  : status(_c.batch[i])),
              trailing: _c.batch[i].status == BatchStatus.done
                  ? const Icon(Icons.open_in_full_rounded)
                  : (_c.batch[i].status == BatchStatus.running
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : null),
              onTap: _c.batch[i].status == BatchStatus.done && !running
                  ? () => _c.openBatchItem(i)
                  : null,
            ),
          if (!running)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('psBatchClear'),
                onPressed: _c.clearBatch,
                icon: const Icon(Icons.clear_all_rounded, size: 18),
                label: Text(t.d1psBatchClear),
              ),
            ),
        ]);
  }

  // ------------------------------------------------------------------ hero
  Widget _hero(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.xl),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Brand.cyan.withValues(alpha: 0.18),
            Brand.blue.withValues(alpha: 0.16),
            Brand.purple.withValues(alpha: 0.20),
          ],
        ),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 52,
          height: 52,
          decoration: const BoxDecoration(
              gradient: Brand.gradient, shape: BoxShape.circle),
          child: const Icon(Icons.auto_awesome, color: Colors.white, size: 26),
        ),
        const SizedBox(height: Gap.md),
        Text(t.psTagline,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800, height: 1.25)),
        const SizedBox(height: Gap.sm),
        Text(_c.config.providerReady ? t.psEmptyBody : t.psEmptyBodyNoPrompt,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.icon(
            key: const Key('psPickGallery'),
            onPressed: () => _c.pick(camera: false),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(t.psPickGallery),
          ),
          OutlinedButton.icon(
            onPressed: () => _c.pick(camera: true),
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(t.psPickCamera),
          ),
          if (_c.enhance.ready)
            OutlinedButton.icon(
              key: const Key('psPickBatch'),
              onPressed: _c.busy ? null : _c.pickBatch,
              icon: const Icon(Icons.burst_mode_outlined),
              label: Text(t.d1psBatchButton),
            ),
        ]),
        if (!_c.free) ...[
          const SizedBox(height: Gap.md),
          _pill(Icons.workspace_premium_outlined, t.psPremiumClean,
              Brand.success),
        ],
      ]),
    );
  }

  Widget _pill(IconData icon, String text, Color color) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: Gap.xs),
          Flexible(child: Text(text, style: const TextStyle(fontSize: 12.5))),
        ]),
      );

  // ------------------------------------------------------------------ preview
  Widget _image(Uint8List bytes) => Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: _c.free ? math.min(_c.config.previewMaxPx, 1024) : null,
      );

  Widget _preview(AppLocalizations t) {
    final s = _c.session!;
    final cur = s.current;
    final Widget img = _c.webImport
        // website photo: one framed passport/visa picture (no before/after)
        ? ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: SizedBox(
                  height: 300,
                  width: double.infinity,
                  child: Image.memory(cur.bytes,
                      key: const Key('psWebImage'),
                      fit: BoxFit.contain,
                      gaplessPlayback: true)),
            ),
          )
        : s.edited
        ? PhotoCompare(
            original: _image(s.original.bytes),
            adjusted: _c.free
                ? Stack(fit: StackFit.expand, children: [
                    _image(cur.bytes),
                    const IgnorePointer(child: _Watermark()),
                  ])
                : _image(cur.bytes),
            height: 300,
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: SizedBox(
                height: 300, width: double.infinity, child: _image(cur.bytes)),
          );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      img,
      const SizedBox(height: Gap.sm),
      if (!_c.webImport)
      Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _pill(Icons.verified_outlined, t.psOriginalKept, Brand.success),
            TextButton.icon(
              onPressed: () => _c.pick(camera: false),
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: Text(t.psChangePhoto),
            ),
          ]),
      if (_c.free) ...[
        const SizedBox(height: Gap.xs),
        _infoLine(Icons.lock_outline, t.psPreviewNote),
        if (_c.secureActive)
          _infoLine(Icons.no_photography_outlined, t.psSecureOn),
      ],
    ]);
  }

  // w1-webphoto: what this website photo is, and how to edit instead.
  Widget _webCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return _card(
        icon: Icons.badge_outlined,
        title: t.psWebTitle,
        children: [
          if (_c.webLabel.isNotEmpty) ...[
            Text(_c.webLabel,
                key: const Key('psWebLabel'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
          ],
          Text(t.psWebBody,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
            key: const Key('psWebPickOriginal'),
            onPressed: () => _c.pick(camera: false),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(t.psWebPickOriginal),
          ),
        ]);
  }

  Widget _infoLine(IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                    height: 1.35))),
      ]),
    );
  }

  // ------------------------------------------------------------------ cards
  Widget _card(
      {required IconData icon,
      required String title,
      required List<Widget> children}) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16.5))),
          ]),
          const SizedBox(height: Gap.md),
          ...children,
        ]),
      ),
    );
  }

  Widget _enhanceCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final av = _c.enhance;
    return _card(
        icon: Icons.auto_fix_high_rounded,
        title: t.psEnhanceTitle,
        children: [
          Text(t.psEnhanceBody,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          Text(t.psStrength,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<EditStrength>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                    value: EditStrength.light, label: Text(t.psStrengthLight)),
                ButtonSegment(
                    value: EditStrength.natural,
                    label: Text(t.psStrengthNatural)),
                ButtonSegment(
                    value: EditStrength.strong,
                    label: Text(t.psStrengthStrong)),
              ],
              selected: {_c.strength},
              onSelectionChanged: (v) => _c.setStrength(v.first),
            ),
          ),
          if (_c.aiEligible && av.ai != AiState.notOffered) ...[
            const SizedBox(height: Gap.sm),
            _aiRow(t, av),
          ],
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('psEnhance'),
              onPressed: _c.busy ? null : _c.runEnhance,
              icon: const Icon(Icons.auto_awesome),
              label: Text(t.psEnhanceButton),
            ),
          ),
          const SizedBox(height: Gap.xs),
          _infoLine(Icons.face_retouching_natural, t.psEnhanceHow),
          if (_c.lastReport.aiUsed && _c.session?.edited == true) ...[
            const SizedBox(height: Gap.sm),
            _pill(Icons.verified_user_outlined, t.psAiUsed, Brand.success),
          ],
          if (_c.lastReport.aiRejected && _c.session?.edited == true)
            _infoLine(Icons.info_outline, t.psAiFellBack),
          if (_c.free) ...[
            const SizedBox(height: Gap.sm),
            _costLine(t, _c.config.quote(PsFeature.enhanceHd)),
          ],
        ]);
  }

  /// p2-photo: AI restore & upscale switch with its honest download state.
  Widget _aiRow(AppLocalizations t, EnhanceAvailability av) {
    final scheme = Theme.of(context).colorScheme;
    final tenths = (av.aiBytes / (1024 * 1024) * 10).round();
    final size = '${fmtInt(context, tenths ~/ 10)}.${fmtInt(context, tenths % 10)} MB';
    final String sub;
    switch (av.ai) {
      case AiState.needsDownload:
        sub = t.psAiSubtitleDownload(size);
      case AiState.downloading:
        sub = t.psAiDownloading('${fmtInt(context, (av.progress * 100).round())}%');
      case AiState.failed:
        sub = t.psAiDownloadFailed;
      case AiState.ready:
      case AiState.notOffered:
        sub = t.psAiReady;
    }
    // d1-photo: what the AI step will really do for THIS photo
    final plan = _c.aiPlan;
    final planLine = plan == null
        ? null
        : t.d1psAiCopy(fmtInt(context, plan.targetLong),
            t.d1psAbout(_dur(t, plan.tileCount * _msPerTile)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile(
        key: const Key('psAiSwitch'),
        contentPadding: EdgeInsets.zero,
        secondary: Icon(Icons.auto_fix_high_outlined, color: scheme.primary),
        title: Text(t.psAiTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(planLine == null ? sub : '$sub\n$planLine',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3)),
        value: _c.aiOn,
        onChanged: (_c.busy || av.ai == AiState.downloading) ? null : _c.setAi,
      ),
      if (av.ai == AiState.downloading)
        LinearProgressIndicator(key: const Key('psAiProgress'), value: av.progress),
      if (av.ai == AiState.failed && _c.aiOn)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('psAiRetry'),
            onPressed: _c.busy ? null : _c.prepareEnhance,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(t.retry),
          ),
        ),
    ]);
  }

  int get _msPerTile {
    final e = _c.deps.engine;
    return e is StudioEnhanceEngine ? e.perf.msPerTile : AiPlan.defaultMsPerTile;
  }

  /// p2-photo d): owner-only note when no cloud image-AI key is connected.
  Widget _ownerKeyNote(AppLocalizations t) => Container(
        key: const Key('psOwnerKeyNote'),
        child: _statusBox(Icons.key_outlined, t.psOwnerAddKey,
            Theme.of(context).colorScheme.onSurfaceVariant),
      );

  Widget _statusBox(IconData icon, String text, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ]),
      );

  Widget _costLine(AppLocalizations t, FeatureQuote q) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[];
    if (q.free) parts.add(t.psCostIncluded);
    final a = q.ads;
    if (a != null) {
      parts.add(t.qa1PsCostAds(a.ads, fmtInt(context, a.ads)) + // qa1: plural
          (a.trial ? ' · ${t.psFreeTrial}' : ''));
    }
    final c = q.credits;
    if (c != null) {
      parts.add(c.via == 'pool'
          ? t.psCostPool(fmtInt(context, c.credits))
          : t.psCostCredits(fmtInt(context, c.credits)));
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.toll_outlined, size: 16, color: scheme.onSurfaceVariant),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: Text(parts.join('  ·  '),
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant))),
    ]);
  }

  String _optLabel(AppLocalizations t, String id) => switch (id) {
        'bg_change' => t.psOptBgChange,
        'bg_remove' => t.psOptBgRemove,
        'bg_blur' => t.psOptBgBlur,
        'sky_replace' => t.psOptSky,
        'remove_objects' => t.psOptRemoveObjects,
        'lighting' => t.psOptLighting,
        'passport_bd' => t.psOptPassport,
        'visa_bd' => t.psOptVisa,
        'product_photo' => t.psOptProduct,
        'document_cleanup' => t.psOptDocument,
        'crop_straighten' => t.psOptCrop,
        'beauty_retouch' => t.psOptBeauty,
        _ => id,
      };

  String _beautyLabel(AppLocalizations t, String id) => switch (id) {
        'skin_smooth' => t.psBeautySkinSmooth,
        'blemish_remove' => t.psBeautyBlemish,
        'under_eye' => t.psBeautyUnderEye,
        'even_tone' => t.psBeautyEvenTone,
        'glow' => t.psBeautyGlow,
        'teeth_whiten' => t.psBeautyTeeth,
        'eye_brighten' => t.psBeautyEyes,
        'hair_tidy' => t.psBeautyHair,
        'light_makeup' => t.psBeautyMakeup,
        _ => id,
      };

  Widget _promptCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final hasPhoto = _c.session != null;
    final feature = hasPhoto ? PsFeature.promptEdit : PsFeature.generate;
    final q = _c.config.quote(feature);
    return _card(
        icon: Icons.edit_note_rounded,
        title: t.psPromptTitle,
        children: [
          if (!hasPhoto)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(t.psGenerateNoPhoto,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          TextField(
            key: const Key('psPrompt'),
            controller: _prompt,
            minLines: 1,
            maxLines: 4,
            maxLength: 500,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: t.psPromptHint,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md)),
              counterText: '',
              suffixIcon: VoiceMicButton(voice: _voice, input: _prompt),
            ),
          ),
          if (hasPhoto) ...[
            const SizedBox(height: Gap.md),
            Text(t.psReadyOptions,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (final id in PsOptions.ready)
                if (!(id == 'beauty_retouch' && _c.childInPhoto))
                  FilterChip(
                    key: Key('psOpt_$id'),
                    label: Text(_optLabel(t, id)),
                    selected: _c.options.contains(id),
                    onSelected: (_) => _c.toggleOption(id),
                  ),
            ]),
            if (_c.options.contains('beauty_retouch')) ...[
              const SizedBox(height: Gap.md),
              Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                for (final b in PsOptions.beautyAllowed)
                  FilterChip(
                    label: Text(_beautyLabel(t, b)),
                    selected: _c.beauty.contains(b),
                    onSelected: (_) => _c.toggleBeauty(b),
                  ),
              ]),
              const SizedBox(height: Gap.sm),
              _infoLine(Icons.face_retouching_natural, t.psBeautyRule),
            ],
            const SizedBox(height: Gap.sm),
            _switch(t.psHasPeople, _c.hasPeople, _c.setHasPeople,
                const Key('psHasPeople')),
            _switch(t.psOthers, _c.othersInPhoto, _c.setOthers,
                const Key('psOthers')),
            _switch(
                t.psChild, _c.childInPhoto, _c.setChild, const Key('psChild')),
            if (_c.othersInPhoto)
              _statusBox(Icons.handshake_outlined, t.psConsent, scheme.primary),
            if (_c.childInPhoto) ...[
              const SizedBox(height: Gap.sm),
              _statusBox(Icons.child_care_outlined, t.psChildCaution,
                  Brand.warnInk(context)),
            ],
          ],
          const SizedBox(height: Gap.md),
          _costLine(t, q),
          if (_c.free && _c.config.trialsLeft != null) ...[
            const SizedBox(height: Gap.xs),
            Text(t.psTrialsLeft(fmtInt(context, _c.config.trialsLeft!)),
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              key: const Key('psRunPrompt'),
              onPressed: _c.busy
                  ? null
                  : () => _c.runPrompt(
                      _prompt.text,
                      SheetGateUi(context,
                          forRun: true,
                          onPremium: _c.free ? _openPlans : null)),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: Text(hasPhoto ? t.psRunEdit : t.psRunGenerate),
            ),
          ),
        ]);
  }

  Widget _switch(String label, bool value, ValueChanged<bool> on, Key key) =>
      SwitchListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label),
        value: value,
        onChanged: on,
      );

  Widget _refusalCard(AppLocalizations t) {
    final r = _c.refusal!;
    return Container(
      key: const Key('psRefusal'),
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: Brand.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: Brand.danger.withValues(alpha: 0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.shield_outlined, color: Brand.danger),
        const SizedBox(width: Gap.md),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.psRefusedTitle,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.xs),
            Text(r.message.isNotEmpty ? r.message : t.psSafetyNote,
                style: const TextStyle(height: 1.35)),
          ]),
        ),
      ]),
    );
  }

  Widget _exportCard(AppLocalizations t) {
    final enabled = _c.canExport && !_c.busy;
    Widget tile(ExportKind k, IconData icon, String label) => _ExportTile(
          key: Key('psExport_${k.wire}'),
          icon: icon,
          label: label,
          enabled: enabled,
          available: _c.deps.sink.available(k),
          onTap: () => _c.export(
              k, SheetGateUi(context, onPremium: _c.free ? _openPlans : null)),
        );
    return _card(
        icon: Icons.ios_share_rounded,
        title: t.psExportTitle,
        children: [
          LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth >= 420 ? 5 : 3;
            final w = (c.maxWidth - Gap.sm * (cols - 1)) / cols;
            return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (final e in [
                tile(ExportKind.save, Icons.download_rounded, t.psSave),
                tile(ExportKind.share, Icons.share_rounded, t.psShare),
                tile(ExportKind.wallpaper, Icons.wallpaper_rounded,
                    t.psWallpaper),
                tile(ExportKind.copy, Icons.copy_rounded, t.psCopy),
                tile(ExportKind.openIn, Icons.open_in_new_rounded, t.psOpenIn),
              ])
                SizedBox(width: w, child: e),
            ]);
          }),
          if (_c.free) ...[
            const SizedBox(height: Gap.sm),
            _costLine(t, _c.config.quote(PsFeature.enhanceHd)),
            _infoLine(Icons.branding_watermark_outlined, t.psCornerNote),
          ],
        ]);
  }

  Widget _footNotes(AppLocalizations t) => Column(children: [
        _infoLine(Icons.shield_moon_outlined, t.psSafetyNote),
        _infoLine(Icons.info_outline, t.psAiMetaNote),
      ]);

  Future<void> _history() async {
    final t = AppLocalizations.of(context);
    final s = _c.session;
    if (s == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: Text(t.psHistory,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          for (var i = 0; i < s.versions.length; i++)
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.xs),
                child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Image.memory(s.versions[i].bytes,
                        fit: BoxFit.cover, cacheWidth: 96)),
              ),
              title: Text(i == 0
                  ? t.psVersionOriginal
                  : t.psVersionEdit(fmtInt(context, i))),
              trailing: i == s.index
                  ? const Icon(Icons.check_circle, color: Brand.success)
                  : null,
              onTap: () {
                s.select(i);
                Navigator.of(ctx).pop();
              },
            ),
        ]),
      ),
    );
  }
}

class _ExportTile extends StatelessWidget {
  const _ExportTile(
      {super.key,
      required this.icon,
      required this.label,
      required this.enabled,
      required this.available,
      required this.onTap});
  final IconData icon;
  final String label;
  final bool enabled;
  final bool available;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = enabled;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: on ? 1 : 0.5),
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: on ? onTap : null,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.xs),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                color: on
                    ? (available ? scheme.primary : scheme.onSurfaceVariant)
                    : scheme.outline),
            const SizedBox(height: Gap.xs),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                    fontSize: 12.5,
                    color: on ? scheme.onSurface : scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

/// Visible diagonal watermark over the FREE preview (pixels-level the preview
/// is also reduced-size; full quality only through the export gate).
class _Watermark extends StatelessWidget {
  const _Watermark();
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: CustomPaint(
            painter: _WatermarkPainter(DefaultTextStyle.of(context).style.fontFamily)),
      );
}

class _WatermarkPainter extends CustomPainter {
  _WatermarkPainter(this.fontFamily);
  final String? fontFamily;
  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
          text: 'Assisto preview',
          style: TextStyle(
              fontFamily: fontFamily,
              color: const Color(0x66FFFFFF),
              fontSize: 15,
              fontWeight: FontWeight.w700,
              shadows: const [Shadow(blurRadius: 2, color: Color(0x55000000))])),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-math.pi / 7);
    final stepX = tp.width + 36, stepY = tp.height + 44;
    final r = math.max(size.width, size.height);
    for (var y = -r; y < r; y += stepY) {
      for (var x = -r; x < r; x += stepX) {
        tp.paint(canvas,
            Offset(x + ((y / stepY).round().isEven ? 0 : stepX / 2), y));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
