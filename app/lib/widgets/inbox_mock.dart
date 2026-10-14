import '../l10n/app_localizations.dart';

/// Inbox category \u2014 mirrors core.logic.ai_inbox CATEGORIES (urgent|action|
/// fyi|promo). The backend is the source of truth for triage; this Dart mirror
/// lets the ADVANCED UI run live on MOCK items today (before Gmail/IMAP is
/// connected) with the exact same deterministic rules. No AI, no network.
enum InboxCategory { urgent, action, fyi, promo }

enum InboxSource { email, notification, message }

/// A single unified-inbox item.
class InboxItem {
  final String id;
  final InboxSource source;
  final String sender;
  final String subject;
  final String snippet;
  final DateTime ts;
  bool read;
  bool done;
  DateTime? snoozedUntil;

  // triage (filled by [triage]) \u2014 mirrors the backend fields 1:1.
  InboxCategory category;
  int priority;
  bool needsReply;

  InboxItem({
    required this.id,
    required this.source,
    required this.sender,
    required this.subject,
    required this.snippet,
    required this.ts,
    this.read = false,
    this.done = false,
    this.snoozedUntil,
    this.category = InboxCategory.fyi,
    this.priority = 0,
    this.needsReply = false,
  });

  /// Deterministic one-line gist (sender: subject) \u2014 not generative.
  String get summary {
    final subj = subject.trim().isEmpty ? snippet.trim() : subject.trim();
    final s = subj.length > 90 ? '${subj.substring(0, 87).trimRight()}...' : subj;
    return sender.isNotEmpty && s.isNotEmpty ? '$sender: $s' : (s.isEmpty ? sender : s);
  }
}

/// Keyword banks mirror ai_inbox.py. Bilingual lists live here as plain matcher
/// data (not UI strings). Bangla words are written as \u escapes so there are
/// ZERO Bangla codepoints in the .dart source, while still matching Bangla
/// content exactly like the server does.
const _urgent = [
  'urgent', 'asap', 'immediately', 'overdue', 'due today', 'final notice',
  'payment failed', 'suspended', 'account locked', 'action required',
  'security alert', 'otp', 'verification code', 'deadline today',
  '\u099c\u09b0\u09c1\u09b0\u09bf',              // jruri (urgent)
  '\u09ac\u0995\u09c7\u09af\u09bc\u09be',        // bokeya (overdue)
  '\u09ac\u09a8\u09cd\u09a7'                     // bondho (closed/stopped)
];
const _action = [
  'reply', 'response needed', 'please confirm', 'waiting', 'reminder',
  'follow up', 'follow-up', 'invoice', 'meeting', 'rsvp', 'approve', 'sign',
  'review', 'schedule', 'can you', 'could you', '?',
  '\u0989\u09a4\u09cd\u09a4\u09b0',              // uttor (reply)
  '\u09ae\u09bf\u099f\u09bf\u0982'               // meeting
];
const _promo = [
  'sale', '% off', 'discount', 'offer', 'deal', 'coupon', 'unsubscribe',
  'newsletter', 'promotion', 'limited time', 'buy now', 'subscribe',
  '\u099b\u09be\u09a1\u09bc',                    // chhar (discount)
  '\u0985\u09ab\u09be\u09b0'                     // offer
];
const _replySignals = [
  '?', 'reply', 'please confirm', 'please respond', 'rsvp', 'let me know',
  'waiting for your', 'can you', 'could you',
  '\u0989\u09a4\u09cd\u09a4\u09b0'               // uttor (reply)
];

bool _any(String t, List<String> bank) => bank.any(t.contains);

InboxCategory categorize(InboxItem it) {
  final t = '${it.subject} ${it.snippet}'.toLowerCase();
  if (_any(t, _promo) && !_any(t, _urgent)) return InboxCategory.promo;
  if (_any(t, _urgent)) return InboxCategory.urgent;
  if (_any(t, _action)) return InboxCategory.action;
  return InboxCategory.fyi;
}

bool _needsReply(InboxItem it, InboxCategory c) {
  if (c == InboxCategory.promo) return false;
  if (c == InboxCategory.urgent) return true;
  return _any('${it.subject} ${it.snippet}'.toLowerCase(), _replySignals);
}

const _base = {
  InboxCategory.urgent: 80,
  InboxCategory.action: 55,
  InboxCategory.fyi: 25,
  InboxCategory.promo: 5,
};

int _recency(InboxItem it, DateTime now) {
  final age = now.difference(it.ts);
  if (age <= const Duration(hours: 1)) return 15;
  if (age <= const Duration(hours: 6)) return 10;
  if (age <= const Duration(days: 1)) return 6;
  if (age <= const Duration(days: 3)) return 2;
  return 0;
}

/// Enrich items in place with category/priority/needs-reply (mirror of
/// ai_inbox.triage_list). Deterministic.
void triage(List<InboxItem> items, DateTime now) {
  for (final it in items) {
    final c = categorize(it);
    it.category = c;
    it.needsReply = _needsReply(it, c);
    var p = _base[c]! + _recency(it, now);
    if (!it.read) p += 5;
    if (it.needsReply) p += 8;
    it.priority = p.clamp(0, 100);
  }
}

List<InboxItem> sortByPriority(List<InboxItem> items) {
  final copy = [...items];
  copy.sort((a, b) {
    final c = b.priority.compareTo(a.priority);
    if (c != 0) return c;
    return b.ts.compareTo(a.ts);
  });
  return copy;
}

/// Active = not done and not currently snoozed.
List<InboxItem> activeItems(List<InboxItem> items, DateTime now) => items
    .where((it) => !it.done && (it.snoozedUntil == null || it.snoozedUntil!.isBefore(now)))
    .toList();

/// Quick-reply label keys per category (MOCK \u2014 mirrors ai_inbox._REPLY_SETS).
/// Keys map to l10n getters so there is zero Bangla in .dart.
List<String> replyKeysFor(InboxCategory c) {
  switch (c) {
    case InboxCategory.urgent:
      return ['inboxReplyAckOnIt', 'inboxReplyNeedTime', 'inboxReplyCallMe'];
    case InboxCategory.action:
      return ['inboxReplyWillDo', 'inboxReplyNotNow', 'inboxReplyAskDetails'];
    case InboxCategory.fyi:
      return ['inboxReplyThanks', 'inboxReplyNoted'];
    case InboxCategory.promo:
      return const [];
  }
}

String replyLabel(AppLocalizations tr, String key) {
  switch (key) {
    case 'inboxReplyAckOnIt':
      return tr.inboxReplyAckOnIt;
    case 'inboxReplyNeedTime':
      return tr.inboxReplyNeedTime;
    case 'inboxReplyCallMe':
      return tr.inboxReplyCallMe;
    case 'inboxReplyWillDo':
      return tr.inboxReplyWillDo;
    case 'inboxReplyNotNow':
      return tr.inboxReplyNotNow;
    case 'inboxReplyAskDetails':
      return tr.inboxReplyAskDetails;
    case 'inboxReplyThanks':
      return tr.inboxReplyThanks;
    case 'inboxReplyNoted':
      return tr.inboxReplyNoted;
  }
  return key;
}

/// A small MOCK dataset (English + Bangla-content items, Bangla as \u escapes)
/// to exercise both keyword banks. These stand in for real
/// email/notifications/messages until a Gmail/IMAP account is connected
/// (key-gated).
List<InboxItem> mockInbox(DateTime now) => [
      InboxItem(
        id: 'm1', source: InboxSource.email, sender: 'bKash',
        subject: 'URGENT: payment failed',
        snippet: 'Your bill payment did not go through. Action required today.',
        ts: now.subtract(const Duration(minutes: 20)),
      ),
      InboxItem(
        id: 'm2', source: InboxSource.email, sender: 'Rahim Uddin',
        subject: 'Meeting tomorrow \u2014 can you confirm?',
        snippet: 'Please reply with your availability for 11am.',
        ts: now.subtract(const Duration(hours: 3)),
      ),
      InboxItem(
        id: 'm3', source: InboxSource.message, sender: 'Apa',
        // Bangla content via \u escapes: "miting riminder" / "uttor diben?"
        subject: '\u09ae\u09bf\u099f\u09bf\u0982 \u09b0\u09bf\u09ae\u09be\u0987\u09a8\u09cd\u09a1\u09be\u09b0',
        snippet: '\u0989\u09a4\u09cd\u09a4\u09b0 \u09a6\u09bf\u09ac\u09c7\u09a8?',
        ts: now.subtract(const Duration(hours: 5)),
      ),
      InboxItem(
        id: 'm4', source: InboxSource.email, sender: 'Daraz',
        subject: 'Mega SALE \u2014 50% off, buy now',
        snippet: 'Limited time offer. Unsubscribe anytime.',
        ts: now.subtract(const Duration(hours: 9)),
      ),
      InboxItem(
        id: 'm5', source: InboxSource.notification, sender: 'Assisto',
        subject: 'Monthly summary is ready',
        snippet: 'Your September activity report is available.',
        ts: now.subtract(const Duration(days: 1, hours: 2)),
        read: true,
      ),
      InboxItem(
        id: 'm6', source: InboxSource.email, sender: 'Office',
        subject: 'Invoice #2042 \u2014 please review',
        snippet: 'Kindly review and approve before Friday.',
        ts: now.subtract(const Duration(days: 2)),
      ),
    ];
