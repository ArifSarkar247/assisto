// c3-msg gallery stubs: REAL ciphertext (encrypted with throw-away test
// identities) so the shots show on-device decryption working — chat list
// previews, ticks, quoted reply, presence.
import 'dart:convert';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/realtime/realtime_channel.dart';

bool fakeC3On = false;

class C3Fake {
  C3Fake._();
  static final e2e = SoftwareE2E();
  static final me = e2e.generateIdentity();
  static final rahim = e2e.generateIdentity();
  static final nadia = e2e.generateIdentity();
  static final karim = e2e.generateIdentity();

  static Map<String, dynamic> env(String text, IdentityKeyPair from, IdentityKeyPair to) {
    final ct = e2e.encrypt(self: from, recipientPublicKey: to.publicKey, plaintext: text);
    return {
      'ciphertext': ct.ciphertextB64,
      'nonce': ct.nonceB64,
      'sender_key_id': ct.senderKeyId,
      'scheme': ct.scheme,
    };
  }

  static String pub(IdentityKeyPair k) => base64Encode(k.publicKey);

  static Map<String, dynamic> member(bool bn) => {
        'id': 1,
        'name': bn ? 'রহিম' : 'Rahim',
        'relation': 'friend',
        'state': 'accepted',
        'public_key': pub(rahim),
      };

  /// Live states for the shots (typing in a row, online in a header).
  static void seedRealtime() {
    RealtimeChannel.instance.states.value = {
      'member:2': const RtChatState(activity: 'typing', online: true),
      'member:1': const RtChatState(online: true),
    };
  }

  static String _ago(Duration d) => DateTime.now().subtract(d).toUtc().toIso8601String();

  static Map<String, dynamic>? get(String path, bool bn) {
    if (!fakeC3On) return null;
    if (path == '/circle/chats') {
      return {
        'results': [
          {
            'id': '1', 'kind': 'member', 'member': member(bn), 'unread': 10,
            'at': _ago(const Duration(minutes: 3)), 'last_text': '',
            'last': {'id': 21, 'mine': false, 'content_type': 'text', 'peer_public_key': pub(rahim),
                     ...env(bn ? 'তুমি কি আসছো? সবাই অপেক্ষা করছে' : 'Are you coming? Everyone is waiting', rahim, me)},
          },
          {
            'id': '2', 'kind': 'member',
            'member': {'id': 2, 'name': bn ? 'নাদিয়া' : 'Nadia', 'public_key': pub(nadia)},
            'unread': 0, 'at': _ago(const Duration(minutes: 20)),
            'last': {'id': 19, 'mine': true, 'status': 'read', 'content_type': 'text', 'peer_public_key': pub(nadia),
                     ...env(bn ? 'ঠিক আছে, কাল দেখা হবে' : 'Okay, see you tomorrow', me, nadia)},
          },
          {
            'id': 'g7', 'kind': 'group', 'is_group': true, 'group_id': 7,
            'group': {'id': 7, 'name': bn ? 'পরিবার' : 'Family', 'my_member_id': 3},
            'member': {'id': null, 'name': bn ? 'পরিবার' : 'Family'},
            'unread': 2, 'at': _ago(const Duration(hours: 2)),
            'last': {'id': 17, 'mine': false, 'sender_name': bn ? 'রহিম' : 'Rahim', 'content_type': 'text',
                     'peer_public_key': pub(rahim), ...env(bn ? 'রাতে খাবার ৮টায়' : 'Dinner at 8 tonight', rahim, me)},
          },
          {
            'id': '3', 'kind': 'member',
            'member': {'id': 3, 'name': bn ? 'করিম' : 'Karim', 'public_key': pub(karim)},
            'unread': 0, 'marked_unread': true, 'at': _ago(const Duration(days: 1)),
            'last': {'id': 15, 'mine': true, 'status': 'delivered', 'content_type': 'text', 'peer_public_key': pub(karim),
                     ...env(bn ? 'ফাইলটা পাঠিয়েছি' : 'I sent the file', me, karim)},
          },
          {
            'id': '4', 'kind': 'member',
            'member': {'id': 4, 'name': bn ? 'আম্মু' : 'Mom', 'public_key': pub(karim)},
            'unread': 0, 'at': _ago(const Duration(days: 3)),
            'last': {'id': 11, 'mine': true, 'status': 'sent', 'content_type': 'photo'},
          },
        ],
      };
    }
    // e2-keys: the chat now asks for a page (?limit=50)
    if (path.split('?').first == '/circle/1/messages') {
      final t0 = DateTime.now().subtract(const Duration(minutes: 30));
      String at(int m) => t0.add(Duration(minutes: m)).toUtc().toIso8601String();
      return {
        'results': [
          {'id': 1, 'sender_id': 50, 'mine': false, 'created_at': at(0), 'content_type': 'text',
           ...env(bn ? 'আজ বিকেলে মিটিং আছে?' : 'Is the meeting this afternoon?', rahim, me)},
          {'id': 2, 'sender_id': 9, 'mine': true, 'status': 'read', 'created_at': at(2), 'content_type': 'text',
           'reply_to': 1, ...env(bn ? 'হ্যাঁ, ৪টায়' : 'Yes, at 4', me, rahim)},
          {'id': 3, 'sender_id': 9, 'mine': true, 'status': 'delivered', 'created_at': at(5), 'content_type': 'text',
           ...env(bn ? 'আমি একটু দেরি করব' : "I'll be a little late", me, rahim)},
          {'id': 4, 'sender_id': 50, 'mine': false, 'created_at': at(9), 'content_type': 'text',
           'reactions': {'9': '\u{1F44D}'},
           ...env(bn ? 'সমস্যা নেই 👍' : 'No problem 👍', rahim, me)},
          {'id': 5, 'sender_id': 9, 'mine': true, 'status': 'sent', 'created_at': at(12), 'content_type': 'text',
           ...env(bn ? 'রাস্তায় আছি' : 'On my way', me, rahim)},
        ],
      };
    }
    // e2-keys gallery: a chat that opens at the "N unread messages" divider,
    // with one message this device cannot decrypt (honest bubble).
    if (path.split('?').first == '/circle/4/messages') {
      final t0 = DateTime.now().subtract(const Duration(minutes: 40));
      String at(int m) => t0.add(Duration(minutes: m)).toUtc().toIso8601String();
      final stranger = e2e.generateIdentity();
      return {
        'results': [
          {'id': 31, 'sender_id': 50, 'mine': false, 'created_at': at(0), 'content_type': 'text',
           ...env(bn ? 'কাল দোকানে আসবে?' : 'Coming to the shop tomorrow?', karim, me)},
          {'id': 32, 'sender_id': 9, 'mine': true, 'status': 'read', 'created_at': at(3), 'content_type': 'text',
           ...env(bn ? 'হ্যাঁ, সকালে' : 'Yes, in the morning', me, karim)},
          {'id': 33, 'sender_id': 50, 'mine': false, 'created_at': at(8), 'content_type': 'text',
           ...env('?', stranger, me)},
          {'id': 34, 'sender_id': 50, 'mine': false, 'created_at': at(20), 'content_type': 'text', 'unseen': true,
           ...env(bn ? 'নতুন মাল এসেছে' : 'New stock arrived', karim, me)},
          {'id': 35, 'sender_id': 50, 'mine': false, 'created_at': at(22), 'content_type': 'text', 'unseen': true,
           ...env(bn ? 'দাম আগের মতোই' : 'Same price as before', karim, me)},
        ],
        'has_more': false,
      };
    }
    return null;
  }

  static Map<String, dynamic> member4(bool bn) => {
        'id': 4,
        'name': bn ? 'আবুল কাশেম' : 'Abul Kashem',
        'relation': 'friend',
        'state': 'accepted',
        'public_key': pub(karim),
      };

  static Map<String, dynamic> info(bool bn) => {
        'id': 3,
        'group': true,
        'status': 'delivered',
        'recipients': [
          {'user_id': 1, 'name': bn ? 'রহিম' : 'Rahim',
           'delivered_at': _ago(const Duration(minutes: 25)), 'seen_at': _ago(const Duration(minutes: 20))},
          {'user_id': 2, 'name': bn ? 'নাদিয়া' : 'Nadia',
           'delivered_at': _ago(const Duration(minutes: 24)), 'seen_at': null, 'seen_hidden': true},
          {'user_id': 3, 'name': bn ? 'করিম' : 'Karim', 'delivered_at': null, 'seen_at': null},
        ],
      };
}
