import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';

/// home-circle (owner 26 Oct): the My Circle unread count + "missed call" dot
/// shown on the pinned home tile AND the sidebar entry — ONE shared source so
/// both always agree with the top-bar My Circle badge.
///
///  * [CircleBadgeState.unread] — the SAME number as the home top bar
///    (GET /home/badges -> my_circle_unread); [HomeScreen] pushes every fetch
///    here via [setUnread].
///  * [CircleBadgeState.missed] — an incoming missed call newer than the last
///    time the user looked at the Calls tab. Computed from GET /circle/calls
///    (newest first) against a device watermark ([seenKey]); cleared by
///    [markCallsSeen] when the Calls tab / call history is shown.
class CircleBadgeState {
  final int unread;
  final bool missed;
  const CircleBadgeState({this.unread = 0, this.missed = false});

  @override
  bool operator ==(Object other) =>
      other is CircleBadgeState &&
      other.unread == unread &&
      other.missed == missed;

  @override
  int get hashCode => Object.hash(unread, missed);
}

class CircleBadges {
  CircleBadges._();
  static final CircleBadges instance = CircleBadges._();

  /// ISO time of the newest missed call the user has already seen.
  static const seenKey = 'circle_missed_seen_v1';

  /// /circle/calls is up to 100 rows — fetch it at most this often (badge
  /// ticks fire on every new chat message).
  static const minGap = Duration(seconds: 20);

  final ValueNotifier<CircleBadgeState> state =
      ValueNotifier(const CircleBadgeState());

  DateTime? _lastFetch;
  DateTime? _newestMissed;

  void setUnread(int n) => state.value =
      CircleBadgeState(unread: n < 0 ? 0 : n, missed: state.value.missed);

  void _setMissed(bool m) =>
      state.value = CircleBadgeState(unread: state.value.unread, missed: m);

  /// Same rule as the call log ([isMissedCallRow]): only an INCOMING call
  /// that was missed / cancelled by the caller counts.
  static bool isMissed(Map c) =>
      c['outgoing'] != true &&
      (c['state'] == 'missed' || c['state'] == 'canceled');

  /// Newest missed incoming call time in [calls] (any order), or null.
  static DateTime? newestMissed(Iterable calls) {
    DateTime? out;
    for (final c in calls) {
      if (c is! Map || !isMissed(c)) continue;
      final t = DateTime.tryParse('${c['started_at'] ?? ''}');
      if (t != null && (out == null || t.isAfter(out))) out = t;
    }
    return out;
  }

  /// Pure: does [newest] need a dot given the [seen] watermark?
  static bool unseen(DateTime? newest, DateTime? seen) =>
      newest != null && (seen == null || newest.isAfter(seen));

  /// Re-check the missed-call dot (throttled unless [force]). Never throws.
  Future<void> refreshMissed(ApiClient api, {bool force = false}) async {
    final now = DateTime.now();
    if (!force && _lastFetch != null && now.difference(_lastFetch!) < minGap) {
      return;
    }
    _lastFetch = now;
    try {
      final r = await api.getJson('/circle/calls');
      final calls = (r['calls'] ?? r['results'] ?? const []) as List;
      await applyCalls(calls);
    } catch (_) {/* offline: keep the last dot */}
  }

  /// Update the dot from a fetched call list. First run on a device (no
  /// watermark yet) seeds the watermark so old history never lights a dot.
  @visibleForTesting
  Future<void> applyCalls(List calls) async {
    final newest = newestMissed(calls);
    _newestMissed = newest;
    final raw = await Settings.getString(seenKey);
    final seen = raw == null ? null : DateTime.tryParse(raw);
    if (raw == null || seen == null) {
      await Settings.setString(
          seenKey, (newest ?? DateTime.now().toUtc()).toIso8601String());
      _setMissed(false);
      return;
    }
    _setMissed(unseen(newest, seen));
  }

  /// The user is looking at the call log: clear the dot. [calls] (when the
  /// screen has them) pins the watermark to the newest missed call shown.
  Future<void> markCallsSeen([List? calls]) async {
    final newest = (calls == null ? null : newestMissed(calls)) ??
        _newestMissed ??
        DateTime.now().toUtc();
    _setMissed(false);
    try {
      await Settings.setString(seenKey, newest.toIso8601String());
    } catch (_) {}
  }

  @visibleForTesting
  void reset() {
    state.value = const CircleBadgeState();
    _lastFetch = null;
    _newestMissed = null;
  }
}

/// Count -> badge text: Bangla digits in bn (99+ cap), ASCII otherwise.
String circleBadgeLabel(int n, String lang) {
  final s = n > 99 ? '99+' : '$n';
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? 0x09E6 + (c - 0x30) : c);
  }
  return b.toString();
}

/// Red unread-count pill (Bangla digits in bn, 99+ cap) with a TalkBack label
/// ([AppLocalizations.hcUnread]). Nothing when [count] <= 0.
class CircleUnreadPill extends StatelessWidget {
  final int count;
  const CircleUnreadPill({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final label = circleBadgeLabel(count, t.localeName);
    return Semantics(
      label: t.hcUnread(label),
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('circle_unread_pill'),
          constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: scheme.error,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              maxLines: 1,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: scheme.onError,
                  fontSize: 12,
                  height: 1.1,
                  fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}

/// [child] (an icon) with a small red "missed call" dot on its top-end
/// corner when [missed]; the dot reads [AppLocalizations.hcMissed].
class CircleBadgeDot extends StatelessWidget {
  final bool missed;
  final Widget child;
  const CircleBadgeDot({super.key, required this.missed, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!missed) return child;
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Stack(clipBehavior: Clip.none, children: [
      child,
      PositionedDirectional(
        top: -2,
        end: -3,
        child: Semantics(
          label: t.hcMissed,
          child: Container(
            key: const ValueKey('circle_missed_dot'),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: scheme.error,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 1.5),
            ),
          ),
        ),
      ),
    ]);
  }
}
