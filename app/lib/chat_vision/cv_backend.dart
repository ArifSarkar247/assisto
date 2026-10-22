import '../api.dart';

/// Server seam for "image in chat" (h1-home): `/chat-vision/*`. Ads are
/// verified by the shared Photo Studio SSV ledger on the server.
class CvOption {
  const CvOption(this.via, {this.ads = 0, this.credits = 0});
  final String via; // pool | ads | credits
  final int ads;
  final int credits;
}

class CvQuote {
  const CvQuote({
    this.ok = false,
    this.reason = 'offline',
    this.options = const [],
    this.message = '',
    this.paidPlan = false,
    this.freeLeft,
  });
  final bool ok;
  final String reason;
  final List<CvOption> options;
  final String message;
  final bool paidPlan;
  final int? freeLeft;

  CvOption? option(String via) {
    for (final o in options) {
      if (o.via == via) return o;
    }
    return null;
  }

  static int _i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  factory CvQuote.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const CvQuote();
    return CvQuote(
      ok: j['ok'] == true,
      reason: '${j['reason'] ?? ''}',
      message: '${j['message'] ?? ''}',
      paidPlan: j['paid_plan'] == true,
      freeLeft: j['free_left'] == null ? null : _i(j['free_left']),
      options: [
        for (final o in (j['options'] as List? ?? const []))
          if (o is Map)
            CvOption('${o['via']}', ads: _i(o['ads']), credits: _i(o['credits'])),
      ],
    );
  }
}

class CvConfig {
  const CvConfig({required this.quote, this.free = true, this.maxImageKb = 4096});
  final CvQuote quote;
  final bool free;
  final int maxImageKb;

  factory CvConfig.fromJson(Map<String, dynamic> j) => CvConfig(
        quote: CvQuote.fromJson(
            j['quote'] is Map ? Map<String, dynamic>.from(j['quote'] as Map) : null),
        free: j['free'] != false,
        maxImageKb: CvQuote._i(j['max_image_kb'] ?? 4096),
      );
}

class CvJob {
  const CvJob({
    required this.id,
    this.status = '',
    this.funding = '',
    this.adsRequired = 0,
    this.adsVerified = 0,
    this.answer = '',
    this.medicine = false,
  });
  final int id;
  final String status;
  final String funding;
  final int adsRequired;
  final int adsVerified;
  final String answer;
  final bool medicine;

  bool get funded => status == 'funded' || status == 'running' || status == 'done';
  bool get done => status == 'done';
  int get adsRemaining => (adsRequired - adsVerified).clamp(0, 99);

  static CvJob? fromJson(dynamic j) {
    if (j is! Map) return null;
    int i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return CvJob(
      id: i(j['id']),
      status: '${j['status'] ?? ''}',
      funding: '${j['funding'] ?? ''}',
      adsRequired: i(j['ads_required']),
      adsVerified: i(j['ads_verified']),
      answer: '${j['answer'] ?? ''}',
      medicine: j['medicine'] == true,
    );
  }
}

class CvReply {
  const CvReply(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  bool get ok => status >= 200 && status < 300 && body['ok'] != false;
  String get reason => '${body['reason'] ?? ''}';
  String get message => '${body['message'] ?? ''}';
  CvJob? get job => CvJob.fromJson(body['job']);
}

abstract class CvBackend {
  Future<CvConfig> config();
  Future<CvReply> create({required String via, required String question});
  Future<CvReply> job(int id);
  Future<CvReply> ticket(int id);
  Future<CvReply> fundWithCredits(int id);
  Future<CvReply> answer(int id,
      {required String imageB64,
      required String question,
      String deviceText = '',
      List<String> deviceLabels = const []});
}

class ApiCvBackend implements CvBackend {
  ApiCvBackend(this.api);
  final ApiClient api;

  CvReply _r(Map<String, dynamic> j) {
    final st = j['_status'] is num ? (j['_status'] as num).toInt() : 200;
    return CvReply(st, Map<String, dynamic>.from(j)..remove('_status'));
  }

  @override
  Future<CvConfig> config() async =>
      CvConfig.fromJson(await api.getJson('/chat-vision/config'));

  @override
  Future<CvReply> create({required String via, required String question}) async =>
      _r(await api.postJsonRaw('/chat-vision/jobs', {'via': via, 'question': question}));

  @override
  Future<CvReply> job(int id) async {
    try {
      return CvReply(200, await api.getJson('/chat-vision/jobs/$id'));
    } on ApiException catch (e) {
      return CvReply(e.status ?? 500, const {});
    }
  }

  @override
  Future<CvReply> ticket(int id) async =>
      _r(await api.postJsonRaw('/chat-vision/jobs/$id/ad-ticket'));

  @override
  Future<CvReply> fundWithCredits(int id) async =>
      _r(await api.postJsonRaw('/chat-vision/jobs/$id/fund'));

  @override
  Future<CvReply> answer(int id,
          {required String imageB64,
          required String question,
          String deviceText = '',
          List<String> deviceLabels = const []}) async =>
      _r(await api.postJsonRaw('/chat-vision/jobs/$id/answer', {
        'image_b64': imageB64,
        'question': question,
        'device_text': deviceText,
        'device_labels': deviceLabels,
      }));
}
