// mktengine: fake MktSource for widget tests + the screenshot gallery.
// Shapes mirror backend/core/views_mktengine.py; texts are what the server
// sends (it builds them in the user's language, Bangla digits in Bangla).
import 'package:assisto/api.dart';
import 'package:assisto/screens/mktengine/mkt_source.dart';

class FakeMkt implements MktSource {
  /// data | empty | started | off | fail | noretention
  final String mode;
  final bool bn;
  final calls = <String>[];
  FakeMkt([this.mode = 'data', this.bn = true]);

  String _l(String b, String e) => bn ? b : e;

  List<Map<String, dynamic>> get questions => [
        {
          'key': 'business_type', 'type': 'single', 'required': true,
          'label': _l('আপনার ব্যবসা কী ধরনের?', 'What kind of business is it?'),
          'options': [
            {'value': 'grocery', 'label': _l('মুদি / নিত্যপণ্য', 'Grocery / daily needs')},
            {'value': 'fashion', 'label': _l('পোশাক / ফ্যাশন', 'Clothing / fashion')},
          ],
        },
        {
          'key': 'area', 'type': 'text', 'required': true,
          'label': _l('দোকান কোথায়? (এলাকা, শহর)', 'Where is the shop? (area, city)'),
          'hint': _l('যেমন: মিরপুর, ঢাকা', 'e.g. Mirpur, Dhaka'),
        },
        {
          'key': 'channels', 'type': 'multi', 'required': true,
          'label': _l('কোথায় কোথায় আছেন / থাকতে চান?', 'Where are you (or want to be)?'),
          'options': [
            {'value': 'facebook', 'label': _l('Facebook পেজ', 'Facebook Page')},
            {'value': 'whatsapp', 'label': _l('WhatsApp (মেসেজ ও স্ট্যাটাস)', 'WhatsApp')},
          ],
        },
        {
          'key': 'usp', 'type': 'text', 'required': false,
          'label': _l('আপনাকে অন্যদের থেকে আলাদা করে কী? (না লিখলেও চলবে)', 'What makes you different? (optional)'),
          'hint': _l('যেমন: নিজের হাতে বানানো', 'e.g. handmade'),
        },
      ];

  Map<String, dynamic> item(String id, String section, String kind, String title, String body,
          {String status = 'draft', Map<String, dynamic> extra = const {}}) =>
      {
        'id': id, 'section': section, 'kind': kind, 'title': title, 'body': body, 'status': status,
        'uses_labels': [_l('ক্যাটালগের আসল দাম', 'Real catalog prices'), _l('সবচেয়ে বেশি বিক্রি (গত ৯০ দিন, POS)', 'Best sellers (last 90 days, POS)')],
        ...extra,
      };

  Map<String, dynamic> get plan => {
        'lang': bn ? 'bn' : 'en',
        'items': [
          item('post1', 'content', 'post', _l('পোস্ট: মিনিকেট চাল ৫ কেজি', 'Post: Miniket rice 5 kg'),
              _l('আমাদের দোকানে সবচেয়ে বেশি চলা জিনিসগুলোর একটা: মিনিকেট চাল ৫ কেজি\n\nমিনিকেট চাল ৫ কেজি — ৳৩৫০\nএই সপ্তাহে ফ্রি ডেলিভারি (শর্ত দোকান ঠিক করবে)\n\nঅর্ডার করতে ইনবক্স বা WhatsApp করুন। — রিনা স্টোর',
                  'One of the most-bought items in our shop: Miniket rice 5 kg\n\nMiniket rice 5 kg — ৳350\nFree delivery this week\n\nOrder by inbox or WhatsApp. — Rina Store'),
              status: 'approved'),
          item('calendar', 'content', 'calendar', _l('৩০ দিনের কনটেন্ট ক্যালেন্ডার', '30-day content calendar'),
              _l('৭/১১ — পণ্যের পোস্ট: মিনিকেট চাল ৫ কেজি\n১১/১১ — উৎসবের পোস্ট: ১১.১১ অনলাইন সেল দিবস\n২২/১১ — ব্ল্যাক ফ্রাইডে আসছে — আগাম অফারের পোস্ট',
                  '7/11 — Product post: Miniket rice 5 kg\n11/11 — Festival post: 11.11 online sale day\n22/11 — Black Friday is coming — early offer post'),
              extra: {'entries': [{'date': '2026-11-11', 'estimated': false}]}),
          item('ads', 'campaign', 'ads', _l('বিজ্ঞাপনের পরামর্শ (অনুমান)', 'Ad recommendation (estimate)'),
              _l('মাসিক বাজেট (আপনার উত্তর): ৳২,০০০–৳৫,০০০', 'Monthly budget (your answer): ৳2,000–৳5,000'),
              extra: {'estimate': true}),
          item('positioning', 'strategy', 'positioning', _l('পজিশনিং (আপনি কে, কার জন্য)', 'Positioning (who you are, for whom)'),
              _l('রিনা স্টোর — মিরপুর-এ পরিবারের জন্য একটি আপনজনের মতো দোকান।', 'Rina Store is a warm shop in Mirpur for families.')),
          item('fu_thanks_review', 'conversion', 'followup', _l('ফলো-আপ: কেনার ২ দিন পর ধন্যবাদ + মতামত', 'Follow-up: Thank-you + feedback 2 days after a purchase'),
              _l('{name}, {shop} থেকে কেনার জন্য অনেক ধন্যবাদ!', '{name}, thanks a lot for buying at {shop}!'),
              status: 'approved'),
          item('fu_reorder', 'conversion', 'followup', _l('ফলো-আপ: আবার কেনার সময় হলে মনে করানো', 'Follow-up: Reorder nudge'),
              _l('{name}, আবার লাগবে?', '{name}, need it again?'),
              status: 'approved', extra: {'automation_id': 3, 'automation_on': true}),
        ],
        'facts': [
          {'key': 'top_products', 'label': _l('সবচেয়ে বেশি বিক্রি (গত ৯০ দিন, POS)', 'Best sellers (last 90 days, POS)'),
           'value': _l('মিনিকেট চাল ৫ কেজি × ১২', 'Miniket rice 5 kg × 12')},
          {'key': 'repeat_customers', 'label': _l('বারবার কেনা গ্রাহক (৯০ দিনে ২+ বার)', 'Repeat customers (2+ buys in 90 days)'),
           'value': _l('৫ জন (মোট গ্রাহক ১৪)', '5 (of 14 buyers)')},
        ],
      };

  @override
  Future<Map<String, dynamic>> overview() async {
    calls.add('overview');
    if (mode == 'off') throw ApiException('feature_off', 403);
    if (mode == 'fail') throw ApiException('Error 500', 500);
    return {
      'shop': 'Rina Store',
      'questions': questions,
      'steps': questions.length,
      'answers': mode == 'started' ? {'business_type': 'grocery'} : (mode == 'empty' ? {} : {'business_type': 'grocery', 'area': 'Mirpur'}),
      'complete': mode == 'data' || mode == 'noretention',
      'plan': (mode == 'data' || mode == 'noretention') ? plan : null,
      'publish': {'facebook': false, 'instagram': false, 'reason': 'meta_review_pending', 'page': ''},
      'followups': {'flag': mode != 'noretention', 'plan_ok': true},
      'ai_available': true,
    };
  }

  @override
  Future<Map<String, dynamic>> saveAnswers(Map<String, dynamic> answers, {bool partial = false}) async {
    calls.add(partial ? 'save_partial' : 'save');
    return {'answers': answers, 'complete': !partial};
  }

  @override
  Future<Map<String, dynamic>> generate() async {
    calls.add('generate');
    return {'plan': plan};
  }

  @override
  Future<Map<String, dynamic>> editItem(String id, Map<String, dynamic> body) async {
    calls.add('edit:$id:${body['status'] ?? 'body'}');
    return {'item': {'id': id, ...body}};
  }

  @override
  Future<Map<String, dynamic>> polish(String id) async {
    calls.add('polish:$id');
    return {'item': {'id': id}};
  }

  @override
  Future<Map<String, dynamic>> activate(String id) async {
    calls.add('activate:$id');
    return {'automation': {'id': 9, 'kind': 'thanks_review', 'enabled': true}};
  }

  @override
  Future<Map<String, dynamic>> publish(String id) async {
    calls.add('publish:$id');
    throw ApiException(_l('Facebook-এ সরাসরি পোস্ট চালু হবে Meta-র অনুমোদন পেলে।', 'Direct Facebook posting starts once Meta approves it.'), 409);
  }
}
