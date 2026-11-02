// amarket: an in-memory MarketSource for widget tests and gallery shots.
// Shapes copy backend/core/market.py payloads (money in POISHA). Test
// fixture only — never shipped.
import 'package:assisto/screens/market/market_source.dart';

class FakeMarketSource implements MarketSource {
  FakeMarketSource({this.empty = false, this.sellerStatus = 'approved', this.hasBusiness = true});

  final bool empty;
  String? sellerStatus; // null = never applied
  final bool hasBusiness;
  final calls = <String>[];
  Map<String, dynamic>? lastNeedBody;

  static const areas = [
    {'key': 'mirpur', 'label': 'Mirpur'},
    {'key': 'uttara', 'label': 'Uttara'},
  ];
  static const categories = [
    {'key': 'grocery', 'label': 'Groceries & food'},
    {'key': 'electronics', 'label': 'Electronics'},
  ];
  static const units = [
    {'key': 'kg', 'label': 'kg'},
    {'key': 'piece', 'label': 'piece'},
  ];

  static Map<String, dynamic> needRow({bool mine = true}) => {
        'id': 7, 'category': 'grocery', 'category_label': 'Groceries & food',
        'title': 'Miniket rice', 'description': 'Good quality, 2nd floor',
        'quantity': 25, 'total_quantity': 40, 'unit': 'kg', 'unit_label': 'kg',
        'area': 'mirpur', 'area_label': 'Mirpur', 'deadline': '2026-11-06T18:00:00+06:00',
        'group_open': true, 'joiners': 1, 'status': 'open', 'bidding_open': true,
        'hidden': false, 'mine': mine, 'joined_qty': null,
        if (mine) 'bid_count': 2,
        if (mine) 'budget_max': 320000,
      };

  static Map<String, dynamic> ranking() => {
        'weights': {'price': 50, 'delivery': 20, 'rating': 20, 'distance': 10},
        'summary': 'Suggested: Rahim Store — 4,000 more than the lowest price, but faster delivery and better rating. '
            'Lowest price: Karim Traders (total 300,000) — pick it if you prefer.',
        'bids': [
          {
            'id': 11, 'unit_price': 7600, 'delivery_hours': 24, 'notes': 'Delivery charge included',
            'status': 'active', 'seller_name': 'Rahim Store', 'seller_area': 'Mirpur',
            'score': 93.1, 'total': 304000, 'recommended': true, 'cheapest': false,
            'fastest': true, 'over_budget': false,
            'reasons': ['400 more than the lowest price (1%)', 'Delivery in 1 day — fastest',
              'Rating 4.6/5 (12 deals)', 'about 0 km away'],
          },
          {
            'id': 12, 'unit_price': 7500, 'delivery_hours': 72, 'notes': '',
            'status': 'active', 'seller_name': 'Karim Traders', 'seller_area': 'Uttara',
            'score': 76.0, 'total': 300000, 'recommended': false, 'cheapest': true,
            'fastest': false, 'over_budget': false,
            'reasons': ['Lowest price', 'Delivery in 3 days', 'New seller — no rating yet (counted as average)',
              'about 6 km away'],
          },
        ],
      };

  @override
  Future<Map<String, dynamic>> overview() async {
    calls.add('overview');
    return {
      'areas': areas, 'categories': categories, 'units': units,
      'weights': {'price': 50, 'delivery': 20, 'rating': 20, 'distance': 10},
      'has_business': hasBusiness, 'seller': _seller(), 'cod_only': true, 'fee': 0,
      'needs': empty ? [] : [needRow()],
    };
  }

  Map<String, dynamic>? _seller() => sellerStatus == null
      ? null
      : {'status': sellerStatus, 'area': 'mirpur', 'area_label': 'Mirpur', 'categories': ['grocery'],
          'shop_name': 'Rahim Store', 'rating_avg': 4.6, 'rating_count': 12};

  @override
  Future<Map<String, dynamic>> createNeed(Map<String, dynamic> body) async {
    calls.add('createNeed');
    lastNeedBody = body;
    return {'need': {...needRow(), 'id': 8}};
  }

  @override
  Future<Map<String, dynamic>> need(int id) async {
    calls.add('need:$id');
    if (id == 9) {
      // seller view: no ranking, own sealed bid only
      return {...needRow(mine: false), 'id': 9, 'can_bid': true, 'my_bid': null, 'km': 6.0};
    }
    return {...needRow(), 'id': id, 'ranking': empty ? {'bids': [], 'summary': ''} : ranking(), 'can_accept': true};
  }

  @override
  Future<Map<String, dynamic>> needAct(int id, String action, [Map<String, dynamic> body = const {}]) async {
    calls.add('$action:$id');
    if (action == 'accept') {
      return {'ok': true, 'deals': [{'id': 21}]};
    }
    return {'ok': true};
  }

  @override
  Future<List<Map<String, dynamic>>> group(String area) async {
    calls.add('group');
    return empty ? [] : [needRow(mine: false)];
  }

  @override
  Future<Map<String, dynamic>> sell() async {
    calls.add('sell');
    return {
      'seller': _seller(), 'has_business': hasBusiness,
      'needs': (empty || sellerStatus != 'approved') ? [] : [{...needRow(mine: false), 'id': 9, 'km': 6.0, 'my_bid': null}],
    };
  }

  @override
  Future<Map<String, dynamic>> applySeller(String area, List<String> categories) async {
    calls.add('apply:$area:${categories.join(',')}');
    sellerStatus = 'pending';
    return {'seller': _seller()};
  }

  @override
  Future<List<Map<String, dynamic>>> deals() async {
    calls.add('deals');
    return empty
        ? []
        : [
            {'id': 21, 'need_id': 7, 'title': 'Miniket rice', 'seller_id': 5, 'role': 'buyer',
              'other_name': 'Rahim Store', 'quantity': 25, 'unit_label': 'kg', 'unit_price': 7600,
              'total': 190000, 'payment': 'cod', 'fee': 0, 'status': 'confirmed', 'rating': null,
              'can_rate': false, 'area_label': 'Mirpur', 'created_at': '2026-11-03T10:00:00+06:00'},
            {'id': 22, 'need_id': 3, 'title': 'LED bulb 12W', 'seller_id': 6, 'role': 'buyer',
              'other_name': 'Alo Electric', 'quantity': 10, 'unit_label': 'piece', 'unit_price': 18000,
              'total': 180000, 'payment': 'cod', 'fee': 0, 'status': 'delivered', 'rating': null,
              'can_rate': true, 'area_label': 'Mirpur', 'created_at': '2026-11-01T10:00:00+06:00'},
          ];
  }

  @override
  Future<Map<String, dynamic>> dealAct(int id, String action, {int? rating}) async {
    calls.add('deal:$action:$id${rating == null ? '' : ':$rating'}');
    return {'deal': {}};
  }

  @override
  Future<Map<String, dynamic>> dealChat(int id) async {
    calls.add('chat:$id');
    return {'member': {'id': 1, 'name': 'Rahim Store', 'state': 'accepted'}, 'state': 'accepted'};
  }

  @override
  Future<void> report(String kind, int id, String category) async => calls.add('report:$kind:$id:$category');

  @override
  Future<void> block(String kind, int id) async => calls.add('block:$kind:$id');
}
