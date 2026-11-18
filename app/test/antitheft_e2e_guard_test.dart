// antitheft-e2e — guards for the native (Kotlin) bugs the emulator E2E found.
// The Kotlin is compiled + exercised on the emulator by
// integration_test/flows/antitheft_e2e_flow.dart; these source checks keep the
// fixes from silently coming back between E2E runs.
//   1. the "Are you OK?" grab notification shared id 8442 with the lock-screen
//      "This phone is lost" message: a grab replaced the lost message and its
//      15 s cancel removed it for good -> every antitheft notification id is
//      unique;
//   2. the owner's sensitivity reached a running engine only from the open app
//      on that phone -> the check-in config applies it;
//   3. the test-only hooks refuse in a release (non-debuggable) build.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _dir = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/antitheft';

String _read(String f) => File('$_dir/$f').readAsStringSync();

void main() {
  test('every anti-theft notification id is unique', () {
    final ids = <String, String>{};
    final re = RegExp(r'const val (\w*NOTIF_ID)\s*=\s*(\d+)');
    for (final f in Directory(_dir).listSync().whereType<File>()) {
      if (!f.path.endsWith('.kt')) continue;
      for (final m in re.allMatches(f.readAsStringSync())) {
        final where = '${f.uri.pathSegments.last}:${m.group(1)}';
        expect(ids.containsKey(m.group(2)), isFalse,
            reason: 'id ${m.group(2)} used by ${ids[m.group(2)]} and $where');
        ids[m.group(2)!] = where;
      }
    }
    expect(ids.length, greaterThanOrEqualTo(6));
  });

  test('a check-in applies the server sensitivity to the running detector', () {
    final s = _read('AntiTheftService.kt');
    final i = s.indexOf('cfg.has("snatch_sensitivity")');
    expect(i, greaterThan(0));
    expect(s.substring(i, i + 400), contains('snatch.sensitivity = sens'));
  });

  test('debug hooks refuse outside a debuggable build', () {
    final s = _read('AntiTheftService.kt');
    for (final fn in ['fun debugInject(', 'fun debugSim(', 'fun debugState(']) {
      final i = s.indexOf(fn);
      expect(i, greaterThan(0), reason: fn);
      expect(s.substring(i, i + 300), contains('if (!isDebuggable(ctx))'), reason: fn);
    }
    expect(s, contains('debugSimSlots?.let { if (isDebuggable(this)) return it }'));
  });
}
