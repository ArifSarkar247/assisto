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
enum PsFeature { enhanceHd, enhanceCloud, promptEdit, generate, deblur, colorize, oldRestore }

extension PsFeatureWire on PsFeature {
  String get wire => switch (this) {
        PsFeature.enhanceHd => 'enhance_hd',
        PsFeature.enhanceCloud => 'enhance_cloud',
        PsFeature.promptEdit => 'prompt_edit',
        PsFeature.generate => 'generate',
        PsFeature.deblur => 'deblur',
        PsFeature.colorize => 'colorize',
        PsFeature.oldRestore => 'old_restore',
      };
  bool get isCloud => this != PsFeature.enhanceHd;

  /// d1-photo: server restore jobs (no prompt, no generative edit).
  bool get isRestore =>
      this == PsFeature.deblur || this == PsFeature.colorize || this == PsFeature.oldRestore;
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
      this.paidPlan = false});
  final bool ok;
  final String reason;
  final List<FundingOption> options;
  final String message;
  final bool paidPlan;

  static const none = FeatureQuote(ok: false, reason: 'unknown');

  FundingOption? get ads =>
      options.where((o) => o.via == 'ads').firstOrNull;
  FundingOption? get credits =>
      options.where((o) => o.via == 'credits' || o.via == 'pool').firstOrNull;
  bool get free => options.any((o) => o.via == 'free');

  factory FeatureQuote.fromJson(Map? j) {
    if (j == null) return none;
    return FeatureQuote(
      ok: j['ok'] == true,
      reason: _s(j['reason']),
      message: _s(j['message']),
      paidPlan: j['paid_plan'] == true,
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
  });
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

  bool get funded => status == 'funded' || status == 'done';

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
      );
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
