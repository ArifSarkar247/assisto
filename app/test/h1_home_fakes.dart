// h1-home fakes: a fake native-ad bridge (gallery stand-in for AdMob's
// template), a scripted chat-vision backend, on-device readers and ads.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/ads/hero_ad.dart';
import 'package:assisto/chat_vision/cv_backend.dart';
import 'package:assisto/chat_vision/on_device_vision.dart';
import 'package:assisto/photo_studio/ps_ads.dart';

final Uint8List kTinyPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAGAAAABACAIAAABqVuVZAAAAzElEQVR42u3bsQ2DMBQFQEBZhpYmPWtkg2zgCbxBNmAN+jRp2SB16lR0VCBFCAF27tU0Pj1/GwnK9+dbyHIqBIAAAQIECBAgQDKXy++PtvdXTivvH40G2WKn2mJThu6a7oLr21ODbDFAgLIe0qsH3oFZfbBoECBAgAABAgTIRfHfXus1CBAgQLkP6RDCGdYQY9QgWwwQIEN63+moQYAAAZIEb9I7nwwaBAgQIDdpDQIECJBsNqQT+rBMgwAdndJv4RoECBAgQIAAAZK5jLqTG1uolIY4AAAAAElFTkSuQmCC');

class FakeHeroHandle implements HeroAdHandle {
  FakeHeroHandle({this.hasVideo = true, this.large = false});
  @override
  final bool hasVideo;
  final bool large;
  bool disposed = false;
  @override
  void dispose() => disposed = true;
  @override
  Widget view() =>
      large ? const _FakeLargeTemplate() : const _FakeNativeTemplate();
}

/// Looks like AdMob's MEDIUM native template (media on top, headline, CTA).
class _FakeLargeTemplate extends StatelessWidget {
  const _FakeLargeTemplate();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('fake-native-ad'),
      color: scheme.surfaceContainerHigh,
      child: Column(
          key: const ValueKey('fake-native-large'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                      colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight),
                ),
                child: const Center(
                    child: Icon(Icons.play_circle_fill_rounded,
                        size: 56, color: Colors.white)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                const Expanded(
                  child: Text('Sample Advertiser — Test ad',
                      maxLines: 2,
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                FilledButton(onPressed: () {}, child: const Text('Install')),
              ]),
            ),
          ]),
    );
  }
}

/// Looks like AdMob's SMALL native template (owner feedback 27 Oct): square
/// icon left, headline, "Ad" badge + one line, CTA button; AdChoices top
/// right. Its text grows at most 1.3x, like the SDK view.
class _FakeNativeTemplate extends StatelessWidget {
  const _FakeNativeTemplate();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        key: const ValueKey('fake-native-ad'),
        color: scheme.surfaceContainerLow,
        padding: const EdgeInsets.all(8),
        child: Stack(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: const LinearGradient(
                      colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight),
                ),
                child: const Icon(Icons.shopping_bag_rounded, color: Colors.white),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Sample Advertiser',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        color: const Color(0xFFF6B60E),
                        // (the SDK's own badge; upper-case here so finders
                        // tell it apart from our localized label)
                        child: const Text('AD',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF111111))),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('Test ad, one line of body text',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                    ]),
                    SizedBox(
                      height: 24,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(6)),
                        child: Center(
                          child: Text('Install',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onPrimary)),
                        ),
                      ),
                    ),
                  ]),
            ),
          ]),
          Positioned(
              right: 0,
              top: 0,
              child: Icon(Icons.info_outline, size: 14, color: scheme.primary)),
        ]),
      ),
    );
  }
}

class FakeHeroBridge implements HeroAdBridge {
  FakeHeroBridge({this.fill = true, this.linkedValue = true});
  final bool fill;
  final bool linkedValue;
  int loads = 0;
  bool? lastStartMuted;
  HeroAdLook? lastLook;
  HeroAdSize? lastSize;
  final List<FakeHeroHandle> handles = [];
  @override
  bool get linked => linkedValue;
  @override
  Future<HeroAdHandle?> load(String unitId,
      {required bool startMuted,
      HeroAdLook? look,
      HeroAdSize size = HeroAdSize.compact}) async {
    loads++;
    lastStartMuted = startMuted;
    lastLook = look;
    lastSize = size;
    if (!fill) return null;
    final h = FakeHeroHandle(
        hasVideo: size == HeroAdSize.large, large: size == HeroAdSize.large);
    handles.add(h);
    return h;
  }
}

Map<String, dynamic> heroConfig(
        {bool enabled = true,
        bool muted = true,
        String plan = 'free',
        int refresh = 90,
        String? size,
        int? cap}) =>
    {
      if (size != null) 'home_native_size': size,
      if (cap != null) 'native_daily_cap': cap,
      'configured': false,
      'plan': plan,
      'paid': plan != 'free',
      'hero_enabled': enabled && plan == 'free',
      'hero_start_muted': muted,
      'hero_refresh_sec': refresh,
      'units': {'native': ''},
    };

class FakeOnDevice implements OnDeviceVision {
  FakeOnDevice(this.reading);
  final OnDeviceReading reading;
  @override
  bool get available => reading.ok;
  @override
  Future<OnDeviceReading> read(Uint8List bytes) async => reading;
}

const kMedicineReading = OnDeviceReading(
  status: OnDeviceStatus.ok,
  text: 'NAPA 500 mg\nParacetamol BP\nBeximco Pharmaceuticals Ltd.',
  labels: ['Paper', 'Text', 'Box'],
);

class FakePhotoAds implements PhotoAdBridge {
  FakePhotoAds({this.outcome = RewardOutcome.earned, this.onShown});
  RewardOutcome outcome;
  final void Function(String customData)? onShown;
  int shown = 0;
  @override
  bool get linked => true;
  @override
  Future<bool> showInterstitial(String unitId) async => false;
  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
      {required String userId, required String customData}) async {
    shown++;
    onShown?.call(customData);
    return outcome;
  }
}

/// Scripted /chat-vision server. [plan] free|premium; [reason] the quote.
class FakeCvBackend implements CvBackend {
  FakeCvBackend({
    this.plan = 'free',
    this.reason = 'ok',
    this.message = '',
    this.adsNeeded = 2,
    this.answerText =
        'This is NAPA 500 mg (paracetamol). The label says 500 mg per tablet.\n\nPlease consult a doctor or pharmacist before taking any medicine.',
    this.refuse = false,
    this.refuseMessage = "I can't identify real people from their face.",
    this.offline = false,
  });
  /// The server's (already localized) refusal text.
  final String refuseMessage;
  final String plan;
  final String reason;
  final String message;
  final int adsNeeded;
  final String answerText;
  final bool refuse;
  final bool offline;

  int verified = 0;
  int answers = 0;
  int creates = 0;
  String status = '';
  String funding = '';
  String? lastImage;

  bool get paid => plan != 'free';

  Map<String, dynamic> _quote() {
    if (paid) {
      return {'ok': true, 'reason': 'ok', 'paid_plan': true,
        'options': [{'via': 'pool', 'credits': 3}]};
    }
    if (reason == 'provider_missing' || reason == 'disabled') {
      return {'ok': false, 'reason': reason, 'message': message, 'options': []};
    }
    return {
      'ok': true, 'reason': reason, 'message': reason == 'ok' ? '' : message,
      'free_left': reason == 'daily_used' ? 0 : 1,
      'options': [
        if (reason == 'ok') {'via': 'ads', 'ads': adsNeeded},
        {'via': 'credits', 'credits': 3},
      ],
    };
  }

  Map<String, dynamic> _job({String answer = ''}) => {
        'id': 7, 'status': status, 'funding': funding,
        'ads_required': funding == 'ads' ? adsNeeded : 0,
        'ads_verified': verified, 'answer': answer, 'medicine': answer.isNotEmpty,
      };

  @override
  Future<CvConfig> config() async {
    if (offline) throw TimeoutException('offline');
    return CvConfig.fromJson({'free': !paid, 'quote': _quote(), 'max_image_kb': 4096});
  }

  @override
  Future<CvReply> create({required String via, required String question}) async {
    creates++;
    if (refuse) {
      return CvReply(422, {'ok': false, 'refused': true, 'reason': 'identify_person',
        'message': refuseMessage});
    }
    funding = via;
    status = via == 'ads' ? 'awaiting_funds' : 'funded';
    return CvReply(201, {'ok': true, 'job': _job()});
  }

  @override
  Future<CvReply> job(int id) async => CvReply(200, {'ok': true, 'job': _job()});

  @override
  Future<CvReply> ticket(int id) async => CvReply(201, {
        'ok': true, 'nonce': 'n$verified', 'custom_data': 'n$verified',
        'user_id': '1', 'rewarded_unit': '', 'job': _job()});

  /// What Google's SSV callback does on the server.
  void ssv() {
    verified++;
    if (verified >= adsNeeded) status = 'funded';
  }

  @override
  Future<CvReply> fundWithCredits(int id) async {
    funding = 'credits';
    status = 'funded';
    return CvReply(200, {'ok': true, 'job': _job()});
  }

  @override
  Future<CvReply> answer(int id,
      {required String imageB64,
      required String question,
      String deviceText = '',
      List<String> deviceLabels = const []}) async {
    if (status != 'funded' && status != 'done') {
      return CvReply(402, {'ok': false, 'reason': 'not_funded', 'job': _job()});
    }
    answers++;
    lastImage = imageB64;
    status = 'done';
    return CvReply(200, {'ok': true, 'job': _job(answer: answerText)});
  }
}
