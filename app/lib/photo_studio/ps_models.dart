/// Photo Studio (ps1-photo) — plain data models parsed defensively from the
/// server (`/photo-studio/*`). The server is the authority on every price,
/// cap and safety decision; these mirror it for UI only.
library;

import 'ps_model.dart';

enum ExportKind { save, share, wallpaper, copy, openIn }

extension ExportKindWire on ExportKind {
  String get wire => switch (this) {
        ExportKind.save => 'save',
        ExportKind.share => 'share',
        ExportKind.wallpaper => 'wallpaper',
        ExportKind.copy => 'copy',
        ExportKind.openIn => 'open_in',
      };
}

/// d1-photo adds three HEAVY restore jobs that run on OUR server (colorize,
/// old-photo restore: ONNX Runtime on the server CPU) or a pay-per-use GPU API
/// behind an Admin key (deblur: NAFNet). They are shown only when the server
/// quote says ok (model installed / key connected) — never a dead button.
enum PsFeature {
  enhanceHd, enhanceCloud, promptEdit, generate, deblur, colorize, oldRestore,

  /// d1-photo v2: HD enhance on OUR photo worker (+ FACE LOCK).
  enhanceServer,

  /// photo-final: Ultra HD (Premium only, hosted upscaler, monthly quota).
  ultraHd,
}

extension PsFeatureWire on PsFeature {
  String get wire => switch (this) {
        PsFeature.enhanceHd => 'enhance_hd',
        PsFeature.enhanceCloud => 'enhance_cloud',
        PsFeature.promptEdit => 'prompt_edit',
        PsFeature.generate => 'generate',
        PsFeature.deblur => 'deblur',
        PsFeature.colorize => 'colorize',
        PsFeature.oldRestore => 'old_restore',
        PsFeature.enhanceServer => 'enhance_server',
        PsFeature.ultraHd => 'ultra_hd',
      };
  bool get isCloud => this != PsFeature.enhanceHd;

  /// d1-photo: server restore jobs (no prompt, no generative edit).
  bool get isRestore =>
      this == PsFeature.deblur ||
      this == PsFeature.colorize ||
      this == PsFeature.oldRestore ||
      this == PsFeature.enhanceServer ||
      this == PsFeature.ultraHd;

  static PsFeature? fromWire(String w) =>
      PsFeature.values.where((f) => f.wire == w).firstOrNull;
}

enum EditStrength { light, natural, strong }

extension EditStrengthWire on EditStrength {
  String get wire => name;
  EditStrength get lighter => switch (this) {
        EditStrength.strong => EditStrength.natural,
        EditStrength.natural => EditStrength.light,
        EditStrength.light => EditStrength.light,
      };
}

int _i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
String _s(dynamic v) => v == null ? '' : '$v';

/// One way to pay for a job: `ads` (N rewarded ads), `credits`, `pool`
/// (Premium/Business monthly credits) or `free` (paid plan, no cost).
class FundingOption {
  const FundingOption(this.via, {this.ads = 0, this.credits = 0, this.trial = false});
  final String via;
  final int ads;
  final int credits;
  final bool trial;

  factory FundingOption.fromJson(Map j) => FundingOption(_s(j['via']),
      ads: _i(j['ads']), credits: _i(j['credits']), trial: j['trial'] == true);
}

class FeatureQuote {
  const FeatureQuote(
      {required this.ok,
      required this.reason,
      this.options = const [],
      this.message = '',
      this.paidPlan = false,
      this.freeLeft,
      this.leftMonth});
  final bool ok;
  final String reason;
  final List<FundingOption> options;
  final String message;
  final bool paidPlan;

  /// photo-final: free HD enhances still left (lifetime or this week);
  /// null = not on a free route.
  final int? freeLeft;

  /// photo-final: Ultra HD images left this month (paid plans).
  final int? leftMonth;

  static const none = FeatureQuote(ok: false, reason: 'unknown');

  FundingOption? get ads =>
      options.where((o) => o.via == 'ads').firstOrNull;
  FundingOption? get credits =>
      options.where((o) => o.via == 'credits' || o.via == 'pool').firstOrNull;
  bool get free => options.any((o) => o.via == 'free');

  /// d1-photo v2: one of the free user's lifetime free AI generations.
  bool get gift => options.any((o) => o.via == 'gift');

  factory FeatureQuote.fromJson(Map? j) {
    if (j == null) return none;
    return FeatureQuote(
      ok: j['ok'] == true,
      reason: _s(j['reason']),
      message: _s(j['message']),
      paidPlan: j['paid_plan'] == true,
      freeLeft: j['free_left'] is num ? _i(j['free_left']) : null,
      leftMonth: j['left_month'] is num ? _i(j['left_month']) : null,
      options: ((j['options'] as List?) ?? const [])
          .whereType<Map>()
          .map(FundingOption.fromJson)
          .toList(),
    );
  }
}

class PsConfig {
  const PsConfig({
    this.plan = 'free',
    this.free = true,
    this.entryAdDue = false,
    this.entryGapMin = 30,
    this.interstitialUnit = '',
    this.adsConfigured = false,
    this.features = const {},
    this.providerReady = false,
    this.providerNeeds = '',
    this.trialsLeft,
    this.previewMaxPx = 1024,
    this.balance = 0,
    this.aiModel = AiModelInfo.none,
    this.isOwner = false,
    this.restoreNeeds = const {},
    this.templates = const [],
    this.limits = const {},
    this.usage = const {},
    this.enhanceCap = EnhanceCapability.none,
  });

  /// photo-final: what the server HD enhance really offers right now.
  final EnhanceCapability enhanceCap;
  final String plan;
  final bool free;
  final bool entryAdDue;
  final int entryGapMin;
  final String interstitialUnit;
  final bool adsConfigured;
  final Map<String, FeatureQuote> features;
  final bool providerReady;
  final String providerNeeds;
  final int? trialsLeft;
  final int previewMaxPx;
  final int balance;

  /// p2-photo: the on-device AI restore model published by our server.
  final AiModelInfo aiModel;

  /// p2-photo: the viewer is the owner (superuser) — only they see the
  /// "add an image-AI key" note when no cloud provider is connected.
  final bool isOwner;

  /// d1-photo: per restore feature, what the OWNER must still do (empty =
  /// ready). Users never see these; the owner sees one note.
  final Map<String, String> restoreNeeds;

  FeatureQuote quote(PsFeature f) => features[f.wire] ?? FeatureQuote.none;

  /// d1-photo v2: one-tap templates from the server.
  final List<PsTemplate> templates;

  /// Owner-editable limits (free_enhance_per_day …) and this user's usage.
  final Map<String, int> limits;
  final Map<String, int> usage;

  /// A restore job is offered only when the server can really run + price it.
  bool restoreReady(PsFeature f) => f.isRestore && quote(f).ok;

  factory PsConfig.fromJson(Map<String, dynamic> j) {
    final entry = (j['entry_ad'] as Map?) ?? const {};
    final prov = (j['providers'] as Map?) ?? const {};
    final feats = <String, FeatureQuote>{};
    ((j['features'] as Map?) ?? const {}).forEach((k, v) {
      if (v is Map) feats['$k'] = FeatureQuote.fromJson(v);
    });
    final free = j['free'] != false;
    return PsConfig(
      plan: _s(j['plan']).isEmpty ? 'free' : _s(j['plan']),
      free: free,
      entryAdDue: free && entry['due'] == true,
      entryGapMin: _i(entry['gap_min']) == 0 ? 30 : _i(entry['gap_min']),
      interstitialUnit: _s(entry['interstitial_unit']),
      adsConfigured: entry['ads_configured'] == true,
      features: feats,
      providerReady: prov['ready'] == true,
      providerNeeds: _s(prov['needs']),
      trialsLeft: j['trials_left_today'] is num ? _i(j['trials_left_today']) : null,
      previewMaxPx: _i(j['preview_max_px']) == 0 ? 1024 : _i(j['preview_max_px']),
      balance: _i(j['balance']),
      aiModel: AiModelInfo.fromJson(j['ai_model']),
      isOwner: j['is_owner'] == true,
      restoreNeeds: {
        for (final e in ((j['restore'] as Map?) ?? const {}).entries)
          if (e.value is Map && (e.value as Map)['ready'] != true)
            '${e.key}': _s((e.value as Map)['needs']),
      },
      templates: ((j['templates'] as List?) ?? const [])
          .whereType<Map>()
          .map(PsTemplate.fromJson)
          .whereType<PsTemplate>()
          .toList(),
      limits: {
        for (final e in ((j['limits'] as Map?) ?? const {}).entries) '${e.key}': _i(e.value)
      },
      usage: {
        for (final e in ((j['usage'] as Map?) ?? const {}).entries) '${e.key}': _i(e.value)
      },
      enhanceCap: EnhanceCapability.fromJson(j['enhance']),
    );
  }
}

/// photo-final: the server's honest capability report for HD enhance — the
/// app shows a control only when the server says it really works.
class EnhanceCapability {
  const EnhanceCapability(
      {this.bgBlur = false,
      this.faceLock = false,
      this.faceRestore = false,
      this.ultraAvailable = false,
      this.providers = const []});
  final bool bgBlur, faceLock, faceRestore, ultraAvailable;

  /// Paid providers connected on the server (names only, for the owner).
  final List<String> providers;

  static const none = EnhanceCapability();

  factory EnhanceCapability.fromJson(Object? raw) {
    if (raw is! Map) return none;
    final u = raw['ultra_hd'];
    return EnhanceCapability(
      bgBlur: raw['bg_blur'] == true,
      faceLock: raw['face_lock'] == true,
      faceRestore: raw['face_restore'] == true,
      ultraAvailable: u is Map && u['available'] == true,
      providers: ((raw['providers'] as List?) ?? const []).map((e) => '$e').toList(),
    );
  }
}

class PsJob {
  const PsJob({
    required this.id,
    required this.feature,
    required this.status,
    this.funding = '',
    this.adsRequired = 0,
    this.adsVerified = 0,
    this.adsRemaining = 0,
    this.previewUrl = '',
    this.cornerMark = true,
    this.flags = const {},
    this.queuePosition = 0,
    this.faceLock,
  });
  final int id;
  final String feature;
  final String status;
  final String funding;
  final int adsRequired;
  final int adsVerified;
  final int adsRemaining;
  final String previewUrl;
  final bool cornerMark;
  final Map<String, dynamic> flags;

  /// d1-photo v2: waiting for the photo worker (1 = next).
  final int queuePosition;

  /// d1-photo v2: what FACE LOCK did on the server (null = no check ran).
  final FaceLockInfo? faceLock;

  bool get funded => status == 'funded' || status == 'done';
  bool get waiting => status == 'queued' || status == 'running';

  /// photo-final: today's paid budget on the server is used — the job waits
  /// in the queue until tomorrow (nothing charged, nothing lost).
  bool get waitingForBudget => status == 'queued' && flags['waiting'] == 'spend_cap';

  factory PsJob.fromJson(Map j) => PsJob(
        id: _i(j['id']),
        feature: _s(j['feature']),
        status: _s(j['status']),
        funding: _s(j['funding']),
        adsRequired: _i(j['ads_required']),
        adsVerified: _i(j['ads_verified']),
        adsRemaining: _i(j['ads_remaining']),
        previewUrl: _s(j['preview']),
        cornerMark: j['corner_mark'] != false,
        flags: ((j['flags'] as Map?) ?? const {}).cast<String, dynamic>(),
        queuePosition: _i(j['queue_position']),
        faceLock: FaceLockInfo.fromJson(j['face_lock']),
      );
}

/// d1-photo v2: FACE LOCK result for one AI image.
class FaceLockInfo {
  const FaceLockInfo({required this.action, this.faces = 0, this.restored = 0, this.score});

  /// kept | restored_original_face | no_faces | unavailable
  final String action;
  final int faces, restored;

  /// Identity similarity 0..1 of the delivered face(s) (worst face).
  final double? score;

  /// The badge is only shown when the check REALLY ran on a face.
  bool get locked => faces > 0 && (action == 'kept' || action == 'restored_original_face');

  static FaceLockInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final a = _s(raw['action']);
    if (a.isEmpty) return null;
    final sc = raw['min_score'];
    return FaceLockInfo(
        action: a,
        faces: _i(raw['faces']),
        restored: _i(raw['restored']),
        score: sc is num ? sc.toDouble() : null);
  }
}

/// d1-photo v2: a one-tap template (prompt is server-owned).
class PsTemplate {
  const PsTemplate(this.id, this.feature, this.label);
  final String id;
  final PsFeature feature;
  final String label;

  static PsTemplate? fromJson(Map j) {
    final f = PsFeatureWire.fromWire(_s(j['feature']));
    if (f == null) return null;
    return PsTemplate(_s(j['id']), f, _s(j['label']));
  }
}

class SafetyVerdict {
  const SafetyVerdict(
      {required this.allowed,
      this.reason = 'ok',
      this.message = '',
      this.childCaution = false,
      this.consentReminder = false});
  final bool allowed;
  final String reason;
  final String message;
  final bool childCaution;
  final bool consentReminder;

  factory SafetyVerdict.fromJson(Map j) {
    final f = (j['flags'] as Map?) ?? const {};
    return SafetyVerdict(
      allowed: j['allowed'] == true,
      reason: _s(j['reason']),
      message: _s(j['message']),
      childCaution: f['child_caution'] == true,
      consentReminder: f['consent_reminder'] == true,
    );
  }
}

/// Result of a backend call that may be refused/locked; never throws for
/// expected 4xx answers.
class PsReply {
  const PsReply(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  bool get ok => status >= 200 && status < 300;
  String get reason => _s(body['reason']);
  String get message => _s(body['message']);
  PsJob? get job => body['job'] is Map ? PsJob.fromJson(body['job'] as Map) : null;
}

/// Ready (tickable) options — ids match the server's READY_OPTIONS.
class PsOptions {
  PsOptions._();
  static const ready = [
    'bg_change', 'bg_remove', 'bg_blur', 'sky_replace', 'remove_objects',
    'lighting', 'passport_bd', 'visa_bd', 'product_photo', 'document_cleanup',
    'crop_straighten', 'beauty_retouch',
  ];

  /// The ONLY beauty operations allowed ("same person, best version").
  static const beautyAllowed = [
    'skin_smooth', 'blemish_remove', 'under_eye', 'even_tone', 'glow',
    'teeth_whiten', 'eye_brighten', 'hair_tidy', 'light_makeup',
  ];
}
