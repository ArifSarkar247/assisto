import 'package:flutter/material.dart';

/// c3-msg — WhatsApp-standard message ticks (sender view).
///
///   pending   clock      queued on this phone, not on the server yet
///   sent      ✓          the relay stored it (server `status: sent`)
///   delivered ✓✓ grey    every recipient's DEVICE fetched it
///   read      ✓✓ blue    every recipient opened the chat (and read receipts
///                        are on for both sides — reciprocal, server-decided)
///   failed    !          the send failed (tap to retry)
enum MsgTick { pending, sent, delivered, read, failed }

/// Map the server's `status` string (+ local flags) to a tick. Unknown /
/// missing statuses are honest "sent" (the row exists on the server).
MsgTick tickFrom(String? status, {bool pending = false, bool failed = false}) {
  if (failed) return MsgTick.failed;
  if (pending) return MsgTick.pending;
  switch ((status ?? '').trim()) {
    case 'read':
    case 'seen':
      return MsgTick.read;
    case 'delivered':
      return MsgTick.delivered;
    case 'failed':
      return MsgTick.failed;
    default:
      return MsgTick.sent;
  }
}

/// Never let a fresher poll downgrade a tick (a late "sent" after "read").
MsgTick maxTick(MsgTick a, MsgTick b) {
  if (a == MsgTick.failed || b == MsgTick.failed) {
    return a == MsgTick.failed ? b : a;
  }
  return a.index >= b.index ? a : b;
}

IconData tickIcon(MsgTick t) {
  switch (t) {
    case MsgTick.pending:
      return Icons.schedule;
    case MsgTick.sent:
      return Icons.done;
    case MsgTick.delivered:
    case MsgTick.read:
      return Icons.done_all;
    case MsgTick.failed:
      return Icons.error_outline;
  }
}

/// The "seen" blue. On a surface (chat list) it is a saturated blue; on my own
/// (brand-blue) bubble it is a light cyan that still clears 3:1 against the
/// bubble, and distinct from the white-ish "delivered" ticks.
Color readTickColor(BuildContext context, {bool onMyBubble = false}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (onMyBubble) {
    return dark ? const Color(0xFF0030C0) : const Color(0xFF67E8F9);
  }
  return dark ? const Color(0xFF53BDEB) : const Color(0xFF0B7FD1);
}

/// One tick glyph. [baseColor] is the muted meta colour for sent/delivered.
class TickIcon extends StatelessWidget {
  final MsgTick tick;
  final Color baseColor;
  final bool onMyBubble;
  final double size;
  const TickIcon(
      {super.key,
      required this.tick,
      required this.baseColor,
      this.onMyBubble = false,
      this.size = 15});

  @override
  Widget build(BuildContext context) {
    final color = switch (tick) {
      MsgTick.read => readTickColor(context, onMyBubble: onMyBubble),
      MsgTick.failed => Theme.of(context).colorScheme.error,
      // on my bubble the grey ticks are dimmed so the "seen" colour pops
      _ => onMyBubble ? baseColor.withValues(alpha: 0.6) : baseColor,
    };
    return Icon(tickIcon(tick),
        key: ValueKey('tick-${tick.name}'), size: size, color: color);
  }
}
