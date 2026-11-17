// design3 (owner order 17 Nov): MOCKUPS ONLY of the self-serve "Add tracker"
// wizard + one "Add CCTV" screen, for the owner's approval. Nothing here is
// wired into the app — mock widgets drawn with the real Design System V2
// tokens/components so the pictures match the app. Sample data only.
//
// Runs only with MOCK_SHOTS=1 (the ds2-goldens job on the design lane);
// PNGs go to $ASSISTO_SHOT_DIR/tracker_wizard (CI artifact) and are committed
// to owner_actions/shots/tracker_wizard/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:assisto/ds/ds.dart';
import 'package:assisto/theme.dart' show Brand, AFonts;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';
import 'screenshots_test.dart' show gallerySetUpAll, galleryPump;

final _on = Platform.environment['MOCK_SHOTS'] == '1';
final _dir = '${Platform.environment['ASSISTO_SHOT_DIR'] ?? 'build/shots'}/tracker_wizard';

String _bnDigits(String s) =>
    s.replaceAllMapped(RegExp('[0-9]'), (m) => String.fromCharCode(0x09E6 + int.parse(m[0]!)));

class _L {
  _L(this.lang);
  final String lang;
  bool get bn => lang == 'bn';
  String s(String en, String bn) => this.bn ? bn : en;
  String d(String v) => bn ? _bnDigits(v) : v;
}

// ---------------------------------------------------------------- shell

Widget _shell(_L l, {required String title, required int step, required List<Widget> body, Widget? bottom}) {
  return Builder(builder: (context) {
    final ds = DsTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl), children: [
        if (step > 0) ...[
          Row(children: [
            for (var i = 1; i <= 7; i++) ...[
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: i <= step ? ds.primary : ds.border,
                    borderRadius: BorderRadius.circular(DsRadius.chip),
                  ),
                ),
              ),
              if (i < 7) const SizedBox(width: Gap.xs),
            ],
          ]),
          const SizedBox(height: Gap.xs),
          Text(l.s('Step ${l.d('$step')} of 7', 'ধাপ ${l.d('$step')} / ৭'),
              style: AType.bodySmall.copyWith(color: ds.muted)),
          const SizedBox(height: Gap.md),
        ],
        ...body,
      ]),
      bottomNavigationBar: bottom == null
          ? null
          : SafeArea(
              child: Padding(padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md), child: bottom)),
    );
  });
}

Widget _badge(BuildContext context, String text, {bool ok = false}) {
  final ds = DsTokens.of(context);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
    decoration: BoxDecoration(
      color: ok ? ds.successBg : Color.alphaBlend(Brand.warning.withValues(alpha: 0.16), ds.card),
      borderRadius: BorderRadius.circular(DsRadius.chip),
    ),
    child: Text(text,
        style: AType.labelMedium.copyWith(
            fontWeight: FontWeight.w700, color: ok ? ds.successInk : Brand.warnInk(context))),
  );
}

// ---------------------------------------------------------------- 1 devices

Widget devices(_L l) => _shell(l, title: l.s('Add a tracker', 'ট্র্যাকার যোগ করুন'), step: 1, body: [
      Builder(builder: (context) {
        final ds = DsTokens.of(context);
        return DsHeroCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.s('Set it up yourself in about 10 minutes', 'নিজেই সেটআপ করুন — প্রায় ১০ মিনিট'),
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.xs),
            Text(
                l.s('Pick your tracker below. Only models we have tested with Assisto are listed.',
                    'নিচে আপনার ট্র্যাকার বাছুন। শুধু Assisto-তে পরীক্ষা করা মডেলই এখানে আছে।'),
                style: AType.bodyMedium.copyWith(color: ds.muted)),
          ]),
        );
      }),
      DsSectionHeader(l.s('Supported trackers', 'যেসব ট্র্যাকার চলে')),
      for (final m in const [
        ('SinoTrack ST-906 4G', 'GPS · 4G · bike / car', '4G'),
        ('SinoTrack ST-901 / 901L', 'GPS · 2G · bike / car', '2G'),
        ('SinoTrack ST-903', 'GPS · 2G · portable', '2G'),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Builder(builder: (context) {
            final ds = DsTokens.of(context);
            return DsCard(
              onTap: () {},
              child: Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: ds.primarySoft, borderRadius: BorderRadius.circular(DsRadius.card)),
                  child: Icon(Icons.gps_fixed_rounded, color: ds.primaryInk),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(m.$1, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                    Text(m.$2, style: AType.bodySmall.copyWith(color: ds.muted)),
                    const SizedBox(height: Gap.xs),
                    _badge(context, l.s('Testing', 'পরীক্ষা চলছে')),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded),
              ]),
            );
          }),
        ),
      DsGroup(margin: EdgeInsets.zero, flat: true, children: [
        DsListRow(
            leading: const Icon(Icons.more_horiz_rounded),
            title: l.s('Concox GT06N · Coban TK103 · Teltonika FMB', 'Concox GT06N · Coban TK103 · Teltonika FMB'),
            subtitle: l.s('Early testing — setup works, not yet tried on a real unit', 'প্রাথমিক পরীক্ষা — সেটআপ তৈরি, আসল ডিভাইসে এখনো চালানো হয়নি')),
        DsListRow(
            leading: const Icon(Icons.bluetooth_rounded),
            title: l.s('iTag Bluetooth tag', 'iTag ব্লুটুথ ট্যাগ'),
            trailing: Builder(builder: (context) => _badge(context, l.s('Coming', 'আসছে')))),
      ]),
      const SizedBox(height: Gap.md),
      Builder(builder: (context) {
        final ds = DsTokens.of(context);
        return DsCard(
          onTap: () {},
          child: Row(children: [
            Icon(Icons.storefront_rounded, color: ds.primaryInk),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.s('Where to buy', 'কোথায় কিনবেন'), style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
                Text(l.s('Shops that sell these exact models', 'ঠিক এই মডেলগুলো যেসব দোকানে পাবেন'),
                    style: AType.bodySmall.copyWith(color: ds.muted)),
              ]),
            ),
            Icon(Icons.open_in_new_rounded, color: ds.primaryInk),
          ]),
        );
      }),
      const SizedBox(height: Gap.sm),
      Builder(builder: (context) => Text(
          l.s('"Testing" = it works with Assisto in our tests; we are still checking it on more roads and SIMs.',
              '"পরীক্ষা চলছে" = আমাদের পরীক্ষায় Assisto-র সঙ্গে চলে; আরও রাস্তা ও সিমে যাচাই চলছে।'),
          style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted))),
    ]);

// ---------------------------------------------------------------- 2 pick

Widget pick(_L l) => _shell(l,
        title: l.s('Your tracker', 'আপনার ট্র্যাকার'),
        step: 2,
        bottom: DsButton(expand: true, label: l.s('Continue', 'এগিয়ে যান'), onPressed: () {}),
        body: [
          Builder(builder: (context) {
            final ds = DsTokens.of(context);
            return DsHeroCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.check_circle_rounded, color: ds.successInk),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                      child: Text('SinoTrack ST-906 4G', style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800))),
                ]),
                const SizedBox(height: Gap.sm),
                _badge(context, l.s('Testing', 'পরীক্ষা চলছে')),
              ]),
            );
          }),
          DsSectionHeader(l.s('What you need', 'যা লাগবে')),
          DsGroup(margin: EdgeInsets.zero, children: [
            DsListRow(
                leading: const Icon(Icons.sim_card_rounded),
                title: l.s('A GP or Robi SIM with a data pack', 'ডেটা প্যাকসহ একটি জিপি বা রবি সিম'),
                subtitle: l.s('Put it in the tracker before you start', 'শুরুর আগেই ট্র্যাকারে লাগান')),
            DsListRow(
                leading: const Icon(Icons.power_rounded),
                title: l.s('Tracker connected to power', 'ট্র্যাকারে বিদ্যুৎ সংযোগ'),
                subtitle: l.s('The light should blink', 'বাতি জ্বলা-নেভা করবে')),
            DsListRow(
                leading: const Icon(Icons.qr_code_rounded),
                title: l.s('The tracker ID (on the label)', 'ট্র্যাকারের আইডি (লেবেলে)'),
                subtitle: l.s('SinoTrack: the 10-digit ID, not the 15-digit IMEI', 'SinoTrack: ১০ সংখ্যার আইডি, ১৫ সংখ্যার IMEI নয়')),
          ]),
        ]);

// ---------------------------------------------------------------- 3 imei

Widget imei(_L l) => _shell(l,
        title: l.s('Tracker ID', 'ট্র্যাকারের আইডি'),
        step: 3,
        bottom: DsButton(expand: true, label: l.s('Continue', 'এগিয়ে যান'), onPressed: () {}),
        body: [
          Builder(builder: (context) {
            final ds = DsTokens.of(context);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DsButton.secondary(
                  expand: true,
                  icon: Icons.qr_code_scanner_rounded,
                  label: l.s('Scan the barcode', 'বারকোড স্ক্যান করুন'),
                  onPressed: () {}),
              const SizedBox(height: Gap.md),
              Center(child: Text(l.s('or type it', 'অথবা লিখুন'), style: AType.bodySmall.copyWith(color: ds.muted))),
              const SizedBox(height: Gap.md),
              TextField(
                controller: TextEditingController(text: '9170012345'),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l.s('Tracker ID', 'ট্র্যাকারের আইডি'),
                  helperText: l.s('10 digits for SinoTrack — checked as you type', 'SinoTrack-এ ১০ সংখ্যা — লিখতে লিখতেই যাচাই'),
                  suffixIcon: Icon(Icons.check_circle_rounded, color: ds.successInk),
                ),
              ),
              const SizedBox(height: Gap.lg),
              DsCard(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.lightbulb_outline_rounded, color: ds.primaryInk),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                        l.s('Where is it? On the tracker\'s label, next to "ID". The long 15-digit IMEI is a different number — a common mistake.',
                            'কোথায় পাবেন? ট্র্যাকারের লেবেলে "ID" লেখার পাশে। লম্বা ১৫ সংখ্যার IMEI আলাদা নম্বর — এটা খুব সাধারণ ভুল।'),
                        style: AType.bodyMedium),
                  ),
                ]),
              ),
            ]);
          }),
        ]);

// ---------------------------------------------------------------- 4 sim

Widget sim(_L l) => _shell(l,
        title: l.s('The tracker\'s SIM', 'ট্র্যাকারের সিম'),
        step: 4,
        bottom: DsButton(expand: true, label: l.s('Continue', 'এগিয়ে যান'), onPressed: () {}),
        body: [
          Text(l.s('Which SIM is in the tracker?', 'ট্র্যাকারে কোন সিম?'),
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(child: DsTile(icon: Icons.sim_card_rounded, label: l.s('GP', 'জিপি'), selected: true, onTap: () {})),
            const SizedBox(width: Gap.md),
            Expanded(child: DsTile(icon: Icons.sim_card_outlined, label: l.s('Robi', 'রবি'), onTap: () {})),
          ]),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: TextEditingController(text: l.d('01700-000000')),
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: l.s('The tracker SIM\'s phone number', 'ট্র্যাকারের সিমের ফোন নম্বর'),
              helperText: l.s('We send the setup SMS to this number', 'এই নম্বরেই সেটআপ SMS যাবে'),
            ),
          ),
          const SizedBox(height: Gap.lg),
          Builder(builder: (context) => DsCard(
                child: Text(
                    l.s('This SIM needs: no PIN lock, a data pack (about 12–20 MB a month) and a little balance for the "OK" replies.',
                        'এই সিমে লাগবে: পিন লক বন্ধ, ডেটা প্যাক (মাসে প্রায় ১২–২০ MB) আর "OK" উত্তরের জন্য সামান্য ব্যালান্স।'),
                    style: AType.bodyMedium.copyWith(color: DsTokens.of(context).text)),
              )),
        ]);

// ---------------------------------------------------------------- 5 sms

Widget sms(_L l) => _shell(l, title: l.s('Send the setup SMS', 'সেটআপ SMS পাঠান'), step: 5, body: [
      Builder(builder: (context) {
        final ds = DsTokens.of(context);
        return Text(
            l.s('3 short messages, in order. Each button opens your SMS app with the message ready — you only tap Send. Wait for the "OK" reply before the next one.',
                '৩টি ছোট বার্তা, ক্রমানুসারে। প্রতিটি বোতাম আপনার SMS অ্যাপ খুলে বার্তা লিখে দেয় — আপনি শুধু Send চাপুন। পরেরটির আগে "OK" উত্তরের অপেক্ষা করুন।'),
            style: AType.bodyMedium.copyWith(color: ds.muted));
      }),
      const SizedBox(height: Gap.md),
      for (final (i, cmd, what, state) in [
        (1, '8030000 gpinternet', ('Internet (APN)', 'ইন্টারনেট (APN)'), 'done'),
        (2, '8040000 16.4.105.173 5023', ('Assisto server', 'Assisto সার্ভার'), 'next'),
        (3, '7100000', ('Turn on GPRS', 'GPRS চালু'), 'todo'),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Builder(builder: (context) {
            final ds = DsTokens.of(context);
            final done = state == 'done';
            final next = state == 'next';
            return DsCard(
              tone: done ? DsTone.success : DsTone.normal,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  done
                      ? Icon(Icons.check_circle_rounded, color: ds.successInk)
                      : DsStepNumber(i),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                      child: Text(l.s(what.$1, what.$2),
                          style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700))),
                  if (done) Text(l.s('Sent', 'পাঠানো হয়েছে'), style: AType.bodySmall.copyWith(color: ds.successInk)),
                ]),
                const SizedBox(height: Gap.sm),
                Container(
                  padding: const EdgeInsets.all(Gap.sm),
                  decoration: BoxDecoration(color: ds.cardHighest, borderRadius: BorderRadius.circular(DsRadius.small)),
                  child: Text(cmd, style: AType.bodyMedium.copyWith(fontFeatures: AFonts.tabular, letterSpacing: 0.5)),
                ),
                if (!done) ...[
                  const SizedBox(height: Gap.sm),
                  next
                      ? DsButton(
                          icon: Icons.sms_rounded,
                          label: l.s('Open SMS app', 'SMS অ্যাপ খুলুন'),
                          onPressed: () {})
                      : DsButton.secondary(
                          icon: Icons.sms_outlined,
                          label: l.s('Open SMS app', 'SMS অ্যাপ খুলুন'),
                          onPressed: () {}),
                ],
              ]),
            );
          }),
        ),
      Builder(builder: (context) => Text(
          l.s('Assisto never reads or sends SMS by itself.', 'Assisto নিজে কখনো SMS পড়ে না বা পাঠায় না।'),
          style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted))),
    ]);

// ---------------------------------------------------------------- 6 wait / connected

Widget wait(_L l) => _shell(l, title: l.s('Connecting…', 'সংযোগ হচ্ছে…'), step: 6, body: [
      Builder(builder: (context) {
        final ds = DsTokens.of(context);
        return DsHeroCard(
          child: Column(children: [
            const DsIllustration(icon: Icons.satellite_alt_rounded, size: 80),
            const SizedBox(height: Gap.md),
            Text(l.d('02:14'), style: AType.displaySmall.copyWith(fontWeight: FontWeight.w800, fontFeatures: AFonts.tabular)),
            Text(l.s('Waiting for the first location from your tracker', 'ট্র্যাকারের প্রথম অবস্থানের অপেক্ষা'),
                textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: ds.muted)),
            const SizedBox(height: Gap.sm),
            Text(l.s('Usually 1–5 minutes after the last SMS; the first GPS fix outdoors can take up to 5 more. Pairing stays open for 10 minutes.',
                    'সাধারণত শেষ SMS-এর ১–৫ মিনিট পর; খোলা জায়গায় প্রথম GPS পেতে আরও ৫ মিনিট লাগতে পারে। জোড়া লাগানোর সময় ১০ মিনিট খোলা থাকে।'),
                textAlign: TextAlign.center, style: AType.bodySmall.copyWith(color: ds.muted)),
          ]),
        );
      }),
      DsSectionHeader(l.s('While you wait, check', 'অপেক্ষার সময় দেখে নিন')),
      DsGroup(margin: EdgeInsets.zero, children: [
        DsListRow(
            leading: const Icon(Icons.wb_sunny_outlined),
            title: l.s('Tracker is outdoors or near a window', 'ট্র্যাকার খোলা জায়গায় বা জানালার পাশে'),
            subtitle: l.s('GPS needs open sky the first time', 'প্রথমবার GPS-এর খোলা আকাশ লাগে')),
        DsListRow(
            leading: const Icon(Icons.network_cell_rounded),
            title: l.s('SIM has balance and a data pack', 'সিমে ব্যালান্স ও ডেটা প্যাক আছে')),
        DsListRow(
            leading: const Icon(Icons.mark_chat_read_outlined),
            title: l.s('Each SMS got an "OK" reply', 'প্রতিটি SMS-এর উত্তরে "OK" এসেছে'),
            subtitle: l.s('Most missed: the third one (7100000)', 'সবচেয়ে বেশি বাদ পড়ে: তৃতীয়টি (৭১০০০০০)')),
        DsListRow(
            leading: const Icon(Icons.power_rounded),
            title: l.s('Power: red to +, black to ground, yellow to the key line', 'বিদ্যুৎ: লাল +, কালো গ্রাউন্ড, হলুদ চাবির লাইনে')),
      ]),
      const SizedBox(height: Gap.md),
      DsButton.secondary(
          expand: true,
          icon: Icons.support_agent_rounded,
          label: l.s('Not connecting? Get help', 'সংযোগ হচ্ছে না? সাহায্য নিন'),
          onPressed: () {}),
    ]);

Widget connected(_L l) => _shell(l, title: l.s('Tracker connected', 'ট্র্যাকার সংযুক্ত'), step: 7, body: [
      Builder(builder: (context) {
        final ds = DsTokens.of(context);
        return DsCard(
          tone: DsTone.success,
          child: Column(children: [
            DsIllustration(icon: Icons.check_circle_rounded, color: ds.success, size: 88),
            const SizedBox(height: Gap.md),
            Text(l.s('Your bike is on the map', 'আপনার বাইক এখন ম্যাপে'),
                style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800), textAlign: TextAlign.center),
            const SizedBox(height: Gap.xs),
            Text(l.s('First location received · setup took 6 min · ST-906 4G · GP', 'প্রথম অবস্থান এসেছে · সেটআপে ৬ মিনিট লেগেছে · ST-906 4G · জিপি'),
                style: AType.bodyMedium.copyWith(color: ds.muted), textAlign: TextAlign.center),
          ]),
        );
      }),
      const SizedBox(height: Gap.lg),
      DsButton(expand: true, icon: Icons.map_rounded, label: l.s('See it live', 'লাইভ দেখুন'), onPressed: () {}),
      const SizedBox(height: Gap.sm),
      DsButton.secondary(
          expand: true,
          icon: Icons.family_restroom_rounded,
          label: l.s('Share with family', 'পরিবারের সঙ্গে শেয়ার'),
          onPressed: () {}),
      DsSectionHeader(l.s('Next, if you want', 'চাইলে এরপর')),
      DsGroup(margin: EdgeInsets.zero, children: [
        DsListRow(
            leading: const Icon(Icons.fence_rounded),
            title: l.s('Safe area alert (geofence)', 'নিরাপদ এলাকার সতর্কতা (জিওফেন্স)'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {}),
        DsListRow(
            leading: const Icon(Icons.speed_rounded),
            title: l.s('Speed alert', 'গতির সতর্কতা'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {}),
      ]),
    ]);

// ---------------------------------------------------------------- 7 help

Widget help(_L l) => _shell(l, title: l.s('Tracker help', 'ট্র্যাকার সাহায্য'), step: 0, body: [
      Builder(builder: (context) {
        final ds = DsTokens.of(context);
        return DsHeroCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.auto_awesome_rounded, color: ds.primaryInk),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(l.s('Ask Assisto — it knows your tracker', 'Assisto-কে জিজ্ঞাসা করুন — আপনার ট্র্যাকার চেনে'),
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
            ]),
            const SizedBox(height: Gap.xs),
            Text(
                l.s('It sees your model, SIM and the last messages from the tracker, and walks you through the fix.',
                    'আপনার মডেল, সিম ও ট্র্যাকারের শেষ বার্তা দেখে ধাপে ধাপে সমাধান বলে দেয়।'),
                style: AType.bodyMedium.copyWith(color: ds.muted)),
            const SizedBox(height: Gap.md),
            DsButton(icon: Icons.chat_rounded, label: l.s('Ask in chat', 'চ্যাটে জিজ্ঞাসা করুন'), onPressed: () {}),
          ]),
        );
      }),
      DsSectionHeader(l.s('Common problems', 'সাধারণ সমস্যা')),
      DsGroup(margin: EdgeInsets.zero, children: [
        for (final p in [
          ('No "OK" reply to the SMS', 'SMS-এর "OK" উত্তর আসেনি'),
          ('Connected once, then offline', 'একবার সংযোগ হয়ে আবার অফলাইন'),
          ('Location is far from the vehicle', 'অবস্থান গাড়ি থেকে অনেক দূরে'),
          ('Forgot the tracker password', 'ট্র্যাকারের পাসওয়ার্ড ভুলে গেছি'),
        ])
          DsListRow(
              leading: const Icon(Icons.help_outline_rounded),
              title: l.s(p.$1, p.$2),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {}),
      ]),
      const SizedBox(height: Gap.lg),
      Builder(builder: (context) => Center(
            child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.person_outline_rounded),
              label: Text(l.s('Still stuck? Talk to a person', 'তবুও সমস্যা? মানুষের সঙ্গে কথা বলুন')),
              onPressed: () {},
            ),
          )),
      Builder(builder: (context) => Text(
          l.s('A person helps with hard cases (a broken unit, wiring). Chat answers most problems at once.',
              'কঠিন সমস্যায় (নষ্ট ডিভাইস, তার লাগানো) মানুষ সাহায্য করে। বেশির ভাগ সমস্যার উত্তর চ্যাটেই সঙ্গে সঙ্গে পাবেন।'),
          textAlign: TextAlign.center,
          style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted))),
    ]);

// ---------------------------------------------------------------- CCTV

Widget cctv(_L l) => _shell(l, title: l.s('Add CCTV', 'সিসিটিভি যোগ করুন'), step: 0, body: [
      Builder(builder: (context) {
        final ds = DsTokens.of(context);
        return DsHeroCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.s('Use the cameras you already have', 'যে ক্যামেরা আছে সেটাই ব্যবহার করুন'),
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.xs),
            Text(l.s('Pick how your camera connects. Each way is a few guided steps — no technician needed.',
                    'আপনার ক্যামেরা কীভাবে যুক্ত হবে বাছুন। প্রতিটি পথ কয়েকটি দেখানো ধাপ — মিস্ত্রি লাগবে না।'),
                style: AType.bodyMedium.copyWith(color: ds.muted)),
          ]),
        );
      }),
      DsSectionHeader(l.s('Choose one', 'একটি বাছুন')),
      for (final o in [
        (Icons.cloud_sync_rounded, ('Brand app camera (Imou, Hikvision, Dahua)', 'ব্র্যান্ড অ্যাপের ক্যামেরা (Imou, Hikvision, Dahua)'),
            ('Sign in once; we show every camera on your account', 'একবার লগইন — অ্যাকাউন্টের সব ক্যামেরা দেখাব'), true),
        (Icons.dns_rounded, ('Shop Box (small computer)', 'Shop Box (ছোট কম্পিউটার)'),
            ('For a DVR or many IP cameras on the shop Wi-Fi', 'দোকানের ওয়াই-ফাইয়ের DVR বা অনেক IP ক্যামেরার জন্য'), false),
        (Icons.phone_android_rounded, ('An old phone as the camera', 'পুরনো ফোনকে ক্যামেরা'),
            ('The cheapest start — nothing to buy', 'সবচেয়ে সস্তা শুরু — কিছু কিনতে হবে না'), false),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Builder(builder: (context) {
            final ds = DsTokens.of(context);
            return DsCard(
              onTap: () {},
              child: Row(children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: ds.primarySoft, borderRadius: BorderRadius.circular(DsRadius.card)),
                  child: Icon(o.$1, color: ds.primaryInk),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.s(o.$2.$1, o.$2.$2), style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
                    Text(l.s(o.$3.$1, o.$3.$2), style: AType.bodySmall.copyWith(color: ds.muted)),
                    if (o.$4) ...[
                      const SizedBox(height: Gap.xs),
                      _badge(context, l.s('Before you start: remove it from the brand app', 'শুরুর আগে: ব্র্যান্ড অ্যাপ থেকে সরান')),
                    ],
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded),
              ]),
            );
          }),
        ),
      const SizedBox(height: Gap.sm),
      DsButton.secondary(
          expand: true,
          icon: Icons.chat_rounded,
          label: l.s('Not sure? Ask Assisto', 'নিশ্চিত নন? Assisto-কে জিজ্ঞাসা করুন'),
          onPressed: () {}),
    ]);

// ---------------------------------------------------------------- test

Future<void> _png(WidgetTester tester, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 2.0)) as ui.Image;
  final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  Directory(_dir).createSync(recursive: true);
  File('$_dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}

void main() {
  if (!_on) {
    test('tracker wizard mockups (MOCK_SHOTS=1 only)', () {}, skip: true);
    return;
  }
  setUpAll(() async => gallerySetUpAll());
  final screens = <String, Widget Function(_L)>{
    'tw1_devices': devices,
    'tw2_pick': pick,
    'tw3_imei': imei,
    'tw4_sim': sim,
    'tw5_sms': sms,
    'tw6_wait': wait,
    'tw6b_connected': connected,
    'tw7_help': help,
    'tw8_cctv_add': cctv,
  };
  for (final e in screens.entries) {
    for (final lang in ['bn', 'en']) {
      final darks = e.key == 'tw5_sms' ? [Brightness.light, Brightness.dark] : [Brightness.light];
      for (final b in darks) {
        testWidgets('mock ${e.key} $lang ${b.name}', (tester) async {
          DsPerf.debugLite = false;
          addTearDown(() => DsPerf.debugLite = null);
          debugDisableShadows = false;
          final key = GlobalKey();
          await galleryPump(tester, e.key, lang, b, e.value(_L(lang)), FakeMode.data, key: key);
          expect(tester.takeException(), isNull);
          await _png(tester, key, '${e.key}_${lang}_${b.name}');
          debugDisableShadows = true;
        });
      }
    }
  }
}
