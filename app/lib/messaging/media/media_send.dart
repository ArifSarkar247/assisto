import 'dart:io';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/circle_attach_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_descriptor.dart';
import 'media_outbox.dart';
import 'media_prep.dart';
import 'voice_recorder_sheet.dart';

/// md1 — the chat side of sending media: pick → (preview + caption) →
/// queue in the persistent media outbox. Shared by 1:1 and group chats.

/// Content types that carry an E2E media descriptor.
const Set<String> kMd1Kinds = {'photo', 'voice', 'document'};

/// "Photo" / "Voice message" / the document's name — for reply quotes.
String md1KindLabel(AppLocalizations t, MediaDescriptor d) => switch (d.kind) {
      'photo' => t.circlePhoto,
      'voice' => t.circleVoiceNote,
      _ => d.name.isEmpty ? t.circleAttachDocument : d.name,
    };

/// The owner-editable per-file caps (admin pricing limits), fetched once per
/// app run from GET /circle/media/limits; safe defaults until then.
class MediaLimits {
  MediaLimits._();
  static const int _mb = 1024 * 1024;
  static int photo = 16 * _mb, voice = 16 * _mb, document = 25 * _mb;
  static bool _loaded = false;

  static Future<void> load(ApiClient api) async {
    if (_loaded) return;
    try {
      final r = await api.getJson('/circle/media/limits');
      int v(String k, int d) => (r[k] as num?)?.toInt() ?? d;
      photo = v('photo_max_bytes', photo);
      voice = v('voice_max_bytes', voice);
      document = v('doc_max_bytes', document);
      _loaded = true;
    } catch (e) {
      reportNonFatal('md1_limits', e); // defaults stay; the server re-checks
    }
  }

  static int of(String kind) =>
      kind == 'photo' ? photo : kind == 'voice' ? voice : document;
}

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

/// Run the picker for [kind]. null = cancelled (or an honest message shown).
Future<MediaDraft?> pickMediaDraft(
    BuildContext context, ApiClient api, CircleAttachKind kind) async {
  final t = AppLocalizations.of(context);
  await MediaLimits.load(api);
  if (!context.mounted) return null;
  try {
    final MediaDraft? d;
    switch (kind) {
      case CircleAttachKind.gallery:
        d = await pickPhoto(context, camera: false);
      case CircleAttachKind.camera:
        d = await pickPhoto(context, camera: true);
      case CircleAttachKind.voice:
        d = await showVoiceRecorder(context);
      case CircleAttachKind.document:
        d = await pickDocument(MediaLimits.document);
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
              ? t.md1TooBig(notifLocalizeDigits(context, '${MediaLimits.document ~/ (1024 * 1024)}'))
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
        builder: (_) => PhotoSendPreview(draft: d, allowViewOnce: chatKind == 'member')));
    if (c == null) {
      _deleteQuietly(d.path);
      return null;
    }
    caption = c.caption;
    viewOnce = c.viewOnce;
  } else if (d.kind == 'document') {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = AppLocalizations.of(ctx);
        return AlertDialog(
          title: Text(t.md1DocSendTitle),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
            Text(t.md1DocSendBody(notifLocalizeDigits(ctx, mediaSizeLabel(d.size)))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.md1Cancel)),
            FilledButton(
                key: const Key('md1-doc-send'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.md1Send)),
          ],
        );
      },
    );
    if (ok != true) {
      _deleteQuietly(d.path);
      return null;
    }
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
    thumbB64: viewOnce ? '' : d.thumbB64,
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
  const PhotoSendPreview({super.key, required this.draft, this.allowViewOnce = false});
  @override
  State<PhotoSendPreview> createState() => _PhotoSendPreviewState();
}

class _PhotoSendPreviewState extends State<PhotoSendPreview> {
  final _caption = TextEditingController();
  bool _viewOnce = false;

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
          icon: const Icon(Icons.close),
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
                      const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 64)),
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
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: t.md1CaptionHint,
                    hintStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Colors.white12,
                    border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(Radii.pill)),
                        borderSide: BorderSide.none),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
                  ),
                ),
              ),
              if (widget.allowViewOnce) ...[
                const SizedBox(width: Gap.xs),
                Tooltip(
                  message: _viewOnce ? t.eVoOnHint : t.eVoToggle,
                  child: Semantics(
                    button: true,
                    toggled: _viewOnce,
                    label: t.eVoToggle,
                    child: InkWell(
                      key: const Key('e-vo-toggle'),
                      customBorder: const CircleBorder(),
                      onTap: () {
                        setState(() => _viewOnce = !_viewOnce);
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                            duration: const Duration(seconds: 2),
                            content: Text(_viewOnce ? t.eVoOnHint : t.eVoOffHint)));
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _viewOnce ? Colors.white : Colors.white12,
                        ),
                        child: Text('1',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: _viewOnce ? Colors.black : Colors.white)),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: Gap.sm),
              IconButton.filled(
                key: const Key('md1-photo-send'),
                tooltip: t.md1Send,
                onPressed: () => Navigator.pop(
                    context, PhotoSendChoice(_caption.text, viewOnce: _viewOnce)),
                icon: const Icon(Icons.send),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
