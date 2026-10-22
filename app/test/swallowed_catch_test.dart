// db1 — static check: a failed user action must never be swallowed silently.
// See swallowed_catch_scan.dart for the rules. Fix a finding by showing
// showActionFailed(context, where, e) (lib/services/action_feedback.dart), or —
// only for real background/cleanup work — add a `// best-effort: <why>` comment.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'swallowed_catch_scan.dart';

void main() {
  test('no user-action handler swallows an error silently', () {
    final findings = scanSwallowedCatches('lib');
    expect(findings.map((f) => f.toString()).toList(), isEmpty,
        reason: 'Empty catch / onError inside a tap/press/change handler. '
            'Show showActionFailed(...) or mark `// best-effort: <why>`.');
  });

  test('the scanner itself catches the patterns it promises to', () {
    // Guard against the scanner silently going blind (regex rot).
    const sample = '''
class _S {
  Widget build(BuildContext c) => TextButton(onPressed: () async {
    try { await go(); } catch (_) {}
  }, child: x);
  Widget b2(BuildContext c) => IconButton(onPressed: _save, icon: y);
  Future<void> _save() async {
    try { await go(); } catch (e) {}
  }
  Future<void> _poll() async {
    try { await go(); } catch (_) {}
  }
  Future<void> _ok() async {
    try { await go(); } catch (_) {} // best-effort: cleanup
  }
  Widget b3(BuildContext c) => TextButton(onPressed: _ok, child: z);
}
''';
    final dir = _tmpLib(sample);
    final f = scanSwallowedCatches(dir);
    expect(f.length, 2, reason: f.join('\n'));
    expect(f.any((x) => x.handler.contains('onPressed closure')), isTrue);
    expect(f.any((x) => x.handler.contains('_save')), isTrue);
  });
}

String _tmpLib(String src) {
  final d = Directory.systemTemp.createTempSync('db1_scan_');
  final lib = Directory('${d.path}/lib')..createSync();
  File('${lib.path}/sample.dart').writeAsStringSync(src);
  return lib.path;
}
