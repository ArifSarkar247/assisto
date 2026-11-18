// antitheft-nine — the battery hour (board row 11), opt-in group `atbattery`
// (e2e.yml group=start+atbattery; ~60 min of screen-off time).
//
// B's REAL engine runs on the emulator (foreground service, 50 Hz motion
// sensor, SIM watch, heartbeats); the phone is unplugged, `batterystats` is
// reset and the screen goes OFF for 60 minutes. Then the host reads
// `dumpsys batterystats` for Assisto's uid and prices it with a typical
// Bangladesh mid-range phone profile (tools/e2e/at_battery.py; honest limits
// are written there and into reality_out/at_battery.json). Limit: < 2 %/hour
// in the WORST case (as if the 50 Hz sensor kept the CPU awake all hour).
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'antitheft_nine_kit.dart';

const _minutes = 60;

void registerAntiTheftBatteryFlow() {
  realityFlow('at11_battery_hour_screen_off', 'Family & safety',
      'Anti-theft battery: the real engine for 60 min, screen off, unplugged -> dumpsys batterystats -> under 2 %/hour (worst case)',
      (f) async {
    await f.home();
    try {
      await f.step('protection on (B), engine running, sensor live', () async {
        await AtKit.arm(f);
        await f.eventually('the motion sensor delivers samples', () async {
          final s = await atCh.invokeMethod<Map>('debugState');
          return ((s?['halSamples'] as num?) ?? 0) > 0;
        }, seconds: 40);
      });
      late Map<String, dynamic> s0;
      await f.step('unplug, reset batterystats, screen OFF', () async {
        s0 = await AtKit.state(f);
        await AtKit.host(f, 'batt_start');
      });
      await f.step('wait $_minutes minutes (nothing else runs)', () async {
        await f.tester.runAsync(
            () => Future<void>.delayed(const Duration(minutes: _minutes)));
      });
      await f.step('read batterystats -> %/hour', () async {
        final s1 = await AtKit.state(f);
        final samples = ((s1['halSamples'] as num?) ?? 0) - ((s0['halSamples'] as num?) ?? 0);
        f.note('engine running=${s1['running']} sensor samples in the hour=$samples '
            'wake holds=${s1['wakeHolds']} alarm beats=${s1['beatAlarms']}');
        if (s1['running'] != true) throw TestFailure('the engine died during the hour');
        final o = await AtKit.host(f, 'batt_end', seconds: 240);
        // ignore: avoid_print
        print('AT_BATTERY ${o.trim().replaceAll('\n', ' | ')}');
        if (o.contains('NO_DATA')) throw TestFailure('no batterystats for the app uid: $o');
        if (!o.contains('at_battery PASS')) throw TestFailure('battery over the limit: $o');
      });
    } finally {
      await f.step('cleanup: protection off', () => AtKit.disarm(f));
    }
  }, timeout: const Duration(minutes: _minutes + 12));
}
