// db1 — static check: no user action may be swallowed silently.
//
// Finds EMPTY catch blocks (`catch (_) {}`, `catch (e) {}`, `catch (e, st) {}`,
// a body of only whitespace/comments) and empty error callbacks
// (`onError: (_) {}`, `catchError((_) {})`) in app/lib, and reports the ones
// that sit inside a user-action handler:
//   * lexically inside an `onTap:` / `onPressed:` / `onChanged:` / … closure, or
//   * inside a method that such a handler references or calls directly
//     (`onTap: _save`, `onPressed: () => _save()`, `onTap: () { _save(); }`).
// A catch is exempt when it (or the line above it) carries a
// `// best-effort:` comment explaining why silence is right (background
// polling, analytics, cleanup, optional plugin probes).
//
// Pure Dart (dart:io only): `dart test/swallowed_catch_scan.dart` prints the
// findings; swallowed_catch_test.dart fails on any.
import 'dart:io';

class SwallowFinding {
  final String file;
  final int line;
  final String handler; // e.g. "onTap closure" or "method _save (onTap)"
  final String snippet;
  SwallowFinding(this.file, this.line, this.handler, this.snippet);
  @override
  String toString() => '$file:$line  [$handler]  $snippet';
}

const _handlerLabels = {
  'onTap', 'onPressed', 'onChanged', 'onLongPress', 'onSelected', 'onSubmitted',
  'onFieldSubmitted', 'onDoubleTap', 'onRefresh', 'onDismissed', 'onConfirm',
  'onEditingComplete', 'onTapUp', 'onTapDown', 'onSend', 'onRetry', 'onAccept',
  'onReject', 'onDelete', 'onSave', 'onCall', 'onOpen', 'onPick', 'onShare',
};

/// Replaces comments and string-literal contents with spaces (same length,
/// newlines kept) so bracket matching is not fooled by text.
String _strip(String s) {
  final out = StringBuffer();
  var i = 0;
  final n = s.length;
  void blank(int from, int to) {
    for (var k = from; k < to; k++) {
      out.write(s[k] == '\n' ? '\n' : ' ');
    }
  }

  while (i < n) {
    final c = s[i];
    if (c == '/' && i + 1 < n && s[i + 1] == '/') {
      final e = s.indexOf('\n', i);
      final end = e < 0 ? n : e;
      blank(i, end);
      i = end;
    } else if (c == '/' && i + 1 < n && s[i + 1] == '*') {
      final e = s.indexOf('*/', i + 2);
      final end = e < 0 ? n : e + 2;
      blank(i, end);
      i = end;
    } else if (c == '"' || c == "'") {
      final raw = i > 0 && s[i - 1] == 'r';
      final triple = i + 2 < n && s[i + 1] == c && s[i + 2] == c;
      final q = triple ? '$c$c$c' : c;
      var j = i + q.length;
      var depth = 0;
      while (j < n) {
        if (!raw && s[j] == '\\') {
          j += 2;
          continue;
        }
        if (!raw && depth == 0 && s.startsWith(r'${', j)) {
          depth = 1;
          j += 2;
          continue;
        }
        if (depth > 0) {
          if (s[j] == '{') depth++;
          if (s[j] == '}') depth--;
          j++;
          continue;
        }
        if (s.startsWith(q, j)) {
          j += q.length;
          break;
        }
        if (!triple && s[j] == '\n') break;
        j++;
      }
      out.write(q);
      blank(i + q.length, j - q.length > i + q.length ? j - q.length : i + q.length);
      if (j - q.length > i + q.length) out.write(q);
      i = j > i + q.length ? j : i + q.length;
      // keep length invariant
      final want = i;
      final have = out.length;
      if (have < want) blank(have, want);
    } else {
      out.write(c);
      i++;
    }
  }
  final r = out.toString();
  return r.length == s.length ? r : r.padRight(s.length).substring(0, s.length);
}

int _lineOf(String s, int pos) => '\n'.allMatches(s.substring(0, pos)).length + 1;

/// Open-bracket positions enclosing [pos], innermost first.
List<int> _enclosing(String t, int pos) {
  final stack = <int>[];
  for (var i = 0; i < pos; i++) {
    final c = t[i];
    if (c == '(' || c == '{' || c == '[') stack.add(i);
    if ((c == ')' || c == '}' || c == ']') && stack.isNotEmpty) stack.removeLast();
  }
  return stack.reversed.toList();
}

final _kw = {'if', 'for', 'while', 'switch', 'catch', 'on', 'return', 'await', 'else', 'try', 'do'};

/// If the `{` at [brace] opens a function body, returns (name, isClosure,
/// handlerLabel). Name is null for closures.
(String?, String?)? _fnHeader(String t, int brace) {
  var j = brace - 1;
  while (j >= 0 && t[j].trim().isEmpty) {
    j--;
  }
  // optional async / async* / sync*
  final before = t.substring(0, j + 1);
  final mm = RegExp(r'(async\*?|sync\*)$').firstMatch(before);
  if (mm != null) {
    j = mm.start - 1;
    while (j >= 0 && t[j].trim().isEmpty) {
      j--;
    }
  }
  if (j < 0 || t[j] != ')') return null;
  // find the matching '('
  var d = 0;
  var k = j;
  for (; k >= 0; k--) {
    if (t[k] == ')') d++;
    if (t[k] == '(') {
      d--;
      if (d == 0) break;
    }
  }
  if (k < 0) return null;
  var h = k - 1;
  while (h >= 0 && t[h].trim().isEmpty) {
    h--;
  }
  // generic type params on methods: foo<T>(...)
  final head = t.substring(0, h + 1);
  final named = RegExp(r'([A-Za-z_$][\w$]*)(<[^<>]*>)?$').firstMatch(head);
  if (named != null) {
    final name = named.group(1)!;
    if (_kw.contains(name)) return null;
    // `onTap: foo(...) {` is not legal; a word before `(` = declaration.
    return (name, null);
  }
  // closure: `label: (...) {`  or positional `(...) {`
  final lab = RegExp(r'([A-Za-z_$][\w$]*)\s*:\s*$').firstMatch(head);
  return (null, lab?.group(1) ?? '');
}

/// Method names a user-action handler references or calls directly.
Set<String> _handlerTargets(String t) {
  final out = <String>{};
  final re = RegExp(r'\b(on[A-Z]\w*)\s*:\s*');
  for (final m in re.allMatches(t)) {
    if (!_handlerLabels.contains(m.group(1))) continue;
    // expression extent: until ',' or a closing bracket at depth 0
    var d = 0;
    var i = m.end;
    for (; i < t.length; i++) {
      final c = t[i];
      if (c == '(' || c == '{' || c == '[') d++;
      if (c == ')' || c == '}' || c == ']') {
        if (d == 0) break;
        d--;
      }
      if (c == ',' && d == 0) break;
      if (c == ';' && d == 0) break;
    }
    final expr = t.substring(m.end, i);
    final tear = RegExp(r'^\s*([A-Za-z_$][\w$]*)\s*$').firstMatch(expr);
    if (tear != null) out.add(tear.group(1)!);
    // tear-offs inside an expression, e.g. `onPressed: _busy ? null : _send`
    for (final m2 in RegExp(r'(?<![\w$.])(_[A-Za-z][\w$]*)(?![\w$])').allMatches(expr)) {
      out.add(m2.group(1)!);
    }
    // direct calls inside the closure (one level: `_x(` / `await _x(`)
    for (final c in RegExp(r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*\(').allMatches(expr)) {
      final name = c.group(1)!;
      if (_kw.contains(name) || name == 'setState') continue;
      out.add(name);
    }
  }
  return out;
}

List<SwallowFinding> scanSwallowedCatches(String libDir) {
  final findings = <SwallowFinding>[];
  final files = Directory(libDir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.contains('/l10n/'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final emptyCatch = RegExp(r'catch\s*\(\s*[A-Za-z_]\w*\s*(,\s*[A-Za-z_]\w*\s*)?\)\s*\{\s*\}');
  final emptyOnError = RegExp(
      r'(onError\s*:\s*|catchError\s*\(\s*)\(\s*[A-Za-z_]\w*\s*(,\s*[A-Za-z_]\w*\s*)?\)\s*(async\s*)?\{\s*\}');
  for (final f in files) {
    final src = f.readAsStringSync();
    final t = _strip(src);
    final lines = src.split('\n');
    final targets = _handlerTargets(t);
    final hits = [
      ...emptyCatch.allMatches(t).map((m) => m.start),
      ...emptyOnError.allMatches(t).map((m) => m.start),
    ]..sort();
    for (final pos in hits) {
      final ln = _lineOf(src, pos);
      final here = lines[ln - 1];
      final prev = ln >= 2 ? lines[ln - 2] : '';
      // exemption comment on this line, the line above, or inside the braces
      final endLine = ln + 2 <= lines.length ? lines.sublist(ln - 1, ln + 1).join('\n') : here;
      if (here.contains('best-effort:') || prev.contains('best-effort:') ||
          RegExp(r'\{\s*//\s*best-effort:').hasMatch(endLine)) {
        continue;
      }
      String? why;
      for (final open in _enclosing(t, pos)) {
        if (t[open] != '{') continue;
        final hdr = _fnHeader(t, open);
        if (hdr == null) continue;
        final (name, label) = hdr;
        if (label != null && _handlerLabels.contains(label)) {
          why = '$label closure';
          break;
        }
        if (name != null) {
          if (targets.contains(name)) why = 'method $name (called from a handler)';
          break; // stop at the enclosing named function
        }
      }
      if (why != null) {
        final rel = f.path.substring(f.path.indexOf('lib/'));
        findings.add(SwallowFinding(rel, ln, why, here.trim()));
      }
    }
  }
  return findings;
}

void main(List<String> args) {
  final dir = args.isNotEmpty ? args.first : 'lib';
  final fs = scanSwallowedCatches(dir);
  for (final x in fs) {
    stdout.writeln(x);
  }
  stdout.writeln('${fs.length} swallowed user-action catch(es)');
}
