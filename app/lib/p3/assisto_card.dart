// P3 — "Assisto cards" inside My Circle chats (see .phaseB/P3_DESIGN.md §2).
//
// A card is an ordinary E2E text message whose PLAINTEXT is
//
//     <readable fallback line>\n\u2063AC1:<base64url(JSON)>
//
// so it is encrypted per recipient exactly like any message (the server sees
// ciphertext only), notifications / chat previews / older app versions show
// the readable first line, and this app renders the rich card.
//
// Hidden events (`tick`, `rem_ack`) are cards too: they are folded into the
// state of the card they reference and never drawn as their own bubble, so a
// shared shopping list stays in sync across phones without the server ever
// seeing an item.
import 'dart:convert';
import 'dart:math';

const String kCardMarker = '\u2063AC1:';

/// Every card type this build understands.
class CardType {
  static const summary = 'summary';
  static const answer = 'answer';
  static const translate = 'translate';
  static const reminder = 'reminder';
  static const remAck = 'rem_ack';
  static const split = 'split';
  static const list = 'list';
  static const tick = 'tick';
  static const arrived = 'arrived';
  static const sos = 'sos';
  static const med = 'med';
  static const lost = 'lost';

  static const all = {
    summary, answer, translate, reminder, remAck, split, list, tick,
    arrived, sos, med, lost,
  };

  /// Events that only change another card's state (never their own bubble).
  static const hidden = {remAck, tick};
}

class AssistoCard {
  final String type;
  final String id;
  final Map<String, dynamic> data;
  const AssistoCard(this.type, this.id, this.data);

  bool get hidden => CardType.hidden.contains(type);

  /// The card this event points at (tick / rem_ack), else ''.
  String get ref => '${data['ref'] ?? ''}';

  String str(String k) => '${data[k] ?? ''}';
  int integer(String k) => (data[k] is num) ? (data[k] as num).toInt() : int.tryParse('${data[k]}') ?? 0;
  List<dynamic> list(String k) => (data[k] is List) ? data[k] as List : const [];

  Map<String, dynamic> toJson() => {'t': type, 'id': id, 'd': data};
}

final Random _rng = Random();

/// A short, collision-safe card id (links ticks / acks to their card).
String newCardId() {
  final r = List.generate(6, (_) => _rng.nextInt(36).toRadixString(36)).join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}$r';
}

/// The plaintext to encrypt for [card]. [fallback] is one readable line in
/// the sender's language (shown wherever the rich card is not rendered).
String encodeCard(AssistoCard card, String fallback) {
  final line = fallback.replaceAll('\n', ' ').trim();
  final body = base64Url.encode(utf8.encode(jsonEncode(card.toJson())));
  return '$line\n$kCardMarker$body';
}

/// The card inside a decrypted message, or null for an ordinary message or a
/// malformed / unknown card (which then shows as its readable text).
AssistoCard? decodeCard(String plaintext) {
  final i = plaintext.indexOf(kCardMarker);
  if (i < 0) return null;
  try {
    final raw = plaintext.substring(i + kCardMarker.length).trim();
    final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(raw))));
    if (j is! Map) return null;
    final t = '${j['t'] ?? ''}';
    if (!CardType.all.contains(t)) return null;
    final d = j['d'];
    return AssistoCard(t, '${j['id'] ?? ''}',
        d is Map ? d.cast<String, dynamic>() : <String, dynamic>{});
  } catch (_) {
    return null;
  }
}

/// The readable part of a message (the card marker and payload removed) —
/// what previews, notifications, search and copy should use.
String cardFallback(String plaintext) {
  var i = plaintext.indexOf(kCardMarker);
  // cde-chat: theme / nickname control messages carry the same shape
  // (lib/messaging/chat_decor/chat_control.dart kControlMarker)
  if (i < 0) i = plaintext.indexOf('⁣CC1:');
  // mc-media2: location / contact cards (messaging/share/share_payload.dart)
  if (i < 0) i = plaintext.indexOf('\u2063SH1:');
  if (i < 0) return plaintext;
  return plaintext.substring(0, i).trim();
}

bool isCardText(String plaintext) => plaintext.contains(kCardMarker);

/// Bangla text can arrive with ZWJ/ZWNJ and decomposed nukta letters
/// (\u09af + \u09bc vs \u09af\u09bc). Fold both to one form before matching keywords.
String normBn(String s) => s
    .replaceAll('\u200c', '')
    .replaceAll('\u200d', '')
    .replaceAll('\u09af\u09bc', '\u09df')
    .replaceAll('\u09a1\u09bc', '\u09dc')
    .replaceAll('\u09a2\u09bc', '\u09dd');

/// One decrypted message as the ledger sees it.
class CardEvent {
  final AssistoCard card;
  final String sender; // display name of who sent it ('' = me)
  final bool mine;
  final DateTime at;
  const CardEvent(this.card, this.sender, this.mine, this.at);
}

/// One shopping-list item's state after folding every tick.
class ListItemState {
  final bool done;
  final String by;
  const ListItemState(this.done, this.by);
}

/// Folds hidden events into the state of the cards they reference.
/// Deterministic: events are applied in time order, last tick per item wins,
/// so every phone that holds the same messages shows the same list.
class CardLedger {
  final Map<String, Map<int, ListItemState>> ticks = {};
  final Map<String, List<String>> acks = {};
  final Set<String> ackedByMe = {};

  CardLedger.fold(Iterable<CardEvent> events) {
    final sorted = events.toList()..sort((a, b) => a.at.compareTo(b.at));
    for (final e in sorted) {
      final c = e.card;
      if (c.type == CardType.tick && c.ref.isNotEmpty) {
        final i = c.integer('i');
        if (i < 0 || i > 200) continue;
        (ticks[c.ref] ??= {})[i] =
            ListItemState(c.data['on'] == true, c.str('name'));
      } else if (c.type == CardType.remAck && c.ref.isNotEmpty) {
        final who = c.str('name');
        final l = acks[c.ref] ??= [];
        if (!l.contains(who)) l.add(who);
        if (e.mine) ackedByMe.add(c.ref);
      }
    }
  }

  ListItemState itemState(String listId, int i) =>
      ticks[listId]?[i] ?? const ListItemState(false, '');

  int doneCount(String listId, int n) {
    var k = 0;
    for (var i = 0; i < n; i++) {
      if (itemState(listId, i).done) k++;
    }
    return k;
  }
}

// ---------------------------------------------------------------- builders

AssistoCard reminderCard({
  required String title,
  required DateTime at,
  required bool forEveryone,
  required String by,
}) =>
    AssistoCard(CardType.reminder, newCardId(), {
      'title': title,
      'at': at.toUtc().toIso8601String(),
      'scope': forEveryone ? 'all' : 'me',
      'by': by,
    });

AssistoCard ackCard(String reminderId, String name) =>
    AssistoCard(CardType.remAck, newCardId(), {'ref': reminderId, 'name': name});

AssistoCard listCard(String title, List<String> items) =>
    AssistoCard(CardType.list, newCardId(), {
      'title': title,
      'items': items.where((s) => s.trim().isNotEmpty).take(50).toList(),
    });

AssistoCard tickCard(String listId, int index, bool on, String name) =>
    AssistoCard(CardType.tick, newCardId(),
        {'ref': listId, 'i': index, 'on': on, 'name': name});

/// Equal split of [totalPoisha] over [names] with the largest-remainder rule
/// (mirrors expense_split.py), so the shares always add up to the total.
List<int> equalShares(int totalPoisha, int n) {
  if (n <= 0 || totalPoisha <= 0) return const [];
  final base = totalPoisha ~/ n;
  var rem = totalPoisha - base * n;
  return List.generate(n, (i) {
    if (rem > 0) {
      rem--;
      return base + 1;
    }
    return base;
  });
}

AssistoCard splitCard({
  required String title,
  required int totalPoisha,
  required String payer,
  required List<String> names,
}) {
  final shares = equalShares(totalPoisha, names.length);
  return AssistoCard(CardType.split, newCardId(), {
    'title': title,
    'total': totalPoisha,
    'payer': payer,
    'shares': [
      for (var i = 0; i < names.length; i++) {'name': names[i], 'amount': shares[i]}
    ],
  });
}

/// "1,234.50" style taka string from poisha (digits localised by the caller).
String takaOf(int poisha) {
  final t = poisha ~/ 100;
  final p = poisha % 100;
  final s = t.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return p == 0 ? s : '$s.${p.toString().padLeft(2, '0')}';
}

/// Parse "1200", "1,200.50", Bangla digits -> poisha (0 when invalid).
int poishaOf(String input) {
  var s = input.trim();
  const bn = '\u09e6\u09e7\u09e8\u09e9\u09ea\u09eb\u09ec\u09ed\u09ee\u09ef';
  for (var i = 0; i < 10; i++) {
    s = s.replaceAll(bn[i], '$i');
  }
  s = s.replaceAll(',', '');
  final m = RegExp(r'\d+(\.\d{1,2})?').firstMatch(s);
  if (m == null) return 0;
  final v = double.tryParse(m.group(0)!) ?? 0;
  return (v * 100).round();
}
