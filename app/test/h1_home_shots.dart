// h1-home gallery states for test/screenshots_test.dart: the home hero with a
// (fake, test-template) native ad for a Free user, the Premium home (logo
// block, never an ad), and image-in-chat photo turns.
import 'package:flutter/material.dart';

import 'package:assisto/chat_vision/chat_photo.dart';
import 'package:assisto/chat_vision/cv_controller.dart';
import 'package:assisto/chat_vision/on_device_vision.dart';
import 'package:assisto/screens/home_screen.dart';
import 'package:assisto/widgets/home_hero.dart';

import 'h1_home_fakes.dart';

Widget _home({required bool free}) {
  HomeHero.debugReset();
  HomeHero.debugBridge = FakeHeroBridge();
  HomeHero.debugLoadConfig = () async => heroConfig(plan: free ? 'free' : 'premium');
  return const HomeScreen();
}

Widget _turn(FakeCvBackend b,
    {OnDeviceReading reading = OnDeviceReading.unavailable,
    String question = 'What medicine is this? How should I take it?',
    String? then}) {
  final c = CvController(
      backend: b,
      bytes: kTinyPng,
      question: question,
      onDevice: FakeOnDevice(reading),
      ads: FakePhotoAds(onShown: (_) => b.ssv()),
      pollEvery: Duration.zero);
  c.start().then((_) {
    if (then != null) c.requestDetailed(then);
  });
  return Scaffold(
    appBar: AppBar(title: const Text('Assisto')),
    body: ListView(padding: const EdgeInsets.all(12), children: [
      ChatPhotoTurn(request: ChatPhotoRequest(kTinyPng, question), controller: c),
    ]),
  );
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> h1Shots = {
  'home_hero_ad_free': (_) => _home(free: true),
  'home_hero_premium': (_) => _home(free: false),
  'chat_photo_free_unavailable': (_) => _turn(FakeCvBackend()),
  'chat_photo_free_ondevice': (_) =>
      _turn(FakeCvBackend(), reading: kMedicineReading),
  'chat_photo_free_credits_only': (_) => _turn(
      FakeCvBackend(
          reason: 'too_many_ads',
          message: "Ads can't cover this answer's cost — it needs credits or Premium."),
      reading: kMedicineReading),
  'chat_photo_premium_done': (_) =>
      _turn(FakeCvBackend(plan: 'premium'), reading: kMedicineReading, then: 'pool'),
  'chat_photo_needs_key': (_) => _turn(FakeCvBackend(
      reason: 'provider_missing',
      message: "Detailed photo answers aren't switched on yet — the owner must add a "
          'Claude, OpenAI or Gemini vision key in Integrations.')),
  'chat_photo_face_refused': (_) => _turn(FakeCvBackend(plan: 'premium', refuse: true),
      question: 'Who is this person?', then: 'pool'),
};
