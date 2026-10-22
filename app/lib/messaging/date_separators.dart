import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// t1-ticks — WhatsApp-standard date separators for My Circle chats (1:1 and
/// groups), list-agnostic so they plug into any message list (plain or a
/// reversed / paged one):
///
///   * [insertDateSeparators] — PURE: interleaves one [ChatDateRow] before
///     each calendar day's first message (local day, injectable timezone).
///   * [DateSeparatorChip]    — the centred "Today / Yesterday / Monday /
///     18 Oct 2026" chip (bn: the ARB words, Bangla weekday/month + digits).
///   * [ChatDateScope] + [ChatDayMarker] — the floating date chip at the top
///     while scrolling (fades out when idle). Wrap the list in the scope and
///     each message row in a marker; the chip shows the day of the row under
///     the top edge, found geometrically, so it works for reversed lists too.

// ---------------------------------------------------------------------------
// pure: rows
// ---------------------------------------------------------------------------
sealed class ChatRow<T> {
  const ChatRow();
}

/// One message (or any list item) and its local calendar day.
class ChatItemRow<T> extends ChatRow<T> {
  final T item;
  final DateTime? day;
  const ChatItemRow(this.item, this.day);
}

/// A centred date chip for [day] (local midnight).
class ChatDateRow<T> extends ChatRow<T> {
  final DateTime day;
  const ChatDateRow(this.day);
  @override
  bool operator ==(Object other) => other is ChatDateRow && other.day == day;
  @override
  int get hashCode => day.hashCode;
}

/// Local calendar day (midnight) of [at]. [toLocal] converts an instant to
/// wall-clock time (default: the phone's zone) — tests pass a fixed offset,
/// e.g. Asia/Dhaka = UTC+6 (no DST).
DateTime localDay(DateTime at, {DateTime Function(DateTime)? toLocal}) {
  final l = toLocal != null ? toLocal(at) : at.toLocal();
  return DateTime(l.year, l.month, l.day);
}

/// Asia/Dhaka wall-clock (UTC+6, no daylight saving) — for tests and for any
/// caller that must not depend on the phone's zone setting.
DateTime dhakaWallClock(DateTime at) {
  final u = at.toUtc().add(const Duration(hours: 6));
  return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
}

/// Interleave a [ChatDateRow] before the first message of every local day.
///
/// [items] are in DISPLAY order: oldest → newest normally, or newest → oldest
/// when [newestFirst] (a `reverse: true` ListView). In the newest-first case
/// the separator is placed AFTER the day's oldest item, which a reversed list
/// paints ABOVE that day's messages. Items whose time is unknown (`atOf`
/// returns null) stay with the day before them and never start a day.
List<ChatRow<T>> insertDateSeparators<T>(
  List<T> items,
  DateTime? Function(T) atOf, {
  bool newestFirst = false,
  DateTime Function(DateTime)? toLocal,
}) {
  final chrono = newestFirst ? items.reversed.toList() : items;
  final out = <ChatRow<T>>[];
  DateTime? current;
  for (final it in chrono) {
    final at = atOf(it);
    final day = at == null ? current : localDay(at, toLocal: toLocal);
    if (day != null && day != current) {
      out.add(ChatDateRow<T>(day));
      current = day;
    }
    out.add(ChatItemRow<T>(it, day));
  }
  return newestFirst ? out.reversed.toList() : out;
}

// ---------------------------------------------------------------------------
// pure: labels
// ---------------------------------------------------------------------------
const _latin = '0123456789';

/// Bangla digits for 'bn' (idempotent; intl usually already returns them —
/// this guarantees it even when the locale data falls back).
String localDigits(String s, String lang) {
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final r in s.runes) {
    final i = _latin.indexOf(String.fromCharCode(r));
    b.writeCharCode(i >= 0 ? 0x09E6 + i : r);
  }
  return b.toString();
}

/// `DateFormat(pattern, lang)` with a safe English fallback (locale data not
/// initialised) and Bangla digits for 'bn'.
String fmtDate(String pattern, DateTime d, String lang) {
  final loc = lang == 'bn' ? 'bn' : 'en';
  String s;
  try {
    s = DateFormat(pattern, loc).format(d);
  } catch (_) {
    s = DateFormat(pattern, 'en').format(d);
  }
  return localDigits(s, loc);
}

/// 24-hour "12:45" (bn: Bangla digits).
String fmtTime(DateTime d, String lang) => fmtDate('HH:mm', d, lang);

/// The chip text for [day]: Today / Yesterday / weekday (2–6 days ago) /
/// "18 Oct 2026" (bn: "d MMMM y" with Bangla month + digits).
String dateChipLabel(AppLocalizations t, DateTime day,
    {required String lang, DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final d = DateTime(day.year, day.month, day.day);
  // rounded hours/24 (not inDays) stays right across a DST change.
  final diff = (today.difference(d).inHours / 24).round();
  if (diff == 0) return t.t1Today;
  if (diff == 1) return t.t1Yesterday;
  if (diff > 1 && diff < 7) return fmtDate('EEEE', d, lang);
  return fmtDate(lang == 'bn' ? 'd MMMM y' : 'd MMM y', d, lang);
}

// ---------------------------------------------------------------------------
// widgets
// ---------------------------------------------------------------------------
class DateSeparatorChip extends StatelessWidget {
  final DateTime day;
  final DateTime? now;

  /// Floating variant: a touch more elevation so it reads over bubbles.
  final bool floating;
  const DateSeparatorChip(
      {super.key, required this.day, this.now, this.floating = false});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final label = dateChipLabel(t, day, lang: lang, now: now);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Material(
          color: dark
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerHigh,
          elevation: floating ? 2 : 0.5,
          shadowColor: Colors.black26,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              label,
              key: ValueKey('t1-date-${day.toIso8601String()}'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.78),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating date chip host. Put it AROUND the message list; it listens to the
/// list's scroll notifications (no controller needed) and shows the day of
/// the [ChatDayMarker] under its top edge, fading out [idle] after scrolling
/// stops.
class ChatDateScope extends StatefulWidget {
  final Widget child;
  final Duration idle;
  final DateTime? now;
  const ChatDateScope(
      {super.key,
      required this.child,
      this.idle = const Duration(milliseconds: 1400),
      this.now});

  @override
  State<ChatDateScope> createState() => ChatDateScopeState();
}

class ChatDateScopeState extends State<ChatDateScope> {
  final Set<_ChatDayMarkerState> _markers = {};
  DateTime? _day;
  bool _shown = false;
  Timer? _hide;

  /// The day the floating chip shows (null = none) — for tests.
  DateTime? get floatingDay => _shown ? _day : null;

  void _add(_ChatDayMarkerState m) => _markers.add(m);
  void _remove(_ChatDayMarkerState m) => _markers.remove(m);

  DateTime? _topDay() {
    final host = context.findRenderObject();
    if (host is! RenderBox || !host.hasSize) return null;
    const probe = 12.0; // a little below the top edge, under the chip
    DateTime? covering;
    double? coveringTop;
    DateTime? below;
    double? belowTop;
    for (final m in _markers) {
      final ro = m.context.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final y = ro.localToGlobal(Offset.zero, ancestor: host).dy;
      final bottom = y + ro.size.height;
      if (y <= probe && bottom > probe) {
        if (coveringTop == null || y > coveringTop) {
          covering = m.widget.day;
          coveringTop = y;
        }
      } else if (y > probe && (belowTop == null || y < belowTop)) {
        below = m.widget.day;
        belowTop = y;
      }
    }
    return covering ?? below;
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollUpdateNotification || n is OverscrollNotification) {
      final d = _topDay();
      _hide?.cancel();
      if (d != _day || !_shown) {
        setState(() {
          _day = d;
          _shown = d != null;
        });
      }
    } else if (n is ScrollEndNotification) {
      _hide?.cancel();
      _hide = Timer(widget.idle, () {
        if (mounted && _shown) setState(() => _shown = false);
      });
    }
    return false;
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          Positioned(
            top: 2,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: const Key('t1-floating-date'),
                opacity: _shown && _day != null ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                child: _day == null
                    ? const SizedBox.shrink()
                    : DateSeparatorChip(
                        day: _day!, now: widget.now, floating: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wrap each message row so the floating chip knows its day. A no-op outside
/// a [ChatDateScope].
class ChatDayMarker extends StatefulWidget {
  final DateTime? day;
  final Widget child;
  const ChatDayMarker({super.key, required this.day, required this.child});

  @override
  State<ChatDayMarker> createState() => _ChatDayMarkerState();
}

class _ChatDayMarkerState extends State<ChatDayMarker> {
  ChatDateScopeState? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.findAncestorStateOfType<ChatDateScopeState>();
    if (s != _scope) {
      _scope?._remove(this);
      _scope = s;
    }
    if (widget.day != null) _scope?._add(this);
  }

  @override
  void didUpdateWidget(ChatDayMarker old) {
    super.didUpdateWidget(old);
    if (widget.day == null) {
      _scope?._remove(this);
    } else {
      _scope?._add(this);
    }
  }

  @override
  void dispose() {
    _scope?._remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Convenience for a ListView item builder over [rows]: a chip for a date
/// row, else [buildItem] wrapped in a [ChatDayMarker].
Widget buildChatRow<T>(ChatRow<T> row, Widget Function(T item) buildItem) {
  return switch (row) {
    ChatDateRow<T>(:final day) => DateSeparatorChip(day: day),
    ChatItemRow<T>(:final item, :final day) =>
      ChatDayMarker(day: day, child: buildItem(item)),
  };
}
