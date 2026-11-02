import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../services/review_prompt.dart';
import '../theme.dart';
import 'app_sheet.dart';
import 'wrapped_share.dart';
import 'local_counter.dart';

/// REUSABLE success sharing (owner 2 Nov) — first for "missing person FOUND",
/// next for the blood-donor "blood found" flow. Opened ONLY after the person
/// agreed to share. Gives:
///  * a ready thank-you text the caller passes (editable), "Copy text" + the
///    hint to paste it on Facebook;
///  * "Share image card": a rendered card (brand gradient) with that text and
///    the Assisto link — NO photo unless the person adds one from their own
///    phone (for a child the caller passes a warning line);
///  * then, after a copy/share, the Google Play In-App Review card
///    ([ReviewPrompt]: lazy, crash-guarded, never "do you like the app?"
///    first, never a reward). No rewards for posts or reviews anywhere here.
///
/// Usage: `Navigator.push(context, MaterialPageRoute(builder: (_) =>
///   SuccessShareScreen(title: ..., initialText: ..., cardHeadline: ...)))`.
class SuccessShareScreen extends StatefulWidget {
  const SuccessShareScreen({
    super.key,
    required this.title,
    required this.initialText,
    required this.cardHeadline,
    this.link = 'https://lifeassisto.com',
    this.allowPhoto = true,
    this.photoWarning,
    this.askReview = true,
    this.pickPhoto,
    this.shareImage,
  });

  final String title;
  final String initialText;
  final String cardHeadline;
  final String link;
  final bool allowPhoto;

  /// Shown under "Add a photo" (e.g. a child's photo stays off by default).
  final String? photoWarning;
  final bool askReview;

  /// Test seams.
  final Future<Uint8List?> Function()? pickPhoto;
  final Future<bool> Function(GlobalKey key, String caption)? shareImage;

  @override
  State<SuccessShareScreen> createState() => _SuccessShareScreenState();
}

class _SuccessShareScreenState extends State<SuccessShareScreen> {
  late final TextEditingController _text;
  final GlobalKey _card = GlobalKey();
  Uint8List? _photo;
  bool _shared = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    var t = widget.initialText.trim();
    if (!t.contains(widget.link)) t = '$t\n${widget.link}';
    _text = TextEditingController(text: t);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _copy() async {
    final t = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: _text.text));
    _shared = true;
    if (mounted) _snack(t.ssCopied);
  }

  Future<void> _shareCard() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    bool ok = false;
    try {
      ok = await (widget.shareImage ?? _defaultShareImage)(_card, _text.text);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _shared = true;
    } else {
      await Clipboard.setData(ClipboardData(text: _text.text));
      _shared = true;
      if (mounted) _snack(t.ssShareFailed);
    }
  }

  static Future<bool> _defaultShareImage(GlobalKey key, String caption) async {
    final f = await WrappedShare.captureToFile(key, fileName: 'assisto_thanks.png');
    if (f == null) return false;
    await Share.shareXFiles([XFile(f.path)], text: caption);
    return true;
  }

  Future<void> _addPhoto() async {
    Uint8List? bytes;
    try {
      if (widget.pickPhoto != null) {
        bytes = await widget.pickPhoto!();
      } else {
        final x = await ImagePicker()
            .pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 80);
        bytes = x == null ? null : await x.readAsBytes();
      }
    } catch (_) {
      bytes = null;
    }
    if (!mounted || bytes == null) return;
    setState(() => _photo = bytes);
  }

  Future<void> _done() async {
    final nav = Navigator.of(context);
    if (_shared && widget.askReview) {
      unawaited(ReviewPrompt.maybeAsk());
    }
    if (nav.canPop()) nav.pop(_shared);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
        children: [
          Text(t.ssNoReward, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('ss-text'),
            controller: _text,
            minLines: 4,
            maxLines: 10,
            maxLength: 1200,
            buildCounter: localCounter,
            decoration: InputDecoration(
              labelText: t.ssEditLabel,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gap.sm),
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
            child: FilledButton.icon(
              key: const ValueKey('ss-copy'),
              onPressed: _copy,
              icon: const Icon(Icons.copy_rounded),
              label: Text(t.ssCopy),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(t.ssPasteHint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Gap.xl),
          Text(t.ssPreview, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Gap.sm),
          Center(
            child: RepaintBoundary(
              key: _card,
              child: SuccessShareCard(
                headline: widget.cardHeadline,
                text: _text.text,
                link: widget.link,
                photo: _photo,
              ),
            ),
          ),
          const SizedBox(height: Gap.md),
          if (widget.allowPhoto) ...[
            if (_photo == null)
              OutlinedButton.icon(
                key: const ValueKey('ss-add-photo'),
                onPressed: _addPhoto,
                icon: const Icon(Icons.add_photo_alternate_rounded),
                label: Text(t.ssAddPhoto),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('ss-remove-photo'),
                onPressed: () => setState(() => _photo = null),
                icon: const Icon(Icons.hide_image_rounded),
                label: Text(t.ssRemovePhoto),
              ),
            const SizedBox(height: Gap.xs),
            Text(widget.photoWarning ?? t.ssNoPhotoDefault,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
          ],
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
            child: FilledButton.tonalIcon(
              key: const ValueKey('ss-share-card'),
              onPressed: _busy ? null : _shareCard,
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share_rounded),
              label: Text(t.ssShareCard),
            ),
          ),
          const SizedBox(height: Gap.lg),
          TextButton(
            key: const ValueKey('ss-done'),
            onPressed: _done,
            child: Text(t.ssDone),
          ),
        ],
      ),
    );
  }
}

/// The image card (fixed 340 logical px, captured at 3x). Fixed colours so
/// it looks the same in light and dark. Photo only when the person added one.
class SuccessShareCard extends StatelessWidget {
  const SuccessShareCard({
    super.key,
    required this.headline,
    required this.text,
    required this.link,
    this.photo,
  });

  final String headline;
  final String text;
  final String link;
  final Uint8List? photo;

  static String clip(String s, {int max = 420}) {
    final t = s.trim();
    return t.length <= max ? t : '${t.substring(0, max).trimRight()}…';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    const white = Colors.white;
    final body = clip(text.replaceAll(link, '').trim());
    return MediaQuery.withNoTextScaling(
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.xl),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Brand.cyan, Brand.blue, Brand.purple],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.favorite_rounded, color: white, size: 22),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(headline,
                    style: const TextStyle(
                        color: white, fontSize: 20, fontWeight: FontWeight.w800, height: 1.25)),
              ),
            ]),
            if (photo != null) ...[
              const SizedBox(height: Gap.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.md),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.memory(photo!, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                ),
              ),
            ],
            const SizedBox(height: Gap.md),
            Text(body, style: const TextStyle(color: white, fontSize: 15, height: 1.4)),
            const SizedBox(height: Gap.lg),
            Text(t.ssFooter(link),
                style: const TextStyle(color: white, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
