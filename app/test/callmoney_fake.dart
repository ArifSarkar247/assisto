// callmoney — a fake native bridge for the gallery, the sweep and the tests.
import 'package:assisto/notiflisten/notif_listen_channel.dart';

class FakeNotifBridge implements NotifListenBridge {
  NotifListenStatus st;
  final List<MoneyQueueItem> queue;
  NotifLaunch? launch;
  final configs = <Map<String, dynamic>>[];
  final done = <int>[];
  int opened = 0;

  FakeNotifBridge({
    this.st = const NotifListenStatus(available: true),
    List<MoneyQueueItem>? queue,
    this.launch,
  }) : queue = queue ?? [];

  @override
  Future<NotifListenStatus> status() async => st;

  @override
  Future<void> openAccessSettings() async => opened++;

  @override
  Future<void> setConfig(
      {required bool callNote,
      required bool money,
      required bool moneyAuto,
      required String lang,
      required Map<String, String> strings}) async {
    configs.add({'callnote': callNote, 'money': money, 'moneyAuto': moneyAuto, 'lang': lang, 'strings': strings});
    st = NotifListenStatus(
        available: st.available, granted: st.granted, callNote: callNote, money: money, moneyAuto: moneyAuto);
  }

  @override
  Future<List<MoneyQueueItem>> takeMoneyQueue() async => List.of(queue);

  @override
  Future<void> moneyDone(List<int> ids) async {
    done.addAll(ids);
    queue.removeWhere((q) => ids.contains(q.id));
  }

  @override
  Future<NotifLaunch?> takeLaunch() async {
    final l = launch;
    launch = null;
    return l;
  }
}

/// Real-format samples written for Assisto (no real user data).
List<MoneyQueueItem> fakeMoneyQueue() => [
      MoneyQueueItem(
          id: 1,
          wallet: 'bkash',
          kind: 'app',
          text: 'You have received Tk 1,500.00 from 01712345678. Fee Tk 0.00. Balance Tk 3,250.50. TrxID BK7Q2M9XAA at 03/11/2026 14:22',
          at: DateTime(2026, 11, 3, 14, 22)),
      MoneyQueueItem(
          id: 2,
          wallet: 'nagad',
          kind: 'sms',
          text: 'Cash Out Successful. Amount: Tk 2,000.00 Agent: 01812345678 Charge: Tk 25.00 TxnID: 71NG3K2PQ Balance: Tk 480.00 03/11/2026 10:05',
          at: DateTime(2026, 11, 3, 10, 5)),
      MoneyQueueItem(
          id: 3,
          wallet: 'bank',
          kind: 'sms',
          text: 'Dear Customer, your A/C XXXX1234 has been debited by BDT 850.00 on 02-Nov-2026 (POS purchase at SHWAPNO). Available Balance BDT 20,150.00. TrxID 88POS1902',
          at: DateTime(2026, 11, 2, 19, 2)),
    ];
