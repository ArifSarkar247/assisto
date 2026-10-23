// ps1-photo test doubles: an in-memory Photo Studio server (jobs, ad tickets,
// a simulated Google SSV callback), fake ads / engines / sink / renderer.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:assisto/photo_studio/ps_ads.dart';
import 'package:assisto/photo_studio/ps_backend.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_export.dart';
import 'package:assisto/photo_studio/ps_models.dart';

/// A valid 1x1 PNG (so Image.memory can decode it in widget tests).
final Uint8List kTinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

class _FJob {
  _FJob(this.id, this.feature, this.funding, this.adsRequired);
  final int id;
  final String feature;
  String funding;
  final int adsRequired;
  String status = 'awaiting_funds';
  int verified = 0;
  final pending = <String>[];
  Map<String, dynamic> json(bool free) => {
        'id': id,
        'feature': feature,
        'status': status,
        'funding': funding,
        'ads_required': adsRequired,
        'ads_verified': verified,
        'ads_remaining': funding == 'ads' ? math.max(0, adsRequired - verified) : 0,
        'corner_mark': free,
        'preview': feature == 'enhance_hd' ? '' : '/api/v1/m/preview_$id.png',
      };
}

class FakePsBackend implements PsBackend {
  FakePsBackend({
    this.free = true,
    this.entryDue = true,
    this.providerReady = true,
    this.credits = 0,
    this.refuse = false,
    this.adsPerCloudJob = 1,
    this.trialsPerDay = 1,
    this.refuseMessage = 'Sexual or undressing edits are not allowed.',
    this.isOwner = false,
    this.restoreReady = false,
  });
  bool isOwner;

  /// d1-photo: server restore jobs (colorize / old_restore / deblur) ready.
  bool restoreReady;
  static const restoreFeatures = ['deblur', 'colorize', 'old_restore'];
  final String refuseMessage;

  bool free;
  bool entryDue;
  bool providerReady;
  int credits;
  bool refuse;
  int adsPerCloudJob;
  int trialsPerDay;
  int trialsUsed = 0;
  int entryRecorded = 0;
  int runs = 0;
  final unlocks = <ExportKind>[];
  final jobs = <int, _FJob>{};
  int _next = 1;

  Map<String, dynamic> _quote(String f) {
    if (restoreFeatures.contains(f)) {
      if (!restoreReady) {
        return {'ok': false, 'reason': 'provider_missing', 'options': [], 'message': 'not installed'};
      }
      return free
          ? {
              'ok': true,
              'reason': 'ok',
              'options': [
                {'via': 'ads', 'ads': 1, 'trial': false},
                {'via': 'credits', 'credits': 3}
              ]
            }
          : {
              'ok': true,
              'reason': 'ok',
              'paid_plan': true,
              'options': [
                {'via': 'pool', 'credits': 3}
              ]
            };
    }
    if (!free) {
      return {
        'ok': true,
        'reason': 'ok',
        'paid_plan': true,
        'options': f == 'enhance_hd'
            ? [
                {'via': 'free'}
              ]
            : [
                {'via': 'pool', 'credits': 9}
              ]
      };
    }
    if (f == 'enhance_hd') {
      return {
        'ok': true,
        'reason': 'ok',
        'options': [
          {'via': 'ads', 'ads': 2, 'trial': false},
          {'via': 'credits', 'credits': 2}
        ]
      };
    }
    if (!providerReady) return {'ok': false, 'reason': 'provider_missing', 'options': []};
    final trialOpen = trialsUsed < trialsPerDay;
    return {
      'ok': true,
      'reason': trialOpen ? 'ok' : 'trial_used',
      'options': [
        if (trialOpen) {'via': 'ads', 'ads': adsPerCloudJob, 'trial': true},
        {'via': 'credits', 'credits': 9}
      ]
    };
  }

  @override
  Future<PsConfig> config() async => PsConfig.fromJson({
        'plan': free ? 'free' : 'premium',
        'free': free,
        'entry_ad': {'due': free && entryDue, 'gap_min': 30, 'interstitial_unit': 'u-int'},
        'features': {
          for (final f in ['enhance_hd', 'enhance_cloud', 'prompt_edit', 'generate', ...restoreFeatures])
            f: _quote(f)
        },
        'restore': {
          for (final f in restoreFeatures)
            f: {
              'ready': restoreReady,
              'needs': restoreReady ? '' : (f == 'deblur' ? 'GPU key (Replicate) + cost per run' : 'server model not installed')
            }
        },
        'providers': {
          'ready': providerReady,
          'needs': providerReady ? '' : 'Gemini API key + cost per image'
        },
        'trials_left_today': free ? math.max(0, trialsPerDay - trialsUsed) : null,
        'preview_max_px': 1024,
        'is_owner': isOwner,
      });

  @override
  Future<SafetyVerdict> safety(Map<String, dynamic> body) async => refuse
      ? SafetyVerdict(allowed: false, reason: 'sexual', message: refuseMessage)
      : SafetyVerdict.fromJson({'allowed': true, 'reason': 'ok', 'flags': {}});

  @override
  Future<PsReply> entryAd({required bool shown}) async {
    if (shown) entryRecorded++;
    entryDue = false;
    return const PsReply(200, {'ok': true});
  }

  /// d1-photo: the last job body the app sent.
  Map<String, dynamic> lastBody = const {};

  @override
  Future<PsReply> createJob(Map<String, dynamic> body) async {
    lastBody = body;
    final f = '${body['feature']}';
    final q = _quote(f);
    if (q['ok'] != true) return PsReply(409, {'reason': q['reason']});
    final opts = (q['options'] as List).cast<Map>();
    final via = body['via'] as String?;
    var opt = opts.where((o) => o['via'] == via).firstOrNull;
    if (opt == null && opts.length == 1 && (opts.first['via'] == 'free' || opts.first['via'] == 'pool')) {
      opt = opts.first;
    }
    if (opt == null) return const PsReply(409, {'reason': 'choose_funding'});
    final id = _next++;
    final j = _FJob(id, f, '${opt['via']}', opt['via'] == 'ads' ? opt['ads'] as int : 0);
    if (opt['via'] == 'credits') {
      if (credits < (opt['credits'] as int)) return const PsReply(402, {'reason': 'insufficient'});
      credits -= opt['credits'] as int;
      j.status = 'funded';
    } else if (opt['via'] != 'ads') {
      j.status = 'funded';
    } else if (opt['trial'] == true) {
      trialsUsed++;
    }
    jobs[id] = j;
    return PsReply(201, {'ok': true, 'job': j.json(free)});
  }

  @override
  Future<PsReply> job(int id) async {
    final j = jobs[id];
    if (j == null) return const PsReply(404, {});
    return PsReply(200, {'ok': true, 'job': j.json(free)});
  }

  @override
  Future<PsReply> ticket(int id) async {
    final j = jobs[id]!;
    if (j.status != 'awaiting_funds') return const PsReply(409, {'reason': 'not_awaiting_ads'});
    final n = 'nonce-$id-${j.pending.length + j.verified}';
    j.pending.add(n);
    return PsReply(201, {'ok': true, 'nonce': n, 'custom_data': n, 'user_id': '7', 'rewarded_unit': 'u-rew'});
  }

  /// What Google's signed SSV callback does on the real server.
  void ssv(String nonce) {
    for (final j in jobs.values) {
      if (j.pending.remove(nonce)) {
        j.verified++;
        if (j.verified >= j.adsRequired) j.status = 'funded';
      }
    }
  }

  @override
  Future<PsReply> fundWithCredits(int id) async {
    final j = jobs[id]!;
    final price = j.feature == 'enhance_hd' ? 2 : 9;
    if (credits < price) return const PsReply(402, {'reason': 'insufficient', 'message': 'Not enough credits.'});
    credits -= price;
    j.funding = 'credits';
    j.status = 'funded';
    return PsReply(200, {'ok': true, 'job': j.json(free)});
  }

  @override
  Future<PsReply> run(int id, {String imageB64 = '', List<List<double>>? faceBoxes}) async {
    final j = jobs[id]!;
    if (j.status != 'funded') return PsReply(402, {'reason': 'not_funded', 'job': j.json(free)});
    runs++;
    j.status = 'done';
    return PsReply(200, {'ok': true, 'job': j.json(free)});
  }

  @override
  Future<PsReply> unlock(int id, ExportKind kind) async {
    final j = jobs[id]!;
    unlocks.add(kind);
    if (j.status != 'funded' && j.status != 'done') {
      return PsReply(402, {'reason': 'locked', 'job': j.json(free)});
    }
    return PsReply(200, {
      'ok': true,
      'token': 'tok-$id-${unlocks.length}',
      'corner_mark': free,
      if (j.feature != 'enhance_hd') 'result': '/api/v1/m/result_$id.png',
      'ai_note': 'Edited with Assisto (AI-assisted)',
    });
  }

  @override
  Future<Uint8List?> download(String url) async => kTinyPng;

  final reports = <String>[];
  @override
  Future<PsReply> report(int id, String reason, {String note = ''}) async {
    reports.add(reason);
    return const PsReply(201, {'ok': true, 'message': 'Thank you'});
  }
}

/// Ads: each rewarded ad pops the next outcome; on `earned` the fake fires
/// the server's SSV callback (like Google would).
class FakeAds implements PhotoAdBridge {
  FakeAds(this.backend, {List<RewardOutcome>? outcomes, this.interstitialShows = true})
      : outcomes = outcomes ?? [];
  final FakePsBackend backend;
  final List<RewardOutcome> outcomes;
  final bool interstitialShows;
  int interstitials = 0;
  int rewardedShown = 0;

  @override
  bool get linked => true;

  @override
  Future<bool> showInterstitial(String unitId) async {
    interstitials++;
    return interstitialShows;
  }

  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
      {required String userId, required String customData}) async {
    rewardedShown++;
    final o = outcomes.isEmpty ? RewardOutcome.earned : outcomes.removeAt(0);
    if (o == RewardOutcome.earned) backend.ssv(customData);
    return o;
  }
}

class FakeEngine implements EnhanceEngine {
  FakeEngine({this.ready = true});
  final bool ready;
  final requests = <EnhanceRequest>[];
  @override
  EnhanceReport lastReport = EnhanceReport.none;
  @override
  Future<EnhanceAvailability> availability() async => ready
      ? const EnhanceAvailability(EnhanceState.ready)
      : EnhanceAvailability.unavailable;
  @override
  Future<EnhanceAvailability> prepare({void Function(EnhanceAvailability)? onProgress}) =>
      availability();
  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) async {
    if (!ready) throw const EnhanceUnavailable(EnhanceState.unavailable);
    requests.add(req);
    return kTinyPng;
  }
}

/// Landmarks: returns [before] for the first image seen and [after] for any
/// later one (enough to drive the identity guard deterministically).
class FakeLandmarks implements LandmarkProvider {
  FakeLandmarks({this.shiftAfter = 0.0, this.available = true});
  final double shiftAfter;
  @override
  final bool available;
  int calls = 0;
  static List<math.Point<double>> face([double dx = 0]) => [
        const math.Point(40, 50), const math.Point(80, 50), // eyes
        math.Point(60 + dx, 70), // nose
        const math.Point(48, 88), math.Point(72 + dx, 88), // mouth corners
      ];
  @override
  Future<List<List<math.Point<double>>>> landmarks(Uint8List encoded) async {
    calls++;
    return [calls.isOdd ? face() : face(shiftAfter)];
  }
}

class FakeSink implements ExportSink {
  FakeSink({Set<ExportKind>? avail}) : avail = avail ?? ExportKind.values.toSet();
  final Set<ExportKind> avail;
  final delivered = <ExportKind>[];
  @override
  bool available(ExportKind kind) => avail.contains(kind);
  @override
  Future<DeliverResult> deliver(ExportKind kind, Uint8List png, String fileName) async {
    delivered.add(kind);
    return DeliverResult.done;
  }
}

class FakeRenderer implements ExportRenderer {
  final marks = <bool>[];
  final notes = <String>[];
  final inputs = <Uint8List>[];
  @override
  Future<Uint8List> render(Uint8List full,
      {required bool cornerMark, required String note, bool generated = false}) async {
    inputs.add(full);
    marks.add(cornerMark);
    notes.add(note);
    return full;
  }
}

class FakePicker implements PhotoPicker {
  FakePicker({this.many = const []});
  final List<Uint8List> many;
  @override
  Future<Uint8List?> pick({required bool camera}) async => kTinyPng;
  @override
  Future<List<Uint8List>> pickMany({int limit = 10}) async => many.take(limit).toList();
}

class FakeSecure implements SecureScreen {
  FakeSecure({this.works = false});
  final bool works;
  bool on = false;
  @override
  Future<bool> enable() async => on = works;
  @override
  Future<void> disable() async => on = false;
}

/// Scripted gate UI for controller-level tests.
class ScriptUi extends GateUi {
  ScriptUi(this.choices);
  final List<FundChoice?> choices;
  final needs = <GateNeed>[];
  @override
  Future<FundChoice?> chooseFunding(GateNeed need) async {
    needs.add(need);
    return choices.isEmpty ? null : choices.removeAt(0);
  }
}

PsDeps fakeDeps(FakePsBackend b,
        {FakeAds? ads,
        FakeEngine? engine,
        LandmarkProvider? landmarks,
        FakeSink? sink,
        FakeRenderer? renderer,
        FakeSecure? secure}) =>
    PsDeps(
      backend: b,
      ads: ads ?? FakeAds(b),
      engine: engine ?? FakeEngine(),
      guard: IdentityGuard(landmarks: landmarks ?? FakeLandmarks()),
      sink: sink ?? FakeSink(),
      renderer: renderer ?? FakeRenderer(),
      secure: secure ?? FakeSecure(),
      picker: FakePicker(),
    );
