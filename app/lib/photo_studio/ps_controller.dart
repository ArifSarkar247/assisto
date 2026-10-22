import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'ps_ads.dart';
import 'ps_backend.dart';
import 'ps_engines.dart';
import 'ps_enhance.dart';
import 'ps_export.dart';
import 'ps_models.dart';
import 'ps_native.dart';
import 'ps_session.dart';
import 'ps_web_import.dart';

/// Image source seam (gallery / camera). Tests inject bytes.
abstract class PhotoPicker {
  Future<Uint8List?> pick({required bool camera});
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
  }) {
    final n = native ?? ChannelPhotoNative();
    final g = guard ?? IdentityGuard(landmarks: NativeLandmarks(n));
    return PsDeps._(
      backend: backend,
      ads: ads ?? createPhotoAdBridge(),
      native: n,
      engine: engine ?? StudioEnhanceEngine(native: n, guard: g),
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
    try {
      enhance = await deps.engine.availability();
    } catch (_) {
      enhance = EnhanceAvailability.unavailable;
    }
    // model already on the phone: AI restore starts switched on
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
    } catch (_) {
      enhance = enhance.withAi(AiState.failed);
    }
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
    } on EnhanceUnavailable {
      _say(PsNotice.failed);
    } catch (_) {
      _say(PsNotice.failed);
    } finally {
      busy = false;
      _notify();
    }
  }

  // ------------------------------------------------------------------ prompt edit
  Map<String, dynamic> _jobBody(PsFeature f, String prompt) => {
        'feature': f.wire,
        'prompt': prompt,
        'options': options.toList(),
        'beauty': beauty.toList(),
        'strength': strength.wire,
        'others_in_photo': othersInPhoto,
        'own_photo': !othersInPhoto,
        'child_in_photo': childInPhoto,
      };

  /// Edit (with a photo) or generate (without). Safety -> identity-guard
  /// precondition -> funding TAKEN (ads/credits/pool) -> provider run.
  Future<void> runPrompt(String prompt, GateUi ui) async {
    final s = session;
    final feature = s == null ? PsFeature.generate : PsFeature.promptEdit;
    if (webImport) return _say(PsNotice.webImportNoEdit);
    if (prompt.trim().isEmpty && options.isEmpty) return _say(PsNotice.needPrompt);
    refusal = null;
    busy = true;
    _notify();
    try {
      final v = await deps.backend.safety(_jobBody(feature, prompt));
      if (!v.allowed) {
        refusal = v;
        return _say(PsNotice.refused, v.message);
      }
      if (!config.providerReady) return _say(PsNotice.providerMissing, config.providerNeeds);
      // never take money for a result we could not show
      if (s != null && hasPeople && !deps.guard.available) {
        return _say(PsNotice.identityCheckMissing);
      }
      final q = config.quote(feature);
      final body = _jobBody(feature, prompt);
      if (config.free) {
        if (q.ads != null) {
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
      final cr = await deps.backend.createJob(body);
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
      if (!rr.ok || rr.job == null) return _say(PsNotice.failed, rr.message);
      final job = rr.job!;
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
      notice = PsNotice.none;
      // trials left / pool balance changed on the server
      try {
        config = await deps.backend.config();
      } catch (_) {}
    } catch (_) {
      _say(PsNotice.failed);
    } finally {
      busy = false;
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
    } catch (_) {
      _say(PsNotice.failed);
    } finally {
      busy = false;
      _notify();
    }
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
