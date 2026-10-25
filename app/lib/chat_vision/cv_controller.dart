import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../photo_studio/ps_ads.dart';
import 'cv_backend.dart';
import 'on_device_vision.dart';

/// One photo turn in a chat (h1-home "image in chat").
///
/// 1. ON-DEVICE first (free, offline): text + labels through [OnDeviceVision]
///    -> an honest local answer (or an honest "not in this build" state).
/// 2. DETAILED answer on request, funded BEFORE the provider runs:
///    Premium/Business from the monthly pool; Free users with 2-3 rewarded
///    ads (verified only by the server's Google-signed SSV callback, the
///    shared Photo Studio ledger) or credits — Profit Guard decides on the
///    server what is offered.
///
/// Privacy: the photo bytes stay in this object's memory for the one answer
/// call and are never written anywhere by the app.
enum CvPhase {
  reading, // on-device reading
  ready, // on-device result shown, detailed answer offered (or closed)
  funding, // creating the job / taking credits
  watchingAd,
  verifying, // waiting for the SSV callback
  adFailed, // the ad didn't load / was closed -> retry or credits
  answering, // provider call running
  done,
  refused, // e.g. "who is this person?"
  error, // server/offline problem -> retry
}

class CvController extends ChangeNotifier {
  CvController({
    required this.backend,
    required this.bytes,
    required this.question,
    OnDeviceVision? onDevice,
    PhotoAdBridge? ads,
    this.pollEvery = const Duration(seconds: 2),
    this.pollTries = 15,
    this.answerTimeout = const Duration(seconds: 90),
  })  : onDevice = onDevice ?? createOnDeviceVision(),
        // admob (owner 25 Oct): no ad of any kind inside a chat conversation
        ads = ads ?? const NoopPhotoAdBridge();

  final CvBackend backend;
  final Uint8List bytes;
  final String question;
  final OnDeviceVision onDevice;
  final PhotoAdBridge ads;
  final Duration pollEvery;
  final int pollTries;
  final Duration answerTimeout;

  CvPhase phase = CvPhase.reading;
  OnDeviceReading reading = OnDeviceReading.unavailable;
  OnDeviceAnswer? local;
  CvConfig? config;
  bool configFailed = false;
  CvJob? job;
  String message = '';
  String answer = '';
  bool insufficient = false;
  bool _disposed = false;

  /// No endless spinners: every server call is bounded.
  static Future<CvReply> _t(Future<CvReply> f) =>
      f.timeout(const Duration(seconds: 30));

  CvQuote get quote => config?.quote ?? const CvQuote();

  void _set(CvPhase p) {
    phase = p;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Run the on-device step and fetch the funding quote (in parallel).
  Future<void> start() async {
    _set(CvPhase.reading);
    final cfgF = _loadConfig();
    try {
      reading = await onDevice.read(bytes).timeout(const Duration(seconds: 20),
          onTimeout: () => OnDeviceReading.failed);
    } catch (_) {
      reading = OnDeviceReading.failed;
    }
    local = reading.ok ? OnDeviceAnswer.from(reading) : null;
    await cfgF;
    _set(CvPhase.ready);
  }

  Future<void> _loadConfig() async {
    try {
      config = await backend.config().timeout(const Duration(seconds: 20));
      configFailed = false;
    } catch (_) {
      config = null;
      configFailed = true;
    }
  }

  Future<void> retryConfig() async {
    _set(CvPhase.reading);
    await _loadConfig();
    _set(job == null ? CvPhase.ready : CvPhase.error);
  }

  /// Ask for the detailed answer via `pool`, `ads` or `credits`.
  Future<void> requestDetailed(String via) async {
    if (phase == CvPhase.funding || phase == CvPhase.answering) return;
    insufficient = false;
    message = '';
    _set(CvPhase.funding);
    try {
      if (job == null) {
        final r = await _t(backend.create(via: via, question: question));
        if (r.status == 422) {
          message = r.message;
          return _set(CvPhase.refused);
        }
        if (!r.ok || r.job == null) {
          insufficient = r.status == 402;
          message = r.message;
          return _set(CvPhase.error);
        }
        job = r.job;
      } else if (via == 'credits' && !job!.funded) {
        final r = await _t(backend.fundWithCredits(job!.id));
        if (!r.ok || r.job == null) {
          insufficient = r.status == 402;
          message = r.message;
          return _set(CvPhase.adFailed);
        }
        job = r.job;
      }
      if (!job!.funded) {
        await _fundWithAds();
        if (!job!.funded) return;
      }
      await _answer();
    } catch (_) {
      message = '';
      _set(CvPhase.error);
    }
  }

  Future<void> _fundWithAds() async {
    while (!job!.funded) {
      final t = await _t(backend.ticket(job!.id));
      if (!t.ok) {
        final fresh = await _t(backend.job(job!.id));
        if (fresh.job != null) job = fresh.job;
        if (job!.funded) return;
        message = t.message;
        return _set(CvPhase.adFailed);
      }
      _set(CvPhase.watchingAd);
      final outcome = await ads.showRewardedSsv('${t.body['rewarded_unit'] ?? ''}',
          userId: '${t.body['user_id'] ?? ''}',
          customData: '${t.body['custom_data'] ?? ''}');
      if (outcome != RewardOutcome.earned) {
        message = '';
        return _set(CvPhase.adFailed); // retry or credits — never a free bypass
      }
      _set(CvPhase.verifying);
      final before = job!.adsVerified;
      for (var i = 0; i < pollTries; i++) {
        final r = await _t(backend.job(job!.id));
        if (r.job != null) job = r.job;
        if (job!.adsVerified > before || job!.funded) break;
        await Future<void>.delayed(pollEvery);
      }
      if (job!.adsVerified <= before && !job!.funded) {
        message = '';
        return _set(CvPhase.adFailed); // SSV never arrived -> honest retry
      }
    }
  }

  /// Retry the ads route after a failed ad.
  Future<void> retryAds() async {
    if (job == null) return requestDetailed('ads');
    _set(CvPhase.funding);
    try {
      await _fundWithAds();
      if (job!.funded) await _answer();
    } catch (_) {
      _set(CvPhase.error);
    }
  }

  Future<void> _answer() async {
    _set(CvPhase.answering);
    final r = await backend
        .answer(job!.id,
            imageB64: base64Encode(bytes),
            question: question,
            deviceText: reading.ok ? reading.text : '',
            deviceLabels: reading.ok ? reading.labels : const [])
        .timeout(answerTimeout,
            onTimeout: () => const CvReply(504, {'ok': false, 'reason': 'timeout'}));
    if (r.status == 422) {
      message = r.message;
      return _set(CvPhase.refused);
    }
    if (!r.ok || r.job == null) {
      if (r.job != null) job = r.job;
      message = r.message;
      return _set(CvPhase.error);
    }
    job = r.job;
    answer = job!.answer;
    _set(CvPhase.done);
  }

  /// "Try again" from the error state: a funded job retries for free.
  Future<void> retry() async {
    if (job != null && job!.funded && !job!.done) {
      try {
        return await _answer();
      } catch (_) {
        return _set(CvPhase.error);
      }
    }
    if (configFailed) return retryConfig();
    _set(CvPhase.ready);
  }
}
