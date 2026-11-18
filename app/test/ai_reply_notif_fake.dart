// ai-reply-notif — a fake native bridge (Dart side of the method channel) for
// tests and the gallery. Records every configure() so tests can check what
// the native gate would receive.
import 'package:assisto/notiflisten/ai_reply_notif.dart';

class FakeAiReplyBridge implements AiReplyNotifBridge {
  AiReplyNativeStatus st;
  final configs = <Map<String, dynamic>>[];
  int openedSettings = 0;
  int cleared = 0;
  FakeAiReplyBridge({this.st = const AiReplyNativeStatus(available: true)});

  @override
  Future<AiReplyNativeStatus> status() async => st;

  @override
  Future<void> configure({
    required bool on,
    required bool flag,
    required String consent,
    required List<String> apps,
    String? token,
    String? api,
    required Map<String, String> strings,
  }) async {
    configs.add({
      'on': on,
      'flag': flag,
      'consent': consent,
      'apps': apps,
      'token': token,
      'api': api,
      'strings': strings,
    });
    st = AiReplyNativeStatus(
      available: st.available,
      granted: st.granted,
      on: on && flag && consent.isNotEmpty,
      apps: apps,
      hasToken: token == null ? st.hasToken : token.isNotEmpty,
      noCreditCount: st.noCreditCount,
      installedPackages: st.installedPackages,
    );
  }

  @override
  Future<void> clearNoCredit() async => cleared++;

  @override
  Future<void> openAccessSettings() async => openedSettings++;
}
