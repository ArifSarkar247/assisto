// pay1: gallery states for test/screenshots_test.dart — the checkout sheet
// on the Play build (Play first + gateway), the website APK (gateway only),
// the owner kill-switch (gateway off inside the Play build), keys not added.
import 'package:flutter/material.dart';

import 'package:assisto/payments/checkout_sheet.dart';

import 'pay1_fakes.dart';

Widget _sheetLike(Widget child) => Scaffold(
      backgroundColor: Colors.black54,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
              top: false,
              child: Padding(
                  padding: const EdgeInsets.only(top: 24), child: child)),
        ),
      ),
    );

Widget _sheet(FakePaymentsBackend b, String flavour, {String sku = 'premium_monthly'}) =>
    _sheetLike(CheckoutSheet(sku: sku, backend: b, flavour: flavour));

final Map<String, Widget Function(String)> pay1Shots = {
  'pay_sheet_play': (_) => _sheet(FakePaymentsBackend(), 'play'),
  'pay_sheet_apk': (_) =>
      _sheet(FakePaymentsBackend(cfg: pay1Config(play: false)), 'apk'),
  'pay_sheet_play_gw_off': (_) =>
      _sheet(FakePaymentsBackend(cfg: pay1Config(gwEnabled: false)), 'play'),
  'pay_sheet_not_ready': (_) => _sheet(
      FakePaymentsBackend(cfg: pay1Config(play: false, gwReady: false)), 'apk'),
  'pay_sheet_pack': (_) =>
      _sheet(FakePaymentsBackend(), 'play', sku: 'pack_p50'),
};
