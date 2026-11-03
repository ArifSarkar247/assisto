// safeplans: fakes + gallery payloads for the Safety plans screens.
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/safe_plans/safe_plans_api.dart';

Map<String, dynamic> safeStatus(
        {String plan = 'free',
        bool onSale = true,
        bool adsOk = true,
        String why = 'ok',
        int total = 3,
        List<Map<String, dynamic>> children = const [
          {'id': 7, 'name': 'Rina'}
        ]}) =>
    {
      'enabled': true,
      'on_sale': onSale,
      'plan': plan,
      'source': plan == 'free' ? '' : 'play',
      'allowance': 3,
      'used': 0,
      'balance': {'monthly': total, 'school': 0, 'day_pass': 0, 'ads': 0, 'packs': 0, 'total': total},
      'packs': [],
      'costs': {'location_request': 1, 'live_trip': 3},
      'schools': [],
      'children': children,
      'ads': {
        'eligible': adsOk,
        'why': why,
        'for_day': 3,
        'for_request': 3,
        'day_n': 0,
        'req_n': 2,
        'day_left': 1,
        'req_left': 3
      },
      'plans': {
        'child': {'price_bdt': 30, 'requests': 15, 'children': 1, 'guardians': 2, 'product_id': 'safe_child'},
        'family': {
          'price_bdt': 99,
          'credits': 150,
          'members': 15,
          'history_days': 30,
          'update_min': 5,
          'product_id': 'safe_family'
        },
        'school': {'guardians': 4, 'requests': 10},
      },
      'base_plan_id': 'monthly',
      'pack_products': [
        {'id': 'safe_req_10', 'requests': 10, 'price_bdt': 10},
        {'id': 'safe_req_30', 'requests': 30, 'price_bdt': 30},
      ],
      'pack_valid_days': 30,
      'free_requests': 3,
      'play_account_id': 'u1',
    };

class FakeSafeApi implements SafePlansApi {
  Map<String, dynamic> st;
  final tickets = <String>[];
  String ticketStatus = 'verified';
  FakeSafeApi(this.st);

  @override
  Future<Map<String, dynamic>> load() async => st;

  @override
  Future<Map<String, dynamic>> redeemSchool(String code, int childId) async =>
      code == 'SUNBEAM1' ? {'ok': true} : {'ok': false, 'reason': 'bad_code'};

  @override
  Future<Map<String, dynamic>> adTicket(String goal) async {
    tickets.add(goal);
    return {'ok': true, 'nonce': 'n1', 'user_id': '1', 'custom_data': 'n1', 'goal': goal};
  }

  @override
  Future<Map<String, dynamic>> adTicketState(String nonce) async => {'status': ticketStatus};

  @override
  Future<PayResult> verify(String kind, String productId, String purchaseToken) async =>
      const PayResult(ok: true, reason: '', message: '', data: {});
}

