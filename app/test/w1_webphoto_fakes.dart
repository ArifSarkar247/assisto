// w1-webphoto test doubles: a fake website-photo claim on top of the ps1
// in-memory Photo Studio server (the claim makes an enhance_hd job, like the
// real POST /web-photo/claim; its clean result unlocks only via the gate).
import 'dart:typed_data';

import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/photo_studio/ps_web_import.dart';

import 'ps1_fakes.dart';

class WebPsBackend extends FakePsBackend {
  WebPsBackend({super.free, super.entryDue = false, super.credits});
  final webJobs = <int>{};
  final downloads = <String>[];

  @override
  Future<PsReply> unlock(int id, ExportKind kind) async {
    final r = await super.unlock(id, kind);
    if (r.status == 200 && webJobs.contains(id)) {
      return PsReply(200, {...r.body, 'result': '/api/v1/m/web_result_$id.jpg'});
    }
    return r;
  }

  @override
  Future<Uint8List?> download(String url) async {
    downloads.add(url);
    return super.download(url);
  }
}

class FakeWebPhotoApi implements WebPhotoApi {
  FakeWebPhotoApi(this.backend, {this.status = 200});
  final WebPsBackend backend;
  int status;
  final claimed = <String>[];

  @override
  Future<WebClaimResult> claim(String token) async {
    claimed.add(token);
    if (status != 200) {
      return decodeClaim({
        '_status': status,
        'ok': false,
        'reason': 'expired',
      }, backend);
    }
    status = 410; // once
    final cr = await backend.createJob(
        {'feature': 'enhance_hd', if (backend.free) 'via': 'ads'});
    final job = Map<String, dynamic>.from(cr.body['job'] as Map);
    backend.webJobs.add(job['id'] as int);
    job['preview'] = '/api/v1/m/web_preview_${job['id']}.jpg';
    return decodeClaim({
      '_status': 200,
      'ok': true,
      'job': job,
      'preset': 'bd_passport',
      'label': 'Bangladesh e-Passport (35×45 mm)',
      'studio_option': 'passport_bd',
    }, backend);
  }
}

PsDeps webDeps(WebPsBackend b, {FakeSink? sink, FakeRenderer? renderer}) => PsDeps(
      backend: b,
      ads: FakeAds(b),
      engine: FakeEngine(ready: false), // no engine: export must use the server result
      guard: IdentityGuard(landmarks: FakeLandmarks()),
      sink: sink ?? FakeSink(),
      renderer: renderer ?? FakeRenderer(),
      secure: FakeSecure(),
      picker: FakePicker(),
    );
