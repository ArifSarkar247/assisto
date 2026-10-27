import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/push/push_payload.dart';

void main() {
  Map<String, String> call({String id = '42'}) => {
        'kind': 'call',
        'title': 'Rafi is calling',
        'body': 'Video call',
        'lang': 'en',
        'channel': 'calls',
        'sent_at': '1760000000',
        'call_id': id,
        'caller_id': '9',
        'caller_name': 'Rafi',
        'video': 'true',
        'chat_id': '15',
        'route': 'circle/call',
      };

  group('PushPayload', () {
    test('parses the backend contract (all strings)', () {
      final p = PushPayload.fromData(call());
      expect(p.kind, 'call');
      expect(p.isCall, isTrue);
      expect(p.isVideo, isTrue);
      expect(p.callId, '42');
      expect(p.chatId, '15');
      expect(p.lang, 'en');
      expect(p.channel, PushChannels.calls);
      expect(p.wantsFullScreen, isTrue);
      expect(p.isDataOnly, isTrue);
    });

    test('non-string values are stringified, nulls dropped', () {
      final p = PushPayload.fromData({'kind': 'sos', 'silent': true, 'lat': null});
      expect(p.silent, isTrue);
      expect(p.data.containsKey('lat'), isFalse);
    });

    test('lang defaults to bn; unknown channel falls back by kind', () {
      final p = PushPayload.fromData({'kind': 'reminder', 'channel': 'weird'});
      expect(p.lang, 'bn');
      expect(p.channel, PushChannels.reminders);
      expect(PushPayload.fromData({'kind': 'shop_alert'}).channel,
          PushChannels.alerts);
      expect(PushPayload.fromData({'kind': 'nope'}).isKnownKind, isFalse);
    });

    test('every backend kind maps to one of the five channels', () {
      for (final k in [
        'message', 'call', 'call_cancel', 'reminder', 'family_alert', 'sos',
        'owner_alert', 'shop_alert'
      ]) {
        expect(PushChannels.all, contains(PushChannels.byKind[k]), reason: k);
      }
    });

    test('call and its cancel share a stable notification id', () {
      final ring = PushPayload.fromData(call());
      final cancel = PushPayload.fromData(
          {'kind': 'call_cancel', 'call_id': '42', 'reason': 'missed'});
      expect(cancel.notificationId, ring.notificationId);
      expect(PushPayload.fromData(call(id: '43')).notificationId,
          isNot(ring.notificationId));
      // stable across runs (FNV-1a, not String.hashCode)
      expect(PushPayload.stableHash('call-42'), PushPayload.stableHash('call-42'));
      expect(ring.notificationId, greaterThanOrEqualTo(0));
      expect(ring.notificationId, lessThan(0x80000000));
    });

    test('messages from one chat collapse into one notification', () {
      final a = PushPayload.fromData(
          {'kind': 'message', 'chat_kind': 'member', 'chat_id': '5', 'message_id': '1'});
      final b = PushPayload.fromData(
          {'kind': 'message', 'chat_kind': 'member', 'chat_id': '5', 'message_id': '2'});
      final g = PushPayload.fromData(
          {'kind': 'message', 'chat_kind': 'group', 'chat_id': '5'});
      expect(a.notificationId, b.notificationId);
      expect(g.notificationId, isNot(a.notificationId));
    });

    test('encode/decode round-trips; junk decodes to null', () {
      final p = PushPayload.fromData(call());
      expect(PushPayload.decode(p.encode())!.data, p.data);
      expect(PushPayload.decode(null), isNull);
      expect(PushPayload.decode('not json'), isNull);
      expect(PushPayload.decode('[1,2]'), isNull);
    });
  });

  group('PushRouting', () {
    PushTarget? go(Map<String, String> d, {String? action}) =>
        PushRouting.targetFor(PushPayload.fromData(d), action: action);

    test('call tap / accept opens the incoming call; decline opens nothing', () {
      expect(go(call())!.openIncomingCall, isTrue);
      expect(go(call(), action: 'accept')!.openIncomingCall, isTrue);
      expect(go(call(), action: 'decline'), isNull);
    });

    test('call without chat_id falls back to call history', () {
      final d = call()..remove('chat_id');
      expect(go(d)!.chatNavRoute, 'circle_calls');
    });

    test('backend routes map to ChatNav keys', () {
      expect(go({'kind': 'message', 'route': 'circle/chat'})!.chatNavRoute, 'messages');
      expect(go({'kind': 'message', 'route': 'circle/group'})!.chatNavRoute, 'messages');
      expect(go({'kind': 'reminder', 'route': 'reminders'})!.chatNavRoute, 'reminders');
      expect(go({'kind': 'family_alert', 'route': 'alerts'})!.chatNavRoute, 'notifications');
      expect(go({'kind': 'sos', 'route': 'safety/sos'})!.chatNavRoute, 'family_alerts');
      expect(go({'kind': 'shop_alert', 'route': 'business/shop-box'})!.chatNavRoute, 'shop_box');
      expect(go({'kind': 'owner_alert', 'route': 'owner'})!.chatNavRoute, 'analytics');
    });

    test('missing/unknown route falls back by kind; unknown kind -> null', () {
      expect(go({'kind': 'reminder'})!.chatNavRoute, 'reminders');
      expect(go({'kind': 'sos', 'route': '??'})!.chatNavRoute, 'family_alerts');
      expect(go({'kind': 'mystery'}), isNull);
    });
  });
}
