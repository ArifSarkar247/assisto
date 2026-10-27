// ops-watch — previous-exit reasons (ANR / Java / native crash) reported once
// per session after consent, scrubbed, acked only when posted, never throws.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/diag/crash_reporter.dart';
import 'package:assisto/diag/device_facts.dart';
import 'package:assisto/diag/exit_info.dart';

class _FakeExits extends ExitInfo {
  _FakeExits(this.items, {this.throws = false});
  final List<Map<String, dynamic>> items;
  final bool throws;
  int calls = 0;
  final List<int> acks = [];
  @override
  Future<List<Map<String, dynamic>>> pending() async {
    calls++;
    if (throws) throw StateError('binder died');
    return items;
  }

  @override
  Future<void> ack(int ts) async => acks.add(ts);
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final anr = {
    'kind': 'anr',
    'ts': 1000,
    'native': false,
    'description': 'Input dispatching timed out "Rahim chat" 01712345678',
  };
  final nat = {'kind': 'exit_crash', 'ts': 2000, 'native': true, 'description': ''};

  CrashReporter make(_FakeExits ex) => CrashReporter(
        exitInfo: ex,
        exitDelay: Duration.zero,
        device: () async => const DeviceFacts(brand: 'realme', model: 'RMX3491'),
      );

  test('body: ANR is not fatal, native crash is; PII scrubbed', () {
    final b = ExitInfo.body(anr)!;
    expect(b['kind'], 'anr');
    expect(b['error_type'], 'ANR');
    expect(b['fatal'], isFalse);
    expect(b['where'], 'exit.anr');
    expect(b['occurred_ms'], 1000);
    expect('${b['message']}'.contains('Rahim'), isFalse);
    expect('${b['message']}'.contains('01712345678'), isFalse);
    final n = ExitInfo.body(nat)!;
    expect(n['fatal'], isTrue);
    expect(n['error_type'], 'NativeCrash');
    expect(ExitInfo.body({'kind': 'other'}), isNull);
  });

  test('reported once per session after consent, then acked', () async {
    final ex = _FakeExits([anr, nat]);
    final r = make(ex);
    final posted = <Map<String, dynamic>>[];
    var consent = false;
    await r.start(
        post: (b) async => posted.add(b),
        consented: () => consent,
        userHash: () => 'u');
    await _settle();
    expect(ex.calls, 0); // no consent -> nothing read, nothing sent
    consent = true;
    await r.onConsentChanged();
    await _settle();
    await r.flush();
    await _settle();
    expect(ex.calls, 1);
    expect(posted.map((b) => b['kind']), ['anr', 'exit_crash']);
    expect(posted.first['device']['brand'], 'realme');
    expect(ex.acks, [2000]);
  });

  test('offline: nothing acked, retried next session', () async {
    final ex = _FakeExits([anr]);
    final r = make(ex);
    await r.start(
        post: (b) async => throw StateError('offline'),
        consented: () => true,
        userHash: () => 'u');
    await _settle();
    expect(ex.calls, 1);
    expect(ex.acks, isEmpty);
  });

  test('a failing lookup never throws', () async {
    final ex = _FakeExits([], throws: true);
    final r = make(ex);
    await r.start(
        post: (b) async {}, consented: () => true, userHash: () => 'u');
    await _settle();
    expect(ex.calls, 1);
    expect(ex.acks, isEmpty);
  });

  test('platform ExitInfo off-device returns [] (no plugin)', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(await const ExitInfo().pending(), isEmpty);
    await const ExitInfo().ack(5);
  });
}
