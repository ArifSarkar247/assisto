import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'bubble_ask.dart'; // bubbles2
import 'bubble_card.dart'; // bubbles2
import 'msg_native.dart';
import 'msg_prefs.dart';

/// bubbles — the per-chat "Show as bubble" switch shared by the 1:1 and the
/// group chat ⋮ menus. Every chat is ON by default (owner 2 Nov).

/// The row's state: null = no bubbles on this phone (Android 10 and below,
/// iOS, tests without the native side) → the menu hides the row.
Future<bool?> loadChatBubble(String kind, int id) async {
  if (id <= 0) return null;
  if (!await MsgNative.bubblesSupported()) return null;
  return MsgPrefs.isBubbleChat(kind, id);
}

/// Flip the switch for one chat; returns the new state. Turning it ON when
/// Android itself blocks Assisto's bubbles explains once and offers the
/// system page (Android keeps that choice; we can't change it for the user).
Future<bool> toggleChatBubble(
    BuildContext context, String kind, int id, bool current) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final next = !current;
  await MsgPrefs.setBubbleChat(kind, id, next);
  if (!next) unawaited(MsgNative.removeBubble(kind, id));
  messenger?.showSnackBar(
      SnackBar(content: Text(next ? t.c3BubbleOnDone : t.c3BubbleOffDone)));
  // bubbles2: turning it ON while the phone doesn't allow Assisto's
  // bubbles → the same "Turn on floating chat bubbles?" card (Android keeps
  // that choice; the user picks "All conversations can bubble").
  if (next && context.mounted) {
    final st = await BubbleAsk.status();
    if (st.askable && context.mounted) await showBubbleCard(context, initial: st);
  }
  return next;
}
