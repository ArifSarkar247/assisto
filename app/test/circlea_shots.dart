// circlea gallery states for test/screenshots_test.dart: tappable links +
// an E2E link preview in chat bubbles, the safe-link interstitial (bKash
// lookalike), Family / Others picker (filled + empty Family), and the
// Guardians screen (2 parents x 2 children, and empty).
import 'package:flutter/material.dart';

import 'package:assisto/messaging/link_open.dart';
import 'package:assisto/messaging/link_preview_client.dart';
import 'package:assisto/screens/circle_guardians_screen.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_bubble.dart';
import 'package:assisto/widgets/circle_people_filter.dart';

String _n(bool bn, String en, String b) => bn ? b : en;

Widget _chat(String l) {
  final bn = l == 'bn';
  final t0 = DateTime(2026, 11, 2, 19, 5);
  const reel = 'https://www.facebook.com/reel/1234567890';
  return Scaffold(
    appBar: AppBar(title: Text(_n(bn, 'Rina', 'রিনা'))),
    body: ListView(padding: const EdgeInsets.symmetric(vertical: Gap.md), children: [
      CircleBubble(
        msg: CircleMessage(
            id: 'l1',
            text: _n(bn, 'Look at this, so funny $reel', 'এটা দেখো, খুব মজার $reel'),
            mine: false,
            at: t0),
        linkPreview: LinkPreviewData(
            url: reel,
            site: 'Facebook',
            title: _n(bn, 'Tea stall in the rain — Reel', 'বৃষ্টিতে চায়ের দোকান — রিল'),
            description: _n(bn, '1.2M views', '১২ লাখ বার দেখা')),
      ),
      CircleBubble(
        msg: CircleMessage(
            id: 'l2',
            text: _n(bn, 'Song: youtu.be/dQw4w9WgXcQ — and the shop is daraz.com.bd.',
                'গান: youtu.be/dQw4w9WgXcQ — আর দোকান daraz.com.bd।'),
            mine: true,
            at: t0,
            status: 'read'),
      ),
      CircleBubble(
        msg: CircleMessage(
            id: 'l3',
            text: _n(bn, 'bKash bonus! http://bkash-bonus.xyz/login',
                'বিকাশ বোনাস! http://bkash-bonus.xyz/login'),
            mine: false,
            at: t0),
      ),
      CircleBubble(
        msg: CircleMessage(
            id: 'l4',
            text: _n(bn, 'Email me at rina@example.com or call 01711-000000',
                'rina@example.com-এ মেইল করো বা ০১৭১১-০০০০০০ নম্বরে ফোন দাও'),
            mine: true,
            at: t0,
            status: 'delivered'),
      ),
    ]),
  );
}

Widget _warning(String l) => Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: Gap.lg),
          child: LinkWarningSheet(
            url: 'http://bkash-bonus.xyz/login',
            destination: 'bkash-bonus.xyz',
            reasons: const ['lookalike', 'not_https', 'suspicious_tld'],
            brand: 'bkash',
            bad: true,
          ),
        ),
      ),
    );

Widget _shortWarning(String l) => Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: Gap.lg),
          child: LinkWarningSheet(
            url: 'https://bit.ly/3xYz',
            destination: 'www.youtube.com',
            reasons: const ['shortener'],
            brand: '',
            bad: false,
          ),
        ),
      ),
    );

List<Map<String, dynamic>> _people(bool bn) => [
      {'circle_id': 1, 'name': _n(bn, 'Ammu', 'আম্মু'), 'relation': 'mother', 'circle_group': 'family', 'phone': '01711000001'},
      {'circle_id': 2, 'name': _n(bn, 'Karim (office)', 'করিম (অফিস)'), 'relation': 'colleague', 'circle_group': 'others', 'phone': '01811000002'},
      {'circle_id': 3, 'name': _n(bn, 'Abbu', 'আব্বু'), 'relation': 'father', 'circle_group': 'family', 'phone': '01711000003'},
      {'circle_id': 4, 'name': _n(bn, 'Shila (friend)', 'শিলা (বন্ধু)'), 'relation': 'friend', 'circle_group': 'others', 'phone': '01911000004'},
      {'circle_id': 5, 'name': _n(bn, 'Nani', 'নানু'), 'relation': 'relative', 'circle_group': 'family', 'phone': '01711000005'},
      {'circle_id': 6, 'name': _n(bn, 'Driver Rahim', 'ড্রাইভার রহিম'), 'relation': 'custom', 'circle_group': 'others', 'phone': '01611000006'},
    ];

Widget _picker(String l, {PeopleFilter? start, bool othersOnly = false}) {
  final bn = l == 'bn';
  final rows = _people(bn).where((r) => !othersOnly || r['circle_group'] == 'others').toList();
  return Scaffold(
    appBar: AppBar(title: Text(_n(bn, 'Who gets your SOS?', 'আপনার SOS কে পাবেন?'))),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: CirclePeopleList(
        rows: rows,
        listKey: 'shot',
        initialFilter: start ?? PeopleFilter.all,
        rowBuilder: (_, r) => ListTile(
          minTileHeight: 56,
          leading: CircleAvatar(child: Text('${r['name']}'.characters.first)),
          title: Text('${r['name']}'),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    ),
  );
}

Widget _guardians(String l, {bool empty = false}) {
  final bn = l == 'bn';
  guardiansLoaderOverride = (path) async {
    if (empty) return path.endsWith('mine') ? {'guardians': []} : {'children': []};
    if (path.endsWith('mine')) {
      return {
        'guardians': [
          {'id': 1, 'name': _n(bn, 'Abbu', 'আব্বু'), 'removable': true, 'sources': [
            {'kind': 'kids_watch', 'removable': false, 'set_up_by': _n(bn, 'Abbu', 'আব্বু')},
            {'kind': 'school_mode', 'removable': true, 'set_up_by': _n(bn, 'Ammu', 'আম্মু')},
          ]},
          {'id': 2, 'name': _n(bn, 'Ammu', 'আম্মু'), 'removable': true, 'sources': [
            {'kind': 'school_mode', 'removable': true, 'set_up_by': _n(bn, 'Ammu', 'আম্মু')},
            {'kind': 'journey', 'removable': true, 'set_up_by': _n(bn, 'Ammu', 'আম্মু')},
          ]},
        ]
      };
    }
    return {
      'children': [
        {'key': 'u3', 'name': _n(bn, 'Rina', 'রিনা'), 'sources': [
          {'kind': 'school_mode'}, {'kind': 'kids_watch'}],
          'co_guardians': [{'id': 1, 'name': _n(bn, 'Abbu', 'আব্বু')}]},
        {'key': 'u4', 'name': _n(bn, 'Babu', 'বাবু'), 'sources': [{'kind': 'school_mode'}],
          'co_guardians': []},
      ]
    };
  };
  return const CircleGuardiansScreen();
}

final Map<String, Widget Function(String)> circleaShots = {
  'cla_chat_links': _chat,
  'cla_link_warning': _warning,
  'cla_link_shortener': _shortWarning,
  'cfa_picker': (l) => _picker(l),
  'cfa_picker_family_empty': (l) => _picker(l, start: PeopleFilter.family, othersOnly: true),
  'cga_guardians': (l) => _guardians(l),
  'cga_guardians_empty': (l) => _guardians(l, empty: true),
};
