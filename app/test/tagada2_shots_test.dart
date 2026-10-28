// tagada2: screenshots of the send order, SMS balance, My Dues and the
// shop <-> customer chat (bn/en x light/dark, 360x800). Writes PNGs to
// $ASSISTO_SHOT_DIR only when it is set; otherwise just renders (smoke).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/khata_chat_screen.dart';
import 'package:assisto/screens/business/sms_balance_screen.dart';
import 'package:assisto/screens/business/tagada_send_screen.dart';
import 'package:assisto/screens/my_dues_screen.dart';
import 'package:assisto/screens/my_dues_shop_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'app_fonts.dart';
import 'fake_khata.dart' show fmtPair;
import 'tagada2_fakes.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

const _biz = {'id': 1, 'name': 'Rahim Store', 'role': 'owner'};

Map<String, dynamic> _party(int id, String name, String phone) =>
    {'id': id, 'name': name, 'phone': phone, 'balance_poisha': 150000};

String _n(String lang, String bn, String en) => lang == 'bn' ? bn : en;

typedef _Spec = (Tg2Api, Widget) Function(String lang);

Map<String, dynamic> _shopRow(String lang) => {
      'business_id': 7,
      'shop_name': _n(lang, 'Rahim Store', 'Rahim Store'),
      'balance_poisha': 150000,
      'balance_display': fmtPair(150000),
      'status': tg2Pr('বাকি', 'Due'),
      'owes': true,
      'last_entry_at': '2026-10-20T10:00:00+06:00',
      'unread': 2,
      'muted': false,
      'blocked': false,
    };

final Map<String, _Spec> _specs = {
  'tg2_send_routes': (l) {
    final api = Tg2Api(lang: l)
      ..wallet = tg2Wallet(allowance: 1, low: true)
      ..reminders = [
        tg2Rem(1, 'Karim Store', '01712345678', assisto: true),
        tg2Rem(2, 'Salma', '01812345678'),
        tg2Rem(3, 'Rina', '01912345678', today: true),
        tg2Rem(4, 'Moni', '01512345678', parts: 2, invite: 'invited'),
      ];
    return (
      api,
      TagadaSendScreen(business: _biz, parties: [
        _party(1, 'Karim Store', '01712345678'),
        _party(2, 'Salma', '01812345678'),
        _party(3, 'Rina', '01912345678'),
        _party(4, 'Moni', '01512345678'),
      ])
    );
  },
  'tg2_sms_balance': (l) {
    final api = Tg2Api(lang: l)
      ..balance = {
        'allowance_total': 30, 'allowance_left': 6, 'allowance_month': '2026-10',
        'pack_left': 2, 'parts_left': 8, 'low': true, 'low_threshold': 10,
        'ready': true, 'packs_on_sale': false,
        'packs': [
          for (final (p, pr) in const [(100, 149), (300, 449), (1000, 1499)])
            {'sku': 'smspack_$p', 'parts': p, 'price_bdt': pr, 'on_sale': false,
             'play_product_id': 'assisto_sms_$p'},
        ],
      };
    return (api, const SmsBalanceScreen(businessId: 1));
  },
  'tg2_my_dues': (l) {
    final api = Tg2Api(lang: l)
      ..dues = {
        'verified': true, 'phone_masked': '01712***678',
        'shops': [_shopRow(l)], 'total_display': fmtPair(150000),
      };
    return (api, const MyDuesScreen());
  },
  'tg2_my_dues_unverified': (l) {
    final api = Tg2Api(lang: l)..dues = {'verified': false, 'shops': const []};
    return (api, const MyDuesScreen());
  },
  'tg2_my_dues_shop': (l) {
    final api = Tg2Api(lang: l)
      ..shop = {
        'shop': {'id': 7, 'name': 'Rahim Store'},
        'balance_poisha': 150000, 'balance_display': fmtPair(150000),
        'status': tg2Pr('বাকি', 'Due'),
        'entries': [
          {'at': '2026-10-20T10:00:00+06:00', 'kind': 'due',
           'amount_display': fmtPair(200000), 'note': ''},
          {'at': '2026-10-22T10:00:00+06:00', 'kind': 'paid',
           'amount_display': fmtPair(50000), 'note': ''},
        ],
        'pay': {'methods': [
          {'provider': 'bkash', 'number': '01711111111', 'kind': 'personal'},
          {'provider': 'nagad', 'number': '01722222222', 'kind': 'merchant'},
        ]},
        'muted': false, 'blocked': false,
      };
    return (api, const MyDuesShopScreen(businessId: 7, shopName: 'Rahim Store'));
  },
  'tg2_chat': (l) {
    final api = Tg2Api(lang: l);
    api.chat.addAll([
      {'id': 1, 'from': 'shop', 'kind': 'tagada',
       'text': 'Hello. Your due at Rahim Store is 1500.',
       'at': '2026-10-27T11:00:00+06:00', 'read': true},
      {'id': 2, 'from': 'customer', 'kind': 'text',
       'text': 'I will pay on Friday.',
       'at': '2026-10-27T12:00:00+06:00', 'read': true},
    ]);
    return (
      api,
      const KhataChatScreen(
          side: ChatSide.customer, businessId: 7, title: 'Rahim Store')
    );
  },
};

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons =
        File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
  });
  for (final e in _specs.entries) {
    for (final lang in ['bn', 'en']) {
      for (final b in [Brightness.light, Brightness.dark]) {
        testWidgets('shot ${e.key} $lang ${b.name}', (tester) async {
          SharedPreferences.setMockInitialValues({});
          await tester.binding.setSurfaceSize(const Size(360, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final (api, screen) = e.value(lang);
          final key = GlobalKey();
          final app = AppState()
            ..api = api
            ..user = AppUser(
                id: 1, name: 'Me', phone: '01712345678', email: '',
                autonomyLevel: 2, language: lang)
            ..locale = Locale(lang)
            ..loading = false;
          await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: app,
            child: RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: Locale(lang),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                theme: AssistoTheme.light,
                darkTheme: AssistoTheme.dark,
                themeMode:
                    b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
                home: screen,
              ),
            ),
          ));
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
          expect(tester.takeException(), isNull);
          if (_out == null) return;
          final rb =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final img =
              await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
          final bytes = await tester
              .runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
          Directory(_out!).createSync(recursive: true);
          File('$_out/${e.key}_${lang}_${b.name}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          img.dispose();
        });
      }
    }
  }
}
