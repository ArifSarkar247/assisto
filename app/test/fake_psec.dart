// pssec: fake GET /ps/today for the gallery + widget tests. Shapes mirror
// backend core/logic/ps_brief.build (lines carry bn + en + src + actions).

const kPsecShotMessage =
    '[02/11/26, 9:41 am] Karim Bhai: next Friday 5pm meeting at the Gulshan office';

Map<String, dynamic> fakePsecBrief() => {
      'date': '2026-11-02',
      'next': {
        'bn': 'পরের মিটিং ১ ঘণ্টা ৩০ মিনিট পরে: ব্যাংকের লোন মিটিং',
        'en': 'Next in 1h 30m: Bank loan meeting',
        'src': {'kind': 'schedule', 'id': 11},
      },
      'sections': [
        {
          'key': 'meetings', 'title_bn': 'আজকের মিটিং', 'title_en': "Today's meetings",
          'lines': [
            {
              'bn': 'সকাল ১১:৩০ — ব্যাংকের লোন মিটিং (রহিম) · মতিঝিল',
              'en': '11:30 am — Bank loan meeting (with Rahim) · Motijheel',
              'src': {'kind': 'schedule', 'id': 11}, 'title': 'Bank loan meeting',
              'place': 'Motijheel', 'start': '2026-11-02T11:30:00',
              'people': ['Rahim'], 'circle': [{'id': 7, 'name': 'Rahim'}],
              'circle_ids': [], 'done': false, 'clash': false,
            },
            {
              'bn': 'বিকেল ৪:০০ — সাপ্লায়ারের সাথে কল ⚠ অন্য মিটিং-এর সাথে ৩০ মিনিট সময় মিলে যায়',
              'en': '4:00 pm — Supplier call ⚠ overlaps another slot by 30 min',
              'src': {'kind': 'schedule', 'id': 12}, 'title': 'Supplier call',
              'place': '', 'start': '2026-11-02T16:00:00', 'people': <String>[],
              'circle': <Map<String, dynamic>>[], 'circle_ids': [], 'done': false,
              'clash': true,
            },
          ],
        },
        {
          'key': 'followups', 'title_bn': 'ফলো-আপ', 'title_en': 'Follow-ups',
          'lines': [
            {
              'bn': 'করিম — দোকানের কোটেশন (২ দিন পেরিয়েছে)',
              'en': 'Karim — Shop quotation (2 day(s) overdue)',
              'src': {'kind': 'followup', 'id': 21}, 'state': 'overdue',
              'counterpart': 'Karim', 'title': 'Shop quotation',
              'circle': [{'id': 8, 'name': 'Karim'}], 'circle_ids': [],
            },
          ],
        },
        {
          'key': 'reminders', 'title_bn': 'আজকের রিমাইন্ডার', 'title_en': "Today's reminders",
          'lines': [
            {'bn': 'রাত ৯:০০ — আম্মার ওষুধ', 'en': '9:00 pm — Ammu\'s medicine',
              'src': {'kind': 'reminder', 'id': 31}},
          ],
        },
        // bizassist: missed My Circle calls, today's bookings, bills
        {
          'key': 'missed_calls', 'title_bn': 'মিসড কল — ফিরতি কল দিন',
          'title_en': 'Missed calls — call back',
          'lines': [
            {'bn': 'রহিম ভাই — ২টি মিসড কল, শেষ সকাল ৯:১০ · ফিরতি কল দিন',
              'en': 'Rahim Bhai — 2 missed calls, last 9:10 am · call back',
              'src': {'kind': 'missed_call', 'id': 501}, 'counterpart': 'Rahim Bhai',
              'circle': [{'id': 9, 'name': 'Rahim Bhai'}], 'circle_ids': [9], 'count': 2},
          ],
        },
        {
          'key': 'bookings', 'title_bn': 'আজকের বুকিং', 'title_en': "Today's bookings",
          'lines': [
            {'bn': 'বিকেল ৫:০০ — চুল কাটা · করিম · নিশ্চিত করুন',
              'en': '5:00 pm — Haircut · Karim · please confirm',
              'src': {'kind': 'booking_biz', 'id': 601}, 'state': 'requested'},
          ],
        },
        {
          'key': 'bills', 'title_bn': 'বিল ও দেনা', 'title_en': 'Bills & dues',
          'lines': [
            {'bn': 'লিংক৩ ইন্টারনেট — ৳১,২০০ (১ দিন পরে)',
              'en': 'Link3 internet — ৳1,200 (in 1 day(s))',
              'src': {'kind': 'subscription', 'id': 701}},
          ],
        },
      ],
      'counts': {'meetings': 2, 'followups': 1, 'overdue': 1, 'reminders': 1,
        'missed_calls': 1, 'bookings': 1, 'bills': 1},
      'empty': false,
      'ai_used': false,
    };

Map<String, dynamic>? fakePsecGet(String path, bool empty) {
  if (path.split('?').first != '/ps/today') return null; // bizassist: ?tz=
  if (empty) {
    return {'date': '2026-11-02', 'next': null, 'sections': <dynamic>[],
      'counts': <String, dynamic>{}, 'empty': true, 'ai_used': false};
  }
  return fakePsecBrief();
}
