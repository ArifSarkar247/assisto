import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart';
import '../../widgets/circle_media_viewer.dart';
import '../msg_native.dart';
import 'media_descriptor.dart';

/// md1 — what the user can do with a decrypted file: view (pinch zoom),
/// save to the phone (gallery / Downloads), share, open a document in another
/// app. Copies leave Assisto's private storage ONLY on these taps.

Future<void> saveMediaToPhone(BuildContext context, File f, MediaDescriptor d) async {
  final t = AppLocalizations.of(context);
  try {
    final r = await MsgNative.saveToPhone(f.path, d.mime, d.name.isEmpty
        ? f.uri.pathSegments.last
        : d.name);
    if (!context.mounted) return;
    if (r == 'ok') {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.md1Saved)));
    } else if (r == 'unsupported') {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.md1SaveOld)));
      await shareMedia(context, f, d);
    } else {
      showActionFailed(context, 'md1_save', StateError(r));
    }
  } catch (e) {
    if (context.mounted) showActionFailed(context, 'md1_save', e);
  }
}

Future<void> shareMedia(BuildContext context, File f, MediaDescriptor d) async {
  try {
    await Share.shareXFiles([XFile(f.path, mimeType: d.mime, name: d.name.isEmpty ? null : d.name)]);
  } catch (e) {
    if (context.mounted) showActionFailed(context, 'md1_share', e, open: true);
  }
}

Future<void> openPhotoViewer(BuildContext context, File f, MediaDescriptor d) async {
  try {
    final bytes = await f.readAsBytes();
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => CircleMediaViewer(
        items: [MediaViewerItem(id: d.ref, bytes: bytes, caption: d.caption, cachedLocally: true)],
        onSave: (_) => saveMediaToPhone(ctx, f, d),
        onShare: (_) => shareMedia(ctx, f, d),
      ),
    ));
  } catch (e) {
    if (context.mounted) showActionFailed(context, 'md1_view', e, open: true);
  }
}

/// A document: Open (another app) / Save to phone / Share.
Future<void> openDocumentSheet(BuildContext context, File f, MediaDescriptor d) async {
  final t = AppLocalizations.of(context);
  final pick = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          title: Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        ListTile(
          key: const Key('md1-doc-open'),
          leading: const Icon(Icons.open_in_new),
          title: Text(t.md1Open),
          onTap: () => Navigator.pop(ctx, 'open'),
        ),
        ListTile(
          key: const Key('md1-doc-save'),
          leading: const Icon(Icons.save_alt_outlined),
          title: Text(t.md1Save),
          onTap: () => Navigator.pop(ctx, 'save'),
        ),
        ListTile(
          key: const Key('md1-doc-share'),
          leading: const Icon(Icons.share_outlined),
          title: Text(t.md1Share),
          onTap: () => Navigator.pop(ctx, 'share'),
        ),
      ]),
    ),
  );
  if (!context.mounted || pick == null) return;
  switch (pick) {
    case 'open':
      try {
        final r = await OpenFilex.open(f.path, type: d.mime);
        if (r.type != ResultType.done && context.mounted) {
          showActionFailed(context, 'md1_open_doc', StateError('${r.type}'), open: true);
        }
      } catch (e) {
        if (context.mounted) showActionFailed(context, 'md1_open_doc', e, open: true);
      }
    case 'save':
      await saveMediaToPhone(context, f, d);
    case 'share':
      await shareMedia(context, f, d);
  }
}
