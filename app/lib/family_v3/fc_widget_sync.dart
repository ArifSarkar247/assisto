import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

import '../l10n/app_localizations.dart';
import 'fc_status.dart';
import 'fc_text.dart';

/// fcscreen — pushes the Family snapshot to the native FamilyWidgetProvider
/// (android_overlay/.../FamilyWidgetProvider.kt). All words are localised
/// here; the native side only re-colours a member gray when its `fu`
/// (fresh-until, epoch ms) passes and swaps in that member's `g` line.
/// Never throws; a no-op off Android and in tests.
class FcWidgetSync {
  FcWidgetSync._();
  static const provider = 'FamilyWidgetProvider';
  static bool Function() isAndroid = () => !kIsWeb && Platform.isAndroid;

  /// Pure: the JSON the native widget reads (unit-tested).
  static Map<String, dynamic> snapshot(BuildContext context, Map board, DateTime now) {
    final t = AppLocalizations.of(context);
    final members = [
      for (final m in (board['members'] as List? ?? const []))
        if (m is Map && m['me'] != true) m
    ];
    final rows = <Map<String, dynamic>>[];
    final lineRows = <Map>[];
    for (final m in members) {
      final st = fcRecheck(m, now);
      final label = '${m['label'] ?? ''}'.trim();
      final name = label.isNotEmpty ? label : '${m['name'] ?? ''}';
      lineRows.add({'user_id': m['user_id'], 'name': name, 'state': st.state, 'reason': st.reason});
      rows.add({
        'i': fcInitial(name),
        'n': name,
        's': st.state,
        'fu': st.freshUntil?.millisecondsSinceEpoch ?? 0,
        'g': t.fc3LineStale(name),
        for (final s in const ['ok', 'check', 'stale', 'sos', 'paused'])
          'w_$s': fcStateWord(t, s),
      });
    }
    final line = fcFamilyLine(lineRows);
    for (final r in rows) {
      r['line_owner'] = line.state == 'check' && r['n'] == line.name;
    }
    final text = switch (line.state) {
      'ok' => t.fc3LineOk,
      'sos' => t.fc3LineSos(line.name),
      'check' => '${t.fc3LineCheck(line.name)}: ${fcReason(context, line.reason, null)}',
      'stale' => t.fc3LineStale(line.name),
      _ => t.fc3WidgetEmpty,
    };
    final fam = (board['family'] as Map?) ?? const {};
    return {
      'title': '${fam['name'] ?? t.fc3Title}',
      'as_of': t.fc3WidgetAsOf(fcClock(context, now.toUtc().toIso8601String())),
      'line': text,
      'line_state': line.state,
      'members': rows.take(6).toList(),
    };
  }

  static Future<void> push(BuildContext context, Map board) async {
    if (!isAndroid()) return;
    try {
      final snap = snapshot(context, board, DateTime.now());
      await HomeWidget.saveWidgetData<String>('fc_widget_json', jsonEncode(snap));
      await HomeWidget.updateWidget(name: provider, androidName: provider);
    } catch (e) {
      if (kDebugMode) debugPrint('fc widget push failed: $e');
    }
  }
}
