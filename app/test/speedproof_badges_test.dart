// speedproof: concurrent GET /home/badges calls share one request; a later
// call (after the first finished) fetches again; an error never sticks.
import 'dart:async';

import 'package:assisto/api.dart';
import 'package:assisto/home_api.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingApi extends ApiClient {
  int calls = 0;
  Completer<Map<String, dynamic>>? gate;
  bool fail = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) {
    expect(path, '/home/badges');
    calls++;
    if (fail) return Future.error(StateError('offline'));
    gate = Completer<Map<String, dynamic>>();
    return gate!.future;
  }
}

void main() {
  test('three callers at once = one request, same answer', () async {
    final api = _CountingApi();
    final a = api.homeBadges(), b = api.homeBadges(), c = api.homeBadges();
    expect(api.calls, 1);
    api.gate!.complete({'my_circle_unread': 3, 'notif_unseen': 1});
    final r = await Future.wait([a, b, c]);
    expect(r.map((x) => x.myCircleUnread), [3, 3, 3]);
    expect(r.first.notifUnseen, 1);
  });

  test('after it finished, the next call fetches fresh', () async {
    final api = _CountingApi();
    final a = api.homeBadges();
    api.gate!.complete({'my_circle_unread': 1, 'notif_unseen': 0});
    await a;
    final b = api.homeBadges();
    expect(api.calls, 2);
    api.gate!.complete({'my_circle_unread': 5, 'notif_unseen': 0});
    expect((await b).myCircleUnread, 5);
  });

  test('a failed fetch is not reused', () async {
    final api = _CountingApi()..fail = true;
    await expectLater(api.homeBadges(), throwsStateError);
    api.fail = false;
    final b = api.homeBadges();
    expect(api.calls, 2);
    api.gate!.complete({'my_circle_unread': 0, 'notif_unseen': 2});
    expect((await b).notifUnseen, 2);
  });

  test('two clients never share', () async {
    final x = _CountingApi(), y = _CountingApi();
    x.homeBadges();
    y.homeBadges();
    expect(x.calls + y.calls, 2);
  });
}
