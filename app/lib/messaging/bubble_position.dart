import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// circlebub (owner 3 Nov 16:30, part A) — where the user last dragged our
/// OWN in-app chat bubble (the call-screen overlay, messaging/
/// in_call_bubbles.dart). Android's system bubbles remember their own spot;
/// this is the same promise for ours.
///
/// Saved per chat ("member:12") plus a "last" fallback, as the snapped EDGE
/// and the vertical position as a FRACTION of the usable height (and the x
/// fraction for completeness). Fractions + edge, not pixels, so the bubble
/// lands in the same place after an app restart, a new message, a rotation
/// or a reboot, and is always clamped inside the current screen (any size,
/// notch, nav bar).
enum BubbleEdge { left, right }

@immutable
class BubblePos {
  const BubblePos({required this.edge, required this.yFrac, this.xFrac});

  final BubbleEdge edge;

  /// 0 = top of the usable area, 1 = bottom.
  final double yFrac;

  /// Where it was dropped before snapping (0..1); informational.
  final double? xFrac;

  /// Default: right edge, a little below the top (the old fixed spot).
  static const fallback = BubblePos(edge: BubbleEdge.right, yFrac: 0.12);

  Map<String, dynamic> toJson() => {
        'e': edge == BubbleEdge.left ? 'l' : 'r',
        'y': double.parse(yFrac.toStringAsFixed(4)),
        if (xFrac != null) 'x': double.parse(xFrac!.toStringAsFixed(4)),
      };

  static BubblePos? fromJson(Object? j) {
    if (j is! Map) return null;
    final y = j['y'];
    if (y is! num || !y.isFinite) return null;
    final x = j['x'];
    return BubblePos(
      edge: j['e'] == 'l' ? BubbleEdge.left : BubbleEdge.right,
      yFrac: y.toDouble().clamp(0.0, 1.0),
      xFrac: x is num && x.isFinite ? x.toDouble().clamp(0.0, 1.0) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BubblePos &&
      other.edge == edge &&
      (other.yFrac - yFrac).abs() < 1e-3;

  @override
  int get hashCode => Object.hash(edge, (yFrac * 1000).round());

  @override
  String toString() => 'BubblePos(${edge.name}, $yFrac)';
}

class BubbleGeometry {
  BubbleGeometry._();

  /// Gap between the bubble and the screen edge.
  static const margin = 8.0;

  /// The usable rectangle (inside the safe area, never under the status bar,
  /// notch or navigation bar) the bubble's top-left may move in.
  static Rect _area(Size screen, Size bubble, EdgeInsets pad) {
    final left = pad.left + margin;
    final top = pad.top + margin;
    final right = math.max(left, screen.width - pad.right - margin - bubble.width);
    final bottom =
        math.max(top, screen.height - pad.bottom - margin - bubble.height);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// Top-left offset for [p] on this screen — always fully on screen.
  static Offset resolve(BubblePos p, Size screen, Size bubble, EdgeInsets pad) {
    final a = _area(screen, bubble, pad);
    final x = p.edge == BubbleEdge.left ? a.left : a.right;
    final y = a.top + p.yFrac.clamp(0.0, 1.0) * a.height;
    return Offset(x, y);
  }

  /// The user let go with the bubble's top-left at [topLeft]: snap to the
  /// nearer side edge, keep the height (clamped).
  static BubblePos fromDrop(
      Offset topLeft, Size screen, Size bubble, EdgeInsets pad) {
    final a = _area(screen, bubble, pad);
    final cx = topLeft.dx + bubble.width / 2;
    final edge = cx < screen.width / 2 ? BubbleEdge.left : BubbleEdge.right;
    final y = topLeft.dy.clamp(a.top, a.bottom);
    final yFrac = a.height <= 0 ? 0.0 : (y - a.top) / a.height;
    final x = topLeft.dx.clamp(a.left, a.right);
    final xFrac = a.width <= 0 ? 0.0 : (x - a.left) / a.width;
    return BubblePos(edge: edge, yFrac: yFrac, xFrac: xFrac);
  }
}

/// Persistence (SharedPreferences, survives restarts and reboots).
class BubblePositionStore {
  BubblePositionStore._();

  static const kKey = 'c3_bubble_pos_v1';
  static const kLast = '_last';
  static const maxChats = 60;

  static Future<Map<String, dynamic>> _all() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(kKey);
      if (raw == null || raw.isEmpty) return {};
      final j = jsonDecode(raw);
      return j is Map ? j.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  /// This chat's spot, else the last spot used for any chat, else default.
  static Future<BubblePos> load(String chatKey) async {
    final all = await _all();
    return BubblePos.fromJson(all[chatKey]) ??
        BubblePos.fromJson(all[kLast]) ??
        BubblePos.fallback;
  }

  /// Save for [chatKey] (and as the "last" spot). Keeps at most [maxChats]
  /// chats (oldest dropped). Never throws.
  static Future<void> save(String chatKey, BubblePos pos) async {
    try {
      final all = await _all();
      all.remove(chatKey); // re-insert = newest
      all[chatKey] = pos.toJson();
      all[kLast] = pos.toJson();
      final chats = all.keys.where((k) => k != kLast).toList();
      while (chats.length > maxChats) {
        all.remove(chats.removeAt(0));
      }
      final p = await SharedPreferences.getInstance();
      await p.setString(kKey, jsonEncode(all));
    } catch (_) {}
  }
}
