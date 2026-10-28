import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../ads/ad_placements.dart' show AdMoments;
import '../perf/low_ram.dart' show LowRamTuning;
import 'ps_ads.dart';
import 'ps_backend.dart';
import 'ps_engines.dart';
import 'ps_enhance.dart';
import 'ps_export.dart';
import 'ps_models.dart';
import 'ps_native.dart';
import 'ps_recipe.dart';
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

  /// photoperf: the recipe step of a reduced (free preview) result — the
  /// export re-renders it at full size. null = [output] is full quality.
  PsStep? step;
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
    MarkPainter mark = const UiMarkPainter(),
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
      mark: mark,
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
    required this.mark,
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

  /// photoperf: draws the free users' corner mark for the full-size export
  /// (composited inside the export isolate).
  final MarkPainter mark;

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

  // ------------------------------------------------------------------ photoperf
  /// The editing proxy of the current photo (null = none: website photo,
  /// batch result, or an engine without proxy support -> full-size edits).
  PsProxy? proxy;

  /// How each version is re-rendered at full size on export (photoperf).
  final Map<int, _Recipe> _recipeOf = {};

  /// Face detection of the current photo (runs in the background after the
  /// photo is shown; edits wait for it through the shared native cache).
  Future<void>? facesReady;

  /// pick / edit / export timings in ms (perf report + diagnostics).
  final Map<String, int> timings = {};

  /// The phone's RAM as Android reported it (tests override).
  static ({int ramMb, bool lowRam}) Function() deviceRam =
      () => (ramMb: LowRamTuning.ramMb, lowRam: LowRamTuning.lowRam);

  PsProxyEngine? get _proxyEngine {
    final e = deps.engine;
    return e is PsProxyEngine ? e as PsProxyEngine : null;
  }

  /// Long edge of every interactive step (proxy; free users never above the
  /// server's preview size — enhance AND tools).
  int get interactiveLong {
    final r = deviceRam();
    return psInteractiveLong(
        proxyLong: psProxyLong(ramMb: r.ramMb, lowRam: r.lowRam),
        free: free,
        previewMaxPx: config.previewMaxPx);
  }

  /// What the screen shows for version [i] (the proxy instead of a 12 MP
  /// original).
  Uint8List shownBytes(int i) {
    final s = session;
    if (s == null) return Uint8List(0);
    if (i == 0) return proxy?.bytes ?? s.original.bytes;
    return s.versions[i].bytes;
  }

  /// The bytes the next interactive step works on (= [shownBytes]).
  Uint8List _workOf(int i) => shownBytes(i);

  void _newSession() {
    _recipeOf.clear();
    _versionStrength.clear();
    _versionAi.clear();
    _jobOfVersion.clear();
    _creditPrice.clear();
    faceLockOf.clear();
    proxy = null;
    facesReady = null;
  }

  /// Recipe of version [i] (version 0 = the original, nothing applied).
  _Recipe? _recipeFor(int i) {
    final s = session;
    if (s == null) return null;
    if (i == 0) {
      if (webImport) return null;
      final px = proxy;
      return _Recipe(s.original.bytes, const [], atFull: px == null || px.identity);
    }
    return _recipeOf[i];
  }

  Future<({int w, int h})?> _fullSizeOf(int i) async {
    final s = session;
    if (s == null) return null;
    final px = proxy;
    if (i == 0 && px != null) return (w: px.srcW, h: px.srcH);
    final rec = _recipeOf[i];
    final sb = rec?.sizeBytes;
    if (i == 0 || rec == null || sb == null) return _sizeOf(s.versions[i].bytes);
    final a = await _sizeOf(sb);
    return a == null ? null : psStepsSize(a.w, a.h, rec.steps);
  }

  /// Full-quality encoded bytes of version [i] (renders the recipe at full
  /// size when the version is a reduced proxy result). [png] = must be a
  /// PNG/JPEG (server uploads), not the fast BMP of a proxy version.
  Future<Uint8List> _fullOf(int i, {bool png = false}) async {
    final s = session!;
    final v = s.versions[i];
    final rec = _recipeFor(i);
    final pe = _proxyEngine;
    Uint8List out;
    if (pe == null || rec == null || rec.atFull || i == 0) {
      out = i == 0 ? s.original.bytes : v.bytes;
      if (png && pe != null && _isBmp(out)) out = await pe.renderExport(out, const []);
      return out;
    }
    progress = const PsProgress(PsStage.export, total: 1000);
    _notify();
    return pe.renderExport(await rec.anchor(), rec.steps);
  }

  static bool _isBmp(Uint8List b) => b.length > 2 && b[0] == 0x42 && b[1] == 0x4D;

  Future<PsProxy?> _makeProxy(Uint8List b) async {
    final pe = _proxyEngine;
    if (pe == null) return null;
    try {
      return await pe.makeProxy(b, maxLong: interactiveLong);
    } catch (e) {
      _report('proxy', e); // edits fall back to the full photo (slower, correct)
      return null;
    }
  }

  /// photoperf: the phone is low on memory (Android onTrimMemory via
  /// Flutter's didHaveMemoryPressure) — free the native models when idle;
  /// the screen drops its decoded images. Everything comes back lazily.
  void onMemoryPressure() {
    if (busy) return;
    final pe = _proxyEngine;
    if (pe != null) unawaited(pe.release().catchError((_) {}));
  }

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
    // photoperf: stop a running job, free ML Kit / ONNX Runtime, and let go
    // of every photo buffer even if something still holds this controller
    // (2 GB CI run 40603594625: ~115 MB native heap stayed after closing).
    final pe = _proxyEngine;
    if (pe != null) unawaited(pe.release().catchError((_) {}));
    session = null;
    proxy = null;
    batch.clear();
    _recipeOf.clear();
    facesReady = null;
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
    if (b == null || disposed) return;
    final sw = Stopwatch()..start();
    timings.clear();
    webImport = false;
    webLabel = '';
    _newSession();
    refusal = null;
    notice = PsNotice.none;
    facesFound = null;
    lastReport = EnhanceReport.none;
    // photoperf: the editing proxy first (the 12 MP photo is decoded once,
    // shrunk; it is never shown or edited at full size)
    final pe = _proxyEngine;
    if (pe != null) {
      busy = true;
      progress = const PsProgress(PsStage.analyse);
      _notify();
    }
    final px = await _makeProxy(b);
    timings['proxy_ms'] = sw.elapsedMilliseconds;
    if (disposed) return;
    session = PhotoSession(b);
    proxy = px;
    if (pe != null) {
      busy = false;
      progress = null;
    }
    _notify();
    await _inspect(b);
    timings['pick_ms'] = sw.elapsedMilliseconds;
  }

  /// p2-photo: ML Kit faces -> "There are people in this photo" switch is
  /// set from what the phone actually sees (the user can still change it);
  /// and is this photo small enough for the AI step?
  ///
  /// photoperf: sizes come from the proxy (no second read of the original),
  /// faces are found on the proxy (boxes are 0..1, landmarks only feed the
  /// scale-free identity check) and in the BACKGROUND — the photo is usable
  /// at once; [facesReady] completes when they are known.
  Future<void> _inspect(Uint8List b) async {
    final eng = deps.engine;
    final px = proxy;
    final size = px != null ? (w: px.srcW, h: px.srcH) : await _sizeOf(b);
    try {
      aiEligible = eng is StudioEnhanceEngine
          ? (size != null ? eng.aiEligibleSize(size) : await eng.aiEligible(b))
          : false;
    } catch (_) {
      aiEligible = false;
    }
    // d1-photo: the honest size/time line + tool list for THIS photo
    aiPlan = null;
    if (eng is StudioEnhanceEngine && aiEligible) {
      final mx = config.free ? config.previewMaxPx : null;
      aiPlan = size != null
          ? await eng.aiPlanForSize(size, maxLongEdge: mx)
          : await eng.aiPlanFor(b, maxLongEdge: mx);
      final s = size;
      // the AI step SHRINKS big photos (it works on a copy): off by default
      // there, on by default for small/old photos once the model is here
      if (s != null && aiPlan != null && aiPlan!.targetLong < math.max(s.w, s.h)) {
        aiOn = false;
      } else if (enhance.ai == AiState.ready) {
        aiOn = true;
      }
    }
    await _refreshToolsFor(0);
    _notify();
    if (deps.faces.available) {
      final ses = session;
      final work = _workOf(0);
      final sw = Stopwatch()..start();
      facesReady = () async {
        try {
          final f = await deps.faces.detect(work);
          if (!disposed && identical(session, ses)) {
            facesFound = f.length;
            hasPeople = f.isNotEmpty;
            timings['faces_ms'] = sw.elapsedMilliseconds;
            _notify();
          }
        } catch (_) {}
      }();
    }
  }

  /// w1-webphoto: open a website photo. The shown bytes are the server's
  /// preview (watermarked for free users); the version carries the server
  /// job, so [export] runs the SAME gate and downloads the clean result only
  /// after it unlocks. Nothing here can export without the gate.
  void loadWebImport(WebPhotoImport imp) {
    _newSession();
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
    final s = session;
    if (s != null) await _refreshToolsFor(s.index);
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
      // photoperf: on the proxy (free users: never above the preview size);
      // engines without proxies keep the old full-size preview
      final pe = _proxyEngine;
      final req = EnhanceRequest(strength: strength, ai: ai).withMaxLongEdge(
          pe != null ? interactiveLong : (config.free ? config.previewMaxPx : null));
      final sw = Stopwatch()..start();
      final out = await deps.engine.enhance(pe != null ? _workOf(0) : s.original.bytes, req);
      timings['enhance_ms'] = sw.elapsedMilliseconds;
      lastReport = deps.engine.lastReport;
      final step = pe?.lastStep;
      final base = _recipeFor(0);
      s.push(PhotoVersion(bytes: out, feature: 'enhance_hd', previewOnly: config.free));
      if (step != null && base != null) {
        _recipeOf[s.index] = base.then(step);
      } else if (pe != null && lastReport.aiUsed) {
        final st = strength, orig = s.original.bytes;
        _recipeOf[s.index] = _Recipe.lazy(
            () => deps.engine.enhance(orig, EnhanceRequest(strength: st, ai: true)), orig);
      }
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

  /// Tools for version [i], judged on its FULL size (photoperf: the proxy
  /// may be smaller — a big photo must not suddenly offer the upscaler).
  Future<void> _refreshToolsFor(int i) async {
    final te = _tools;
    final s = session;
    if (te == null || s == null) {
      tools = ToolsAvailability.none;
      return;
    }
    try {
      final pe = _proxyEngine;
      final sz = pe == null ? null : await _fullSizeOf(i);
      tools = sz != null ? await pe!.toolsAt(sz.w, sz.h) : await te.tools(s.versions[i].bytes);
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
      final sw = Stopwatch()..start();
      final from = s.index;
      final pe = _proxyEngine;
      final rec = _recipeFor(from);
      // photoperf: AI upscale needs the real pixels (bounded: ≤ 1280 px
      // sources); every other tool previews on the proxy and is recorded
      final input = (pe != null && tool.usesAi) ? await _fullOf(from) : _workOf(from);
      final out = await _runToolOn(te, tool, input,
          maxLongEdge: pe != null && config.free ? config.previewMaxPx : null);
      timings['tool_ms'] = sw.elapsedMilliseconds;
      final step = pe?.lastStep;
      _Recipe? next;
      var full = true; // engines without proxies: the result IS full quality
      if (pe != null) {
        if (step == null) {
          next = _Recipe(out, const [], atFull: true); // AI upscale: the result itself
        } else if (rec != null) {
          next = rec.then(step);
          full = rec.atFull;
        } // else: a tool on a website/cloud preview -> that preview, as before
      }
      s.push(PhotoVersion(
          bytes: out, feature: 'enhance_hd', previewOnly: config.free, fullQuality: full,
          aiEdited: tool.usesAi));
      if (next != null) _recipeOf[s.index] = next;
      _versionAi[s.index] = tool.usesAi;
      notice = PsNotice.none;
      await _refreshToolsFor(s.index);
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

  Future<Uint8List> _runToolOn(PhotoToolEngine te, PsTool tool, Uint8List bytes,
      {int? maxLongEdge}) async {
    if ((tool.usesAi && tools.needsUpscaleModel) || (tool == PsTool.bgBlur && tools.needsMaskModel)) {
      progress = const PsProgress(PsStage.download);
      _notify();
      if (!await te.prepareTool(tool)) {
        throw const PhotoStudioFailure('download', 'failed');
      }
      if (tool.usesAi) enhance = enhance.withAi(AiState.ready, progress: 1);
      tools = await te.tools(bytes);
    }
    return te.runTool(tool, bytes, maxLongEdge: tool.usesAi ? null : maxLongEdge);
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

  /// A free user's preview of [b] is smaller than the photo (photoperf).
  Future<bool> _reduced(Uint8List b) async {
    if (!config.free || _proxyEngine == null) return false;
    final sz = await _sizeOf(b);
    return sz != null && math.max(sz.w, sz.h) > config.previewMaxPx;
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
          final pe = _proxyEngine;
          if (tool == null) {
            it.output = await deps.engine.enhance(
                it.input,
                EnhanceRequest(strength: strength, ai: aiOn && enhance.ai == AiState.ready)
                    .withMaxLongEdge(config.free ? config.previewMaxPx : null));
            it.step = await _reduced(it.input) ? pe?.lastStep : null;
          } else {
            if (te == null) throw const PhotoStudioFailure('batch', 'no_engine');
            final av = await te.tools(it.input);
            if (!av.has(tool)) {
              it.status = BatchStatus.skipped;
              it.reason = PsNotice.tooBig;
              continue;
            }
            tools = av;
            // photoperf: free users get the preview size here too (the
            // export re-renders the recorded step at full size)
            it.output = await _runToolOn(te, tool, it.input,
                maxLongEdge: pe != null && config.free ? config.previewMaxPx : null);
            it.step = await _reduced(it.input) ? pe?.lastStep : null;
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
    _newSession();
    final s = PhotoSession(it.input);
    final step = it.step;
    s.push(PhotoVersion(
        bytes: out, feature: 'enhance_hd', previewOnly: config.free,
        fullQuality: batchTool != null && step == null));
    if (step != null) _recipeOf[s.index] = _Recipe(it.input, [step], atFull: false);
    if (batchTool == null) {
      _versionStrength[s.index] = strength;
      _versionAi[s.index] = aiOn && enhance.ai == AiState.ready;
    }
    session = s;
    notice = PsNotice.none;
    _notify();
    unawaited(_refreshToolsFor(s.index));
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
      // photoperf: faces from the proxy (0..1 boxes, cached); the server
      // gets full-quality pixels (a proxy result is rendered at full size)
      final faces = (s != null && deps.faces.available)
          ? await deps.faces.detect(_workOf(s.index))
          : const <FaceBox>[];
      final upload = s == null ? null : await _fullOf(s.index, png: true);
      final rr = await deps.backend.run(cr.job!.id,
          imageB64: upload == null ? '' : ApiPsBackend.b64(upload),
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
      final sw = Stopwatch()..start();
      final png = await _renderFull(s,
          resultUrl: grant.resultUrl,
          cornerMark: grant.cornerMark,
          note: grant.aiNote.isEmpty ? 'Edited with Assisto' : grant.aiNote,
          generated: v.feature == 'generate');
      timings['export_ms'] = sw.elapsedMilliseconds;
      if (png == null) return _say(PsNotice.failed);
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

  /// The exported file of the current version (PNG, corner mark, AI note).
  /// null = nothing to export (download failed).
  Future<Uint8List?> _renderFull(PhotoSession s,
      {String resultUrl = '', required bool cornerMark, required String note,
      bool generated = false}) async {
    final v = s.current;
    Uint8List? full;
    final rec = _recipeOf[s.index];
    final pe = _proxyEngine;
    if (resultUrl.isNotEmpty) {
      full = await deps.backend.download(resultUrl);
    } else if (v.fullQuality) {
      // d1-photo tool / batch result: already full quality on the phone
      full = v.bytes;
    } else if (pe != null && rec != null && !(_versionAi[s.index] ?? false)) {
      // photoperf: the recorded recipe on the full-resolution original, in a
      // background isolate (progress + Cancel), the corner mark composited
      // there, the PNG written directly — same look as the preview
      progress = const PsProgress(PsStage.export, total: 1000);
      _notify();
      return pe.renderExport(await rec.anchor(), rec.steps,
          mark: cornerMark ? deps.mark : null, note: note, generated: generated);
    } else {
      final st = _versionStrength[s.index] ?? strength;
      progress = const PsProgress(PsStage.classic);
      _notify();
      full = await deps.engine.enhance(s.original.bytes,
          EnhanceRequest(strength: st, ai: _versionAi[s.index] ?? false));
    }
    if (full == null) return null;
    return deps.renderer.render(full, cornerMark: cornerMark, note: note, generated: generated);
  }

  /// perf/diagnostics: the export render of the current version exactly as
  /// [export] runs it after the gate (no gate, no file written). Returns the
  /// PNG size in bytes (0 = nothing to export).
  @visibleForTesting
  Future<int> renderExportForPerf({bool cornerMark = false}) async {
    final s = session;
    if (s == null || !s.edited) return 0;
    busy = true;
    _notify();
    final sw = Stopwatch()..start();
    try {
      final png = await _renderFull(s, cornerMark: cornerMark, note: 'Edited with Assisto');
      timings['export_ms'] = sw.elapsedMilliseconds;
      return png?.length ?? 0;
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

/// photoperf: how one version is rendered at full size — [steps] applied to
/// [anchor] (the original, or an AI-upscaled result that IS full quality).
/// [atFull]: the version's own bytes already are full size (small photo:
/// proxy == original) — no re-render needed.
class _Recipe {
  const _Recipe(Uint8List this.anchorBytes, this.steps, {required this.atFull})
      : anchorFn = null,
        sizeBytes = anchorBytes;

  /// The anchor is made on demand: an on-device AI enhance, re-run at full
  /// size exactly as its own export always did — only needed when a tool was
  /// chained on it. [sizeBytes] (the original) stands for its size.
  const _Recipe.lazy(Future<Uint8List> Function() this.anchorFn, this.sizeBytes,
      {this.steps = const []})
      : anchorBytes = null,
        atFull = false;

  final Uint8List? anchorBytes;
  final Future<Uint8List> Function()? anchorFn;
  final Uint8List? sizeBytes;
  final List<PsStep> steps;
  final bool atFull;

  Future<Uint8List> anchor() async => anchorBytes ?? await anchorFn!();

  _Recipe then(PsStep s) => anchorBytes != null
      ? _Recipe(anchorBytes!, [...steps, s], atFull: atFull)
      : _Recipe.lazy(anchorFn!, sizeBytes, steps: [...steps, s]);
}
