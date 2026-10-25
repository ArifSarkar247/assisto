import 'package:flutter/material.dart';

import 'chat_decor/chat_themes.dart';

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
      return Icons.schedule_rounded;
    case MsgTick.sent:
      return Icons.done_rounded;
    case MsgTick.delivered:
    case MsgTick.read:
      return Icons.done_all_rounded;
    case MsgTick.failed:
      return Icons.error_outline_rounded;
  }
}

/// x2-ticks — the OUTGOING bubble + tick palette (WhatsApp-like, owner
/// order 22 Oct: on the old brand-blue bubble a blue ✓✓ was invisible).
/// WCAG (checked): light bubble #D9FDD3 — text #0B141A 16.8:1, grey ticks /
/// time #5B6B63 5.1:1, read ticks #0E86D4 3.5:1; dark bubble #005C4B — text
/// #E9EDEF 6.8:1, grey #AEBAC1 4.0:1, read #34B7F1 3.5:1. On plain surfaces
/// (chat list, group cards, Message info) read is #0E86D4 (3.9:1 on white)
/// / #34B7F1 (8.2:1 on dark). Grey vs bright blue also differs in HUE, so the
/// three states never look alike.
class MsgPalette {
  MsgPalette._();
  static const outLight = Color(0xFFD9FDD3);
  static const outLightText = Color(0xFF0B141A);
  static const outLightMeta = Color(0xFF5B6B63);
  static const outDark = Color(0xFF005C4B);
  static const outDarkText = Color(0xFFE9EDEF);
  static const outDarkMeta = Color(0xFFAEBAC1);
  static const readLight = Color(0xFF0E86D4);
  static const readDark = Color(0xFF34B7F1);

  static bool _dark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;
  // cde-chat: inside a themed chat the theme's own bubble colours win.
  static Color outBubble(BuildContext c) =>
      ChatThemeScope.of(c)?.outBubble ?? (_dark(c) ? outDark : outLight);
  static Color outText(BuildContext c) =>
      ChatThemeScope.of(c)?.outText ?? (_dark(c) ? outDarkText : outLightText);
  static Color outMeta(BuildContext c) =>
      ChatThemeScope.of(c)?.outMeta ?? (_dark(c) ? outDarkMeta : outLightMeta);
}

/// The "seen" bright blue — the same hue on my bubble and on surfaces.
Color readTickColor(BuildContext context, {bool onMyBubble = false}) {
  // cde-chat: a themed bubble keeps the blue ticks visible on its colour
  final th = ChatThemeScope.of(context);
  if (th != null && onMyBubble) {
    return th.outText.computeLuminance() > 0.5
        ? const Color(0xFF8FE3FF)
        : const Color(0xFF0B57D0);
  }
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? MsgPalette.readDark : MsgPalette.readLight;
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
      // x2-ticks: ✓ and ✓✓ stay a solid, readable grey (no alpha games).
      _ => onMyBubble ? MsgPalette.outMeta(context) : baseColor,
    };
    return Icon(tickIcon(tick),
        key: ValueKey('tick-${tick.name}'), size: size, color: color);
  }
}
