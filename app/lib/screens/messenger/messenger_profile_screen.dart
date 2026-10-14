import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_avatar.dart';

/// The Messenger profile — photo (change / remove via image_picker), display
/// name, about/bio, phone, and privacy (who can see the phone, who can message
/// in communities). Reads `/me`, writes via the core typed PATCH /me.
///
/// ORIGINAL identity: Assisto gradient header, our own icons/wording.
class MessengerProfileScreen extends StatefulWidget {
  const MessengerProfileScreen({super.key});

  @override
  State<MessengerProfileScreen> createState() =>
      _MessengerProfileScreenState();
}

class _MessengerProfileScreenState extends State<MessengerProfileScreen> {
  final _name = TextEditingController();
  final _about = TextEditingController();
  final _picker = ImagePicker();

  bool _loading = true;
  bool _saving = false;
  String _phone = '';
  String? _photoB64; // new/removed photo (null = untouched, '' = removed)
  String _existingPhoto = '';
  String _phoneVisibility = 'circle'; // circle | family | nobody
  String _communitiesWhoCanMsg = 'circle';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    try {
      final me = await _api.messengerProfile();
      _name.text = '${me['name'] ?? ''}';
      _about.text = '${me['bio'] ?? me['about'] ?? ''}';
      _phone = '${me['phone'] ?? ''}';
      _existingPhoto = '${me['photo_link'] ?? me['photo'] ?? ''}';
      _phoneVisibility = _norm('${me['show_phone'] ?? 'circle'}');
      _communitiesWhoCanMsg =
          _norm('${me['communities_who_can_msg'] ?? 'circle'}');
    } catch (_) {
      // Fall back to the cached user.
      final u = context.read<AppState>().user;
      _name.text = u?.name ?? '';
      _phone = u?.phone ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  String _norm(String v) {
    if (v == 'everyone' || v == 'circle' || v == 'true') return 'circle';
    if (v == 'family') return 'family';
    if (v == 'nobody' || v == 'none' || v == 'false') return 'nobody';
    return 'circle';
  }

  String get _currentPhoto =>
      _photoB64 ?? _existingPhoto; // '' means removed

  Future<void> _changePhoto() async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(_t.msgrTakePhoto),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(_t.msgrPickFromGallery),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
          if (_currentPhoto.isNotEmpty)
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text(_t.msgrRemovePhoto,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, null),
            ),
        ]),
      ),
    );
    if (src == null) {
      // Remove photo path (only when the sheet's remove row was tapped).
      setState(() {
        _photoB64 = '';
      });
      return;
    }
    // Crop/resize via the picker's maxWidth/quality (a lightweight square crop
    // without an extra plugin): request a modest square source.
    final x = await _picker.pickImage(
        source: src, maxWidth: 512, maxHeight: 512, imageQuality: 85);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _photoB64 = base64Encode(bytes));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final fields = <String, dynamic>{
      'name': _name.text.trim(),
      'bio': _about.text.trim(),
      'show_phone': _phoneVisibility,
      'communities_who_can_msg': _communitiesWhoCanMsg,
    };
    if (_photoB64 != null) {
      // '' removes the photo; a base64 string sets a new one.
      fields['photo'] = _photoB64;
    }
    try {
      await _api.updateProfile(fields);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t.msgrProfileSaved)));
      Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t.msgrProfileSaveFailed)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrProfileTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
              children: [
                // ---- photo ----
                Center(
                  child: Column(children: [
                    Stack(children: [
                      MsgrAvatar(
                          name: _name.text,
                          photoUrl: _currentPhoto,
                          radius: 52),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Material(
                          color: scheme.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _changePhoto,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(Icons.photo_camera_outlined,
                                  size: 18, color: scheme.onPrimary),
                            ),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: Gap.sm),
                    TextButton(
                        onPressed: _changePhoto,
                        child: Text(t.msgrChangePhoto)),
                  ]),
                ),
                const SizedBox(height: Gap.md),
                // ---- name ----
                Text(t.msgrDisplayName,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(hintText: t.msgrDisplayName),
                ),
                const SizedBox(height: Gap.lg),
                // ---- about ----
                Text(t.msgrAbout,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                TextField(
                  controller: _about,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 140,
                  decoration: InputDecoration(hintText: t.msgrAboutHint),
                ),
                const SizedBox(height: Gap.sm),
                // ---- phone ----
                if (_phone.isNotEmpty) ...[
                  Text(t.msgrPhone,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.xs),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.phone_outlined,
                        color: scheme.onSurfaceVariant),
                    title: Text(_phone),
                  ),
                  const SizedBox(height: Gap.sm),
                ],
                // ---- privacy ----
                Text(t.msgrPhoneVisibility,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                _visibilityPicker(
                    _phoneVisibility, (v) => setState(() => _phoneVisibility = v)),
                const SizedBox(height: Gap.lg),
                Text(t.msgrWhoCanMessage,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                _visibilityPicker(_communitiesWhoCanMsg,
                    (v) => setState(() => _communitiesWhoCanMsg = v)),
                const SizedBox(height: Gap.xl),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.msgrSaveProfile),
                ),
              ],
            ),
    );
  }

  Widget _visibilityPicker(String value, ValueChanged<String> onChanged) {
    final t = _t;
    final opts = <(String, String)>[
      ('circle', t.msgrVisibilityEveryone),
      ('family', t.msgrVisibilityFamily),
      ('nobody', t.msgrVisibilityNobody),
    ];
    return Wrap(
      spacing: Gap.sm,
      children: [
        for (final o in opts)
          ChoiceChip(
            label: Text(o.$2),
            selected: value == o.$1,
            onSelected: (_) => onChanged(o.$1),
          ),
      ],
    );
  }
}
