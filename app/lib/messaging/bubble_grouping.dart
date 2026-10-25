import 'date_separators.dart';

/// wa-polish2 — WhatsApp bubble grouping for My Circle chats (1:1 + groups).
///
/// Consecutive messages from the SAME sender within [kBubbleRunGap] form one
/// "run": tight spacing, and only the run's FIRST (oldest, top) bubble gets
/// the tail (1:1) or the sender name (groups). A date chip, an unread
/// divider, a call event or a system line between two messages always
/// starts a new run. PURE — no widgets, no I/O.

/// How far apart two messages from one sender may be and still be one run.
const Duration kBubbleRunGap = Duration(minutes: 3);

/// True when the message ([sender], [at]) continues the run of the message
/// just OLDER than it ([olderSender], [olderAt]). A null sender = "not a
/// groupable bubble" (system line, call chip, divider…) → never a run.
bool sameBubbleRun({
  required String? olderSender,
  required DateTime? olderAt,
  required String? sender,
  required DateTime? at,
  Duration gap = kBubbleRunGap,
}) {
  if (olderSender == null || sender == null || olderSender != sender) {
    return false;
  }
  if (olderAt == null || at == null) return false;
  return at.difference(olderAt).abs() <= gap;
}

/// For a NEWEST-FIRST row list (a `reverse: true` chat ListView, as built by
/// [insertDateSeparators] with `newestFirst: true`): does `rows[i]` continue
/// the run of the older row at `i + 1`? Date chips / the E2E notice are not
/// items, so they break a run.
bool continuesOlderRow<T>(
  List<ChatRow<T>> rows,
  int i, {
  required String? Function(T item) senderOf,
  required DateTime? Function(T item) atOf,
  Duration gap = kBubbleRunGap,
}) {
  if (i < 0 || i + 1 >= rows.length) return false;
  final cur = rows[i];
  final older = rows[i + 1];
  if (cur is! ChatItemRow<T> || older is! ChatItemRow<T>) return false;
  return sameBubbleRun(
    olderSender: senderOf(older.item),
    olderAt: atOf(older.item),
    sender: senderOf(cur.item),
    at: atOf(cur.item),
    gap: gap,
  );
}
