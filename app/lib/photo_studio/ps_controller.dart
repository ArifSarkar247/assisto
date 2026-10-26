import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../ads/ad_placements.dart' show AdMoments;
import 'ps_ads.dart';
import 'ps_backend.dart';
import 'ps_engines.dart';
import 'ps_enhance.dart';
import 'ps_export.dart';
import 'ps_models.dart';
import 'ps_native.dart';
import 'ps_report.dart';
import 'ps_session.dart';
import 'ps_tools.dart';
import 'ps_web_import.dart';

/// Image source seam (gallery / camera). Tests inject bytes.
abstract class PhotoPicker {
  Future<Uint8List?> pick({required bool camera});

  /// d1-photo batch: several gallery photos (at most [limit]).
  Future<List<Uint8List>> pickMany({int limit = PhotoStudioController.batchMax});
}

class ImagePickerPhotoPicker implements PhotoPicker {
  ImagePickerPhotoPicker();
  final _p = ImagePicker();
  @override
  Future<Uint8List?> pick({required bool camera}) async {
    try {
      final x = await _p.pickImage(
          source: camera ? ImageSource.camera : ImageSource.gallery,
          imageQuality: 97);
      return x == null ? null : await x.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Uint8List>> pickMany({int limit = PhotoStudioController.batchMax}) async {
    try {
      final xs = await _p.pickMultiImage(imageQuality: 97, limit: limit);
      final out = <Uint8List>[];
      for (final x in xs.take(limit)) {
        out.add(await x.readAsBytes());
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}

/// d1-photo batch: one photo of a batch run.
enum BatchStatus { waiting, running, done, failed, skipped, cancelled }

class BatchItem {
  BatchItem(this.input);
  final Uint8List input;
  Uint8List? output;
  BatchStatus status = BatchStatus.waiting;

  /// For failed/skipped: a PsNotice the screen localises.
  PsNotice reason = PsNotice.none;
}

/// Everything Photo Studio depends on, injectable for tests + the gallery.
///
/// p2-photo: by default the REAL on-device parts are wired: one lazy
/// [ChannelPhotoNative] (ML Kit faces + ONNX Runtime upscaler) feeds the
/// face detector, the identity guard (landmarks) and [StudioEnhanceEngine].
/// Nothing touches the platform until Photo Studio opens ([PhotoStudioController.init]).
class PsDeps {
  factory PsDeps({
    required PsBackend backend,
    PhotoAdBridge? ads,
    PhotoNative? native,
    EnhanceEngine? engine,
    FaceDetector? faces,
    IdentityGuard? guard,
    SecureScreen secure = const ChannelSecureScreen(),
    ExportSink sink = const PlatformExportSink(),
    ExportRenderer renderer = const UiExportRenderer(),
    PhotoPicker? picker,
    PsReporter? reporter,
  }) {
    final n = native ?? ChannelPhotoNative();
    final g = guard ?? IdentityGuard(landmarks: NativeLandmarks(n));
    final rep = reporter ?? defaultPsReporter;
    return PsDeps._(
      backend: backend,
      ads: ads ?? createPhotoAdBridge(),
      native: n,
      engine: engine ?? StudioEnhanceEngine(native: n, guard: g, reporter: rep),
      reporter: rep,
      faces: faces ?? NativeFaceDetector(n),
      guard: g,
      secure: secure,
      sink: sink,
      renderer: renderer,
      picker: picker ?? ImagePickerPhotoPicker(),
    );
  }
  PsDeps._({
    required this.backend,
    required this.ads,
    required this.native,
    required this.engine,
    required this.faces,
    required this.guard,
    required this.secure,
    required this.sink,
    required this.renderer,
    required this.picker,
    required this.reporter,
  });
  final PsBackend backend;
  final PhotoAdBridge ads;
  final PhotoNative native;
  final EnhanceEngine engine;
  final FaceDetector faces;
  final IdentityGuard guard;
  final SecureScreen secure;
  final ExportSink sink;
  final ExportRenderer renderer;
  final PhotoPicker picker;

  /// d1-photo: every Photo Studio failure -> crash-report pipe (non-PII).
  final PsReporter reporter;
}

enum PsPhase { loading, entryAd, open, error }

/// Honest notices the screen renders (localised there).
enum PsNotice {
  none,
  enhancePreparing,

  /// p2-photo: a cloud edit of a photo with people, on a phone where the
  /// on-device face check could not run (ML Kit failed) — nothing charged.
  identityCheckMissing,

  /// p2-photo: the AI result did not keep the face -> classical result used.
  aiFellBack,

  /// p2-photo: the one-time AI model download failed (retry possible).
  aiDownloadFailed,
  identityFailed,
  providerMissing,
  sinkUnavailable,
  adUnavailable,
  insufficient,
  failed,
  saved,
  shared,
  opened,
  cancelled,
  refused,
  needPhoto,
  needPrompt,

  /// w1-webphoto: the website photo is a (watermarked) preview of a server
  /// job — it is exported as-is; editing needs the user's original photo.
  webImportNoEdit,

  /// d1-photo: the AI step failed on this phone (reported); the safe
  /// classical result is shown instead.
  aiStepFailed,

  /// d1-photo: a tool failed for real (reported) — nothing was changed.
  toolFailed,

  /// d1-photo: background blur found no clear person/subject (or it would
  /// have blurred a face) — nothing was changed.
  noSubject,

  /// d1-photo: the photo is too big for this upscale factor.
  tooBig,

  /// d1-photo: a batch finished (counts in [PhotoStudioController.batch]).
  batchDone,

  /// d1-photo v2: today's free HD enhances / this week's free AI are used
  /// (server message in noticeText; the screen offers Premium).
  limitReached,

  /// d1-photo v2: the server photo worker is still busy after the wait.
  stillWorking,

  /// d1-photo v2: "Report this AI image" sent.
  reported,

  /// photo-final: the job waits in the server queue for tomorrow's budget
  /// (nothing charged; the result appears when it has run).
  queuedBudget,
}

class PhotoStudioController extends ChangeNotifier {
  PhotoStudioController(this.deps);
  final PsDeps deps;

  PsPhase phase = PsPhase.loading;
  PsConfig config = const PsConfig();
  PhotoSession? session;
  EnhanceAvailability enhance = EnhanceAvailability.unavailable;

  /// p2-photo: the user's "AI restore & upscale" switch, and whether the
  /// current photo is small enough for it (big photos don't need it).
  bool aiOn = false;
  bool aiEligible = false;

  /// Faces ML Kit found in the current photo (null = detector unavailable).
  int? facesFound;
  EnhanceReport lastReport = EnhanceReport.none;
  EditStrength strength = EditStrength.natural;
  final Set<String> options = {};
  final Set<String> beauty = {};
  bool othersInPhoto = false;
  bool childInPhoto = false;
  bool hasPeople = true;
  bool busy = false;
  bool secureActive = false;
  PsNotice notice = PsNotice.none;
  String noticeText = '';
  SafetyVerdict? refusal;
  bool disposed = false;

  /// w1-webphoto: the current session came from lifeassisto.com/photo.
  bool webImport = false;
  String webLabel = '';

  final Map<int, EditStrength> _versionStrength = {};

  bool get free => config.free;

  // ------------------------------------------------------------------ d1-photo
  /// Live progress of the running job (null = nothing running). Real counts
  /// from the engine: model bytes, AI tiles, batch photos.
  PsProgress? progress;

  /// Cancel was pressed; the engine stops after the current tile.
  bool cancelling = false;

  /// d1-photo: tools this phone can run on the current photo.
  ToolsAvailability tools = ToolsAvailability.none;

  /// The AI step's plan for the current photo (size it works at + tiles) —
  /// shown honestly next to the switch.
  AiPlan? aiPlan;

  /// d1-photo: old-photo restore also colourises (black & white photos).
  bool restoreColorize = true;

  /// d1-photo v2: the user confirmed the OTHER people in the photo agreed
  /// to an AI edit (server refuses realistic AI edits of others without it).
  bool consentOthers = false;

  /// d1-photo v2: FACE LOCK result per version index (server AI results).
  final Map<int, FaceLockInfo> faceLockOf = {};
  FaceLockInfo? get currentFaceLock => session == null ? null : faceLockOf[session!.index];

  /// Poll interval / max wait for a queued server job (tests shorten them).
  Duration pollEvery = const Duration(seconds: 2);
  Duration pollMax = const Duration(minutes: 8);

  /// Batch run (at most [batchMax] photos — nothing unlimited).
  static const batchMax = 10;
  final List<BatchItem> batch = [];
  bool batchRunning = false;
  bool _batchCancel = false;
  PsTool? batchTool;

  PhotoToolEngine? get _tools {
    final e = deps.engine;
    return e is PhotoToolEngine ? e as PhotoToolEngine : null;
  }

  void _onProgress(PsProgress p) {
    progress = p;
    _notify();
  }

  /// Report a failure (non-PII) — never throws.
  void _report(String stage, Object e) {
    try {
      deps.reporter(e is PhotoStudioFailure
          ? e
          : PhotoStudioFailure(stage, psErrorCode(e), model: config.aiModel.version));
    } catch (_) {}
  }

  /// Stop the running job: the engine stops after the current tile; nothing
  /// is kept and nothing is charged.
  Future<void> cancelRun() async {
    _batchCancel = true;
    cancelling = true; // the overlay says "Stopping…" until the tile ends
    _notify();
    try {
      await _tools?.cancel();
    } catch (_) {}
  }

  Future<void> init() async {
    phase = PsPhase.loading;
    _notify();
    try {
      config = await deps.backend.config();
    } catch (_) {
      phase = PsPhase.error;
      _notify();
      return;
    }
    // p2-photo: probe the native parts now (cheap class lookups) — never at
    // app launch, only when Photo Studio opens.
    try {
      await deps.native.probe();
    } catch (_) {}
    final eng = deps.engine;
    if (eng is StudioEnhanceEngine) eng.model = config.aiModel;
    final te = _tools;
    if (te != null) te.progress = _onProgress;
    try {
      enhance = await deps.engine.availability();
    } catch (e) {
      _report('availability', e);
      enhance = EnhanceAvailability.unavailable;
    }
    // model already on the phone: AI restore starts switched on (for big
    // photos it is switched off again in _inspect — it works on a copy)
    aiOn = enhance.ai == AiState.ready;
    // ENTRY AD: free users only, server-capped (30 min default), shown BEFORE
    // the studio opens with a natural transition. Never for Premium/Business.
    if (config.free && config.entryAdDue) {
      phase = PsPhase.entryAd;
      _notify();
      var shown = false;
      try {
        shown = await deps.ads.showInterstitial(config.interstitialUnit);
      } catch (_) {
        shown = false;
      }
      if (shown) {
        try {
          await deps.backend.entryAd(shown: true);
        } catch (_) {}
      }
    }
    phase = PsPhase.open;
    if (config.free) {
      secureActive = await deps.secure.enable();
    }
    _notify();
  }

  @override
  void dispose() {
    disposed = true;
    if (secureActive) unawaited(deps.secure.disable());
    super.dispose();
  }

  void _notify() {
    if (!disposed) notifyListeners();
  }

  void _say(PsNotice n, [String text = '']) {
    notice = n;
    noticeText = text;
    _notify();
  }

  void clearNotice() => _say(PsNotice.none);

  Future<void> pick({required bool camera}) async {
    final b = await deps.picker.pick(camera: camera);
    if (b == null) return;
    webImport = false;
    webLabel = '';
    session = PhotoSession(b);
    refusal = null;
    notice = PsNotice.none;
    facesFound = null;
    lastReport = EnhanceReport.none;
    _notify();
    await _inspect(b);
  }

  /// p2-photo: ML Kit faces -> "There are people in this photo" switch is
  /// set from what the phone actually sees (the user can still change it);
  /// and is this photo small enough for the AI step?
  Future<void> _inspect(Uint8List b) async {
    final eng = deps.engine;
    try {
      aiEligible = eng is StudioEnhanceEngine ? await eng.aiEligible(b) : false;
    } catch (_) {
      aiEligible = false;
    }
    // d1-photo: the honest size/time line + tool list for THIS photo
    aiPlan = null;
    if (eng is StudioEnhanceEngine && aiEligible) {
      aiPlan = await eng.aiPlanFor(b, maxLongEdge: config.free ? config.previewMaxPx : null);
      final s = await _sizeOf(b);
      // the AI step SHRINKS big photos (it works on a copy): off by default
      // there, on by default for small/old photos once the model is here
      if (s != null && aiPlan != null && aiPlan!.targetLong < math.max(s.w, s.h)) {
        aiOn = false;
      } else if (enhance.ai == AiState.ready) {
        aiOn = true;
      }
    }
    await _refreshTools(b);
    if (deps.faces.available) {
      try {
        final f = await deps.faces.detect(b);
        if (identical(session?.original.bytes, b)) {
          facesFound = f.length;
          hasPeople = f.isNotEmpty;
        }
      } catch (_) {}
    }
    _notify();
  }

  /// w1-webphoto: open a website photo. The shown bytes are the server's
  /// preview (watermarked for free users); the version carries the server
  /// job, so [export] runs the SAME gate and downloads the clean result only
  /// after it unlocks. Nothing here can export without the gate.
  void loadWebImport(WebPhotoImport imp) {
    final s = PhotoSession(imp.preview);
    s.push(PhotoVersion(
        bytes: imp.preview,
        feature: PsFeature.enhanceHd.wire,
        jobId: imp.job.id,
        previewOnly: config.free));
    session = s;
    webImport = true;
    webLabel = imp.label;
    if (imp.studioOption.isNotEmpty) options.add(imp.studioOption);
    refusal = null;
    notice = PsNotice.none;
    _notify();
  }

  void setStrength(EditStrength s) {
    strength = s;
    _notify();
  }

  void toggleOption(String id) {
    options.contains(id) ? options.remove(id) : options.add(id);
    if (id == 'beauty_retouch' && !options.contains(id)) beauty.clear();
    if ((id == 'product_photo' || id == 'document_cleanup') && options.contains(id)) {
      hasPeople = false;
    }
    _notify();
  }

  void toggleBeauty(String id) {
    beauty.contains(id) ? beauty.remove(id) : beauty.add(id);
    if (beauty.isNotEmpty) options.add('beauty_retouch');
    _notify();
  }

  void setOthers(bool v) {
    othersInPhoto = v;
    _notify();
  }

  void setChild(bool v) {
    childInPhoto = v;
    if (v) {
      beauty.clear();
      options.remove('beauty_retouch');
    }
    _notify();
  }

  void setHasPeople(bool v) {
    hasPeople = v;
    _notify();
  }

  // ------------------------------------------------------------------ enhance
  /// Start/resume the one-time AI model download (progress is shown live).
  Future<void> prepareEnhance() async {
    try {
      enhance = await deps.engine.prepare(onProgress: (a) {
        enhance = a;
        _notify();
      });
    } catch (e) {
      _report('download', e);
      enhance = enhance.withAi(AiState.failed);
    }
    final b = session?.current.bytes;
    if (b != null) await _refreshTools(b);
    if (enhance.ai == AiState.failed) _say(PsNotice.aiDownloadFailed);
    _notify();
  }

  /// The "AI restore & upscale" switch. Turning it on downloads the model
  /// the first time (in the app, from our server); after that it is offline.
  Future<void> setAi(bool on) async {
    aiOn = on;
    _notify();
    if (on && (enhance.ai == AiState.needsDownload || enhance.ai == AiState.failed)) {
      await prepareEnhance();
    }
  }

  bool get _aiForRun => aiOn && aiEligible && enhance.ai == AiState.ready;

  /// One-tap enhance (on-device). Preview only for free users; the full-HD
  /// render happens after the export gate.
  Future<void> runEnhance() async {
    final s = session;
    if (s == null) return _say(PsNotice.needPhoto);
    if (webImport) return _say(PsNotice.webImportNoEdit);
    if (!enhance.ready) return _say(PsNotice.failed);
    busy = true;
    progress = const PsProgress(PsStage.analyse);
    _notify();
    try {
      // The classical pipeline only changes tone/noise/sharpness per pixel —
      // it cannot move a facial feature, so it needs no identity check. The
      // optional AI step is checked INSIDE the engine (fallback to classical).
      final ai = _aiForRun;
      final req = EnhanceRequest(strength: strength, ai: ai)
          .withMaxLongEdge(config.free ? config.previewMaxPx : null);
      final out = await deps.engine.enhance(s.original.bytes, req);
      lastReport = deps.engine.lastReport;
      s.push(PhotoVersion(bytes: out, feature: 'enhance_hd', previewOnly: config.free));
      _versionStrength[s.index] = strength;
      _versionAi[s.index] = ai && lastReport.aiUsed;
      notice = PsNotice.none;
      if (lastReport.aiRejected) _say(PsNotice.aiFellBack);
      if (lastReport.aiFailed) _say(PsNotice.aiStepFailed);
    } on PsCancelled {
      _say(PsNotice.cancelled);
    } on EnhanceUnavailable {
      _say(PsNotice.failed);
    } catch (e) {
      _report('enhance', e);
      _say(PsNotice.failed);
    } finally {
      busy = false;
      progress = null;
      cancelling = false;
      _notify();
    }
  }

  // ------------------------------------------------------------------ tools
  Future<({int w, int h})?> _sizeOf(Uint8List b) async {
    final eng = deps.engine;
    if (eng is! StudioEnhanceEngine) return null;
    try {
      return await eng.codec.size(b);
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshTools(Uint8List b) async {
    final te = _tools;
    if (te == null) {
      tools = ToolsAvailability.none;
      return;
    }
    try {
      tools = await te.tools(b);
    } catch (e) {
      _report('tool', e);
      tools = ToolsAvailability.none;
    }
  }

  /// Run one on-device tool on the CURRENT version (tools chain: e.g.
  /// enhance, then blur the background). The result is full quality; free
  /// users still see it only as a protected preview and export through the
  /// same gate.
  Future<void> runTool(PsTool tool) async {
    final s = session;
    if (s == null) return _say(PsNotice.needPhoto);
    if (webImport) return _say(PsNotice.webImportNoEdit);
    final te = _tools;
    if (te == null || !tools.has(tool)) return _say(PsNotice.toolFailed);
    busy = true;
    progress = const PsProgress(PsStage.analyse);
    _notify();
    try {
      final out = await _runToolOn(te, tool, s.current.bytes);
      s.push(PhotoVersion(
          bytes: out, feature: 'enhance_hd', previewOnly: config.free, fullQuality: true,
          aiEdited: tool.usesAi));
      _versionAi[s.index] = tool.usesAi;
      notice = PsNotice.none;
      await _refreshTools(out);
    } on PsCancelled {
      _say(PsNotice.cancelled);
    } on PsIdentityRejected {
      _say(PsNotice.identityFailed);
    } on PsNoSubject {
      _say(PsNotice.noSubject);
    } on PhotoStudioFailure catch (f) {
      // already reported by the engine
      _say(f.code == 'too_big' ? PsNotice.tooBig : PsNotice.toolFailed);
    } catch (e) {
      _report('tool', e);
      _say(PsNotice.toolFailed);
    } finally {
      busy = false;
      progress = null;
      cancelling = false;
      _notify();
    }
  }

  Future<Uint8List> _runToolOn(PhotoToolEngine te, PsTool tool, Uint8List bytes) async {
    if ((tool.usesAi && tools.needsUpscaleModel) || (tool == PsTool.bgBlur && tools.needsMaskModel)) {
      progress = const PsProgress(PsStage.download);
      _notify();
      if (!await te.prepareTool(tool)) {
        throw const PhotoStudioFailure('download', 'failed');
      }
      if (tool.usesAi) enhance = enhance.withAi(AiState.ready, progress: 1);
      tools = await te.tools(bytes);
    }
    return te.runTool(tool, bytes);
  }

  // ------------------------------------------------------------------ batch
  /// Pick up to [batchMax] photos and run ONE tool (or the one-tap enhance
  /// when [tool] is null) on each, one after another, with progress. Each
  /// result can then be opened and exported through the normal gate.
  Future<void> pickBatch() async {
    final list = await deps.picker.pickMany(limit: batchMax);
    if (list.isEmpty) return;
    batch
      ..clear()
      ..addAll(list.take(batchMax).map(BatchItem.new));
    _notify();
  }

  void clearBatch() {
    if (batchRunning) return;
    batch.clear();
    _notify();
  }

  Future<void> runBatch({PsTool? tool}) async {
    if (batch.isEmpty || batchRunning) return;
    batchRunning = true;
    _batchCancel = false;
    batchTool = tool;
    busy = true;
    _notify();
    final te = _tools;
    try {
      for (var i = 0; i < batch.length; i++) {
        final it = batch[i];
        if (it.status == BatchStatus.done) continue;
        if (_batchCancel) {
          it.status = BatchStatus.cancelled;
          continue;
        }
        it.status = BatchStatus.running;
        progress = PsProgress(PsStage.batch, done: i, total: batch.length, item: i + 1, items: batch.length);
        _notify();
        try {
          if (tool == null) {
            it.output = await deps.engine.enhance(
                it.input,
                EnhanceRequest(strength: strength, ai: aiOn && enhance.ai == AiState.ready)
                    .withMaxLongEdge(config.free ? config.previewMaxPx : null));
          } else {
            if (te == null) throw const PhotoStudioFailure('batch', 'no_engine');
            final av = await te.tools(it.input);
            if (!av.has(tool)) {
              it.status = BatchStatus.skipped;
              it.reason = PsNotice.tooBig;
              continue;
            }
            tools = av;
            it.output = await _runToolOn(te, tool, it.input);
          }
          it.status = BatchStatus.done;
        } on PsCancelled {
          it.status = BatchStatus.cancelled;
          _batchCancel = true;
        } on PsIdentityRejected {
          it.status = BatchStatus.skipped;
          it.reason = PsNotice.identityFailed;
        } on PsNoSubject {
          it.status = BatchStatus.skipped;
          it.reason = PsNotice.noSubject;
        } catch (e) {
          if (e is! PhotoStudioFailure) _report('batch', e);
          it.status = BatchStatus.failed;
          it.reason = PsNotice.toolFailed;
        }
        _notify();
      }
      _say(PsNotice.batchDone);
    } finally {
      batchRunning = false;
      busy = false;
      progress = null;
      cancelling = false;
      _notify();
    }
  }

  /// Open one finished batch result in the studio (export via the gate).
  void openBatchItem(int i) {
    if (i < 0 || i >= batch.length) return;
    final it = batch[i];
    final out = it.output;
    if (out == null) return;
    webImport = false;
    final s = PhotoSession(it.input);
    s.push(PhotoVersion(
        bytes: out, feature: 'enhance_hd', previewOnly: config.free, fullQuality: batchTool != null));
    if (batchTool == null) {
      _versionStrength[s.index] = strength;
      _versionAi[s.index] = aiOn && enhance.ai == AiState.ready;
    }
    session = s;
    notice = PsNotice.none;
    _notify();
    unawaited(_refreshTools(out));
  }

  // ------------------------------------------------------------------ restore (server)
  /// d1-photo: heavy restore on OUR server (colorize / old-photo restore) or
  /// the key-gated GPU API (deblur). Same money path as a prompt edit:
  /// safety -> funding TAKEN (ads/credits/pool, Profit Guard) -> run -> the
  /// identity check on the result before it is shown.
  Future<void> runRestore(PsFeature f, GateUi ui) async {
    if (!f.isRestore) return;
    if (!config.restoreReady(f)) {
      final q = config.quote(f);
      if (const {'daily_limit', 'fair_use_cap', 'week_free_used', 'premium_only', 'ultra_quota'}
          .contains(q.reason)) {
        return _say(PsNotice.limitReached, q.message);
      }
      return _say(PsNotice.providerMissing, q.message);
    }
    await _runCloud(f, '', ui, extra: {
      if (f == PsFeature.oldRestore) 'restore_colorize': restoreColorize,
      // photo-final: portrait background blur (only offered when the server
      // reports it can really do it)
      if (f == PsFeature.enhanceServer) 'bg_blur': portraitBlur && config.enhanceCap.bgBlur,
    });
  }

  /// photo-final: "Portrait blur" switch of the server HD enhance.
  bool portraitBlur = false;

  void setPortraitBlur(bool v) {
    portraitBlur = v;
    _notify();
  }

  // ------------------------------------------------------------------ prompt edit
  Map<String, dynamic> _jobBody(PsFeature f, String prompt) => {
        'feature': f.wire,
        'prompt': prompt,
        // d1-photo: restore jobs are faithful (no generative options)
        'options': f.isRestore ? const <String>[] : options.toList(),
        'beauty': f.isRestore ? const <String>[] : beauty.toList(),
        'strength': strength.wire,
        'others_in_photo': othersInPhoto,
        'own_photo': !othersInPhoto,
        'child_in_photo': childInPhoto,
        if (othersInPhoto) 'consent': consentOthers,
      };

  /// Edit (with a photo) or generate (without). Safety -> identity-guard
  /// precondition -> funding TAKEN (ads/credits/pool) -> provider run.
  Future<void> runPrompt(String prompt, GateUi ui) async {
    final s = session;
    final feature = s == null ? PsFeature.generate : PsFeature.promptEdit;
    if (webImport) return _say(PsNotice.webImportNoEdit);
    if (prompt.trim().isEmpty && options.isEmpty) return _say(PsNotice.needPrompt);
    await _runCloud(feature, prompt, ui);
  }

  Future<void> _runCloud(PsFeature feature, String prompt, GateUi ui,
      {Map<String, dynamic> extra = const {}}) async {
    final s = session;
    if (webImport) return _say(PsNotice.webImportNoEdit);
    if (feature.isRestore && s == null) return _say(PsNotice.needPhoto);
    refusal = null;
    busy = true;
    progress = feature.isRestore ? const PsProgress(PsStage.server) : null;
    _notify();
    try {
      final v = await deps.backend.safety(_jobBody(feature, prompt));
      if (!v.allowed) {
        refusal = v;
        return _say(PsNotice.refused, v.message);
      }
      if (!feature.isRestore && !config.providerReady) {
        return _say(PsNotice.providerMissing, config.providerNeeds);
      }
      // never take money for a result we could not show
      if (s != null && hasPeople && !deps.guard.available) {
        return _say(PsNotice.identityCheckMissing);
      }
      final q = config.quote(feature);
      final body = {..._jobBody(feature, prompt), ...extra};
      if (config.free) {
        if (q.gift) {
          body['via'] = 'gift'; // a lifetime free AI generation (no ads)
        } else if (q.ads != null) {
          body['via'] = 'ads';
        } else {
          final c = await ui.chooseFunding(GateNeed(
              adsRemaining: 0,
              adsTotal: 0,
              credits: q.credits?.credits,
              adsLinked: deps.ads.linked,
              reason: q.reason));
          if (c != FundChoice.credits) return _say(PsNotice.cancelled);
          body['via'] = 'credits';
        }
      }
      var cr = await deps.backend.createJob(body);
      if (cr.status == 402 && cr.reason == 'insufficient' && await ui.outOfCredits()) {
        cr = await deps.backend.createJob(body); // credout: once, same prompt
      }
      if (!cr.ok || cr.job == null) {
        if (cr.status == 422) {
          refusal = SafetyVerdict(allowed: false, reason: cr.reason, message: cr.message);
          return _say(PsNotice.refused, cr.message);
        }
        return _say(cr.status == 402 ? PsNotice.insufficient : PsNotice.failed, cr.message);
      }
      final gate = ExportGate(
          backend: deps.backend, ads: deps.ads, creditsPrice: q.credits?.credits);
      final f = await gate.ensureFunded(cr.job!, ui);
      if (!f.ok) return _gateNotice(f);
      final faces = (s != null && deps.faces.available)
          ? await deps.faces.detect(s.current.bytes)
          : const <FaceBox>[];
      final rr = await deps.backend.run(cr.job!.id,
          imageB64: s == null ? '' : ApiPsBackend.b64(s.current.bytes),
          faceBoxes: faces.map((e) => e.toList()).toList());
      if (!rr.ok || rr.job == null) {
        if (feature.isRestore) {
          _report('server', PhotoStudioFailure('server', '${feature.wire}:${rr.status}:${rr.reason}'));
        }
        return _say(PsNotice.failed, rr.message);
      }
      var job = rr.job!;
      // d1-photo v2: queued on the photo worker -> wait honestly (position)
      if (job.waiting) {
        final waited = await _waitForJob(job);
        if (waited != null && waited.waitingForBudget) return _say(PsNotice.queuedBudget);
        if (waited == null) return _say(PsNotice.stillWorking);
        job = waited;
        if (job.status != 'done') return _say(PsNotice.failed, job.status);
      }
      final prev = job.previewUrl.isEmpty ? null : await deps.backend.download(job.previewUrl);
      if (prev == null) return _say(PsNotice.failed);
      if (s != null && hasPeople) {
        final verdict = await deps.guard.check(s.original.bytes, prev);
        if (!verdict.pass) {
          return _say(verdict.outcome == IdentityOutcome.cannotVerify
              ? PsNotice.identityCheckMissing
              : PsNotice.identityFailed);
        }
      }
      final ver = PhotoVersion(
          bytes: prev, feature: feature.wire, jobId: job.id, aiEdited: true,
          previewOnly: config.free);
      if (s == null) {
        session = PhotoSession(prev);
        session!.push(ver);
      } else {
        s.push(ver);
      }
      final fl = job.faceLock;
      if (fl != null) faceLockOf[session!.index] = fl;
      notice = PsNotice.none;
      // trials left / pool balance changed on the server
      try {
        config = await deps.backend.config();
      } catch (_) {}
    } catch (e) {
      _report(feature.isRestore ? 'server' : 'prompt', e);
      _say(PsNotice.failed);
    } finally {
      busy = false;
      progress = null;
      cancelling = false;
      _notify();
    }
  }

  void _gateNotice(GateResult r) {
    switch (r.status) {
      case GateStatus.cancelled:
        _say(PsNotice.cancelled);
      case GateStatus.adUnavailable:
        _say(PsNotice.adUnavailable);
      case GateStatus.insufficient:
        _say(PsNotice.insufficient, r.message);
      default:
        _say(PsNotice.failed, r.message);
    }
  }

  // ------------------------------------------------------------------ export
  bool get canExport => session != null && session!.edited;

  /// THE single exit: save / share / wallpaper / copy / open-in all land here.
  Future<void> export(ExportKind kind, GateUi ui) async {
    final s = session;
    if (s == null || !s.edited) return _say(PsNotice.needPhoto);
    if (!deps.sink.available(kind)) return _say(PsNotice.sinkUnavailable);
    busy = true;
    _notify();
    try {
      final v = s.current;
      var jobId = v.jobId ?? _jobOfVersion[s.index];
      PsJob job;
      if (jobId == null) {
        // on-device result: its export job is created now (free: ads/credits)
        final q = config.quote(PsFeature.enhanceHd);
        final cr = await deps.backend.createJob({
          'feature': PsFeature.enhanceHd.wire,
          if (config.free) 'via': 'ads',
          'others_in_photo': othersInPhoto,
          'own_photo': !othersInPhoto,
        });
        if (!cr.ok || cr.job == null) return _say(PsNotice.failed, cr.message);
        job = cr.job!;
        jobId = job.id;
        // remember the export job of this version (history order unchanged)
        _jobOfVersion[s.index] = jobId;
        _creditPrice[jobId] = q.credits?.credits;
      } else {
        final r = await deps.backend.job(jobId);
        job = r.job ?? PsJob(id: jobId, feature: v.feature, status: 'awaiting_funds');
      }
      final gate = ExportGate(
          backend: deps.backend,
          ads: deps.ads,
          creditsPrice: _creditPrice[jobId] ?? config.quote(PsFeature.enhanceHd).credits?.credits);
      final g = await gate.unlock(job, kind, ui);
      if (!g.ok || g.grant == null) return _gateNotice(g);
      final grant = g.grant!;
      // full quality only now, after the gate
      Uint8List? full;
      if (grant.resultUrl.isNotEmpty) {
        full = await deps.backend.download(grant.resultUrl);
      } else if (v.fullQuality) {
        // d1-photo tool / batch result: already full quality on the phone
        full = v.bytes;
      } else {
        final st = _versionStrength[s.index] ?? strength;
        full = await deps.engine.enhance(s.original.bytes,
            EnhanceRequest(strength: st, ai: _versionAi[s.index] ?? false));
      }
      if (full == null) return _say(PsNotice.failed);
      final png = await deps.renderer.render(full,
          cornerMark: grant.cornerMark,
          note: grant.aiNote.isEmpty ? 'Edited with Assisto' : grant.aiNote,
          generated: v.feature == 'generate');
      final name = 'assisto_${DateTime.now().millisecondsSinceEpoch}.png';
      final d = await deps.sink.deliver(kind, png, name);
      // admob: a saved photo is a natural break (Free only, capped, never
      // within 5 min of another full-screen ad)
      if (d == DeliverResult.done && kind == ExportKind.save) {
        AdMoments.report('photo_saved');
      }
      _say(switch (d) {
        DeliverResult.done => kind == ExportKind.share
            ? PsNotice.shared
            : kind == ExportKind.openIn
                ? PsNotice.opened
                : PsNotice.saved,
        DeliverResult.unavailable => PsNotice.sinkUnavailable,
        DeliverResult.failed => PsNotice.failed,
      });
    } on EnhanceUnavailable {
      _say(PsNotice.failed);
    } on PsCancelled {
      _say(PsNotice.cancelled);
    } catch (e) {
      _report('export', e);
      _say(PsNotice.failed);
    } finally {
      busy = false;
      progress = null;
      cancelling = false;
      _notify();
    }
  }

  /// Poll a queued job until done/failed. null = still running after
  /// [pollMax] or the user pressed Cancel (the job keeps its funds).
  Future<PsJob?> _waitForJob(PsJob job) async {
    _batchCancel = false;
    final sw = Stopwatch()..start();
    var j = job;
    while (j.waiting) {
      if (j.waitingForBudget) return j; // honest: waits for tomorrow, not "working"
      if (_batchCancel || sw.elapsed > pollMax) return null;
      progress = PsProgress(PsStage.server, item: j.queuePosition);
      _notify();
      await Future<void>.delayed(pollEvery);
      final r = await deps.backend.job(j.id);
      if (r.job != null) j = r.job!;
    }
    return j;
  }

  /// d1-photo v2: one-tap template.
  Future<void> runTemplate(PsTemplate t, GateUi ui) async {
    switch (t.feature) {
      case PsFeature.enhanceServer:
      case PsFeature.oldRestore:
      case PsFeature.colorize:
      case PsFeature.deblur:
        return runRestore(t.feature, ui);
      default:
        if (session == null) return _say(PsNotice.needPhoto);
        if (!config.providerReady) return _say(PsNotice.providerMissing, config.providerNeeds);
        return _runCloud(t.feature, '', ui, extra: {'template': t.id});
    }
  }

  /// d1-photo v2: "Report this AI image".
  Future<void> reportCurrent(String reason, {String note = ''}) async {
    final id = jobForCurrent();
    if (id == null) return;
    try {
      final r = await deps.backend.report(id, reason, note: note);
      _say(r.ok ? PsNotice.reported : PsNotice.failed, r.message);
    } catch (e) {
      _report('report', e);
      _say(PsNotice.failed);
    }
  }

  void setConsent(bool v) {
    consentOthers = v;
    _notify();
  }

  final Map<int, bool> _versionAi = {};
  final Map<int, int> _jobOfVersion = {};
  final Map<int, int?> _creditPrice = {};

  int? jobForCurrent() {
    final s = session;
    if (s == null) return null;
    return s.current.jobId ?? _jobOfVersion[s.index];
  }

  // db1: the screen listens to the controller, not the session — without
  // this notify, Undo/Redo changed nothing on screen (dead-button sweep).
  void undo() {
    session?.undo();
    if (!disposed) notifyListeners();
  }

  void redo() {
    session?.redo();
    if (!disposed) notifyListeners();
  }
}
