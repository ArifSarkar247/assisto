import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../messaging/media/media_prep.dart';
import '../p3/p3_api.dart';
import '../p3/story_crypto.dart';
import '../p3/story_privacy_sheet.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;

/// Text backgrounds for a text story (white text on each is >= 4.5:1).
const List<Color> kStoryBgs = [
  Color(0xFF2347D9), // brand deep blue
  Color(0xFF6A2BC2), // purple
  Color(0xFF0F6E5A), // teal
  Color(0xFF8A2D3B), // maroon
  Color(0xFF1F2933), // charcoal
];

/// Compose a 24-hour story (owner P3): TEXT or PHOTO, end-to-end encrypted.
///
/// The text (or the photo's media descriptor, which carries the photo's
/// file key) is sealed ON THIS PHONE once per allowed viewer; a photo itself
/// is encrypted before upload through the existing E2E media path
/// (circle_media_blobs). The server only ever stores ciphertext and re-checks
/// the audience on every read. Video stories are not offered (no video
/// pipeline exists yet).
class CircleStatusComposerScreen extends StatefulWidget {
  final IdentityKeyPair identity;
  final List<Map<String, dynamic>> members;

  const CircleStatusComposerScreen({
    super.key,
    required this.identity,
    required this.members,
  });

  @override
  State<CircleStatusComposerScreen> createState() => _CircleStatusComposerScreenState();
}

class _CircleStatusComposerScreenState extends State<CircleStatusComposerScreen> {
  final _e2e = SoftwareE2E();
  final _text = TextEditingController();
  final _caption = TextEditingController();
  StoryPrivacy _privacy = StoryPrivacy.contacts;
  int _bg = 0;
  MediaDraft? _photo;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().api.privacyDefaults().then((d) {
      if (mounted) setState(() => _privacy = StoryPrivacy.fromJson(d['status']));
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _text.dispose();
    _caption.dispose();
    super.dispose();
  }

  int get _audienceN => audienceOf(widget.members, _privacy).length;

  Future<void> _pickAudience() async {
    final t = AppLocalizations.of(context);
    final p = await showStoryPrivacySheet(context,
        members: widget.members, initial: _privacy, title: t.p3PrivThisStory);
    if (p != null) setState(() => _privacy = p);
  }

  Future<void> _pickPhoto(bool camera) async {
    try {
      final d = await pickPhoto(context, camera: camera);
      if (d != null && mounted) setState(() => _photo = d);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).p3PhotoFailed)));
      }
    }
  }

  Future<void> _post({required bool photo}) async {
    final t = AppLocalizations.of(context);
    if (_posting) return;
    if (!photo && _text.text.trim().isEmpty) return;
    if (photo && _photo == null) return;
    setState(() => _posting = true);
    final app = context.read<AppState>();
    try {
      String plain;
      String blobRef = '';
      if (photo) {
        final desc = await uploadStoryPhoto(_photo!, caption: _caption.text.trim());
        plain = desc.encode();
        blobRef = desc.ref;
      } else {
        plain = StoryContent.encodeText(_text.text.trim(), _bg);
      }
      final per = sealForAudience(
        e2e: _e2e,
        me: widget.identity,
        myUserId: app.user?.id ?? -1,
        audience: audienceOf(widget.members, _privacy),
        plaintext: plain,
      );
      await app.api.postStory({
        'kind': photo ? 'photo' : 'text',
        'per_recipient': per,
        'scheme': _e2e.scheme,
        'sender_key_id': widget.identity.keyId,
        'visibility': _privacy.toJson(),
        if (blobRef.isNotEmpty) 'blob_ref': blobRef,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => _posting = false);
        // HONEST error: say the post failed and keep what was typed.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.statusPostFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.statusAdd),
          bottom: TabBar(tabs: [
            Tab(icon: const Icon(Icons.text_fields), child: Text(t.statusText, maxLines: 1, overflow: TextOverflow.ellipsis)),
            Tab(icon: const Icon(Icons.photo_outlined), child: Text(t.statusPhoto, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        body: TabBarView(children: [_textTab(t), _photoTab(t)]),
      ),
    );
  }

  Widget _footer(AppLocalizations t, {required bool photo, required bool enabled}) {
    final scheme = Theme.of(context).colorScheme;
    final n = notifLocalizeDigits(context, '$_audienceN');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Flexible(
            child: ActionChip(
              key: const ValueKey('p3-story-audience'),
              avatar: const Icon(Icons.lock_person_outlined, size: 18),
              label: Text(privacyLabel(t, _privacy, context), overflow: TextOverflow.ellipsis),
              onPressed: _pickAudience,
            ),
          ),
          const SizedBox(width: Gap.sm),
          FilledButton.icon(
            key: ValueKey(photo ? 'p3-story-post-photo' : 'p3-story-post-text'),
            onPressed: _posting || !enabled ? null : () => _post(photo: photo),
            icon: _posting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: Text(t.statusPost),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        Text(_audienceN == 0 ? t.p3AudienceNone : t.p3AudienceN(n),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xs),
        _note(Icons.schedule, t.statusExpiresIn24h, scheme),
        const SizedBox(height: Gap.xs),
        _note(Icons.lock_outline, t.p3StoriesE2e, scheme),
      ],
    );
  }

  Widget _textTab(AppLocalizations t) {
    final bg = kStoryBgs[_bg % kStoryBgs.length];
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.md)),
              padding: const EdgeInsets.all(Gap.lg),
              alignment: Alignment.center,
              child: TextField(
                key: const ValueKey('p3-story-text'),
                controller: _text,
                maxLines: null,
                maxLength: 700,
                textAlign: TextAlign.center,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white, fontSize: 22, height: 1.35),
                cursorColor: Colors.white,
                buildCounter: (ctx, {required currentLength, required isFocused, required maxLength}) =>
                    Text(notifLocalizeDigits(ctx, '$currentLength/${maxLength ?? ''}'),
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                decoration: InputDecoration(
                  hintText: t.statusTypeSomething,
                  hintStyle: const TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Row(children: [
            for (var i = 0; i < kStoryBgs.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: Gap.sm),
                child: InkWell(
                  onTap: () => setState(() => _bg = i),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: kStoryBgs[i],
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: i == _bg ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                          width: 2.5),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          _footer(t, photo: false, enabled: _text.text.trim().isNotEmpty),
        ],
      ),
    );
  }

  Widget _photoTab(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final p = _photo;
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: p == null
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.add_photo_alternate_outlined, size: 56, color: scheme.outline),
                      const SizedBox(height: Gap.md),
                      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, alignment: WrapAlignment.center, children: [
                        FilledButton.tonalIcon(
                            onPressed: () => _pickPhoto(false),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: Text(t.p3PickGallery)),
                        FilledButton.tonalIcon(
                            onPressed: () => _pickPhoto(true),
                            icon: const Icon(Icons.photo_camera_outlined),
                            label: Text(t.p3PickCamera)),
                      ]),
                    ]),
                  )
                : Stack(fit: StackFit.expand, children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.md),
                      child: Image.file(File(p.path), fit: BoxFit.contain),
                    ),
                    Positioned(
                      top: Gap.sm,
                      right: Gap.sm,
                      child: IconButton.filledTonal(
                        tooltip: t.p3RemovePhoto,
                        onPressed: () => setState(() => _photo = null),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ]),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _caption,
            maxLength: 200,
            decoration: InputDecoration(hintText: t.p3CaptionHint, border: const OutlineInputBorder()),
          ),
          _footer(t, photo: true, enabled: p != null),
        ],
      ),
    );
  }

  Widget _note(IconData icon, String text, ColorScheme scheme) => Row(children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, height: 1.3)),
        ),
      ]);
}
