import 'dart:io';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/circle_attach_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'album.dart'; // circlemedia
import 'album_send_preview.dart'; // circlemedia
import 'media_descriptor.dart';
import 'media_outbox.dart';
import 'media_prep.dart';
import 'multi_pick.dart'; // circlemedia
import 'photo_prep.dart'; // circlemedia
import 'video_prep.dart';
import 'media_limits.dart'; // viewonce
import 'video_limits_flow.dart'; // viewonce
import '../view_once.dart' show ViewOnceSwitch; // viewonce
import 'view_once_toggle.dart'; // circlemedia
import 'voice_recorder_sheet.dart';

export 'media_limits.dart'; // viewonce: MediaLimits moved there

/// md1 — the chat side of sending media: pick → (preview + caption) →
/// queue in the persistent media outbox. Shared by 1:1 and group chats.

/// Content types that carry an E2E media descriptor.
const Set<String> kMd1Kinds = {'photo', 'voice', 'document', 'video'}; // mc-media2: + video

/// "Photo" / "Voice message" / the document's name — for reply quotes.
String md1KindLabel(AppLocalizations t, MediaDescriptor d) => switch (d.kind) {
      'photo' => t.circlePhoto,
      'voice' => t.circleVoiceNote,
      'video' => t.circleVideo,
      _ => d.name.isEmpty ? t.circleAttachDocument : d.name,
    };

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

/// Run the picker for [kind]. null = cancelled (or an honest message shown).
/// [onRecording]: see [showVoiceRecorder] (voice only).
Future<MediaDraft?> pickMediaDraft(
    BuildContext context, ApiClient api, CircleAttachKind kind,
    {ValueChanged<bool>? onRecording}) async {
  final t = AppLocalizations.of(context);
  await MediaLimits.load(api);
  if (!context.mounted) return null;
  try {
    MediaDraft? d;
    switch (kind) {
      case CircleAttachKind.gallery:
        d = await pickPhoto(context, camera: false);
      case CircleAttachKind.camera:
        d = await pickPhoto(context, camera: true);
      case CircleAttachKind.voice:
        d = await showVoiceRecorder(context, onRecording: onRecording);
      case CircleAttachKind.document:
        d = await pickDocument(MediaLimits.document);
      case CircleAttachKind.video:
        // viewonce (owner 3 Nov): longer than 3 min -> trim screen; then
        // compressed on the phone to 720p, under 25 MB (owner-editable)
        d = await pickVideo(kRawVideoPickMax);
        if (d != null) {
          if (!context.mounted) return null;
          d = await prepareVideoForSend(context, d);
        }
      default:
        return null; // not offered (circleAttachKinds)
    }
    if (d == null) return null;
    if (d.size > MediaLimits.of(d.kind)) {
      _deleteQuietly(d.path);
      if (context.mounted) {
        _toast(context,
            t.md1TooBig(notifLocalizeDigits(context, '${MediaLimits.of(d.kind) ~/ (1024 * 1024)}')));
      }
      return null;
    }
    return d;
  } on MediaPickError catch (e) {
    if (context.mounted) {
      _toast(
          context,
          e.code == 'too_big'
              ? t.md1TooBig(notifLocalizeDigits(context,
                  '${(kind == CircleAttachKind.video ? MediaLimits.video : MediaLimits.document) ~/ (1024 * 1024)}'))
              : t.md1PickFailed);
    }
    return null;
  } catch (e) {
    if (context.mounted) showActionFailed(context, 'md1_pick', e);
    return null;
  }
}

void _deleteQuietly(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (e) {
    reportNonFatal('md1_draft_cleanup', e);
  }
}

/// Photo: full-screen preview + caption; document: a confirm with name and
/// size; voice: straight from the recorder. Then the job is queued.
Future<MediaJob?> confirmAndQueueMedia(BuildContext context, MediaDraft d,
    {required String chatKind, required int chatId, String? replyTo}) async {
  String caption = '';
  var viewOnce = false;
  if (d.kind == 'photo') {
    final c = await Navigator.of(context).push<PhotoSendChoice>(MaterialPageRoute(
        fullscreenDialog: true,
        // e-gaps: view-once is offered in 1:1 chats
        // viewonce: groups too (each member opens once, server-enforced)
        builder: (_) => PhotoSendPreview(draft: d, allowViewOnce: true)));
    if (c == null) {
      _deleteQuietly(d.path);
      return null;
    }
    caption = c.caption;
    viewOnce = c.viewOnce;
  } else if (d.kind == 'document' || d.kind == 'video') {
    var vo = false; // viewonce: the "1" next to Send (video only)
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = AppLocalizations.of(ctx);
        return StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
          scrollable: true, // insets: 200% text / keyboard
          title: Text(d.kind == 'video' ? t.mc2VideoSendTitle : t.md1DocSendTitle),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
            // viewonce: the size AFTER the 720p compression, before Send
            Text(d.kind == 'video'
                ? t.mc2VideoSendBody(notifLocalizeDigits(ctx,
                    '${mediaSizeLabel(d.size)}${d.durationMs == null ? '' : ' · ${mediaDurationLabel(d.durationMs!)}'}'))
                : t.md1DocSendBody(notifLocalizeDigits(ctx, mediaSizeLabel(d.size))),
                key: const Key('vo1-send-size')),
          ]),
          actions: [
            if (d.kind == 'video')
              ViewOnceSwitch(value: vo, onChanged: (v) => setLocal(() => vo = v)),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.md1Cancel)),
            FilledButton(
                key: const Key('md1-doc-send'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.md1Send)),
          ],
        ));
      },
    );
    if (ok != true) {
      _deleteQuietly(d.path);
      return null;
    }
    viewOnce = vo;
  } else if (d.kind == 'voice') {
    viewOnce = d.viewOnce; // viewonce: the recorder's "1"
  }
  final job = MediaJob(
    id: newMediaId(),
    chatKind: chatKind,
    chatId: chatId,
    kind: d.kind,
    srcPath: d.path,
    name: d.name,
    mime: d.mime,
    plainSize: d.size,
    at: DateTime.now(),
    width: d.width,
    height: d.height,
    durationMs: d.durationMs,
    wave: d.wave,
    thumbB64: viewOnce ? '' : d.thumbB64, // e-gaps / viewonce: no preview
    caption: caption.trim(),
    replyTo: replyTo,
    viewOnce: viewOnce,
  );
  try {
    await MediaOutbox.instance.add(job);
  } catch (e) {
    if (context.mounted) showActionFailed(context, 'md1_queue', e);
    return null;
  }
  return job;
}

/// What the photo preview returns: the caption + e-gaps view-once choice.
class PhotoSendChoice {
  final String caption;
  final bool viewOnce;
  const PhotoSendChoice(this.caption, {this.viewOnce = false});
}

/// WhatsApp-like photo preview: the picture, a caption box, Send.
class PhotoSendPreview extends StatefulWidget {
  final MediaDraft draft;

  /// e-gaps: show the "1" (view once) toggle.
  final bool allowViewOnce;

  /// The toggle's starting state (gallery shots).
  final bool initialViewOnce;
  const PhotoSendPreview(
      {super.key, required this.draft, this.allowViewOnce = false, this.initialViewOnce = false});
  @override
  State<PhotoSendPreview> createState() => _PhotoSendPreviewState();
}

class _PhotoSendPreviewState extends State<PhotoSendPreview> {
  final _caption = TextEditingController();
  late bool _viewOnce = widget.initialViewOnce;

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: t.md1Cancel,
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(children: [
        Expanded(
          child: InteractiveViewer(
            maxScale: 4,
            child: Center(
              child: Image.file(File(widget.draft.path),
                  fit: BoxFit.contain,
                  cacheWidth: 1080,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 64)),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.md),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('md1-caption'),
                  controller: _caption,
                  minLines: 1,
                  maxLines: 4,
                  textAlignVertical: TextAlignVertical.center, // a11y1
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: t.md1CaptionHint,
                    hintStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Colors.white12,
                    border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(Radii.pill)),
                        borderSide: BorderSide.none),
                    // a11y1: 48 dp tall field (was 40).
                    constraints: const BoxConstraints(minHeight: kMinTap),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
                  ),
                ),
              ),
              if (widget.allowViewOnce) ...[
                const SizedBox(width: Gap.xs),
                ViewOnceToggle( // circlemedia: shared with the album preview
                    value: _viewOnce,
                    onChanged: (v) => setState(() => _viewOnce = v)),
              ],
              const SizedBox(width: Gap.sm),
              IconButton.filled(
                key: const Key('md1-photo-send'),
                tooltip: t.md1Send,
                onPressed: () => Navigator.pop(
                    context, PhotoSendChoice(_caption.text, viewOnce: _viewOnce)),
                icon: const Icon(Icons.send_rounded),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- circlemedia
/// circlemedia: gallery (up to [MediaLimits.photosPerSend] photos AND videos
/// at once) or camera → the album preview (swipe, remove, crop, rotate, one
/// caption, HD / Standard) → queued in the media outbox, one E2E message per
/// item, grouped back into ONE album bubble on every phone.
/// Returns the queued jobs ([] = cancelled / nothing usable).
Future<List<MediaJob>> pickPreviewAndQueuePhotos(BuildContext context, ApiClient api,
    {required bool camera,
    required String chatKind,
    required int chatId,
    String? replyTo}) async {
  final t = AppLocalizations.of(context);
  await MediaLimits.load(api);
  if (!context.mounted) return const [];
  final limit = MediaLimits.photosPerSend.clamp(1, 100);
  List<MediaDraft> drafts;
  try {
    if (camera) {
      final d = await pickPhoto(context, camera: true, maxEdge: kHdEdge, quality: kHdQuality);
      drafts = [if (d != null) d];
    } else {
      final r = await pickMultiDrafts(limit: limit, videoMax: kRawVideoPickMax);
      if (r == null) return const [];
      if (context.mounted) _multiNotes(context, r, limit);
      drafts = r.drafts;
    }
  } on MediaPickError {
    if (context.mounted) _toast(context, t.md1PickFailed);
    return const [];
  } catch (e) {
    if (context.mounted) showActionFailed(context, 'cm_pick', e);
    return const [];
  }
  if (!context.mounted) return const [];
  drafts = await _videosToRule(context, drafts);
  if (!context.mounted) return const [];
  drafts = _withinCaps(context, drafts);
  if (drafts.isEmpty || !context.mounted) return const [];
  final choice = await Navigator.of(context).push<AlbumSendChoice>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => AlbumSendPreview(
      drafts: drafts,
      limit: limit,
      // viewonce: groups support view once too (each member opens once)
      allowViewOnce: true,
      onAddMore: (left) async {
        try {
          final r = await pickMultiDrafts(limit: left, videoMax: kRawVideoPickMax);
          if (r == null) return const [];
          if (!context.mounted) return r.drafts;
          _multiNotes(context, r, limit);
          final ok = await _videosToRule(context, r.drafts);
          return context.mounted ? _withinCaps(context, ok) : ok;
        } catch (e) {
          reportNonFatal('cm_add_more', e);
          return const [];
        }
      },
    ),
  ));
  if (choice == null || choice.items.isEmpty) return const [];
  try {
    return await queueAlbumChoice(choice,
        chatKind: chatKind, chatId: chatId, replyTo: replyTo);
  } catch (e) {
    if (context.mounted) showActionFailed(context, 'cm_queue', e);
    return const [];
  }
}

/// circlemedia + viewonce: every video in an album follows the owner's video
/// rule exactly like a single video (longer than the limit -> trim screen;
/// compressed on the phone to 720p under the size cap). A video the user
/// does not trim is left out; photos pass through untouched.
Future<List<MediaDraft>> _videosToRule(BuildContext context, List<MediaDraft> drafts) async {
  final out = <MediaDraft>[];
  for (final d in drafts) {
    if (d.kind != 'video') {
      out.add(d);
      continue;
    }
    if (!context.mounted) {
      _deleteQuietly(d.path);
      continue;
    }
    try {
      final v = await prepareVideoForSend(context, d);
      if (v != null) out.add(v);
    } catch (e) {
      reportNonFatal('cm_album_video', e);
      _deleteQuietly(d.path);
    }
  }
  return out;
}

void _multiNotes(BuildContext context, MultiPickResult r, int limit) {
  final t = AppLocalizations.of(context);
  final lines = <String>[
    if (r.overLimit > 0) t.cmLimitNote('$limit'),
    if (r.tooBig > 0) t.cmVideoTooBig('${r.tooBig}', '${kRawVideoPickMax ~/ (1024 * 1024)}'),
    if (r.failed > 0) t.cmSomeFailed('${r.failed}'),
  ];
  if (lines.isNotEmpty) _toast(context, notifLocalizeDigits(context, lines.join('\n')));
}

/// Drop (and delete) photos over the per-file cap; tell the user once.
List<MediaDraft> _withinCaps(BuildContext context, List<MediaDraft> drafts) {
  final keep = <MediaDraft>[];
  var dropped = 0;
  for (final d in drafts) {
    if (d.size > MediaLimits.of(d.kind)) {
      _deleteQuietly(d.path);
      dropped++;
    } else {
      keep.add(d);
    }
  }
  if (dropped > 0 && context.mounted) {
    final t = AppLocalizations.of(context);
    _toast(context,
        t.md1TooBig(notifLocalizeDigits(context, '${MediaLimits.photo ~/ (1024 * 1024)}')));
  }
  return keep;
}

/// circlemedia: turn the preview's choice into outbox jobs. Two or more
/// items share one album id (inside each E2E descriptor); the caption and
/// the reply ride on the first item. Photo rotate / HD-or-Standard work is
/// left to the outbox (background isolate), so Send returns at once.
Future<List<MediaJob>> queueAlbumChoice(AlbumSendChoice c,
    {required String chatKind,
    required int chatId,
    String? replyTo,
    MediaOutbox? outbox}) async {
  final box = outbox ?? MediaOutbox.instance;
  final n = c.items.length;
  final albumId = n > 1 ? newAlbumId() : null;
  final stamp = newMediaId();
  final base = DateTime.now();
  final jobs = <MediaJob>[];
  for (var i = 0; i < n; i++) {
    final it = c.items[i];
    final d = it.draft;
    Map<String, dynamic>? prep;
    int? w = d.width, h = d.height;
    if (d.kind == 'photo') {
      final spec = photoPrepSpec(turns: it.turns, hd: c.hd);
      if (prepNeeded(spec, d.width, d.height)) {
        prep = spec;
        final s = preppedSize(d.width, d.height, turns: it.turns, hd: c.hd);
        if (s != null) {
          w = s.$1;
          h = s.$2;
        }
      }
    }
    jobs.add(MediaJob(
      id: n > 1 ? '$stamp-$i' : stamp,
      chatKind: chatKind,
      chatId: chatId,
      kind: d.kind,
      srcPath: d.path,
      name: d.name,
      mime: d.mime,
      plainSize: d.size,
      // a microsecond apart: the outbox keeps the album order
      at: base.add(Duration(microseconds: i)),
      width: w,
      height: h,
      durationMs: d.durationMs,
      thumbB64: c.viewOnce ? '' : d.thumbB64,
      caption: i == 0 ? c.caption.trim() : '',
      replyTo: i == 0 ? replyTo : null,
      viewOnce: c.viewOnce,
      album: albumId == null ? null : AlbumRef(id: albumId, index: i, count: n),
      prep: prep,
    ));
  }
  for (final j in jobs) {
    await box.add(j);
  }
  return jobs;
}
