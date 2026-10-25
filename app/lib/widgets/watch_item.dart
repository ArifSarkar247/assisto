import 'package:flutter/material.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;

/// A single actionable thing in the Watch Feed. Built on the client by
/// composing real signals from existing module endpoints (alerts, briefing,
/// medicines-today, money summary, subscriptions, watchers). NO fake data —
/// if a source has nothing, it contributes nothing.
///
/// Grouping/priority mirrors the pure backend helper
/// `backend/core/logic/watch_feed.py` so the ordering is identical whether the
/// feed is built here or server-side.
enum WatchGroup { needsYou, today, upcoming }

enum WatchSeverity { high, med, low }

/// Quick action available on a card. The screen decides what each does.
enum WatchAction { open, dismiss, snooze, markDone, markTaken, call, payHint }

class WatchItem {
  /// Stable-ish id for dismiss/snooze bookkeeping (source + key).
  final String id;

  /// Signal kind, e.g. reminder, medicine_dose, refill, loan_due, budget,
  /// subscription, birthday, checkin_overdue, family_alert, doc_expiry, change.
  final String kind;
  final String title;
  final String? body;
  final WatchGroup group;
  final WatchSeverity severity;

  /// Which source (ARB-labelled) this came from — used for the "enable X"
  /// honest states and the personalization filter.
  final WatchSource source;

  /// Canonical ChatNav route to deep-link into the owning module (null = none).
  final String? route;

  /// Days until due: negative = overdue, 0 = today, null = no date.
  final int? daysUntil;

  /// Quick actions to render (first is primary).
  final List<WatchAction> actions;

  /// Optional callbacks keyed by action (screen supplies the real work).
  final Future<void> Function(WatchAction)? onAction;

  const WatchItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.group,
    required this.source,
    this.body,
    this.severity = WatchSeverity.med,
    this.route,
    this.daysUntil,
    this.actions = const [WatchAction.open],
    this.onAction,
  });

  /// Lower sorts first. Mirrors watch_feed.priority().
  int get priority {
    const groupRank = {
      WatchGroup.needsYou: 0,
      WatchGroup.today: 100,
      WatchGroup.upcoming: 200,
    };
    const sevRank = {
      WatchSeverity.high: 0,
      WatchSeverity.med: 10,
      WatchSeverity.low: 20,
    };
    final base = groupRank[group]! + sevRank[severity]!;
    final du = daysUntil ?? 0;
    // Pack into a single comparable: base dominates, due-day breaks ties.
    return base * 1000 + (du + 500);
  }

  WatchItem copyWith({WatchGroup? group}) => WatchItem(
        id: id,
        kind: kind,
        title: title,
        body: body,
        group: group ?? this.group,
        severity: severity,
        source: source,
        route: route,
        daysUntil: daysUntil,
        actions: actions,
        onAction: onAction,
      );
}

/// Sources the user can toggle on/off (personalization). Each maps to a
/// module and an ARB label.
enum WatchSource {
  reminders,
  medicine,
  money,
  subscriptions,
  birthdays,
  safety,
  family,
  watchers,
}

/// The sources THIS build offers. play-nomed: no medicine source in the Play
/// flavour (no dose items, no refill alerts, no medicine switch).
List<WatchSource> watchSourcesAvailable() => [
      for (final s in WatchSource.values)
        if (s != WatchSource.medicine || kMedicalFeaturesAllowed) s,
    ];

/// Visuals for a severity — WCAG-conscious tints taken from the brand palette.
({IconData icon, Color tint}) watchSeverityVisual(
    WatchSeverity s, ColorScheme scheme) {
  switch (s) {
    case WatchSeverity.high:
      return (icon: Icons.priority_high_rounded, tint: Brand.danger);
    case WatchSeverity.med:
      return (icon: Icons.notifications_active_rounded, tint: Brand.warning);
    case WatchSeverity.low:
      return (icon: Icons.info_outline_rounded, tint: scheme.primary);
  }
}
