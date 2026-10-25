import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../services/error_report.dart';
import '../theme.dart';
import '../widgets/msgr_channel_common.dart' show msgrLocalizeDigits;
import 'media/media_store.dart';
import 'preview_cache.dart';
import 'unread_store.dart';

/// chat-actions (owner 26 Oct) — WhatsApp-style chat actions shared by the
/// chat list, the 1:1 chat and the group chat.
///
/// Every action here is metadata on rows the server already holds as
/// CIPHERTEXT ONLY; nothing is decrypted or re-encrypted, so E2E is untouched.
///   * Delete chat — hides the conversation from MY list (server marker, so a
///     reinstall / another phone agrees) and wipes this phone's copies; the
///     person stays in My Circle (membership is never touched).
///   * Clear chat  — every message removed for me, the row stays; optional
///     "Keep starred messages".
extension ChatActionsApi on ApiClient {
  /// POST /circle/<id>/delete-chat or /circle/groups/<id>/delete-chat.
  /// [chatKey] is 'member:<edge id>' | 'group:<group id>'.
  Future<Map<String, dynamic>> deleteChatFor(String chatKey,
          {bool deleteMedia = false}) =>
      postJson('${chatActionBase(chatKey)}/delete-chat',
          {'delete_media': deleteMedia});

  /// POST …/clear {keep_starred}.
  Future<Map<String, dynamic>> clearChatFor(String chatKey,
          {bool keepStarred = false}) =>
      postJson('${chatActionBase(chatKey)}/clear', {'keep_starred': keepStarred});

  /// GET/POST /circle/settings/default-timer {ttl: off|24h|7d|90d}.
  Future<Map<String, dynamic>> defaultTimer() =>
      getJson('/circle/settings/default-timer');
  Future<Map<String, dynamic>> setDefaultTimer(int seconds) => postJson(
      '/circle/settings/default-timer', {'ttl': timerTokenOf(seconds)});
}

/// '/circle/12' | '/circle/groups/5' for a chat key.
String chatActionBase(String chatKey) {
  final i = chatKey.indexOf(':');
  final id = chatKey.substring(i + 1);
  return chatKey.startsWith('group:') ? '/circle/groups/$id' : '/circle/$id';
}

const Map<int, String> kTimerTokens = {
  0: 'off',
  86400: '24h',
  604800: '7d',
  7776000: '90d',
};

String timerTokenOf(int sec) => kTimerTokens[sec] ?? 'off';

/// "Off" / "24 hours" / "7 days" / "90 days" in the app language.
String timerLabel(AppLocalizations t, int sec) {
  switch (sec) {
    case 86400:
      return t.msgrChatDisap24h;
    case 604800:
      return t.msgrChatDisap7d;
    case 7776000:
      return t.msgrChatDisap90d;
    default:
      return t.msgrChatDisapOff;
  }
}

/// Wipe what THIS phone made from a chat: the decrypted media files (only
/// when [deleteMedia]), the cached preview and the unread badge. Never throws.
Future<int> wipeChatLocally(String chatKey,
    {List<String> mediaRefs = const [], bool deleteMedia = false}) async {
  var n = 0;
  try {
    await PreviewCache.instance.dropChat(chatKey);
    UnreadStore.instance.clear(chatKey);
    if (deleteMedia && mediaRefs.isNotEmpty) {
      final root = MediaDirs.rootSync ?? await MediaDirs.root();
      final dir = Directory('$root/files');
      if (dir.existsSync()) {
        final refs = mediaRefs.where((r) => r.isNotEmpty && !r.contains('/')).toSet();
        for (final f in dir.listSync().whereType<File>()) {
          final name = f.uri.pathSegments.last;
          final dot = name.lastIndexOf('.');
          final ref = dot > 0 ? name.substring(0, dot) : name;
          if (refs.contains(ref)) {
            f.deleteSync();
            n++;
          }
        }
      }
    }
  } catch (e) {
    reportNonFatal('ca_wipe_local', e);
  }
  return n;
}

List<String> mediaRefsOf(Map<String, dynamic> r) =>
    ((r['media_refs'] as List?) ?? const []).map((e) => '$e').toList();

/// Confirm "Delete this chat?" with an "Also delete media" checkbox.
/// null = cancelled; otherwise the checkbox value.
Future<bool?> showDeleteChatDialog(BuildContext context,
    {required String name, required bool group, int count = 1}) {
  final t = AppLocalizations.of(context);
  final bn = Localizations.localeOf(context).languageCode == 'bn';
  final many = count > 1;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => _CheckDialog(
      key: const Key('ca-delete-dialog'),
      title: many
          ? t.caDeleteChatsTitle(msgrLocalizeDigits('$count', bn))
          : t.caDeleteChatTitle,
      body: many
          ? t.caDeleteChatsBody
          : (group ? t.caDeleteGroupChatBody : t.caDeleteChatBody(name)),
      checkLabel: t.caAlsoDeleteMedia,
      checkKey: const Key('ca-delete-media'),
      confirm: t.caDeleteChat,
      confirmKey: const Key('ca-delete-confirm'),
    ),
  );
}

/// Confirm "Clear this chat?" with "Keep starred messages".
/// null = cancelled; otherwise keep-starred.
Future<bool?> showClearChatDialog(BuildContext context) {
  final t = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => _CheckDialog(
      key: const Key('ca-clear-dialog'),
      title: t.caClearChatTitle,
      body: t.caClearChatBody,
      checkLabel: t.caKeepStarred,
      checkKey: const Key('ca-keep-starred'),
      initial: true,
      confirm: t.caClearChat,
      confirmKey: const Key('ca-clear-confirm'),
    ),
  );
}

class _CheckDialog extends StatefulWidget {
  final String title, body, checkLabel, confirm;
  final Key checkKey, confirmKey;
  final bool initial;
  const _CheckDialog({
    super.key,
    required this.title,
    required this.body,
    required this.checkLabel,
    required this.checkKey,
    required this.confirm,
    required this.confirmKey,
    this.initial = false,
  });

  @override
  State<_CheckDialog> createState() => _CheckDialogState();
}

class _CheckDialogState extends State<_CheckDialog> {
  late bool _on = widget.initial;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: Gap.sm),
            CheckboxListTile(
              key: widget.checkKey,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _on,
              onChanged: (v) => setState(() => _on = v ?? false),
              title: Text(widget.checkLabel),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
          key: widget.confirmKey,
          style: FilledButton.styleFrom(
              backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: () => Navigator.pop(context, _on),
          child: Text(widget.confirm),
        ),
      ],
    );
  }
}

/// The small timer glyph on a chat row / chat header when disappearing
/// messages are on (screen readers say so).
class ChatTimerIcon extends StatelessWidget {
  final int seconds;
  final double size;
  final Color? color;
  const ChatTimerIcon({super.key, required this.seconds, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    if (seconds <= 0) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    return Semantics(
      label: '${t.caTimerOn} · ${timerLabel(t, seconds)}',
      child: Tooltip(
        message: '${t.caTimerOn} · ${timerLabel(t, seconds)}',
        child: Icon(Icons.timer_outlined,
            key: const Key('ca-timer-icon'),
            size: size,
            color: color ?? Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
