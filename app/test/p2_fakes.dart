// p2-money: a fake SponsorBackend for tests + the screenshot gallery.
import 'package:assisto/ads/sponsor_api.dart';
import 'package:assisto/ads/sponsor_models.dart';

Map<String, dynamic> p2Creative({int id = 7, String placement = 'app_open', bool match = false}) => {
      'campaign_id': id,
      'sponsor_id': 3,
      'sponsor': 'Shapla Mobile',
      'placement': placement,
      'label': 'sponsored',
      'title': {'bn': 'নতুন ফোনে ১০% ছাড়', 'en': '10% off new phones'},
      'body': {
        'bn': 'ঢাকার সব শাখায় এই সপ্তাহে। কিস্তিতেও কেনা যাবে।',
        'en': 'This week at every Dhaka branch. Instalments available.'
      },
      'cta': {'bn': 'অফার দেখুন', 'en': 'See the offer'},
      'url': 'https://example.com/offer',
      'image_url': '',
      'token': 'tok-$id',
      'why': {
        'bn': [
          'আপনি ফ্রি প্ল্যানে আছেন — প্রিমিয়ামে কোনো বিজ্ঞাপন নেই।',
          'আমরা আপনার মেসেজ, কন্টাক্ট বা অবস্থান বিজ্ঞাপনদাতাকে দিই না।'
        ],
        'en': [
          'You are on the Free plan — Premium has no ads.',
          'We never share your messages, contacts or location with sponsors.'
        ],
      },
      'matches_you': match,
      'ends_at': '2026-10-31T23:59:00+06:00',
    };

Map<String, dynamic> p2Offer({bool trial = true, bool bn = false}) => {
      'reason': 'out_of_credits',
      'plan': 'free',
      'benefits': [
        {'key': 'credits', 'text': bn ? 'প্রতি মাসে ৯০ AI ক্রেডিট' : '90 AI credits every month'},
        {'key': 'no_ads', 'text': bn ? 'কোনো বিজ্ঞাপন নেই — অ্যাপ খুললে, হোমে, কমিউনিটিতে কোথাও না' : 'No ads anywhere — not on app open, home or communities'},
        {'key': 'family', 'text': bn ? '৫ জন পর্যন্ত পরিবার সার্কেল ও কেয়ারগিভার ড্যাশবোর্ড' : 'Family circle of up to 5 & caregiver dashboard'},
        {'key': 'storage', 'text': bn ? '৫ GB স্টোরেজ' : '5 GB storage'},
      ],
      'monthly_price': 199,
      'yearly_price': 2173,
      'yearly_discount_pct': 9,
      'yearly_monthly_equiv': 181.08,
      'trial_available': trial,
      'trial_days': 3,
      'trial_active': false,
      'cur': 'BDT',
    };

class FakeSponsorBackend implements SponsorBackend {
  FakeSponsorBackend({
    this.slotJson,
    this.prefs,
    this.offers,
    this.offer,
    this.trialOk = true,
    this.ticket,
    this.ticketStatus = 'verified',
  });

  Map<String, dynamic>? slotJson;
  Map<String, dynamic>? prefs;
  List<Map<String, dynamic>>? offers;
  Map<String, dynamic>? offer;
  bool trialOk;
  Map<String, dynamic>? ticket;
  String ticketStatus;

  final events = <String>[];
  final saved = <Map<String, dynamic>>[];
  final muted = <int, bool>{};
  int trials = 0;
  int ticketReads = 0;

  @override
  Future<AdSlot> slot(String placement,
          {String screen = 'home', String entry = '', String ctxKind = '', int? ctxId}) async =>
      AdSlot.fromJson(slotJson);

  @override
  Future<void> event(String token, String kind) async => events.add('$kind:$token');

  @override
  Future<Map<String, dynamic>> why(String token) async => {};

  @override
  Future<Map<String, dynamic>> offerPrefs() async =>
      prefs ??
      {
        'categories': ['mobile'],
        'notifs_on': true,
        'division': '',
        'notif_daily_cap': 2,
        'paid': false,
        'premium_gets_offers': false,
      };

  @override
  Future<Map<String, dynamic>> saveOfferPrefs(Map<String, dynamic> body) async {
    saved.add(body);
    return {...(await offerPrefs()), ...body};
  }

  @override
  Future<List<SponsorCreative>> offersFeed() async =>
      (offers ?? [p2Creative(placement: 'brand_offer', match: true)])
          .map(SponsorCreative.fromJson)
          .whereType<SponsorCreative>()
          .toList();

  @override
  Future<List<Map<String, dynamic>>> brands() async => [
        {'id': 3, 'name': 'Shapla Mobile', 'muted': false, 'followed': false},
        {'id': 4, 'name': 'Nodi Fashion', 'muted': true, 'followed': false},
      ];

  @override
  Future<void> muteBrand(int sponsorId, bool m) async => muted[sponsorId] = m;

  @override
  Future<Map<String, dynamic>> premiumOffer(String reason) async =>
      {...(offer ?? p2Offer()), 'reason': reason};

  @override
  Future<Map<String, dynamic>> startTrial() async {
    trials++;
    return trialOk
        ? {'ok': true, 'days': 3, 'trial_until': '2026-10-26T10:00:00Z'}
        : {'ok': false, 'reason': 'trial_used'};
  }

  @override
  Future<Map<String, dynamic>> rewardTicket() async =>
      ticket ?? {'ok': true, 'nonce': 'n1', 'custom_data': 'n1', 'user_id': '1'};

  @override
  Future<Map<String, dynamic>> rewardTicketState(String nonce) async {
    ticketReads++;
    return {'ok': true, 'status': ticketStatus};
  }
}
