// t1-ticks gallery states for test/screenshots_test.dart: WhatsApp-standard
// chat headers (every status line, 1:1 + group, long name), date separators
// + the floating date chip, legacy Message info, the version gate.
import 'package:flutter/material.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_header.dart';
import 'package:assisto/messaging/date_separators.dart';
import 'package:assisto/messaging/mc_version_gate.dart';
import 'package:assisto/messaging/msg_widgets.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/realtime/realtime_channel.dart';

String _n(String l, String en, String bn) => l == 'bn' ? bn : en;

PreferredSizeWidget _bar(Widget title) => AppBar(
      titleSpacing: 0,
      title: title,
      actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.videocam_outlined)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.call_outlined)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
      ],
    );

Widget _headers(String l) => Builder(builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      final now = DateTime.now();
      String? p(RtChatState s, {bool group = false}) =>
          presenceLabel(t, s, lang: l, isGroup: group);
      final today = DateTime(now.year, now.month, now.day, 12, 45);
      final yest = DateTime(now.year, now.month, now.day, 21, 10)
          .subtract(const Duration(days: 1));
      final old = DateTime(now.year, now.month, now.day, 9)
          .subtract(const Duration(days: 4));
      final name = _n(l, 'T Shanto Rahman', 'টি শান্ত রহমান');
      final rows = <(String?, bool)>[
        (p(const RtChatState(online: true)), false),
        (p(const RtChatState(activity: 'typing')), true),
        (p(const RtChatState(activity: 'recording')), true),
        (p(RtChatState(online: false, lastSeen: today)), false),
        (p(RtChatState(online: false, lastSeen: yest)), false),
        (p(RtChatState(online: false, lastSeen: old)), false),
        (null, false), // hidden by privacy
      ];
      return Scaffold(
        body: ListView(children: [
          for (final r in rows)
            _bar(ChatHeaderTitle(
                name: name,
                status: r.$1,
                statusActive: r.$2,
                avatar: HeaderInitialAvatar(name: name))),
          _bar(ChatHeaderTitle(
              name: _n(l, 'Mohammad Abdullah Al Mamun Chowdhury',
                  'মোহাম্মদ আব্দুল্লাহ আল মামুন চৌধুরী'),
              status: t.c3Online,
              avatar: const HeaderInitialAvatar(name: 'M'))),
          _bar(GroupHeaderTitle(
              name: _n(l, 'Family', 'পরিবার'),
              memberNames: [
                _n(l, 'Rahim', 'রহিম'),
                _n(l, 'Nadia', 'নাদিয়া'),
                _n(l, 'Karim', 'করিম'),
                _n(l, 'Mom', 'আম্মু'),
              ],
              avatar: const HeaderInitialAvatar(name: '', group: true))),
          _bar(GroupHeaderTitle(
              name: _n(l, 'Family', 'পরিবার'),
              activity: p(RtChatState(activity: 'typing', who: _n(l, 'Rahim', 'রহিম')),
                  group: true),
              avatar: const HeaderInitialAvatar(name: '', group: true))),
        ]),
      );
    });

class _Msg {
  final String text;
  final bool mine;
  final DateTime at;
  const _Msg(this.text, this.mine, this.at);
}

Widget _separators(String l, {bool floating = false}) => Builder(builder: (ctx) {
      final now = DateTime.now();
      final d0 = DateTime(now.year, now.month, now.day);
      DateTime at(int daysAgo, int h) =>
          d0.subtract(Duration(days: daysAgo)).add(Duration(hours: h));
      final msgs = [
        _Msg(_n(l, 'Did you get the tickets?', 'টিকিট পেয়েছ?'), false, at(12, 10)),
        _Msg(_n(l, 'Yes, two for Friday', 'হ্যাঁ, শুক্রবারের দুটো'), true, at(12, 11)),
        _Msg(_n(l, 'Call me when free', 'ফ্রি হলে ফোন দিও'), false, at(3, 9)),
        _Msg(_n(l, 'Will do', 'ঠিক আছে'), true, at(3, 18)),
        _Msg(_n(l, 'Dinner at 8?', 'রাতে ৮টায় খাবার?'), false, at(1, 20)),
        _Msg(_n(l, 'Perfect', 'একদম ঠিক'), true, at(1, 21)),
        _Msg(_n(l, 'Good morning!', 'সুপ্রভাত!'), false, at(0, 8)),
        _Msg(_n(l, 'Morning ☀️', 'শুভ সকাল ☀️'), true, at(0, 8)),
      ];
      final rows = insertDateSeparators<_Msg>(msgs, (m) => m.at);
      final scheme = Theme.of(ctx).colorScheme;
      return Scaffold(
        appBar: _bar(ChatHeaderTitle(
            name: _n(l, 'Rahim', 'রহিম'),
            status: AppLocalizations.of(ctx).c3Online,
            avatar: const HeaderInitialAvatar(name: 'R'))),
        body: Stack(children: [
          ListView.builder(
            // mid-scroll for the floating-chip shot: the top edge is inside
            // the oldest day, so the floating chip shows that day
            controller: ScrollController(initialScrollOffset: floating ? 150 : 0),
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: rows.length,
            itemBuilder: (_, i) => buildChatRow<_Msg>(
                rows[i],
                (m) => Align(
                      alignment:
                          m.mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 3),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: m.mine
                              ? scheme.primaryContainer
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text('${m.text}   ${fmtTime(m.at, l)}'),
                      ),
                    )),
          ),
          // the floating chip as it looks mid-scroll
          if (floating)
            Positioned(
                top: 2,
                left: 0,
                right: 0,
                child: DateSeparatorChip(
                    day: d0.subtract(const Duration(days: 12)), floating: true)),
        ]),
      );
    });

Widget _info(String l, {required bool legacy}) {
  final now = DateTime.now();
  String ago(int m) =>
      now.subtract(Duration(minutes: m)).toUtc().toIso8601String();
  return Scaffold(
    appBar: AppBar(),
    body: Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        elevation: 6,
        child: MessageInfoView(
            load: () async => {
                  'id': 3,
                  'group': false,
                  'receipts_legacy': legacy,
                  'status': legacy ? 'sent' : 'read',
                  'recipients': [
                    {
                      'user_id': 1,
                      'name': _n(l, 'Rahim', 'রহিম'),
                      'delivered_at': legacy ? null : ago(25),
                      'seen_at': legacy ? null : ago(4),
                    }
                  ],
                }),
      ),
    ),
  );
}

Widget _gate(String l) => Scaffold(
      appBar: _bar(ChatHeaderTitle(
          name: _n(l, 'Bilal', 'বিলাল'),
          avatar: const HeaderInitialAvatar(name: 'B'))),
      body: Column(children: [
        McVersionBanner(
            kind: 'member',
            chatId: 1,
            fixed: McGateState(
                minVersion: 183,
                outdatedNames: [_n(l, 'Bilal', 'বিলাল')],
                outdatedCount: 1)),
        const SizedBox(height: 12),
        McVersionBanner(
            kind: 'group',
            chatId: 7,
            fixed: McGateState(minVersion: 183, outdatedNames: [
              _n(l, 'Rahim', 'রহিম'),
              _n(l, 'Nadia', 'নাদিয়া'),
            ], outdatedCount: 4)),
        const SizedBox(height: 12),
        const McVersionBanner(
            kind: 'member',
            chatId: 1,
            fixed: McGateState(minVersion: 190, meOutdated: true)),
      ]),
    );

final Map<String, Widget Function(String)> t1Shots = {
  't1_headers': _headers,
  't1_date_separators': _separators,
  't1_date_floating': (l) => _separators(l, floating: true),
  't1_msg_info_real': (l) => _info(l, legacy: false),
  't1_msg_info_legacy': (l) => _info(l, legacy: true),
  't1_version_banners': _gate,
  't1_update_screen': (_) => const McUpdateScreen(),
};
